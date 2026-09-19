"""Where people's feet were over a whole clip, drawn over the empty-court still.

Usage: uv run python tools/footage_heatmap.py data/footage/clip.tracks.jsonl background.jpg out.jpg
       [--zones config/zones.yaml]
Dev-only (see README).
"""

import argparse

import cv2
import numpy as np

from opencourt.config import load_zones
from opencourt.trackfile import read


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("tracks")
    ap.add_argument("background")
    ap.add_argument("out")
    ap.add_argument("--zones")
    args = ap.parse_args()

    bg = cv2.imread(args.background)
    h, w = bg.shape[:2]
    heat = np.zeros((h, w), np.float32)
    _, frames = read(args.tracks)
    for obs in frames:
        for tr in obs.tracks:
            x, y = tr.foot
            if 0 <= x < w and 0 <= y < h:
                heat[int(y), int(x)] += 1.0
    heat = cv2.GaussianBlur(heat, (0, 0), 5)
    heat = np.log1p(heat * 50)  # time spent spans orders of magnitude; log keeps both visible
    norm = np.clip(heat / (heat.max() + 1e-6), 0, 1)
    color = cv2.applyColorMap((norm * 255).astype(np.uint8), cv2.COLORMAP_INFERNO)
    mask = (norm > 0.08)[..., None]
    out = np.where(mask, cv2.addWeighted(bg, 0.35, color, 0.65, 0), bg)

    if args.zones:
        z = load_zones(args.zones)
        for n, poly in z.courts.items():
            pts = np.array(poly, np.int32)
            cv2.polylines(out, [pts], True, (0, 255, 0), 3)
            cv2.putText(out, f"court {n}", tuple(pts.min(axis=0) + [10, 40]),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0, 255, 0), 3)
        q = np.array(z.queue, np.int32)
        cv2.polylines(out, [q], True, (255, 0, 255), 3)
        cv2.putText(out, "line", tuple(q.min(axis=0) + [10, 40]),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.2, (255, 0, 255), 3)
    # light grid so zone corners can be read off the image
    for x in range(0, w, 100):
        cv2.line(out, (x, 0), (x, h), (80, 80, 80), 1)
        cv2.putText(out, str(x), (x + 2, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)
    for y in range(0, h, 100):
        cv2.line(out, (0, y), (w, y), (80, 80, 80), 1)
        cv2.putText(out, str(y), (2, y - 2), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)
    cv2.imwrite(args.out, out)
    print(args.out)


if __name__ == "__main__":
    main()
