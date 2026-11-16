#!/usr/bin/env python3
"""Analyze a captured TTS WAV file and fail on obvious audio-quality problems.

The capture wrapper writes 16-bit PCM WAV, which keeps this analyzer dependency-free.
It emits JSON to stdout and writes <file>.analysis.json next to the WAV.
"""

from __future__ import annotations

import array
import json
import math
import os
import statistics
import sys
import wave
from pathlib import Path
from typing import Iterable, List


def env_float(name: str, default: float) -> float:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    try:
        return float(value)
    except ValueError as exc:
        raise SystemExit(f"Invalid float for {name}: {value!r}") from exc


def env_int(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise SystemExit(f"Invalid integer for {name}: {value!r}") from exc


def dbfs(value: float) -> float:
    if value <= 1e-12:
        return -120.0
    return 20.0 * math.log10(value)


def percentile(sorted_values: List[float], pct: float) -> float:
    if not sorted_values:
        return 0.0
    if pct <= 0:
        return sorted_values[0]
    if pct >= 100:
        return sorted_values[-1]
    idx = (len(sorted_values) - 1) * (pct / 100.0)
    lower = int(math.floor(idx))
    upper = int(math.ceil(idx))
    if lower == upper:
        return sorted_values[lower]
    frac = idx - lower
    return sorted_values[lower] * (1.0 - frac) + sorted_values[upper] * frac


def load_pcm16_wav(path: Path) -> tuple[int, int, int, List[float], array.array]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frame_count = wav.getnframes()
        compression = wav.getcomptype()
        raw = wav.readframes(frame_count)

    if compression != "NONE":
        raise SystemExit(f"Unsupported WAV compression {compression!r}; expected PCM")
    if sample_width != 2:
        raise SystemExit(f"Unsupported sample width {sample_width}; expected 16-bit PCM")
    if channels <= 0:
        raise SystemExit("Invalid WAV channel count")
    if sample_rate <= 0:
        raise SystemExit("Invalid WAV sample rate")

    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder != "little":
        samples.byteswap()

    usable = (len(samples) // channels) * channels
    if usable != len(samples):
        samples = samples[:usable]

    mono: List[float] = []
    scale = 32768.0
    if channels == 1:
        mono = [s / scale for s in samples]
    else:
        for i in range(0, len(samples), channels):
            mono.append(sum(samples[i : i + channels]) / (channels * scale))

    return sample_rate, channels, frame_count, mono, samples


def collapse_event_count(indices: Iterable[int], gap_samples: int) -> tuple[int, List[float]]:
    count = 0
    last = -10**12
    event_indices: List[int] = []
    for idx in indices:
        if idx - last > gap_samples:
            count += 1
            event_indices.append(idx)
            last = idx
    return count, event_indices[:25]


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: tts-analyze.py file.wav")

    path = Path(sys.argv[1])
    if not path.exists():
        raise SystemExit(f"File does not exist: {path}")

    sample_rate, channels, frame_count, mono, raw_samples = load_pcm16_wav(path)
    n = len(mono)
    duration_s = n / sample_rate if sample_rate else 0.0

    if n == 0:
        rms = 0.0
        peak = 0.0
        dc_offset = 0.0
    else:
        peak = max(abs(x) for x in mono)
        rms = math.sqrt(sum(x * x for x in mono) / n)
        dc_offset = sum(mono) / n

    clipped_threshold = env_int("CLIPPED_ABS_SAMPLE", 32760)
    clipped_samples = sum(1 for s in raw_samples if abs(s) >= clipped_threshold)

    # Windowed silence detection.
    silence_dbfs = env_float("SILENCE_DBFS", -50.0)
    silence_rms = 10.0 ** (silence_dbfs / 20.0)
    window_s = env_float("SILENCE_WINDOW_S", 0.050)
    window = max(1, int(sample_rate * window_s))
    window_rms_values: List[float] = []
    silent_windows = 0
    if n >= window:
        for start in range(0, n - window + 1, window):
            segment = mono[start : start + window]
            wrms = math.sqrt(sum(x * x for x in segment) / len(segment))
            window_rms_values.append(wrms)
            if wrms < silence_rms:
                silent_windows += 1
    silence_ratio = (silent_windows / len(window_rms_values)) if window_rms_values else 1.0

    # Leading/trailing silence estimates using 10 ms windows.
    edge_window = max(1, int(sample_rate * 0.010))
    leading_windows = 0
    trailing_windows = 0
    if n >= edge_window:
        for start in range(0, n - edge_window + 1, edge_window):
            segment = mono[start : start + edge_window]
            wrms = math.sqrt(sum(x * x for x in segment) / len(segment))
            if wrms < silence_rms:
                leading_windows += 1
            else:
                break
        for start in range(n - edge_window, -1, -edge_window):
            segment = mono[start : start + edge_window]
            wrms = math.sqrt(sum(x * x for x in segment) / len(segment))
            if wrms < silence_rms:
                trailing_windows += 1
            else:
                break

    # Rough pop/click detector. It intentionally reports "possible" clicks because
    # hard consonants and very sharp synthetic transients can look similar.
    diffs: List[float] = []
    if n > 1:
        # Cap median/MAD sampling cost on long captures.
        sample_step = max(1, (n - 1) // env_int("CLICK_STATS_MAX_SAMPLES", 200_000))
        prev = mono[0]
        for i in range(1, n, sample_step):
            cur = mono[i]
            diffs.append(abs(cur - prev))
            prev = cur

    if diffs:
        median_diff = statistics.median(diffs)
        abs_devs = [abs(x - median_diff) for x in diffs]
        mad_diff = statistics.median(abs_devs)
    else:
        median_diff = 0.0
        mad_diff = 0.0

    min_click_delta = env_float("MIN_CLICK_DELTA", 0.18)
    click_mad_multiplier = env_float("CLICK_MAD_MULTIPLIER", 25.0)
    click_threshold = max(min_click_delta, median_diff + click_mad_multiplier * mad_diff)
    collapse_gap = max(1, int(sample_rate * env_float("CLICK_COLLAPSE_GAP_S", 0.005)))

    click_indices: List[int] = []
    if n > 1:
        prev = mono[0]
        for i in range(1, n):
            cur = mono[i]
            if abs(cur - prev) > click_threshold:
                click_indices.append(i)
            prev = cur

    click_events, first_click_indices = collapse_event_count(click_indices, collapse_gap)
    first_click_times = [round(idx / sample_rate, 4) for idx in first_click_indices]

    sorted_window_rms = sorted(window_rms_values)
    report = {
        "file": str(path),
        "duration_s": round(duration_s, 4),
        "sample_rate_hz": sample_rate,
        "channels": channels,
        "frames": frame_count,
        "rms_dbfs": round(dbfs(rms), 2),
        "peak_dbfs": round(dbfs(peak), 2),
        "dc_offset": round(dc_offset, 6),
        "clipped_samples": clipped_samples,
        "silence_ratio": round(silence_ratio, 4),
        "leading_silence_s": round(leading_windows * edge_window / sample_rate, 4),
        "trailing_silence_s": round(trailing_windows * edge_window / sample_rate, 4),
        "window_rms_dbfs_p50": round(dbfs(percentile(sorted_window_rms, 50)), 2),
        "window_rms_dbfs_p95": round(dbfs(percentile(sorted_window_rms, 95)), 2),
        "possible_click_events": click_events,
        "first_possible_click_times_s": first_click_times,
        "click_threshold_delta": round(click_threshold, 6),
        "median_sample_delta": round(median_diff, 6),
        "mad_sample_delta": round(mad_diff, 6),
    }

    failures: List[str] = []
    if duration_s < env_float("MIN_DURATION_S", 0.25):
        failures.append("too_short")
    if dbfs(rms) < env_float("MIN_RMS_DBFS", -45.0):
        failures.append("too_quiet_or_silent")
    if clipped_samples > env_int("MAX_CLIPPED_SAMPLES", 0):
        failures.append("clipping")
    if click_events > env_int("MAX_CLICK_EVENTS", 10):
        failures.append("possible_pops_or_clicks")
    if silence_ratio > env_float("MAX_SILENCE_RATIO", 0.98):
        failures.append("mostly_silent")

    report["status"] = "fail" if failures else "pass"
    report["failures"] = failures

    output = json.dumps(report, indent=2, sort_keys=True)
    print(output)

    report_path = Path(os.getenv("TTS_REPORT_OUT", str(path) + ".analysis.json"))
    report_path.write_text(output + "\n", encoding="utf-8")
    print(f"Analysis JSON: {report_path}")

    if failures:
        print("Audio validation failed: " + ", ".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
