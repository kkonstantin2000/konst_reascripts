#!/usr/bin/env python3
"""
konst_transient_detect.py — High-precision transient detection for drum audio.

Detects transients in a drum audio stem with sub-frame accuracy using:
  - Harmonic-percussive separation to isolate drum attacks
  - High-resolution onset detection (hop_length=128 ≈ 2.9ms at 44.1kHz)
  - Per-band analysis: low (kick), mid (snare/toms), high (hi-hat/cymbals)
  - Onset backtracking for precise attack onset positioning
  - Onset strength output for confidence-based matching

Usage:
    python konst_transient_detect.py <audio_file> <output_json> [start_offset] [duration]

Output JSON:
    {
      "sample_rate": 44100,
      "hop_length": 128,
      "duration": 12.5,
      "transients": [
        {"time": 0.123, "strength": 0.85},
        ...
      ],
      "transients_low":  [{"time": ..., "strength": ...}, ...],
      "transients_mid":  [{"time": ..., "strength": ...}, ...],
      "transients_high": [{"time": ..., "strength": ...}, ...]
    }

Dependencies: pip install librosa numpy soundfile
"""

import sys
import os
import json
import traceback


def detect_transients(audio_path, start_offset=0.0, duration=None):
    import numpy as np
    import librosa

    SR = 44100
    HOP = 128          # ~2.9ms per frame — high temporal resolution
    N_FFT = 2048
    N_MELS = 128

    # ── Load audio ──────────────────────────────────────────────────────
    y, sr = librosa.load(audio_path, sr=SR, mono=True,
                         offset=start_offset, duration=duration)

    if len(y) == 0:
        raise ValueError("Audio file is empty or could not be loaded")

    actual_duration = len(y) / sr

    # ── Harmonic-percussive separation ──────────────────────────────────
    # margin=3.0 gives cleaner percussive isolation
    y_harm, y_perc = librosa.effects.hpss(y, margin=3.0)

    # ── Full-band transient detection ───────────────────────────────────
    # Use the percussive component for cleaner onset detection
    onset_env = librosa.onset.onset_strength(
        y=y_perc, sr=sr, hop_length=HOP, n_fft=N_FFT,
        aggregate=np.median  # median across frequency bands — robust to noise
    )

    # Normalize envelope
    env_max = float(onset_env.max()) if onset_env.max() > 0 else 1.0

    # Peak-pick with backtracking for precise attack onset
    onset_frames = librosa.onset.onset_detect(
        onset_envelope=onset_env, sr=sr, hop_length=HOP,
        backtrack=True,     # find actual start of attack, not peak
        normalize=True,
        units='frames'
    )

    # Build full-band transient list with strength values
    transients_all = []
    for f in onset_frames:
        t = float(librosa.frames_to_time(f, sr=sr, hop_length=HOP))
        s = float(onset_env[f]) / env_max if f < len(onset_env) else 0.0
        transients_all.append({'time': round(t, 6), 'strength': round(s, 4)})

    # ── Per-band transient detection (for smart matching) ───────────────
    S = librosa.feature.melspectrogram(
        y=y_perc, sr=sr, n_mels=N_MELS, n_fft=N_FFT,
        hop_length=HOP, fmax=sr // 2
    )
    S_db = librosa.power_to_db(S, ref=np.max)

    mel_freqs = librosa.mel_frequencies(n_mels=N_MELS, fmax=sr // 2)

    # Band boundaries
    low_end = int(np.searchsorted(mel_freqs, 250))     # 0–250 Hz   → kick
    mid_end = int(np.searchsorted(mel_freqs, 4000))    # 250–4 kHz  → snare/toms
    # 4 kHz+   → hi-hat/cymbal

    low_S  = S_db[:low_end, :]
    mid_S  = S_db[low_end:mid_end, :]
    high_S = S_db[mid_end:, :]

    def detect_band(band_S, label):
        """Detect transients in a single frequency band."""
        env = librosa.onset.onset_strength(
            S=band_S, sr=sr, hop_length=HOP,
            aggregate=np.median
        )
        e_max = float(env.max()) if env.max() > 0 else 1.0

        frames = librosa.onset.onset_detect(
            onset_envelope=env, sr=sr, hop_length=HOP,
            backtrack=True,
            normalize=True,
            units='frames'
        )

        result = []
        for f in frames:
            t = float(librosa.frames_to_time(f, sr=sr, hop_length=HOP))
            s = float(env[f]) / e_max if f < len(env) else 0.0
            result.append({'time': round(t, 6), 'strength': round(s, 4)})
        return result

    transients_low  = detect_band(low_S, 'low')
    transients_mid  = detect_band(mid_S, 'mid')
    transients_high = detect_band(high_S, 'high')

    # ── Refine timing using energy envelope ─────────────────────────────
    # For each detected transient, search for the exact sample where
    # energy starts rising sharply — gives sub-frame precision.

    def refine_onset_time(t_approx, y_signal, sr_val, window_ms=5.0):
        """
        Refine onset time by finding the energy rise point
        in a small window around the approximate onset.
        Uses a short-term energy envelope at sample resolution.
        """
        window_samples = int(sr_val * window_ms / 1000.0)
        center_sample = int(t_approx * sr_val)

        search_start = max(0, center_sample - window_samples)
        search_end = min(len(y_signal), center_sample + window_samples)

        if search_end <= search_start:
            return t_approx

        segment = y_signal[search_start:search_end]

        # Compute short-term energy with very small window (32 samples ≈ 0.7ms)
        energy_win = 32
        if len(segment) < energy_win * 2:
            return t_approx

        energy = np.array([
            np.sum(segment[i:i + energy_win] ** 2)
            for i in range(len(segment) - energy_win)
        ])

        if len(energy) < 2:
            return t_approx

        # Find the point of maximum energy increase (steepest rise)
        energy_diff = np.diff(energy)
        if len(energy_diff) == 0:
            return t_approx

        rise_point = int(np.argmax(energy_diff))
        refined_sample = search_start + rise_point

        return round(refined_sample / sr_val, 6)

    # Refine all transients
    for t_list in [transients_all, transients_low, transients_mid, transients_high]:
        for entry in t_list:
            entry['time'] = refine_onset_time(entry['time'], y_perc, sr)

    # ── Remove duplicates within 3ms after refinement ───────────────────
    def deduplicate(t_list, min_gap=0.003):
        if not t_list:
            return t_list
        t_list.sort(key=lambda x: x['time'])
        result = [t_list[0]]
        for i in range(1, len(t_list)):
            if t_list[i]['time'] - result[-1]['time'] >= min_gap:
                result.append(t_list[i])
            else:
                # Keep the stronger one
                if t_list[i]['strength'] > result[-1]['strength']:
                    result[-1] = t_list[i]
        return result

    transients_all  = deduplicate(transients_all)
    transients_low  = deduplicate(transients_low)
    transients_mid  = deduplicate(transients_mid)
    transients_high = deduplicate(transients_high)

    return {
        'sample_rate':     SR,
        'hop_length':      HOP,
        'duration':        round(actual_duration, 6),
        'transient_count': len(transients_all),
        'transients':      transients_all,
        'transients_low':  transients_low,
        'transients_mid':  transients_mid,
        'transients_high': transients_high,
    }


# ═══════════════════════════════════════════════════════════════════════
def main():
    if len(sys.argv) < 3:
        print("Usage: python konst_transient_detect.py <audio_file> <output_json> "
              "[start_offset] [duration]")
        sys.exit(1)

    audio_path   = sys.argv[1]
    output_path  = sys.argv[2]
    start_offset = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    duration     = float(sys.argv[4]) if len(sys.argv) > 4 else None
    if duration is not None and duration <= 0:
        duration = None

    if not os.path.exists(audio_path):
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    result = detect_transients(audio_path, start_offset, duration)

    # Write atomically: tmp → rename
    tmp_path = output_path + ".tmp"
    with open(tmp_path, 'w') as f:
        json.dump(result, f, indent=2)

    if os.path.exists(output_path):
        os.remove(output_path)
    os.rename(tmp_path, output_path)

    print(f"Detected {result['transient_count']} transients in {result['duration']:.2f}s "
          f"(low: {len(result['transients_low'])}, "
          f"mid: {len(result['transients_mid'])}, "
          f"high: {len(result['transients_high'])})")


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        err_path = sys.argv[2] + ".err" if len(sys.argv) > 2 else "transient_detect_error.txt"
        with open(err_path, 'w') as f:
            f.write(str(e) + "\n\n" + traceback.format_exc())
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
