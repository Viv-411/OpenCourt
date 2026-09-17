"""Person detection + motion-only tracking (YOLO + ByteTrack via ultralytics).

Imported lazily so the core and tests never need ultralytics/torch.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol

from .config import DetectorConfig
from .types import Track

PERSON_CLASS = 0


class Detector(Protocol):
    def __call__(self, frame: Any) -> tuple[Track, ...]: ...


class YoloTracker:
    def __init__(self, cfg: DetectorConfig, base_dir: Path):
        from ultralytics import YOLO  # heavy import, deferred

        tracker = Path(cfg.tracker)
        if not tracker.is_absolute():
            tracker = base_dir / tracker
        text = tracker.read_text()
        if "bytetrack" not in text or "with_reid: true" in text.lower():
            raise ValueError(f"{tracker} must be a motion-only ByteTrack config")
        model = cfg.model
        if not Path(model).is_absolute() and (base_dir / model).exists():
            model = str(base_dir / model)
        self._model = YOLO(model, task="detect")
        self._tracker = str(tracker)
        self._cfg = cfg

    def __call__(self, frame: Any) -> tuple[Track, ...]:
        results = self._model.track(
            frame,
            persist=True,
            classes=[PERSON_CLASS],
            tracker=self._tracker,
            imgsz=self._cfg.imgsz,
            conf=self._cfg.confidence,
            device=self._cfg.device,
            verbose=False,
        )
        if not results:
            return ()
        boxes = results[0].boxes
        if boxes is None or len(boxes) == 0:
            return ()
        xyxy = boxes.xyxy.cpu().tolist()
        conf = boxes.conf.cpu().tolist()
        ids = boxes.id.int().cpu().tolist() if boxes.id is not None else [None] * len(xyxy)
        return tuple(
            Track(bbox=(b[0], b[1], b[2], b[3]), track_id=i, confidence=c)
            for b, i, c in zip(xyxy, ids, conf, strict=True)
        )


def export_ncnn(model: str, imgsz: int) -> str:
    """Export for the Pi's CPU. Returns the exported model directory."""
    from ultralytics import YOLO

    return str(YOLO(model).export(format="ncnn", imgsz=imgsz))
