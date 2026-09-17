"""The camera loop: frames -> detector -> engine -> lights / backend / history."""

from __future__ import annotations

import json
import logging
import signal
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any

from .capture import FrameSource
from .detect import Detector
from .engine import Engine, Snapshot
from .lights import LightDriver
from .line import LineEvent
from .publish import HistoryWriter, Publisher
from .types import Observation

log = logging.getLogger(__name__)


@dataclass
class Sinks:
    lights: LightDriver
    publisher: Publisher
    history: HistoryWriter | None = None
    events: IO[str] | None = None  # JSON lines of line events (replay/evaluate)
    on_snapshot: Callable[[Snapshot], None] | None = None

    def handle(self, snap: Snapshot) -> None:
        for c in snap.courts:
            self.lights.set(c.number, c.signal.light)
        self.publisher.submit(snap)
        if self.history:
            self.history.submit(snap)
        if self.events:
            for e in snap.events:
                self.events.write(json.dumps(event_json(e)) + "\n")
        if self.on_snapshot:
            self.on_snapshot(snap)

    def close(self) -> None:
        self.lights.close()  # lights off on the way out: fail dark
        self.publisher.close()
        if self.history:
            self.history.close()


def event_json(e: LineEvent) -> dict[str, Any]:
    d: dict[str, Any] = {"kind": e.kind.value, "t": round(e.t, 1), "court": e.court}
    if e.from_court is not None:
        d["from_court"] = e.from_court
    if e.ref is not None:
        d["ref"] = e.ref
    if e.assumed:
        d["assumed"] = True
    if e.note:
        d["note"] = e.note
    return d


class _Stop:
    def __init__(self) -> None:
        self.requested = False
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, self._handler)

    def _handler(self, *_: Any) -> None:
        self.requested = True


def run_camera(
    engine: Engine,
    source_factory: Callable[[], FrameSource],
    detector: Detector,
    sinks: Sinks,
    overlay: Any | None = None,
    reconnect: bool = True,
) -> None:
    """Run until the source ends (files) or a stop signal (live cameras).

    If a live camera fails, the engine keeps ticking so health turns DEGRADED and the
    lights go dark, and the source is reopened with backoff.
    """
    stop = _Stop()
    backoff = 1.0
    fps_t0, fps_n = time.monotonic(), 0
    try:
        while not stop.requested:
            source = None
            try:
                source = source_factory()
                for t, frame in source.frames():
                    tracks = detector(frame)
                    snap = engine.step(Observation(t, tracks))
                    sinks.handle(snap)
                    if overlay is not None and not overlay.show(frame, tracks, snap):
                        stop.requested = True
                    fps_n += 1
                    if time.monotonic() - fps_t0 >= 60:
                        log.info("%.1f fps, health=%s", fps_n / (time.monotonic() - fps_t0),
                                 snap.health.value)
                        fps_t0, fps_n = time.monotonic(), 0
                    if stop.requested:
                        break
                    backoff = 1.0
                else:
                    return  # source exhausted (recorded video)
            except Exception:
                if not reconnect:
                    raise
                log.exception("capture failed; retrying in %.0fs", backoff)
                deadline = time.monotonic() + backoff
                while time.monotonic() < deadline and not stop.requested:
                    sinks.handle(engine.tick(_engine_now(engine)))
                    time.sleep(1.0)
                backoff = min(backoff * 2, 30.0)
            finally:
                if source is not None:
                    source.close()
    finally:
        sinks.close()
        if overlay is not None:
            overlay.close()


def _engine_now(engine: Engine) -> float:
    # Live sources use time.monotonic() as their clock, so ticks can use it too.
    return time.monotonic()


def history_path(cfg_path: Path, rel: str | None) -> Path | None:
    if rel is None:
        return None
    p = Path(rel)
    return p if p.is_absolute() else cfg_path.resolve().parent.parent / p
