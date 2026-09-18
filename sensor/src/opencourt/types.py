"""Plain data types shared across the pipeline.

Nothing here carries identity. A ``Track.track_id`` is an ephemeral integer from a
motion-only tracker; it is only ever used to count zone-boundary crossings over a
few seconds (docs/PLAN.md §3).
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

Point = tuple[float, float]


@dataclass(frozen=True, slots=True)
class Track:
    """One tracked person in one frame.

    ``bbox`` is (x1, y1, x2, y2) in pixels. ``track_id`` is None when the tracker
    has not (yet) assigned an ID; such detections still count toward occupancy.
    """

    bbox: tuple[float, float, float, float]
    track_id: int | None = None
    confidence: float = 1.0

    @property
    def foot(self) -> Point:
        """Bottom-center of the box: approximate ground contact point."""
        x1, _, x2, y2 = self.bbox
        return ((x1 + x2) / 2.0, y2)

    @classmethod
    def at_foot(cls, x: float, y: float, track_id: int | None = None,
                width: float = 30.0, height: float = 80.0) -> Track:
        """Build a track whose foot point is (x, y). Handy for tests and the simulator."""
        return cls((x - width / 2, y - height, x + width / 2, y), track_id)


@dataclass(frozen=True, slots=True)
class Observation:
    """Everything the engine needs from one processed frame."""

    t: float  # seconds, monotonic within a session (video time during replay)
    tracks: tuple[Track, ...]


class Zone(StrEnum):
    QUEUE = "queue"
    OTHER = "other"

    @staticmethod
    def court(number: int) -> str:
        return f"court_{number}"


def court_number(zone: str) -> int | None:
    if zone.startswith("court_"):
        return int(zone.removeprefix("court_"))
    return None


@dataclass(frozen=True, slots=True)
class Crossing:
    """A track that settled in ``to_zone`` after having been settled in ``from_zone``."""

    t: float
    track_id: int
    from_zone: str
    to_zone: str
    # When this track was last seen waiting in the line, if it was. Kept because people
    # walking from the line to a court cross the walkway on the way (and often pick up a new
    # tracker ID doing it), so ``from_zone`` alone loses where they actually came from.
    queue_seen_t: float | None = None


class CourtState(StrEnum):
    UNKNOWN = "unknown"
    EMPTY = "empty"
    ROTATING = "rotating"  # a group is moving onto this court; light held until it arrives
    IDLE = "idle"
    ACTIVE = "active"
    WARNING = "warning"
    DUE = "due"


class LightMode(StrEnum):
    OFF = "off"
    PULSE = "pulse"
    SOLID = "solid"


LIGHT_FOR_STATE: dict[CourtState, LightMode] = {
    CourtState.UNKNOWN: LightMode.OFF,
    CourtState.EMPTY: LightMode.OFF,
    CourtState.ROTATING: LightMode.OFF,
    CourtState.IDLE: LightMode.OFF,
    CourtState.ACTIVE: LightMode.OFF,
    CourtState.WARNING: LightMode.PULSE,
    CourtState.DUE: LightMode.SOLID,
}


class Health(StrEnum):
    WARMING_UP = "warming_up"
    OK = "ok"
    DEGRADED = "degraded"
