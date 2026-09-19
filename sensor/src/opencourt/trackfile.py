"""Cached detections for development footage.

Running the detector over a recording is the slow part of replaying it. ``opencourt detect``
runs it once and writes what it found — boxes and short-lived tracker numbers, nothing
else — so ``opencourt replay --tracks`` can re-run the engine with different zones or
settings in seconds. No images are stored (docs/PLAN.md §3); the files live under the
git-ignored ``data/`` directory next to the footage they came from.

Format (JSON lines): a header line ``{"video", "fps", "size", "model", "imgsz", "step"}``,
then one line per processed frame ``{"t": seconds, "tracks": [[x1, y1, x2, y2, id, conf]]}``
where ``id`` is null when the tracker hasn't assigned one.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any

from .types import Observation, Track


@dataclass(frozen=True)
class TrackFileHeader:
    video: str
    fps: float
    size: tuple[int, int]
    model: str
    imgsz: int
    step: int  # every Nth video frame was processed


def write_header(f: IO[str], header: TrackFileHeader) -> None:
    f.write(json.dumps({"video": header.video, "fps": header.fps, "size": list(header.size),
                        "model": header.model, "imgsz": header.imgsz,
                        "step": header.step}) + "\n")


def write_frame(f: IO[str], t: float, tracks: tuple[Track, ...]) -> None:
    rows = [[round(v, 1) for v in tr.bbox] + [tr.track_id, round(tr.confidence, 3)]
            for tr in tracks]
    f.write(json.dumps({"t": round(t, 3), "tracks": rows}) + "\n")


def read(path: str | Path) -> tuple[TrackFileHeader, Iterator[Observation]]:
    f = open(path)  # noqa: SIM115 - closed by the generator
    raw: dict[str, Any] = json.loads(f.readline())
    header = TrackFileHeader(video=raw["video"], fps=raw["fps"], size=tuple(raw["size"]),
                             model=raw["model"], imgsz=raw["imgsz"], step=raw["step"])

    def frames() -> Iterator[Observation]:
        with f:
            for line in f:
                if not line.strip():
                    continue
                d = json.loads(line)
                yield Observation(d["t"], tuple(
                    Track(bbox=(r[0], r[1], r[2], r[3]), track_id=r[4], confidence=r[5])
                    for r in d["tracks"]
                ))

    return header, frames()
