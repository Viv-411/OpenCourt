"""Frame sources. Frames stay in memory; nothing here writes to disk (docs/PLAN.md §3)."""

from __future__ import annotations

import time
from collections.abc import Iterator
from typing import Any, Protocol

from .config import CaptureConfig


class FrameSource(Protocol):
    def frames(self) -> Iterator[tuple[float, Any]]:
        """Yield (t, BGR frame). ``t`` is seconds on a monotonic session clock."""
        ...

    def close(self) -> None: ...


class VideoFileSource:
    """Recorded footage for development. ``t`` is *video* time, so replay is deterministic
    and can run faster than real time (``realtime=False``)."""

    def __init__(self, path: str, target_fps: float, realtime: bool = False):
        import cv2

        self._cap = cv2.VideoCapture(path)
        if not self._cap.isOpened():
            raise FileNotFoundError(f"cannot open video {path}")
        self.fps = self._cap.get(cv2.CAP_PROP_FPS) or 30.0
        self.frame_count = int(self._cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        self.width = int(self._cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.height = int(self._cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        self._step = max(1, round(self.fps / target_fps))
        self._realtime = realtime

    @property
    def step(self) -> int:
        return self._step

    def frames(self) -> Iterator[tuple[float, Any]]:
        idx = 0
        start = time.monotonic()
        while True:
            ok = self._cap.grab()
            if not ok:
                return
            if idx % self._step == 0:
                ok, frame = self._cap.retrieve()
                if not ok:
                    return
                t = idx / self.fps
                if self._realtime:
                    delay = start + t - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                yield t, frame
            idx += 1

    def close(self) -> None:
        self._cap.release()


class _Paced:
    def __init__(self, target_fps: float):
        self._period = 1.0 / target_fps
        self._next = time.monotonic()

    def wait(self) -> float:
        now = time.monotonic()
        if now < self._next:
            time.sleep(self._next - now)
            now = self._next
        self._next = max(self._next + self._period, now)
        return now


class UsbCameraSource:
    def __init__(self, index: int, cfg: CaptureConfig):
        import cv2

        self._cap = cv2.VideoCapture(index)
        if not self._cap.isOpened():
            raise RuntimeError(f"cannot open USB camera {index}")
        self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, cfg.width)
        self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, cfg.height)
        self._pace = _Paced(cfg.target_fps)

    def frames(self) -> Iterator[tuple[float, Any]]:
        while True:
            t = self._pace.wait()
            ok, frame = self._cap.read()
            if not ok:
                raise RuntimeError("USB camera read failed")
            yield t, frame

    def close(self) -> None:
        self._cap.release()


class PiCameraSource:
    """Pi Camera Module 3 Wide via picamera2 (installed from apt on the Pi:
    ``sudo apt install python3-picamera2``; create the venv with --system-site-packages)."""

    def __init__(self, cfg: CaptureConfig):
        from picamera2 import Picamera2

        self._cam = Picamera2()
        # "RGB888" in picamera2 is BGR byte order, which is what OpenCV/ultralytics expect.
        conf = self._cam.create_video_configuration(
            main={"size": (cfg.width, cfg.height), "format": "RGB888"},
            buffer_count=2,
        )
        self._cam.configure(conf)
        self._cam.start()
        self._pace = _Paced(cfg.target_fps)

    def frames(self) -> Iterator[tuple[float, Any]]:
        while True:
            t = self._pace.wait()
            yield t, self._cam.capture_array("main")

    def close(self) -> None:
        self._cam.stop()
        self._cam.close()


def open_source(cfg: CaptureConfig, override: str | None = None,
                realtime: bool = False) -> FrameSource:
    """``override`` is a video path, ``usb:N``, or ``picamera``."""
    spec = override or {"file": cfg.path, "usb": f"usb:{cfg.path or 0}",
                        "picamera": "picamera"}[cfg.source]
    if spec is None:
        raise ValueError("capture.path is required for file sources")
    if spec == "picamera":
        return PiCameraSource(cfg)
    if spec.startswith("usb:"):
        return UsbCameraSource(int(spec.removeprefix("usb:")), cfg)
    return VideoFileSource(spec, cfg.target_fps, realtime=realtime)
