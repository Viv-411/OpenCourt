"""Per-court state and light (docs/PLAN.md §5). Pure functions."""

from __future__ import annotations

from bisect import bisect_right
from dataclasses import dataclass

from .config import TimerConfig
from .line import Group
from .types import LIGHT_FOR_STATE, CourtState, Health, LightMode


@dataclass(frozen=True, slots=True)
class CourtSignal:
    state: CourtState
    light: LightMode
    clock_seconds: float | None  # gated clock: time on court while someone was waiting
    seconds_remaining: float | None
    on_court_seconds: float | None  # ungated: time since the group stepped on


class HeldUpClock:
    """How long people in line have actually been held up: someone waiting *and* every
    court taken. While a court is open, whoever is waiting could walk on, so nobody is
    being kept off by the groups playing; every clock pauses (it doesn't reset: a court
    open for a few seconds mid-rotation mustn't wipe out everyone's time).

    Kept as the running total at each moment the held-up state flipped, so the total at
    any earlier time (a group's arrival, the start of the line) can be looked up.
    """

    def __init__(self) -> None:
        self._times: list[float] = []
        self._totals: list[float] = []  # total held-up seconds at each flip
        self._flags: list[bool] = []  # held up after each flip
        self.held = False

    def update(self, t: float, held: bool) -> None:
        if self._times and held == self.held:
            return
        total = self.total_at(t) if self._times else 0.0
        self._times.append(t)
        self._totals.append(total)
        self._flags.append(held)
        self.held = held

    def total_at(self, t: float) -> float:
        i = bisect_right(self._times, t) - 1
        if i < 0:
            return 0.0
        return self._totals[i] + (t - self._times[i] if self._flags[i] else 0.0)

    def between(self, start: float, end: float) -> float:
        return max(0.0, self.total_at(end) - self.total_at(start))


def court_signal(
    group: Group | None,
    now: float,
    *,
    health: Health,
    waiting: bool,
    waiting_since: float | None,
    timer: TimerConfig,
    held: HeldUpClock | None = None,
) -> CourtSignal:
    if health is not Health.OK:
        return _signal(CourtState.UNKNOWN)
    if group is None:
        return _signal(CourtState.EMPTY)
    on_court = max(0.0, now - group.on_since)
    if not waiting or waiting_since is None:
        return _signal(CourtState.IDLE, on_court=on_court)

    start = max(group.on_since, waiting_since)
    if held is None:
        clock, paused = max(0.0, now - start), False
    else:
        clock, paused = held.between(start, now), not held.held
    remaining = timer.threshold_seconds - clock
    if paused:
        state = CourtState.ACTIVE  # a court is open: nobody is held up, so no light
    elif remaining <= 0:
        state = CourtState.DUE
    elif timer.warning_seconds > 0 and remaining <= timer.warning_seconds:
        state = CourtState.WARNING
    else:
        state = CourtState.ACTIVE
    return _signal(state, clock=clock, remaining=max(0.0, remaining), on_court=on_court)


def rotating(sig: CourtSignal) -> CourtSignal:
    """Hold the light off while a court is mid-rotation, so a group moving up never walks
    onto a court that is still lit for the group that just left."""
    return CourtSignal(CourtState.ROTATING, LIGHT_FOR_STATE[CourtState.ROTATING],
                       sig.clock_seconds, sig.seconds_remaining, sig.on_court_seconds)


def _signal(state: CourtState, *, clock: float | None = None, remaining: float | None = None,
            on_court: float | None = None) -> CourtSignal:
    return CourtSignal(state, LIGHT_FOR_STATE[state], clock, remaining, on_court)
