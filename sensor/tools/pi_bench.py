"""Can this computer keep up? Time the detector on a benchmark clip.

Usage: uv run python tools/pi_bench.py data/pi-bench/clip.mp4 \
           --model data/pi-bench/models/yolo11n_640_ncnn_model --imgsz 640 \
           --out data/pi-bench/results/pi-640.tracks.jsonl

Runs the same detector + ByteTrack as `opencourt detect`, but times two things apart:
  * decoding the video file, which a deployed Pi never does (the camera gives raw frames);
  * the detector and tracker, which is what has to reach the target frame rate.
Also logs the board, temperature and throttling, and writes the boxes as a normal trackfile
so `opencourt replay --tracks` and `tools/compare_runs.py` can check the results. Nothing
but boxes and timings is written. Dev-only (see README).
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import resource
import statistics
import subprocess
import sys
import time
from pathlib import Path

SENSOR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SENSOR / "src"))

from opencourt.capture import VideoFileSource  # noqa: E402
from opencourt.config import DetectorConfig  # noqa: E402
from opencourt.detect import YoloTracker  # noqa: E402
from opencourt.trackfile import TrackFileHeader, write_frame, write_header  # noqa: E402

# docs/PLAN.md §8: below about 8 frames/s, ByteTrack loses fast-moving players.
TARGET_FPS = 8.0
# The first few inferences include one-off setup, so they'd understate the steady speed.
WARMUP_FRAMES = 10

THROTTLE_BITS = {
    0: "under-voltage now", 1: "CPU speed capped now", 2: "throttled now",
    3: "temperature limit now", 16: "under-voltage happened", 17: "speed cap happened",
    18: "throttling happened", 19: "temperature limit happened",
}


def board() -> dict:
    info = {"machine": platform.machine(), "python": platform.python_version(),
            "cpus": os.cpu_count()}
    model = Path("/proc/device-tree/model")
    info["board"] = (model.read_bytes().decode(errors="replace").strip("\x00 \n")
                     if model.exists() else platform.platform())
    meminfo = Path("/proc/meminfo")
    if meminfo.exists():
        kb = next(int(line.split()[1]) for line in meminfo.read_text().splitlines()
                  if line.startswith("MemTotal"))
        info["ram_gb"] = round(kb / 1024 / 1024, 1)
    return info


def temperature() -> float | None:
    zone = Path("/sys/class/thermal/thermal_zone0/temp")
    try:
        return int(zone.read_text()) / 1000
    except (OSError, ValueError):
        return None


def throttling() -> tuple[int | None, list[str]]:
    """The Pi firmware's throttle flags (`vcgencmd get_throttled`); None off a Pi."""
    try:
        out = subprocess.run(["vcgencmd", "get_throttled"], capture_output=True, text=True,
                             timeout=5).stdout
        value = int(out.strip().split("=")[1], 16)
    except (OSError, IndexError, ValueError, subprocess.SubprocessError):
        return None, []
    return value, [text for bit, text in THROTTLE_BITS.items() if value & (1 << bit)]


def peak_memory_mb() -> float:
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / 1024 / 1024 if sys.platform == "darwin" else peak / 1024  # bytes vs KiB


def verdict(fps: float) -> str:
    if fps >= TARGET_FPS:
        return f"KEEPS UP: {fps:.1f} frames/s is at or above the {TARGET_FPS:.0f} target."
    if fps >= TARGET_FPS * 0.6:
        return (f"BORDERLINE: {fps:.1f} frames/s is under the {TARGET_FPS:.0f} target. "
                "Tracks will break when players move fast; try --imgsz 480.")
    return (f"TOO SLOW: {fps:.1f} frames/s is far under the {TARGET_FPS:.0f} target. "
            "This board can't run the detector live.")


def run(clip: str, model: str, imgsz: int, out: Path, label: str) -> dict:
    src = VideoFileSource(clip, target_fps=1e9)  # every frame: the clip is already at 10 fps
    detector = YoloTracker(DetectorConfig(model=model, imgsz=imgsz, device="cpu"), SENSOR)
    out.parent.mkdir(parents=True, exist_ok=True)

    info = board()
    temp_start = temperature()
    temps = [t for t in [temp_start] if t is not None]
    print(f"{info['board']} ({info['machine']}, {info['cpus']} cores"
          + (f", {info['ram_gb']} GB" if "ram_gb" in info else "") + ")", file=sys.stderr)
    print(f"model {Path(model).name} at imgsz {imgsz}, {src.frame_count} frames", file=sys.stderr)

    decode, detect = [], []
    frames = src.frames()
    n = 0
    with open(out, "w") as f:
        write_header(f, TrackFileHeader(video=Path(clip).name, fps=src.fps,
                                        size=(src.width, src.height), model=Path(model).name,
                                        imgsz=imgsz, step=src.step))
        while True:
            t0 = time.perf_counter()
            try:
                t, frame = next(frames)
            except StopIteration:
                break
            t1 = time.perf_counter()
            tracks = detector(frame)
            t2 = time.perf_counter()
            write_frame(f, t, tracks)
            n += 1
            if n > WARMUP_FRAMES:
                decode.append(t1 - t0)
                detect.append(t2 - t1)
            if n % 100 == 0 and detect:
                temp = temperature()
                if temp is not None:
                    temps.append(temp)
                recent = detect[-100:]
                print(f"  {n:5d}/{src.frame_count}  detector {len(recent) / sum(recent):5.1f} "
                      f"frames/s" + (f"  {temp:.0f}°C" if temp is not None else ""),
                      file=sys.stderr)
    src.close()

    # One-minute slices (600 frames at 10 fps) show whether the board slows as it heats up.
    per_minute = [round(len(c) / sum(c), 1) for c in
                  (detect[i:i + 600] for i in range(0, len(detect), 600)) if len(c) >= 60]
    flags, reasons = throttling()
    detect_fps = round(len(detect) / sum(detect), 1)  # one rounding, so every line agrees
    summary = {
        "label": label, **info, "model": Path(model).name, "imgsz": imgsz, "frames": n,
        "detector_fps": detect_fps,
        "detector_ms_p95": round(statistics.quantiles(detect, n=20)[-1] * 1000, 1),
        "decode_ms_mean": round(statistics.mean(decode) * 1000, 1),
        "end_to_end_fps": round(len(detect) / (sum(detect) + sum(decode)), 2),
        "detector_fps_per_minute": per_minute,
        "temp_c_start": temp_start, "temp_c_max": max(temps) if temps else None,
        "throttled": None if flags is None else hex(flags), "throttle_reasons": reasons,
        "peak_memory_mb": round(peak_memory_mb()),
        "verdict": verdict(detect_fps),
    }
    out.with_suffix("").with_suffix(".summary.json").write_text(json.dumps(summary, indent=2))
    return summary


def report(s: dict) -> None:
    print(f"\n=== {s['label']}: {s['board']} ===")
    print(f"detector + tracker : {s['detector_fps']:.1f} frames/s "
          f"(slowest 5% of frames: {s['detector_ms_p95']:.0f} ms)")
    print(f"per minute         : {', '.join(str(v) for v in s['detector_fps_per_minute'])}")
    print(f"decoding this file : {s['decode_ms_mean']:.0f} ms/frame "
          "(a camera doesn't pay this)")
    print(f"end to end on file : {s['end_to_end_fps']:.1f} frames/s")
    if s["temp_c_max"] is not None:
        print(f"temperature        : {s['temp_c_start']:.0f}°C at start, "
              f"{s['temp_c_max']:.0f}°C peak")
    if s["throttled"] is not None:
        print(f"throttling         : {s['throttled']}"
              + (f" ({'; '.join(s['throttle_reasons'])})" if s["throttle_reasons"] else " (none)"))
    print(f"peak memory        : {s['peak_memory_mb']} MB")
    print(f"\n{s['verdict']}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("clip")
    p.add_argument("--model", required=True, help="NCNN folder (…_ncnn_model) or .pt file")
    p.add_argument("--imgsz", type=int, default=640)
    p.add_argument("--out", type=Path, required=True, help="where to write the trackfile")
    p.add_argument("--label", default=platform.node(), help="name for this run")
    a = p.parse_args()
    report(run(a.clip, a.model, a.imgsz, a.out, a.label))
