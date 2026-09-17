"""Per-court state and light (docs/PLAN.md §5). Pure functions."""

from __future__ import annotations

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


def court_signal(
    group: Group | None,
    now: float,
    *,
    health: Health,
    waiting: bool,
    waiting_since: float | None,
    timer: TimerConfig,
) -> CourtSignal:
    if health is not Health.OK:
        return _signal(CourtState.UNKNOWN)
    if group is None:
        return _signal(CourtState.EMPTY)
    on_court = max(0.0, now - group.on_since)
    if not waiting or waiting_since is None:
        return _signal(CourtState.IDLE, on_court=on_court)

    clock = max(0.0, now - max(group.on_since, waiting_since))
    remaining = timer.threshold_seconds - clock
    if remaining <= 0:
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
