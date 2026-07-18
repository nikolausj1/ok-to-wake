#!/usr/bin/env python3
"""Turn a steady ambience recording (rain, ocean, birdsong from ElevenLabs)
into a seamless loop (Phase 6, PRD Section 8 "Bundled content").

Technique: equal-power crossfade of the tail into the head. After trimming a
little off both ends (generators sometimes add tiny fades), the last XF
seconds are overlaid onto the first XF seconds with sin/cos gains, then the
tail is dropped. The loop end now flows into the loop start through the same
material, so there is no discontinuity at the seam by construction.

Verification: prints RMS in 250 ms windows straddling the loop join (end ->
start) against windows from the middle of the file, plus the seam sample step
vs the interior maximum step. Loudness is normalized to a target RMS.

Usage:
  python3 Tools/loopify.py in.wav out.wav [--xfade 2.5] [--trim 0.4]
                                          [--rms 0.11] [--peak 0.9]
Input must be WAV (any rate/channels via prior afconvert; this script expects
16-bit PCM mono or stereo and mixes stereo to mono for bundle consistency).
"""

import argparse
import math
import sys
import wave

import numpy as np

SAMPLE_RATE = 44100


def read_wav_mono(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, "expected 16-bit PCM (afconvert -d LEI16 first)"
        rate = w.getframerate()
        assert rate == SAMPLE_RATE, f"expected {SAMPLE_RATE} Hz, got {rate} (resample with afconvert)"
        frames = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
        ch = w.getnchannels()
    x = frames.astype(np.float64) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x


def write_wav_mono(path, samples):
    ints = np.clip(np.round(samples * 32767), -32767, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(ints.tobytes())


def rms(chunk):
    return math.sqrt(float(np.mean(chunk * chunk)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--xfade", type=float, default=2.5, help="crossfade seconds")
    ap.add_argument("--trim", type=float, default=0.4, help="seconds trimmed from each end first")
    ap.add_argument("--rms", type=float, default=0.11, help="target RMS after normalization")
    ap.add_argument("--peak", type=float, default=0.9, help="peak ceiling")
    ap.add_argument("--knee", type=float, default=0.55,
                    help="xfade mode: soft-limiter knee (samples above this are tanh-curved toward --peak)")
    ap.add_argument("--mode", choices=["xfade", "edges"], default="xfade",
                    help="xfade: seamless ambience loop; edges: event sound "
                         "(birdsong/chime style) - fade both edges to silence "
                         "so the loop repeats as sound ... pause ... sound")
    ap.add_argument("--edge-fade", type=float, default=0.6,
                    help="edges mode: fade length in seconds at each end")
    args = ap.parse_args()

    x = read_wav_mono(args.infile)
    trim = int(args.trim * SAMPLE_RATE)
    x = x[trim: len(x) - trim]

    if args.mode == "edges":
        ef = int(args.edge_fade * SAMPLE_RATE)
        y = x.copy()
        ramp = 0.5 - 0.5 * np.cos(math.pi * np.arange(ef) / ef)
        y[:ef] *= ramp
        y[-ef:] *= ramp[::-1]
        gain = min(args.peak / np.max(np.abs(y)), args.rms / rms(y))
        y *= gain
        print(f"  edges: {len(y) / SAMPLE_RATE:.2f}s, RMS {rms(y):.4f}, "
              f"peak {np.max(np.abs(y)):.3f}, start {y[0]:.6f}, end {y[-1]:.6f}")
        write_wav_mono(args.outfile, y)
        print(f"  wrote {args.outfile}")
        return

    xf = int(args.xfade * SAMPLE_RATE)
    if xf * 3 > len(x):
        sys.exit("crossfade too long for the material")

    # Equal-power crossfade: head ramps in (sin), tail ramps out (cos).
    t = np.arange(xf) / xf
    g_in = np.sin(0.5 * math.pi * t)
    g_out = np.cos(0.5 * math.pi * t)
    y = x[: len(x) - xf].copy()
    y[:xf] = x[:xf] * g_in + x[len(x) - xf:] * g_out

    # Normalize loudness. Sparse transients (individual rain drops) can have a
    # huge crest factor; rather than letting one-in-70k-sample peaks force the
    # whole loop quieter than the other noise loops, soft-limit just those
    # peaks (tanh knee above --knee, ceiling --peak) after gaining to target.
    y *= args.rms / rms(y)
    knee = args.knee
    over = np.abs(y) > knee
    if np.any(over):
        span = args.peak - knee
        y[over] = np.sign(y[over]) * (knee + span * np.tanh((np.abs(y[over]) - knee) / span))
        print(f"  soft-limited {np.mean(over) * 100:.3f}% of samples above {knee}")
    y *= args.rms / rms(y)   # re-trim RMS (limiting changes it negligibly)

    # --- Seam verification: play the join virtually and measure around it ---
    n = len(y)
    win = int(0.25 * SAMPLE_RATE)
    joined = np.concatenate([y[-2 * win:], y[: 2 * win]])   # end -> start, join at center
    join_windows = [rms(joined[i * win:(i + 1) * win]) for i in range(4)]
    mid = n // 2
    interior = [rms(y[mid + i * win: mid + (i + 1) * win]) for i in range(-2, 2)]
    seam_step = abs(y[0] - y[-1])
    max_step = float(np.max(np.abs(np.diff(y))))
    print(f"  loop: {n / SAMPLE_RATE:.2f}s, RMS {rms(y):.4f}, peak {np.max(np.abs(y)):.3f}")
    print(f"  RMS 250ms windows across the join (end,end,start,start): "
          + ", ".join(f"{v:.4f}" for v in join_windows))
    print(f"  RMS 250ms windows mid-file for comparison:               "
          + ", ".join(f"{v:.4f}" for v in interior))
    print(f"  seam sample step {seam_step:.4f} vs interior max step {max_step:.4f}")
    spread = max(join_windows) / max(min(join_windows), 1e-9)
    print(f"  join loudness spread x{spread:.3f} (1.0 = perfectly steady)")

    write_wav_mono(args.outfile, y)
    print(f"  wrote {args.outfile}")


if __name__ == "__main__":
    main()
