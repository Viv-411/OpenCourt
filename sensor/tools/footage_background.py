"""Empty-court still: the per-pixel median of frames spread across the clip.

Usage: uv run python tools/footage_background.py data/footage/clip.MOV [out.jpg]
People who move around disappear in the median, which leaves the court, fences and zones
visible for drawing polygons — without a frame showing anyone. Dev-only (see README).
"""

import sys
from pathlib import Path

import cv2
import numpy as np


def background(video: str, samples: int = 60) -> np.ndarray:
    cap = cv2.VideoCapture(video)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frames = []
    for i in np.linspace(0, n - 1, samples).astype(int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(i))
        ok, f = cap.read()
        if ok:
            frames.append(f)
    cap.release()
    return np.median(np.stack(frames), axis=0).astype(np.uint8)


if __name__ == "__main__":
    video = sys.argv[1]
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(video).with_suffix(".background.jpg")
    cv2.imwrite(str(out), background(video))
    print(out)
