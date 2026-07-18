#!/usr/bin/env python3
"""Design-time generator for the programmatic sound set (PRD Section 8,
"Bundled content"; Phase 6). Produces WAVs, then the caller converts them to
CAF with afconvert (linear PCM CAF: no encoder priming frames, so
AVAudioPlayer's numberOfLoops = -1 loops it gaplessly - AAC/m4a would add a
seam).

White noise loops (60 s each, loop-clean BY CONSTRUCTION):
  The noise colors are shaped in the frequency domain: white noise -> FFT ->
  multiply by the desired magnitude response -> inverse FFT. FFT filtering is
  circular convolution, so the filter state "wraps" perfectly and the loop
  seam is statistically identical to any interior sample step (same guarantee
  the old time-domain warm-up pass gave, exact instead of asymptotic). The
  script verifies the seam anyway.

  classicWhite.wav  shaped white: one-pole LP response at ~1.5 kHz plus a
                    little raw white blended back in for air (same voicing as
                    the Phase 2 placeholder, now 60 s and RMS-matched).
  brownNoise.wav    1/f amplitude slope (Brownian), flattened below 30 Hz and
                    an extra gentle LP - a deep, comforting rumble.
  pinkNoise.wav     1/sqrt(f) amplitude slope, flattened below 20 Hz, gentle
                    LP at ~6 kHz so the top end is soft, not hissy.

  All three are normalized to the same RMS so switching sounds in Settings
  doesn't jump in loudness.

Alarm sounds:
  gentleChime.wav    ~5 s soft synthesized three-note bell (C5 E5 G5),
                     decaying partials, silence tail (unchanged from Phase 2).
  playfulMelody.wav  ~4.5 s cheerful marimba-style pentatonic phrase with a
                     clean silent gap before the loop repeats.

Rain / ocean / birdsong come from ElevenLabs and are loop-treated by
Tools/loopify.py, not this script.

Usage: python3 Tools/generate_placeholder_audio.py <output-dir>
Deterministic (fixed RNG seeds) so regeneration is reproducible.
"""

import math
import sys
import wave

import numpy as np

SAMPLE_RATE = 44100
LOOP_SECONDS = 60
# Common loudness target for the noise loops (~ -19 dBFS RMS; peaks stay well
# under full scale for all three spectra).
NOISE_TARGET_RMS = 0.11


def write_wav(path, samples):
    """samples: float array in [-1, 1]; writes 16-bit mono WAV."""
    ints = np.clip(np.round(np.asarray(samples) * 32767), -32767, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(ints.tobytes())


def verify_loop(name, out):
    """Loop-cleanliness check: the step across the seam (last -> first) must be
    no larger than the biggest step inside the file, and loudness at the two
    ends must match."""
    steps = np.abs(np.diff(out))
    seam_step = abs(out[0] - out[-1])
    half = SAMPLE_RATE // 2

    def rms(chunk):
        return math.sqrt(float(np.mean(chunk * chunk)))

    print(f"  {name}: {len(out) / SAMPLE_RATE:.0f}s, peak {np.max(np.abs(out)):.3f}, "
          f"RMS {rms(out):.4f}")
    print(f"    seam step {seam_step:.4f} vs interior max step {steps.max():.4f}")
    print(f"    RMS first 0.5s {rms(out[:half]):.4f} vs last 0.5s {rms(out[-half:]):.4f}")
    assert seam_step <= steps.max(), f"{name}: loop seam is an outlier step"


def shaped_noise(magnitude_response, seed, seconds=LOOP_SECONDS):
    """White noise spectrally shaped by `magnitude_response(freqs) -> gains`,
    filtered circularly via the FFT so the loop seam is clean by construction.
    Returned at NOISE_TARGET_RMS."""
    n = SAMPLE_RATE * seconds
    rng = np.random.default_rng(seed)
    white = rng.uniform(-1.0, 1.0, n)
    spectrum = np.fft.rfft(white)
    freqs = np.fft.rfftfreq(n, d=1.0 / SAMPLE_RATE)
    gains = magnitude_response(freqs)
    gains[0] = 0.0          # no DC
    gains[-1] = 0.0         # no Nyquist bin
    out = np.fft.irfft(spectrum * gains, n)
    out *= NOISE_TARGET_RMS / math.sqrt(float(np.mean(out * out)))
    return out


def one_pole_lp(freqs, fc):
    """Magnitude response of a one-pole low-pass at fc."""
    return 1.0 / np.sqrt(1.0 + (freqs / fc) ** 2)


def make_classic_white():
    # Same voicing as the Phase 2 placeholder: one-pole LP at 1.5 kHz with a
    # touch of raw white blended back in for air.
    def response(freqs):
        return 0.85 * one_pole_lp(freqs, 1500.0) + 0.045
    return shaped_noise(response, seed=20260718)


def make_pink_noise():
    # 1/sqrt(f) amplitude (= 1/f power), flat below 20 Hz, softened top end.
    def response(freqs):
        f = np.maximum(freqs, 20.0)
        return (1.0 / np.sqrt(f)) * one_pole_lp(freqs, 6000.0)
    return shaped_noise(response, seed=20260719)


def make_brown_noise():
    # 1/f amplitude (= 1/f^2 power), flat below 30 Hz (iPad speakers do not
    # reproduce lower and it would only eat headroom), plus an extra gentle LP
    # so what little top end remains is velvety - a deep comforting rumble.
    def response(freqs):
        f = np.maximum(freqs, 30.0)
        return (30.0 / f) * one_pole_lp(freqs, 800.0)
    return shaped_noise(response, seed=20260720)


def make_gentle_chime():
    total = 5.0
    n = int(SAMPLE_RATE * total)
    out = np.zeros(n)
    t_all = np.arange(n) / SAMPLE_RATE
    # C5, E5, G5 - a soft ascending pentatonic-ish motif.
    notes = [(0.0, 523.25), (0.65, 659.25), (1.3, 783.99)]
    # (harmonic multiple, amplitude, decay tau seconds)
    partials = [(1.0, 1.0, 1.4), (2.0, 0.35, 0.6), (3.0, 0.12, 0.3)]
    attack = 0.008
    for start, f0 in notes:
        s0 = int(start * SAMPLE_RATE)
        t = t_all[: n - s0]
        env_a = 0.5 - 0.5 * np.cos(math.pi * np.minimum(t / attack, 1.0))  # click-free attack
        v = np.zeros(n - s0)
        for mult, amp, tau in partials:
            v += amp * np.exp(-t / tau) * np.sin(2 * math.pi * f0 * mult * t)
        out[s0:] += env_a * v
    out *= 0.4 / np.max(np.abs(out))
    # Guarantee a silent, click-free tail (the loop restarts from silence).
    fade = int(0.05 * SAMPLE_RATE)
    out[-fade:] *= 1.0 - np.arange(1, fade + 1) / fade
    print(f"  chime: {total}s, peak {np.max(np.abs(out)):.3f}, "
          f"end sample {out[-1]:.6f}, start sample {out[0]:.6f}")
    return out


def make_playful_melody():
    """Cheerful marimba-style phrase in C major pentatonic, then a quiet gap so
    the alarm loop repeats as melody ... pause ... melody."""
    total = 4.5
    n = int(SAMPLE_RATE * total)
    out = np.zeros(n)
    C5, D5, E5, G5, A5, C6 = 523.25, 587.33, 659.25, 783.99, 880.00, 1046.50
    beat = 0.21   # ~143 bpm eighth notes - playful, not frantic
    melody = [
        (0 * beat, C5, 1.0), (1 * beat, E5, 0.9), (2 * beat, G5, 0.95),
        (3 * beat, A5, 0.85), (4 * beat, G5, 0.9), (5 * beat, E5, 0.85),
        (6 * beat, G5, 0.9), (7.5 * beat, C6, 1.0),   # little skip into the top note
    ]
    # Marimba voicing: strong fundamental, the characteristic ~4x bar partial,
    # a whisper of a high partial; woody fast decay; soft mallet attack.
    partials = [(1.0, 1.0, 0.40), (3.9, 0.22, 0.10), (9.2, 0.05, 0.04)]
    attack = 0.004
    t_all = np.arange(n) / SAMPLE_RATE
    for start, f0, vel in melody:
        s0 = int(start * SAMPLE_RATE)
        t = t_all[: n - s0]
        env_a = 0.5 - 0.5 * np.cos(math.pi * np.minimum(t / attack, 1.0))
        v = np.zeros(n - s0)
        for mult, amp, tau in partials:
            v += amp * np.exp(-t / tau) * np.sin(2 * math.pi * f0 * mult * t)
        out[s0:] += vel * env_a * v
    out *= 0.45 / np.max(np.abs(out))
    # Clean silent gap before the loop repeats.
    fade = int(0.05 * SAMPLE_RATE)
    out[-fade:] *= 1.0 - np.arange(1, fade + 1) / fade
    print(f"  melody: {total}s, peak {np.max(np.abs(out)):.3f}, "
          f"end sample {out[-1]:.6f}, start sample {out[0]:.6f}")
    return out


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    for name, maker, is_loop in [
        ("classicWhite", make_classic_white, True),
        ("brownNoise", make_brown_noise, True),
        ("pinkNoise", make_pink_noise, True),
        ("gentleChime", make_gentle_chime, False),
        ("playfulMelody", make_playful_melody, False),
    ]:
        print(f"generating {name}.wav")
        samples = maker()
        if is_loop:
            verify_loop(name, samples)
        write_wav(f"{outdir}/{name}.wav", samples)
    print("done")


if __name__ == "__main__":
    main()
