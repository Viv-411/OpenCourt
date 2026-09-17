"""Debug overlay for development. Shows frames in a window; never writes them anywhere."""

from __future__ import annotations

from typing import Any

from .config import Zones
from .engine import Snapshot
from .types import CourtState, Track

STATE_COLORS = {  # BGR
    CourtState.UNKNOWN: (128, 128, 128),
    CourtState.EMPTY: (200, 200, 200),
    CourtState.ROTATING: (255, 200, 0),
    CourtState.IDLE: (0, 200, 0),
    CourtState.ACTIVE: (0, 200, 0),
    CourtState.WARNING: (0, 190, 255),
    CourtState.DUE: (0, 140, 255),
}


class Overlay:
    def __init__(self, zones: Zones, window: str = "OpenCourt (not recorded)"):
        import cv2

        self.cv2 = cv2
        self.zones = zones
        self.window = window
        cv2.namedWindow(window, cv2.WINDOW_NORMAL)

    def show(self, frame: Any, tracks: tuple[Track, ...], snap: Snapshot) -> bool:
        """Draw and display. Returns False if the user pressed q/Esc."""
        cv2, np = self.cv2, __import__("numpy")
        img = frame.copy()
        states = {c.number: c for c in snap.courts}
        for n, poly in self.zones.courts.items():
            cs = states[n]
            color = STATE_COLORS[cs.signal.state]
            pts = np.array(poly, dtype=np.int32)
            cv2.polylines(img, [pts], True, color, 3)
            label = f"C{n} {cs.signal.state.value} n={cs.occupancy:.0f}"
            if cs.signal.clock_seconds is not None:
                label += f" {cs.signal.clock_seconds / 60:.1f}m"
            x, y = pts.min(axis=0)
            cv2.putText(img, label, (int(x) + 6, int(y) + 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8,
                        color, 2)
        q = np.array(self.zones.queue, dtype=np.int32)
        cv2.polylines(img, [q], True, (255, 0, 255), 2)
        qx, qy = q.min(axis=0)
        cv2.putText(img, f"queue {snap.queue_count:.0f}{' waiting' if snap.queue_waiting else ''}",
                    (int(qx) + 6, int(qy) + 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 0, 255), 2)
        for tr in tracks:
            fx, fy = tr.foot
            cv2.circle(img, (int(fx), int(fy)), 6, (255, 255, 255), -1)
        cv2.putText(img, f"{snap.health.value}  t={snap.t:.0f}s", (10, img.shape[0] - 14),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
        cv2.imshow(self.window, img)
        return (cv2.waitKey(1) & 0xFF) not in (ord("q"), 27)

    def close(self) -> None:
        self.cv2.destroyWindow(self.window)
