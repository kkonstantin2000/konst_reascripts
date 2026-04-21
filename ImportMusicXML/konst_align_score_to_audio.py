#!/usr/bin/env python3
# @version 1.5.0
# @description Score-to-audio alignment helper for konst_Import MusicXML
# @author kkonstantin2000
"""
konst_align_score_to_audio.py — Align MusicXML score to audio.

Score-guided per-bar alignment using multi-band onset detection,
per-bar grid search with correct time signatures, and boundary
snapping for tight alignment with actual musical events.

Usage:
    python konst_align_score_to_audio.py <input_json> <output_json>

Input JSON:
    {
      "audio_path":  "C:/path/to/drums.wav",
      "score_onsets": [0.0, 0.5, 1.0, ...],
      "measure_boundaries": [
        {"measure": 1, "score_time": 0.0, "beats": 4, "beat_type": 4},
        ...
      ],
      "start_time": 3.45  // optional — audio-file-relative time of START marker
    }

Output JSON:
    {
      "aligned_boundaries": [
        {"measure": 1, "real_time": 3.45, "tempo": 122.5, "beats": 4, "beat_type": 4},
        ...
      ],
      "confidence": 0.85,
      "detected_tempo": 125.0,
      "offset": 3.45
    }

Dependencies: pip install librosa numpy scipy soundfile
"""

import sys
import os
import json
import traceback


def align_score_to_audio(audio_path, score_onsets, measure_boundaries,
                         start_time=None):
    import numpy as np
    import librosa
    from scipy.ndimage import gaussian_filter1d, median_filter
    from scipy.signal import fftconvolve

    # ── 1. Load audio ───────────────────────────────────────────────────
    y, sr = librosa.load(audio_path, sr=22050, mono=True)
    if len(y) == 0:
        raise ValueError("Audio file is empty or could not be loaded")

    dur = len(y) / sr
    print(f"Audio: {dur:.1f}s, sr={sr}")

    # ── 2. Dual envelope follower transient detection (sample-accurate) ──
    # Ported from konst_Detect tempo.lua — fast/slow envelope ratio method.
    # No STFT windowing delay, no backtracking: detects the exact sample
    # where the transient begins.

    threshold_dB   = -60    # absolute floor: ignore anything below this
    sensitivity_dB = 5      # fast/slow ratio threshold (dB) — lower = more sensitive
    retrig_ms      = 30     # minimum ms between consecutive detections

    threshold   = 10.0 ** (threshold_dB / 20.0)
    sensitivity = 10.0 ** (sensitivity_dB / 20.0)
    retrig_smp  = int(retrig_ms * sr / 1000.0)

    # Fast envelope: 1ms attack, 10ms release
    ga1 = np.exp(-1.0 / (sr * 0.001))
    gr1 = np.exp(-1.0 / (sr * 0.010))
    # Slow envelope: 7ms attack, 15ms release
    ga2 = np.exp(-1.0 / (sr * 0.007))
    gr2 = np.exp(-1.0 / (sr * 0.015))

    abs_y = np.abs(y).astype(np.float64)
    n_samples = len(abs_y)
    onset_times_list = []
    onset_str_list = []
    env1 = 0.0
    env2 = 0.0
    retrig_cnt = retrig_smp + 1  # start ready to trigger

    for i in range(n_samples):
        s = abs_y[i]
        # Fast envelope
        if s > env1:
            env1 = s + ga1 * (env1 - s)
        else:
            env1 = s + gr1 * (env1 - s)
        # Slow envelope
        if s > env2:
            env2 = s + ga2 * (env2 - s)
        else:
            env2 = s + gr2 * (env2 - s)
        # Detection: ratio exceeds sensitivity AND above absolute floor
        if retrig_cnt > retrig_smp and env1 > threshold and env2 > 0 and env1 / env2 > sensitivity:
            onset_times_list.append(i / sr)
            onset_str_list.append(env1)
            retrig_cnt = 0
        else:
            retrig_cnt += 1

    onset_times = np.array(onset_times_list, dtype=np.float64)
    onset_times_peak = onset_times.copy()  # same — no backtracking needed

    onset_strengths = np.array(onset_str_list, dtype=np.float64)
    if len(onset_strengths) > 0:
        mx = np.max(onset_strengths)
        if mx > 0:
            onset_strengths /= mx

    print(f"Detected {len(onset_times)} transients (dual envelope follower)")

    # ── 3. Estimate score tempo from measure boundaries ─────────────────
    bar_tempos_score = []
    for i in range(len(measure_boundaries) - 1):
        mb0, mb1 = measure_boundaries[i], measure_boundaries[i + 1]
        bar_dur = mb1['score_time'] - mb0['score_time']
        if bar_dur > 0.01:
            qn = mb0['beats'] * 4.0 / mb0['beat_type']
            bar_tempos_score.append(qn * 60.0 / bar_dur)
    score_tempo = float(np.median(bar_tempos_score)) if bar_tempos_score else 120.0
    print(f"Score tempo (median): {score_tempo:.1f} BPM")

    # ── 4. Beat tracking for global tempo + offset estimation ───────────
    tempo_raw, beat_frames_bt = librosa.beat.beat_track(
        y=y, sr=sr, start_bpm=score_tempo, units='frames')
    if hasattr(tempo_raw, '__len__'):
        detected_tempo = float(tempo_raw[0]) if len(tempo_raw) > 0 else score_tempo
    else:
        detected_tempo = float(tempo_raw)
    beat_times = librosa.frames_to_time(beat_frames_bt, sr=sr)

    ratio = detected_tempo / score_tempo if score_tempo > 0 else 1.0
    if 0.45 < ratio < 0.55:
        detected_tempo *= 2
    elif 1.8 < ratio < 2.2:
        detected_tempo /= 2
    elif 0.3 < ratio < 0.37:
        detected_tempo *= 3
    elif 2.7 < ratio < 3.3:
        detected_tempo /= 3

    detected_tempo = max(30.0, min(300.0, detected_tempo))
    tempo_ratio = detected_tempo / score_tempo if score_tempo > 0 else 1.0
    print(f"Detected tempo: {detected_tempo:.1f} BPM (ratio: {tempo_ratio:.3f})")

    if len(beat_times) >= 4:
        intervals = np.diff(beat_times)
        med_int = np.median(intervals)
        valid = intervals[(intervals > med_int * 0.5) & (intervals < med_int * 2.0)]
        if len(valid) > 2:
            refined = 60.0 / np.median(valid)
            if 0.9 < refined / detected_tempo < 1.1:
                detected_tempo = refined
                tempo_ratio = detected_tempo / score_tempo if score_tempo > 0 else 1.0
                print(f"Refined tempo: {detected_tempo:.2f} BPM")

    # ── 5. Find offset ──────────────────────────────────────────────────
    if start_time is not None:
        offset = float(start_time)
        if len(onset_times) > 0:
            dists = np.abs(onset_times - offset)
            nearest = int(np.argmin(dists))
            if dists[nearest] < 0.05:
                offset = float(onset_times[nearest])
        confidence = 1.0
        print(f"Using START marker offset: {offset:.3f}s")
    else:
        scaled_onsets = np.array(score_onsets) / tempo_ratio
        resolution = 0.005
        n_audio_bins = int(dur / resolution) + 1

        audio_pulse = np.zeros(n_audio_bins)
        for t in onset_times:
            idx = int(t / resolution)
            if 0 <= idx < n_audio_bins:
                audio_pulse[idx] = 1.0

        score_len = (max(scaled_onsets) + 1.0) if len(scaled_onsets) > 0 else 1.0
        n_score_bins = int(score_len / resolution) + 1
        score_pulse = np.zeros(n_score_bins)
        for t in scaled_onsets:
            idx = int(t / resolution)
            if 0 <= idx < n_score_bins:
                score_pulse[idx] = 1.0

        sigma = 0.05 / resolution
        audio_smooth = gaussian_filter1d(audio_pulse, sigma=sigma)
        score_smooth = gaussian_filter1d(score_pulse, sigma=sigma)

        corr = fftconvolve(audio_smooth, score_smooth[::-1], mode='full')
        peak_idx = int(np.argmax(corr))
        offset_bins = peak_idx - (len(score_smooth) - 1)
        offset = max(0.0, min(dur, offset_bins * resolution))

        if len(onset_times) > 0:
            dists = np.abs(onset_times - offset)
            nearest = int(np.argmin(dists))
            if dists[nearest] < 0.1:
                offset = float(onset_times[nearest])

        peak_val = float(corr[peak_idx])
        score_auto = float(np.sum(score_smooth ** 2))
        confidence = max(0.0, min(1.0, peak_val / (score_auto + 1e-10)))
        print(f"Auto-detected offset: {offset:.3f}s, confidence: {confidence:.1%}")

    # ── 6. Precise global tempo via onset matching optimization ────────
    # Map every score onset to audio time, find tempo_ratio that minimizes
    # the total distance from mapped onsets to nearest audio transients.
    # This uses ALL notes simultaneously — far more precise than beat tracking.

    n_bars = len(measure_boundaries)
    score_onsets_arr = np.array(sorted(score_onsets))
    otp = np.array(onset_times_peak)  # audio onset times (peak positions)

    def onset_match_cost(tempo_r):
        """Total squared distance from mapped score onsets to nearest audio onset."""
        mapped = offset + score_onsets_arr / tempo_r
        idxs = np.searchsorted(otp, mapped)
        idxs = np.clip(idxs, 1, len(otp) - 1)
        d_left = np.abs(mapped - otp[idxs - 1])
        d_right = np.abs(mapped - otp[idxs])
        dists = np.minimum(d_left, d_right)
        # Only count notes within 50ms of a transient (tight matching)
        mask = dists < 0.05
        if np.sum(mask) < 10:
            mask = dists < 0.08  # relax if too few matches
        dists = dists[mask]
        if len(dists) == 0:
            return 1e6
        return float(np.sum(dists ** 2))

    # Grid search ±5% around initial estimate, then refine with scipy
    best_ratio = tempo_ratio
    best_cost = onset_match_cost(tempo_ratio)
    for r in np.arange(tempo_ratio * 0.95, tempo_ratio * 1.05, 0.0005):
        c = onset_match_cost(r)
        if c < best_cost:
            best_cost = c
            best_ratio = r

    from scipy.optimize import minimize_scalar
    result = minimize_scalar(onset_match_cost,
                             bounds=(best_ratio * 0.998, best_ratio * 1.002),
                             method='bounded',
                             options={'xatol': 1e-7})
    if result.fun < best_cost:
        best_ratio = result.x

    tempo_ratio = best_ratio
    detected_tempo = score_tempo * tempo_ratio
    print(f"Optimized global tempo: {detected_tempo:.4f} BPM (ratio: {tempo_ratio:.6f})")

    # ── 7. Note-to-transient matching → per-bar timing correction ────────
    # Strategy: we know where every MIDI note WOULD land at the global tempo.
    # We match each note to its nearest audio transient.  For each bar, the
    # mean signed error tells us how much the bar's position needs to shift.
    # Smoothing the corrections prevents noisy single-note mismatches from
    # causing wild tempo swings.  Tempo stays close to baseline with small
    # fluctuations — exactly what a real performance looks like.

    # Pre-compute bar structure
    qn_per_bar_list = []
    for i in range(n_bars):
        mb = measure_boundaries[i]
        beats = mb.get('beats', 4)
        beat_type = mb.get('beat_type', 4)
        qn_per_bar_list.append(beats * 4.0 / beat_type)

    # Global predictions for bar start positions
    global_positions = np.array([
        offset + mb['score_time'] / tempo_ratio for mb in measure_boundaries
    ])

    # Match each score onset to nearest audio transient
    bar_error_sums = np.zeros(n_bars)     # weighted sum of signed errors
    bar_error_weights = np.zeros(n_bars)  # total weight per bar
    n_matched = 0
    # Per-note matches: score_time → transient audio time (for per-note nudge)
    note_matches = {}  # key: round(score_time, 4), value: audio-file transient time

    for t_s in score_onsets_arr:
        mapped_t = offset + t_s / tempo_ratio  # predicted audio time

        # Find nearest audio transient
        idx = np.searchsorted(otp, mapped_t)
        best_dist = float('inf')
        best_error = 0.0
        best_strength = 1.0
        best_transient_t = mapped_t
        for ci in [idx - 1, idx]:
            if 0 <= ci < len(otp):
                d = abs(float(otp[ci]) - mapped_t)
                if d < best_dist:
                    best_dist = d
                    best_error = float(otp[ci]) - mapped_t  # signed: positive = note needs to be later
                    best_strength = float(onset_strengths[ci]) if ci < len(onset_strengths) else 1.0
                    best_transient_t = float(otp[ci])

        if best_dist > 0.04:   # 40ms tolerance — if no transient nearby, skip
            continue
        n_matched += 1
        note_matches[round(float(t_s), 4)] = best_transient_t

        # Assign to bar
        bar_idx = n_bars - 1
        for j in range(n_bars - 1):
            if measure_boundaries[j]['score_time'] <= t_s < measure_boundaries[j + 1]['score_time']:
                bar_idx = j
                break

        # Weight by onset strength — strong transients are more reliable anchors
        w = max(best_strength, 0.1)
        bar_error_sums[bar_idx] += best_error * w
        bar_error_weights[bar_idx] += w

    print(f"Matched {n_matched}/{len(score_onsets_arr)} score onsets to audio transients")

    # Compute weighted mean error per bar
    raw_corrections = np.zeros(n_bars)
    has_data = bar_error_weights > 0
    raw_corrections[has_data] = bar_error_sums[has_data] / bar_error_weights[has_data]

    # Interpolate bars with no matches from neighbors
    if np.any(~has_data) and np.any(has_data):
        good_idx = np.where(has_data)[0]
        bad_idx = np.where(~has_data)[0]
        raw_corrections[bad_idx] = np.interp(bad_idx, good_idx, raw_corrections[good_idx])

    bars_with_data = int(np.sum(has_data))
    print(f"Per-bar corrections: {bars_with_data}/{n_bars} bars have direct matches")
    print(f"  raw range: {float(np.min(raw_corrections))*1000:.1f}ms to "
          f"{float(np.max(raw_corrections))*1000:.1f}ms")

    # ── 8. Smooth corrections → stable bar positions → tempo ─────────────
    # Median filter rejects outlier bars, Gaussian smooths the rest.
    # This ensures adjacent bars have similar corrections → similar tempos.
    kernel = min(7, n_bars if n_bars % 2 == 1 else max(1, n_bars - 1))
    smoothed = np.array(raw_corrections, dtype=float)
    if kernel >= 3:
        smoothed = median_filter(smoothed, size=kernel)
    smoothed = gaussian_filter1d(smoothed, sigma=2.0)

    print(f"  smoothed range: {float(np.min(smoothed))*1000:.1f}ms to "
          f"{float(np.max(smoothed))*1000:.1f}ms")

    # Apply corrections to global positions
    bar_positions = list(global_positions + smoothed)

    # Enforce strict monotonicity
    for i in range(1, n_bars):
        min_bar_dur = qn_per_bar_list[i - 1] * 60.0 / (detected_tempo * 1.15)
        if bar_positions[i] <= bar_positions[i - 1] + min_bar_dur:
            bar_positions[i] = bar_positions[i - 1] + qn_per_bar_list[i - 1] * 60.0 / detected_tempo

    # Compute per-bar tempo from actual bar durations
    bar_tempos = []
    for i in range(n_bars):
        if i < n_bars - 1:
            bar_dur = bar_positions[i + 1] - bar_positions[i]
            if bar_dur > 0.05:
                tempo = qn_per_bar_list[i] * 60.0 / bar_dur
                # Clamp to ±10% of detected global tempo
                tempo = max(detected_tempo * 0.90, min(detected_tempo * 1.10, tempo))
                bar_tempos.append(round(tempo, 4))
            else:
                bar_tempos.append(round(detected_tempo, 4))
        else:
            bar_tempos.append(bar_tempos[-1] if bar_tempos else round(detected_tempo, 4))

    tempo_arr = np.array(bar_tempos)
    print(f"Per-bar tempos: {float(np.min(tempo_arr)):.2f} - "
          f"{float(np.max(tempo_arr)):.2f} BPM, "
          f"median={float(np.median(tempo_arr)):.2f}, "
          f"std={float(np.std(tempo_arr)):.3f}")

    # ── 9. Build output — every bar gets an entry ────────────────────────
    aligned = []
    for i in range(n_bars):
        mb = measure_boundaries[i]
        aligned.append({
            'measure':   mb['measure'],
            'real_time': round(bar_positions[i], 6),
            'tempo':     bar_tempos[i],
            'beats':     mb.get('beats', 4),
            'beat_type': mb.get('beat_type', 4)
        })

    tempos = [a['tempo'] for a in aligned]
    print(f"Result: {n_bars} bars, "
          f"range {min(tempos):.2f}-{max(tempos):.2f} BPM")

    # ── 10. Per-note corrections for transient snapping ──────────────────
    # Re-match notes AFTER tempo correction for precise per-note nudging.
    # Key improvement: EVERY note gets a correction (matched or interpolated)
    # so the entire drum performance shifts coherently and doesn't sound doubled.

    align_offset = bar_positions[0]

    def score_time_to_corrected_audio(t_s):
        """Convert original score time to corrected audio time (relative to item start)."""
        bar_idx = n_bars - 1
        for j in range(n_bars - 1):
            if measure_boundaries[j]['score_time'] <= t_s < measure_boundaries[j + 1]['score_time']:
                bar_idx = j
                break
        bar_score_start = measure_boundaries[bar_idx]['score_time']
        within_bar_score = t_s - bar_score_start
        if bar_idx < n_bars - 1:
            bar_score_dur = measure_boundaries[bar_idx + 1]['score_time'] - bar_score_start
            bar_audio_dur = bar_positions[bar_idx + 1] - bar_positions[bar_idx]
        else:
            bar_score_dur = 1.0
            bar_audio_dur = bar_score_dur / tempo_ratio
        if bar_score_dur > 0.001:
            local_ratio = bar_audio_dur / bar_score_dur
        else:
            local_ratio = 1.0 / tempo_ratio
        audio_t = (bar_positions[bar_idx] - align_offset) + within_bar_score * local_ratio
        return audio_t

    # High-resolution energy envelope for sub-sample onset refinement
    env_hop = 32   # ~1.5ms at 22050Hz — very fine for tight drum alignment
    energy = np.array([
        np.sum(y[i:i+env_hop]**2) for i in range(0, len(y) - env_hop, env_hop)
    ], dtype=float)
    energy_times = np.arange(len(energy)) * env_hop / sr

    def refine_onset(coarse_t, window=0.012):
        """Find the loudest energy peak near coarse_t.
        For drums, the transient IS the peak — the exact moment of impact."""
        lo = max(0, int((coarse_t - window) * sr / env_hop))
        hi = min(len(energy), int((coarse_t + window) * sr / env_hop) + 1)
        if hi <= lo:
            return coarse_t
        seg = energy[lo:hi]
        pk = int(np.argmax(seg))
        return float(energy_times[lo + pk])

    # Pass 1: Match notes directly to nearest transient (tight tolerance)
    matched_score_times = []    # score times of matched notes
    matched_deltas = []         # delta = (target - tempo_map_position) for each match
    note_direct_match = {}      # score_time_key → target_from_item_start

    for t_s in score_onsets_arr:
        corrected_t = score_time_to_corrected_audio(float(t_s))
        abs_t = corrected_t + align_offset
        idx = np.searchsorted(otp, abs_t)
        best_dist = float('inf')
        best_transient = abs_t
        for ci in [idx - 1, idx]:
            if 0 <= ci < len(otp):
                d = abs(float(otp[ci]) - abs_t)
                if d < best_dist:
                    best_dist = d
                    best_transient = float(otp[ci])
        if best_dist > 0.025:  # 25ms — tight: drums should be very close
            continue
        refined_t = refine_onset(best_transient)
        target_from_start = refined_t - align_offset
        delta = target_from_start - corrected_t
        st_key = round(float(t_s), 4)
        matched_score_times.append(float(t_s))
        matched_deltas.append(delta)
        note_direct_match[st_key] = target_from_start

    n_direct = len(matched_score_times)
    print(f"Note corrections pass 1: {n_direct}/{len(score_onsets_arr)} notes directly matched (25ms)")

    # Pass 2: Interpolate deltas for ALL notes
    # Each matched note has a delta (how much to shift from tempo-map position).
    # Unmatched notes get an interpolated delta from the nearest matched notes.
    # This keeps the entire performance coherent — no notes left behind.
    note_corrections = []
    n_corrected = 0

    if n_direct >= 2:
        matched_score_arr = np.array(matched_score_times)
        matched_delta_arr = np.array(matched_deltas)
        # Sort by score time
        sort_idx = np.argsort(matched_score_arr)
        matched_score_arr = matched_score_arr[sort_idx]
        matched_delta_arr = matched_delta_arr[sort_idx]

        for t_s in score_onsets_arr:
            st_key = round(float(t_s), 4)
            corrected_t = score_time_to_corrected_audio(float(t_s))

            if st_key in note_direct_match:
                # Directly matched — use exact target
                target = note_direct_match[st_key]
            else:
                # Interpolate delta from nearest matched notes
                delta = float(np.interp(float(t_s), matched_score_arr, matched_delta_arr))
                target = corrected_t + delta

            note_corrections.append({
                'st': st_key,
                'tt': round(target, 6)
            })
            n_corrected += 1
    elif n_direct > 0:
        # Only 1 match — apply same delta to all
        single_delta = matched_deltas[0]
        for t_s in score_onsets_arr:
            corrected_t = score_time_to_corrected_audio(float(t_s))
            st_key = round(float(t_s), 4)
            note_corrections.append({
                'st': st_key,
                'tt': round(corrected_t + single_delta, 6)
            })
            n_corrected += 1
    else:
        # No matches at all — use tempo-map positions as-is
        for t_s in score_onsets_arr:
            corrected_t = score_time_to_corrected_audio(float(t_s))
            st_key = round(float(t_s), 4)
            note_corrections.append({
                'st': st_key,
                'tt': round(corrected_t, 6)
            })
            n_corrected += 1

    print(f"Note corrections: {n_corrected}/{len(score_onsets_arr)} notes, "
          f"{n_direct} direct + {n_corrected - n_direct} interpolated")

    return {
        'aligned_boundaries': aligned,
        'confidence':      round(confidence, 3),
        'detected_tempo':  round(detected_tempo, 2),
        'offset':          round(offset, 6),
        'note_corrections': note_corrections,
        'onset_times': [round(float(t) - align_offset, 6) for t in otp]
    }


# ═══════════════════════════════════════════════════════════════════════
def main():
    if len(sys.argv) < 3:
        print("Usage: python konst_align_score_to_audio.py <input_json> <output_json>")
        sys.exit(1)

    input_path  = sys.argv[1]
    output_path = sys.argv[2]

    with open(input_path, 'r') as f:
        data = json.load(f)

    audio_path = data['audio_path']
    score_onsets = data.get('score_onsets', [])
    measure_boundaries = data.get('measure_boundaries', [])
    start_time = data.get('start_time', None)

    if not os.path.exists(audio_path):
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    if not measure_boundaries:
        raise ValueError("No measure boundaries provided")

    if not score_onsets:
        raise ValueError("No score onset times provided")

    result = align_score_to_audio(audio_path, score_onsets, measure_boundaries,
                                  start_time=start_time)

    # Write atomically
    tmp_path = output_path + ".tmp"
    with open(tmp_path, 'w') as f:
        json.dump(result, f, indent=2)

    if os.path.exists(output_path):
        os.remove(output_path)
    os.rename(tmp_path, output_path)

    n_bars = len(result['aligned_boundaries'])
    conf = result['confidence']
    tempos = [b['tempo'] for b in result['aligned_boundaries']]
    avg_tempo = sum(tempos) / len(tempos) if tempos else 0
    print(f"Aligned {n_bars} bars, avg tempo {avg_tempo:.1f} BPM, "
          f"confidence {conf:.1%}")


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        err_path = sys.argv[2] + ".err" if len(sys.argv) > 2 else "align_error.txt"
        with open(err_path, 'w') as f:
            f.write(str(e) + "\n\n" + traceback.format_exc())
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
