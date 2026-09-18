"""Zone-boundary crossings from ephemeral tracker IDs.

A crossing is emitted only when a track that had *settled* in one zone later settles in a
different zone. Settling requires the track to stay in the zone for ``dwell`` seconds.

Consequences, by design:

* A track first seen inside a court never produces an "entry" — tracker ID switches
  create brand-new IDs mid-court all the time, and they must not look like arrivals.
* Tracks are forgotten after ``ttl`` seconds unseen. Nothing about a track outlives that.

Excursions: a track that leaves a court and settles back on the *same* court within
``excursion_seconds`` (a ball chase, a step off the sideline) produces no crossings at all.
Exits from a court are therefore reported up to ``excursion_seconds`` late.

Handoff: when a new ID appears within ``handoff_radius`` pixels and ``handoff_seconds`` of
where another ID was last seen, it inherits that track's settled zone. This is purely
positional (the same kind of association ByteTrack itself does) and bridges the ID breaks
that would otherwise hide a boundary crossing.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .types import Crossing, Point, Zone, court_number


def _is_court(zone: str) -> bool:
    return court_number(zone) is not None


@dataclass(slots=True)
class _TrackState:
    settled: str | None  # zone the track is confirmed in
    candidate: str  # zone the track is currently observed in
    candidate_since: float
    last_seen: float
    pos: Point
    handed_off: bool = False
    queue_seen_t: float | None = None  # last time this track (or its predecessor) was in the line
    pending: Crossing | None = None  # court exit held back until it is clearly not an excursion


class CrossingDetector:
    def __init__(self, dwell: float, ttl: float, handoff_radius: float = 60.0,
                 handoff_seconds: float = 1.5, excursion_seconds: float = 8.0):
        self.dwell = dwell
        self.excursion_seconds = excursion_seconds
        self.ttl = ttl
        self.handoff_radius = handoff_radius
        self.handoff_seconds = handoff_seconds
        self._tracks: dict[int, _TrackState] = {}

    def _inherit(self, t: float, pos: Point, seen_now: set[int]) -> _TrackState | None:
        best, best_d = None, self.handoff_radius
        for tid, st in self._tracks.items():
            if tid in seen_now or st.handed_off or st.settled is None:
                continue
            if not (0 < t - st.last_seen <= self.handoff_seconds):
                continue
            d = math.dist(pos, st.pos)
            if d <= best_d:
                best, best_d = st, d
        return best

    def update(self, t: float, zoned: list[tuple[int, str, Point]]) -> list[Crossing]:
        """``zoned`` is (track_id, zone, foot point) for every tracked person in this frame."""
        out: list[Crossing] = []
        seen_now = {tid for tid, _, _ in zoned}
        for tid, zone, pos in zoned:
            st = self._tracks.get(tid)
            if st is None:
                prev = self._inherit(t, pos, seen_now)
                if prev is not None:
                    prev.handed_off = True
                    st = _TrackState(settled=prev.settled, candidate=prev.candidate,
                                     candidate_since=prev.candidate_since, last_seen=t, pos=pos,
                                     pending=prev.pending, queue_seen_t=prev.queue_seen_t)
                    prev.pending = None
                else:
                    st = _TrackState(settled=None, candidate=zone, candidate_since=t,
                                     last_seen=t, pos=pos)
                self._tracks[tid] = st
            st.last_seen = t
            st.pos = pos
            if zone != st.candidate:
                st.candidate = zone
                st.candidate_since = t
            if st.candidate == Zone.QUEUE:
                st.queue_seen_t = t
            if st.candidate != st.settled and t - st.candidate_since >= self.dwell:
                if st.settled is not None:
                    self._settle(st, Crossing(t, tid, st.settled, st.candidate,
                                              queue_seen_t=st.queue_seen_t), out)
                st.settled = st.candidate
        for st in self._tracks.values():
            if st.pending is not None and t - st.pending.t > self.excursion_seconds:
                out.append(st.pending)
                st.pending = None
        stale = [tid for tid, st in self._tracks.items() if t - st.last_seen > self.ttl]
        for tid in stale:
            st = self._tracks.pop(tid)
            if st.pending is not None:
                out.append(st.pending)
        return out

    def _settle(self, st: _TrackState, x: Crossing, out: list[Crossing]) -> None:
        p = st.pending
        if p is not None:
            st.pending = None
            if x.to_zone == p.from_zone:
                return  # back where it came from: an excursion, report nothing
            out.append(p)
        if _is_court(x.from_zone) and not _is_court(x.to_zone) and self.excursion_seconds > 0:
            st.pending = x
        else:
            out.append(x)

    @property
    def live_tracks(self) -> int:
        return len(self._tracks)
