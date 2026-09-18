"""The engine: observations in, court snapshots out. No IO, no camera, no hardware."""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from typing import Any

from .activity import CrossingLedger, FastOccupancy
from .config import Config
from .crossings import CrossingDetector
from .estimate import WaitEstimate, estimate_wait
from .geometry import ZoneMap
from .line import CourtLine, FillEvidence, LineEvent
from .signals import CourtSignal, court_signal, rotating
from .smoothing import RollingMedian, Sustained
from .types import Health, Observation, Zone

PAYLOAD_VERSION = 1


@dataclass(frozen=True, slots=True)
class CourtSnapshot:
    number: int
    occupancy: float
    signal: CourtSignal


@dataclass(frozen=True, slots=True)
class Snapshot:
    t: float
    wall_time: float
    health: Health
    queue_count: float
    queue_waiting: bool
    courts: tuple[CourtSnapshot, ...]
    wait: WaitEstimate
    events: tuple[LineEvent, ...] = field(default_factory=tuple)

    def to_payload(self, site_id: str) -> dict[str, Any]:
        """What leaves the device. Counts and states only (docs/PLAN.md §3)."""

        def r(x: float | None) -> int | None:
            return None if x is None else int(round(x))

        return {
            "version": PAYLOAD_VERSION,
            "site_id": site_id,
            "generated_at": self.wall_time,
            "health": self.health.value,
            "queue": {"count": round(self.queue_count, 1), "waiting": self.queue_waiting},
            "wait": {
                "next_free_seconds": r(self.wait.next_free_seconds),
                "wait_seconds": r(self.wait.wait_seconds),
                "groups_ahead": self.wait.groups_ahead,
            },
            "courts": [
                {
                    "number": c.number,
                    "state": c.signal.state.value,
                    "light": c.signal.light.value,
                    "occupancy": round(c.occupancy, 1),
                    "clock_seconds": r(c.signal.clock_seconds),
                    "seconds_remaining": r(c.signal.seconds_remaining),
                    "on_court_seconds": r(c.signal.on_court_seconds),
                }
                for c in self.courts
            ],
        }

    def signature(self) -> tuple:
        """Changes when anything a viewer would notice changes (used to throttle publishing)."""
        return (
            self.health,
            round(self.queue_count),
            self.queue_waiting,
            tuple((c.signal.state, round(c.occupancy)) for c in self.courts),
        )


class Engine:
    def __init__(self, cfg: Config, wall_clock: Callable[[], float] = time.time):
        self.cfg = cfg
        zones = cfg.require_zones()
        self.zone_map = ZoneMap(zones)
        self.courts = self.zone_map.court_numbers
        self._wall_clock = wall_clock

        w = cfg.smoothing.window_seconds
        self.court_sm = {c: RollingMedian(w) for c in self.courts}
        self.queue_sm = RollingMedian(w)
        self.crossings = CrossingDetector(cfg.tracking.zone_dwell_seconds,
                                          cfg.tracking.track_ttl_seconds,
                                          cfg.tracking.handoff_radius_px,
                                          cfg.tracking.handoff_seconds,
                                          cfg.tracking.excursion_seconds)
        self.queue_gate = Sustained(cfg.queue.on_seconds, cfg.queue.off_seconds)
        rot = cfg.rotation
        self.fast = FastOccupancy(self.courts, rot.fast_window_seconds, rot.empty_below_people,
                                  cfg.court.occupied_min_people, rot.fill_confirm_seconds,
                                  rot.expected_fill_confirm_seconds)
        self.ledger = CrossingLedger(
            keep=max(rot.shift_window_seconds, rot.restore_seconds) + 60,
            transit_seconds=rot.queue_transit_seconds)
        self.line = CourtLine(len(self.courts), rot)
        self.event_log: list[LineEvent] = []

        self._t0: float | None = None
        self._seeded = False
        self._last_turnover_check = -1e18
        self._last_frame_t: float | None = None

    @property
    def last_frame_t(self) -> float | None:
        return self._last_frame_t

    # -- health ---------------------------------------------------------------------------

    def _health(self, t: float) -> Health:
        if self._t0 is None or t - self._t0 < self.cfg.warmup_seconds:
            return Health.WARMING_UP
        stale = self.cfg.health.stale_frame_seconds
        if self._last_frame_t is None or t - self._last_frame_t > stale:
            return Health.DEGRADED
        return Health.OK

    def tick(self, t: float) -> Snapshot:
        """Produce a snapshot without a new frame (e.g. camera stalled)."""
        return self._snapshot(t, ())

    # -- main step ------------------------------------------------------------------------

    def step(self, obs: Observation) -> Snapshot:
        t = obs.t
        if self._t0 is None:
            self._t0 = t
        self._last_frame_t = t

        counts = {c: 0 for c in self.courts}
        queue_raw = 0
        zoned: list[tuple[int, str, tuple[float, float]]] = []
        for tr in obs.tracks:
            foot = tr.foot
            zone = self.zone_map.classify(foot)
            if zone == Zone.QUEUE:
                queue_raw += 1
            elif zone != Zone.OTHER:
                counts[int(zone.removeprefix("court_"))] += 1
            if tr.track_id is not None:
                zoned.append((tr.track_id, zone, foot))

        for c in self.courts:
            self.court_sm[c].add(t, counts[c])
        queue = self.queue_sm.add(t, queue_raw)
        crossings = self.crossings.update(t, zoned)
        self.queue_gate.update(t, queue >= self.cfg.queue.min_people)

        occ_min = self.cfg.court.occupied_min_people
        occupied = {c: self.court_sm[c].value >= occ_min for c in self.courts}

        self.ledger.add(t, crossings)
        self.fast.expecting = {c for c, v in self.line.vacancies.items()
                               if v.incoming is not None}
        transitions = self.fast.update(t, counts)

        events: list[LineEvent] = []
        if self._health(t) is not Health.WARMING_UP:
            if not self._seeded:
                self.line.seed(t, {c for c, o in occupied.items() if o})
                self._seeded = True
            # Empties before fills, top court first: a move-up needs the vacancy above to
            # exist before the court below reports empty.
            for kind, c in sorted(transitions, key=lambda x: (x[0] != "empty", -x[1])):
                if kind == "empty":
                    events += self.line.on_empty(c, t)
                else:
                    events += self.line.on_fill(c, t, self._evidence)
            events += self.line.decide(t, self.ledger.flows)
            if t - self._last_turnover_check >= self.cfg.rotation.turnover_check_seconds:
                self._last_turnover_check = t
                events += self.line.check_turnover(t, self.ledger.flows)
            events += self.line.expire(t)
            self.event_log += events
        return self._snapshot(t, tuple(events))

    def _evidence(self, court: int, since: float) -> FillEvidence:
        ev = self.ledger.into(court, since)
        before = self.queue_sm.value_at(since - self.cfg.rotation.queue_lookback_seconds)
        return replace(ev, queue_drop=before - self.queue_sm.value)

    def _snapshot(self, t: float, events: tuple[LineEvent, ...]) -> Snapshot:
        health = self._health(t)
        waiting = self.queue_gate.state
        courts = []
        for c in self.courts:
            sig = court_signal(
                self.line.slots[c], t,
                health=health,
                waiting=waiting,
                waiting_since=self.queue_gate.since,
                timer=self.cfg.timer,
            )
            if health is Health.OK and self.line.is_rotating(c):
                sig = rotating(sig)
            courts.append(CourtSnapshot(c, self.court_sm[c].value, sig))
        if health is Health.OK:
            wait = estimate_wait(
                [cs.signal.on_court_seconds for cs in courts],
                self.queue_sm.value,
                self.cfg.court.players_per_group,
                self.cfg.estimate,
            )
        else:
            wait = WaitEstimate(None, None, 0)
        return Snapshot(
            t=t,
            wall_time=self._wall_clock(),
            health=health,
            queue_count=self.queue_sm.value,
            queue_waiting=waiting,
            courts=tuple(courts),
            wait=wait,
            events=events,
        )
