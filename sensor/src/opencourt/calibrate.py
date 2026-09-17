"""Interactive zone calibration: click polygons on one live or recorded frame.

The frame is only displayed, never saved.

Keys:
  left click  add a vertex to the current zone
  u           undo last vertex
  n / Enter   finish current zone, move to the next
  r           restart the current zone
  s           save (all zones must be complete)
  q / Esc     quit without saving

Draw each court polygon around the *whole playing box including run-off space*
(roughly half-way to the neighbouring court or fence), not just the painted lines:
players constantly step behind the baseline, and that must not count as leaving.
Make the queue polygon touch the path players take onto court 1.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .config import Zones, save_zones

HELP = "click=add  u=undo  n=next  r=reset  s=save  q=quit"


def grab_frame(spec: str, width: int = 1920, height: int = 1080) -> Any:
    import cv2

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
    else:
        cap = cv2.VideoCapture(spec)
        # Skip ahead a little in recordings so the frame is representative.
        cap.set(cv2.CAP_PROP_POS_MSEC, 5000)
    ok, frame = cap.read()
    cap.release()
    if not ok:
        raise RuntimeError(f"could not read a frame from {spec}")
    return frame


def calibrate(spec: str, courts: int, out: Path, existing: Zones | None = None) -> bool:
    import cv2
    import numpy as np

    frame = grab_frame(spec)
    h, w = frame.shape[:2]
    names = [f"court {i}" for i in range(1, courts + 1)] + ["queue"]
    polys: list[list[tuple[float, float]]] = [[] for _ in names]
    if existing is not None and existing.court_count == courts:
        polys = [list(existing.courts[i]) for i in range(1, courts + 1)] + [list(existing.queue)]
    current = 0
    win = "OpenCourt calibration (not recorded)"

    def on_mouse(event, x, y, *_):
        if event == cv2.EVENT_LBUTTONDOWN and current < len(names):
            polys[current].append((float(x), float(y)))

    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.setMouseCallback(win, on_mouse)
    while True:
        img = frame.copy()
        for i, poly in enumerate(polys):
            if not poly:
                continue
            color = (0, 255, 255) if i == current else (0, 200, 0)
            pts = np.array(poly, dtype=np.int32)
            cv2.polylines(img, [pts], i != current, color, 2)
            for p in pts:
                cv2.circle(img, tuple(int(v) for v in p), 4, color, -1)
            cv2.putText(img, names[i], tuple(int(v) for v in pts[0]),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.9, color, 2)
        status = f"drawing: {names[current]}" if current < len(names) else "all zones done"
        cv2.putText(img, f"{status}   {HELP}", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8,
                    (255, 255, 255), 2)
        cv2.imshow(win, img)
        key = cv2.waitKey(30) & 0xFF
        if key in (ord("q"), 27):
            cv2.destroyWindow(win)
            return False
        if key == ord("u") and current < len(names) and polys[current]:
            polys[current].pop()
        elif key == ord("r") and current < len(names):
            polys[current] = []
        elif key in (ord("n"), 13) and current < len(names):
            if len(polys[current]) >= 3:
                current += 1
        elif key == ord("s"):
            if all(len(p) >= 3 for p in polys):
                zones = Zones(image_size=(w, h),
                              courts={i + 1: polys[i] for i in range(courts)},
                              queue=polys[-1])
                save_zones(zones, out)
                cv2.destroyWindow(win)
                print(f"saved {out}")
                return True
            print("every zone needs at least 3 points before saving")
