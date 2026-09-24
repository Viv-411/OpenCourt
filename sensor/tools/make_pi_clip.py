"""Cut a benchmark clip for the Raspberry Pi from a phone recording.

Usage: uv run python tools/make_pi_clip.py data/footage/clip.MOV data/pi-bench/clip.mp4 \
           [--start 60] [--seconds 180] [--fps 10]

Phones record HEVC at 30 fps, and decoding that in software is a big job for a small Pi:
it would swamp the timing, although a deployed Pi never decodes video (the camera hands
over raw frames). So this keeps the frame size (the zones were drawn on it) but drops to
the processing rate and re-encodes as MPEG-4, which any Pi decodes cheaply. Dev-only: it
writes video, which is why it lives outside the `opencourt` package (see README).
"""

import argparse
import sys
from pathlib import Path

import cv2


def cut(video: str, out: Path, start: float, seconds: float, fps: float) -> int:
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        raise SystemExit(f"cannot open {video}")
    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    step = max(1, round(src_fps / fps))
    size = (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))
    first = int(start * src_fps)
    last = first + int(seconds * src_fps)
    cap.set(cv2.CAP_PROP_POS_FRAMES, first)

    out.parent.mkdir(parents=True, exist_ok=True)
    # src_fps / step, not `fps`, so video time stays true to the original (29.97 / 3 = 9.99).
    writer = cv2.VideoWriter(str(out), cv2.VideoWriter_fourcc(*"mp4v"), src_fps / step, size)
    written = 0
    for idx in range(first, last):
        if not cap.grab():
            break
        if (idx - first) % step:
            continue
        ok, frame = cap.retrieve()
        if not ok:
            break
        writer.write(frame)
        written += 1
    writer.release()
    cap.release()
    return written


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("video")
    p.add_argument("out", type=Path)
    p.add_argument("--start", type=float, default=60.0, help="seconds into the recording")
    p.add_argument("--seconds", type=float, default=180.0, help="length of the clip")
    p.add_argument("--fps", type=float, default=10.0, help="processing rate to keep")
    a = p.parse_args()
    n = cut(a.video, a.out, a.start, a.seconds, a.fps)
    print(f"wrote {a.out} ({n} frames)", file=sys.stderr)
