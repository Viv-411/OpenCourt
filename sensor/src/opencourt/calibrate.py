"""Interactive zone calibration: click polygons on a still of the courts.

For a recording, the still is the per-pixel median of frames spread across the clip, so
moving people vanish and the court is clear to draw on. The still is only displayed,
never saved.

Steps, in order: every court (court 1 = the one nearest where people wait), then the
waiting line, then any number of optional "ignore" areas around things the detector
mistakes for people (a sign post, a pole).

Keys:
  click        add a corner
  z            undo the last corner
  n / Enter    this zone is done, go to the next one
  b            go back to the previous zone to fix it
  r            clear the zone you're drawing
  s            save (all courts and the line must be done)
  q / Esc      quit without saving

Draw each court around the playing area *including* the run-off behind the baselines and
beside the sidelines, where players stand during points. Leave the walking lane and the
waiting area out of the courts.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .config import Zones, save_zones

COURT_COLORS = [(0, 255, 0), (255, 200, 0), (0, 200, 255), (255, 120, 120), (200, 120, 255)]
LINE_COLOR = (255, 0, 255)
IGNORE_COLOR = (150, 150, 150)
VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v", ".avi", ".mkv"}


def grab_frame(spec: str, width: int = 1920, height: int = 1080) -> Any:
    """An image to draw on: an image file as-is, the empty-court median of a recording, or a
    live frame from a camera."""
    import cv2
    import numpy as np

    if spec == "picamera":
        from picamera2 import Picamera2

        cam = Picamera2()
        cam.configure(cam.create_still_configuration(
            main={"size": (width, height), "format": "RGB888"}))
        cam.start()
        frame = cam.capture_array("main")
        cam.close()
        return frame
    if spec.startswith("usb:"):
        cap = cv2.VideoCapture(int(spec.removeprefix("usb:")))
        ok, frame = cap.read()
        cap.release()
        if not ok:
            raise RuntimeError(f"could not read a frame from {spec}")
        return frame
    if Path(spec).suffix.lower() not in VIDEO_SUFFIXES:
        frame = cv2.imread(spec)
        if frame is None:
            raise RuntimeError(f"could not read image {spec}")
        return frame
    cap = cv2.VideoCapture(spec)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frames = []
    print("building an empty-court still from the recording (a few seconds)...")
    for i in np.linspace(0, max(n - 1, 0), 40).astype(int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(i))
        ok, f = cap.read()
        if ok:
            frames.append(f)
    cap.release()
    if not frames:
        raise RuntimeError(f"could not read frames from {spec}")
    return np.median(np.stack(frames), axis=0).astype(np.uint8)


def _steps(courts: int) -> list[tuple[str, str]]:
    return [("court", f"court {i}") for i in range(1, courts + 1)] + [("line", "waiting line")]


def calibrate(spec: str, courts: int, out: Path, existing: Zones | None = None) -> bool:
    import cv2
    import numpy as np

    frame = grab_frame(spec)
    h, w = frame.shape[:2]
    steps = _steps(courts)
    polys: list[list[tuple[float, float]]] = [[] for _ in steps]
    ignores: list[list[tuple[float, float]]] = []
    if existing is not None and existing.court_count == courts:
        polys = [list(existing.courts[i]) for i in range(1, courts + 1)] + [list(existing.queue)]
        ignores = [list(p) for p in existing.ignore]
    current = 0  # index into steps; len(steps) + k means ignore area k
    win = "OpenCourt zones (not recorded)"

    def cur_list() -> list[tuple[float, float]]:
        if current < len(steps):
            return polys[current]
        k = current - len(steps)
        while len(ignores) <= k:
            ignores.append([])
        return ignores[k]

    def on_mouse(event, x, y, *_):
        if event == cv2.EVENT_LBUTTONDOWN:
            cur_list().append((float(x), float(y)))

    def color(i: int) -> tuple[int, int, int]:
        if i < courts:
            return COURT_COLORS[i % len(COURT_COLORS)]
        return LINE_COLOR if i == courts else IGNORE_COLOR

    def label(i: int) -> str:
        return steps[i][1] if i < len(steps) else f"ignore area {i - len(steps) + 1}"

    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(win, min(w, 1500), int(min(w, 1500) * h / w))
    cv2.setMouseCallback(win, on_mouse)
    font = cv2.FONT_HERSHEY_SIMPLEX
    s = w / 1920  # text scale for the image resolution

    while True:
        img = frame.copy()
        shade = img.copy()
        all_polys = list(enumerate(polys)) + [(len(steps) + k, p) for k, p in enumerate(ignores)]
        for i, poly in all_polys:
            if len(poly) >= 3 and i != current:
                cv2.fillPoly(shade, [np.array(poly, np.int32)], color(i))
        img = cv2.addWeighted(shade, 0.25, img, 0.75, 0)
        for i, poly in all_polys:
            if not poly:
                continue
            pts = np.array(poly, np.int32)
            active = i == current
            cv2.polylines(img, [pts], not active, color(i), max(2, int(4 * s)))
            if active and len(poly) >= 2:  # dashed-looking closing edge preview
                cv2.line(img, tuple(pts[-1]), tuple(pts[0]), color(i), 1)
            for p in pts:
                cv2.circle(img, tuple(int(v) for v in p), max(4, int(7 * s)), color(i), -1)
            cx, cy = pts.mean(axis=0).astype(int)
            cv2.putText(img, label(i), (cx - int(60 * s), cy), font, 1.1 * s, (0, 0, 0),
                        int(6 * s) + 1)
            cv2.putText(img, label(i), (cx - int(60 * s), cy), font, 1.1 * s, color(i),
                        int(2 * s) + 1)

        # banner
        bar_h = int(110 * s)
        cv2.rectangle(img, (0, 0), (w, bar_h), (25, 25, 25), -1)
        if current < len(steps):
            kind = steps[current][0]
            hint = ("click the corners of the playing area plus run-off, then press N"
                    if kind == "court" else
                    "click the corners of where people stand while waiting, then press N")
            title = f"Now drawing: {label(current).upper()}   ({current + 1} of {len(steps)})"
        else:
            hint = ("optional: outline anything detected as a person that isn't one "
                    "(a post, a sign); N for another, S to save")
            title = f"Now drawing: {label(current).upper()} (optional)"
        cv2.putText(img, title, (int(20 * s), int(45 * s)), font, 1.3 * s,
                    color(min(current, len(steps))), int(3 * s) + 1)
        cv2.putText(img, hint + "     z undo  b back  r clear  s save  q quit",
                    (int(20 * s), int(90 * s)), font, 0.75 * s, (230, 230, 230),
                    int(2 * s) + 1)
        cv2.imshow(win, img)

        key = cv2.waitKey(30) & 0xFF
        if key in (ord("q"), 27):
            cv2.destroyWindow(win)
            return False
        if key == ord("z") and cur_list():
            cur_list().pop()
        elif key == ord("r"):
            cur_list().clear()
        elif key == ord("b") and current > 0:
            current -= 1
        elif key in (ord("n"), 13):
            if len(cur_list()) >= 3:
                current += 1
            elif current >= len(steps) and not cur_list():
                pass  # nothing to finish on an empty optional area
        elif key == ord("s"):
            missing = [steps[i][1] for i in range(len(steps)) if len(polys[i]) < 3]
            if missing:
                print("still to draw (at least 3 corners each):", ", ".join(missing))
                continue
            zones = Zones(image_size=(w, h),
                          courts={i + 1: polys[i] for i in range(courts)},
                          queue=polys[courts],
                          ignore=[p for p in ignores if len(p) >= 3])
            save_zones(zones, out)
            cv2.destroyWindow(win)
            print(f"saved {out}")
            return True
