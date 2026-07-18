#!/usr/bin/env python3
"""Design-time generator for the Phase 2 placeholder sounds (PRD Section 8,
"Bundled content"). Produces WAVs, then the caller converts them to CAF with
afconvert (linear PCM CAF: no encoder priming frames, so AVAudioPlayer's
numberOfLoops = -1 loops it gaplessly - AAC/m4a would add a seam).

  classicWhite.caf  45 s shaped white noise, loop-clean by construction:
                    white noise is memoryless, and the low-pass filter is run
                    circularly (warm-up pass over the whole buffer first), so
                    the filter state entering sample 0 equals the state leaving
                    the last sample - the seam is statistically identical to
                    any interior sample step. The script verifies this.
  gentleChime.caf   ~5 s soft synthesized three-note bell (C5 E5 G5), decaying
                    partials, silence tail. Looped as the alarm, it repeats as
                    chime ... pause ... chime.

Usage: python3 Tools/generate_placeholder_audio.py <output-dir>
Deterministic (fixed RNG seed) so regeneration is reproducible.
"""

import math
import random
import struct
import sys
import wave

SAMPLE_RATE = 44100


def write_wav(path, samples):
    """samples: list of floats in [-1, 1]; writes 16-bit mono WAV."""
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        ints = [max(-32767, min(32767, int(round(s * 32767)))) for s in samples]
        w.writeframes(struct.pack("<%dh" % len(ints), *ints))


def make_white_noise(seconds=45):
    n = SAMPLE_RATE * seconds
    rng = random.Random(20260718)
    white = [rng.uniform(-1.0, 1.0) for _ in range(n)]

    # One-pole low-pass (fc ~ 1.5 kHz) to soften the hiss toward a fan-like
    # "classic white". Run circularly: a full warm-up pass first, so the state
    # wraps and the loop seam is clean by construction.
    fc = 1500.0
    a = 1.0 - math.exp(-2.0 * math.pi * fc / SAMPLE_RATE)
    y = 0.0
    for x in white:            # warm-up pass (discarded output)
        y = a * x + (1.0 - a) * y
    lp = []
    for x in white:            # real pass, starting from the wrapped state
        y = a * x + (1.0 - a) * y
        lp.append(y)

    # Blend a little raw white back in for air, then normalize with headroom.
    mixed = [0.85 * l + 0.15 * w * 0.3 for l, w in zip(lp, white)]
    peak = max(abs(s) for s in mixed)
    gain = 0.5 / peak
    out = [s * gain for s in mixed]

    # Loop-cleanliness check: the step across the seam (last -> first) must be
    # no larger than the biggest step inside the file.
    interior_max_step = max(abs(out[i] - out[i - 1]) for i in range(1, len(out)))
    seam_step = abs(out[0] - out[-1])

    def rms(chunk):
        return math.sqrt(sum(s * s for s in chunk) / len(chunk))

    half_sec = SAMPLE_RATE // 2
    print(f"  noise: {seconds}s, peak {max(abs(s) for s in out):.3f}")
    print(f"  seam step {seam_step:.4f} vs interior max step {interior_max_step:.4f}")
    print(f"  RMS first 0.5s {rms(out[:half_sec]):.4f} vs last 0.5s {rms(out[-half_sec:]):.4f}")
    assert seam_step <= interior_max_step, "loop seam is an outlier step"
    return out


def make_gentle_chime():
    total = 5.0
    n = int(SAMPLE_RATE * total)
    out = [0.0] * n
    # C5, E5, G5 - a soft ascending pentatonic-ish motif.
    notes = [(0.0, 523.25), (0.65, 659.25), (1.3, 783.99)]
    # (harmonic multiple, amplitude, decay tau seconds)
    partials = [(1.0, 1.0, 1.4), (2.0, 0.35, 0.6), (3.0, 0.12, 0.3)]
    attack = 0.008
    for start, f0 in notes:
        s0 = int(start * SAMPLE_RATE)
        for i in range(s0, n):
            t = (i - s0) / SAMPLE_RATE
            env_a = 0.5 - 0.5 * math.cos(math.pi * min(t / attack, 1.0))  # click-free attack
            v = 0.0
            for mult, amp, tau in partials:
                v += amp * math.exp(-t / tau) * math.sin(2 * math.pi * f0 * mult * t)
            out[i] += env_a * v
    peak = max(abs(s) for s in out)
    gain = 0.4 / peak
    out = [s * gain for s in out]
    # Guarantee a silent, click-free tail (the loop restarts from silence).
    fade = int(0.05 * SAMPLE_RATE)
    for i in range(fade):
        out[n - fade + i] *= 1.0 - (i + 1) / fade
    print(f"  chime: {total}s, peak {max(abs(s) for s in out):.3f}, "
          f"end sample {out[-1]:.6f}, start sample {out[0]:.6f}")
    return out


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    print("generating classicWhite.wav")
    write_wav(f"{outdir}/classicWhite.wav", make_white_noise())
    print("generating gentleChime.wav")
    write_wav(f"{outdir}/gentleChime.wav", make_gentle_chime())
    print("done")


if __name__ == "__main__":
    main()
