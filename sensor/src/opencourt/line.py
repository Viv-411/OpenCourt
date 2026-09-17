"""The ordered line of groups on the courts (docs/PLAN.md §2, §6).

Shift-up rotation: when the group on court k leaves, every group below moves up one court
and the next group in line takes court 1. Groups never overtake each other, so a group's
clock — and its light — can follow it from court to court *by position*, without
recognising anyone.

The line is driven online by two per-court events from lightly smoothed counts:

* ``on_empty(c)`` — court c just went empty. A few seconds later (once crossings are in),
  ``decide(t)`` settles what happened: if people were seen crossing onto the open court
  above, the group moved up and its clock is handed over; otherwise the group left (which a
  quick return can still undo).
* ``on_fill(c)`` — court c just became occupied again. The newcomer is, in order of
  preference: the group already known to be moving in; a new group from the queue (court 1);
  the group from the court below if people were seen crossing up from it ("silent" shift);
  the same group returning from a break if they were seen coming back from outside; or,
  when nothing is certain, a new group with a fresh clock.

Every fallback hands out a *younger* clock than the truth could be. Uncertainty can delay a
light; it must never light a group early (docs/PLAN.md §5).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum

from .config import RotationConfig


@dataclass(frozen=True, slots=True)
class Group:
    on_since: float  # when this group stepped onto the courts
    assumed: bool = False  # True when on_since is a conservative guess (boot, uncertainty)
    # Stand-in for "whoever took this court after its group moved up". If the court then
    # empties, that was just the moving group finishing its walk, not a departure.
    provisional: bool = False


class LineEventKind(StrEnum):
    DEPARTURE = "departure"  # a group left the courts (may later be undone by RESTORE)
    RESTORE = "restore"  # the "departed" group was only on a break; clock restored
    MOVE = "move"  # a group moved up a court, clock and light with it
    ARRIVAL = "arrival"  # a new group started on a court
    LOST = "lost"  # a group expected to move in never arrived


@dataclass(frozen=True, slots=True)
class LineEvent:
    kind: LineEventKind
    t: float
    court: int
    from_court: int | None = None
    ref: int | None = None  # departure id (DEPARTURE / RESTORE)
    assumed: bool = False
    note: str = ""


@dataclass(frozen=True, slots=True)
class FillEvidence:
    """People seen crossing onto a court since a given time, by where they came from."""

    from_below: int = 0  # from court c-1
    from_outside: int = 0  # from the lane / walkway / anywhere that is not a court or queue
    from_queue: int = 0
    queue_drop: float = 0.0  # smoothed queue length back then minus now


EvidenceFn = Callable[[int, float], FillEvidence]


@dataclass(frozen=True, slots=True)
class Flows:
    """Crossings of one court's boundary, by direction (see activity.CrossingLedger)."""

    out_outside: int = 0  # to the lane / walkway / queue
    out_down: int = 0  # to court c-1 (e.g. walking the lane toward the entrance)
    out_up: int = 0  # to court c+1 (moving up)
    in_below: int = 0  # from court c-1 (moving up onto this court)
    in_above: int = 0  # from court c+1 (someone walking down the lane through this court)
    in_queue: int = 0
    in_other: int = 0  # from the lane/walkway, or from a court that isn't a neighbour

    @property
    def left(self) -> int:
        """People who left toward the entrance, net of people just passing through."""
        return self.out_outside + self.out_down - self.in_above


FlowsFn = Callable[[int, float], Flows]


@dataclass(slots=True)
class Vacancy:
    since: float
    removed: Group | None = None  # the group that left (kept for a possible RESTORE)
    departure_id: int | None = None
    incoming: Group | None = None  # a group moving up into this court
    incoming_from: int | None = None
    incoming_since: float | None = None
    undecided: Group | None = None  # the group that just stepped off; decide() settles it
    decide_at: float = 0.0


class CourtLine:
    def __init__(self, court_count: int, cfg: RotationConfig):
        self.court_count = court_count
        self.cfg = cfg
        self.slots: dict[int, Group | None] = {c: None for c in range(1, court_count + 1)}
        self.vacancies: dict[int, Vacancy] = {}
        self._next_departure = 1
        self._last_change: dict[int, float] = {}

    # -- queries ----------------------------------------------------------------------------

    @property
    def occupied(self) -> set[int]:
        return {c for c, g in self.slots.items() if g is not None}

    def is_rotating(self, c: int) -> bool:
        """Groups are changing here (someone just stepped off, or a group is on its way in):
        hold the light until it's clear who is on the court."""
        v = self.vacancies.get(c)
        return v is not None and (v.incoming is not None or v.undecided is not None)

    def seed(self, t: float, occupied: set[int]) -> None:
        """Boot: groups already playing get the full time (on_since = now, assumed)."""
        self.vacancies.clear()
        for c in self.slots:
            if c in occupied:
                self.slots[c] = Group(t, assumed=True)
            else:
                self.slots[c] = None
                self.vacancies[c] = Vacancy(since=t)

    # -- events -----------------------------------------------------------------------------

    def on_empty(self, c: int, t: float) -> list[LineEvent]:
        if c in self.vacancies:
            return []
        self._last_change[c] = t
        group = self.slots[c]
        self.slots[c] = None
        if group is None:
            self.vacancies[c] = Vacancy(since=t)
            return []
        if group.provisional and t - group.on_since <= self.cfg.shift_window_seconds:
            self.vacancies[c] = Vacancy(since=t)
            return []
        self.vacancies[c] = Vacancy(since=t, undecided=group,
                                    decide_at=t + self.cfg.decide_delay_seconds)
        return []

    def decide(self, t: float, flows: FlowsFn) -> list[LineEvent]:
        """Settle every emptied court whose decision delay has passed (top court first, so a
        chain of move-ups hands clocks over in order)."""
        events: list[LineEvent] = []
        for c in sorted(self.vacancies, reverse=True):
            v = self.vacancies[c]
            if v.undecided is not None and t >= v.decide_at:
                events += self._decide(c, t, flows)
        return events

    def _decide(self, c: int, t: float, flows: FlowsFn) -> list[LineEvent]:
        v = self.vacancies[c]
        group, v.undecided = v.undecided, None
        assert group is not None
        above = self.vacancies.get(c + 1)
        since = v.since - self.cfg.decide_lookback_seconds
        # Seen stepping onto the open court above — directly, or by a longer walk (e.g. from
        # the end of one row of courts to the start of the next).
        went_up = flows(c, since).out_up + (flows(c + 1, since).in_other if above else 0)
        if (above is not None and went_up >= self.cfg.evidence_min_people
                and t - above.since <= self.cfg.shift_window_seconds):
            if above.incoming is not None:
                self._push_incoming_up(c + 1, t)
            if above.incoming is None:
                above.incoming, above.incoming_from, above.incoming_since = group, c, v.since
                return [LineEvent(LineEventKind.MOVE, v.since, c + 1, from_court=c)]
        dep = self._next_departure
        self._next_departure += 1
        v.removed, v.departure_id = group, dep
        return [LineEvent(LineEventKind.DEPARTURE, v.since, c, ref=dep)]

    def _push_incoming_up(self, c: int, t: float) -> None:
        """Court c is still waiting for a group that, it turns out, kept walking: with several
        empty courts above, groups move up more than once before settling. If there is an open
        court further up, every group in transit moves one step along the chain."""
        top = c
        while top in self.vacancies and self.vacancies[top].incoming is not None:
            top += 1
        target = self.vacancies.get(top)
        if target is None or t - target.since > self.cfg.shift_window_seconds:
            return
        for k in range(top, c, -1):
            src, dst = self.vacancies[k - 1], self.vacancies[k]
            dst.incoming, dst.incoming_from, dst.incoming_since = (
                src.incoming, src.incoming_from, t)
        self.vacancies[c].incoming = None
        self.vacancies[c].incoming_from = None

    def on_fill(self, c: int, t: float, evidence: EvidenceFn) -> list[LineEvent]:
        self._last_change[c] = t
        v = self.vacancies.pop(c, None)
        if v is None:
            if self.slots[c] is None:  # should not happen; be lenient
                self.slots[c] = Group(t, assumed=True)
                return [LineEvent(LineEventKind.ARRIVAL, t, c, assumed=True, note="no vacancy")]
            return []

        if v.undecided is not None:  # back before we even decided: nothing happened
            self.slots[c] = v.undecided
            return []

        events: list[LineEvent] = []
        below = self.vacancies.get(c - 1)
        if (below is not None and below.undecided is not None and v.incoming is None
                and evidence(c, v.since).from_below >= self.cfg.evidence_min_people):
            # The group from below arrived before we got round to deciding: it moved up.
            group, below.undecided = below.undecided, None
            v.incoming, v.incoming_from = group, c - 1
            events.append(LineEvent(LineEventKind.MOVE, below.since, c, from_court=c - 1))

        if v.incoming is not None:
            self.slots[c] = v.incoming
            return events  # the MOVE was already reported

        need = self.cfg.evidence_min_people
        ev = evidence(c, v.since)

        if c == 1 and (ev.from_queue >= need or ev.queue_drop >= need):
            self.slots[1] = Group(t)
            return [LineEvent(LineEventKind.ARRIVAL, t, 1)]

        if c > 1 and ev.from_below >= need and self.slots.get(c - 1) is not None:
            return self._silent_shift(c, t, v.since, evidence)

        if (v.removed is not None and ev.from_outside >= need and ev.from_below < need
                and t - v.since <= self.cfg.restore_seconds):
            self.slots[c] = v.removed
            return [LineEvent(LineEventKind.RESTORE, t, c, ref=v.departure_id)]

        self.slots[c] = Group(t, assumed=True)
        return [LineEvent(LineEventKind.ARRIVAL, t, c, assumed=True, note="unclear who arrived")]

    def _silent_shift(self, c: int, t: float, since: float,
                      evidence: EvidenceFn) -> list[LineEvent]:
        """Court c refilled from below without the lower court ever looking empty: the chain
        below moved up at once. Walk down while people were seen crossing up."""
        events = []
        need = self.cfg.evidence_min_people
        i = c
        while i > 1 and self.slots.get(i - 1) is not None and (
            i == c or evidence(i, since).from_below >= need
        ):
            self.slots[i] = self.slots[i - 1]
            events.append(LineEvent(LineEventKind.MOVE, t, i, from_court=i - 1,
                                    note="seen crossing up"))
            i -= 1
        # Court i's group moved up and someone we can't place took its spot: a new group from
        # the queue if it's court 1 and the line shrank, otherwise unknown (fresh clock).
        ev = evidence(i, since)
        from_queue = i == 1 and (ev.from_queue >= need or ev.queue_drop >= need)
        self.slots[i] = Group(t, assumed=not from_queue, provisional=True)
        events.append(LineEvent(LineEventKind.ARRIVAL, t, i, assumed=not from_queue,
                                note="took the court the moving group left"))
        return events

    def check_turnover(self, t: float, flows: FlowsFn) -> list[LineEvent]:
        """Catch a quick swap: a group left and the next one walked on before the court ever
        looked empty. Checked top court first so a chain of move-ups resolves in order."""
        events: list[LineEvent] = []
        need = self.cfg.turnover_min_people
        gave_up: set[int] = set()  # courts whose group we just moved up
        for c in range(self.court_count, 0, -1):
            if c in self.vacancies:
                continue
            since = max(t - self.cfg.turnover_window_seconds, self._last_change.get(c, -1e18))
            f = flows(c, since)
            came = f.in_queue if c == 1 else f.in_below
            if came < need:
                continue
            below = self.slots.get(c - 1) if c > 1 else None
            if c in gave_up:
                pass  # its group already moved up; someone new came in behind
            elif f.left >= need and self.slots[c] is not None:
                dep = self._next_departure
                self._next_departure += 1
                events.append(LineEvent(LineEventKind.DEPARTURE, t, c, ref=dep,
                                        note="quick swap"))
            else:
                continue
            if c > 1 and below is not None and (c - 1) not in self.vacancies:
                self.slots[c] = below
                self.slots[c - 1] = Group(t, assumed=True, provisional=True)
                gave_up.add(c - 1)
                events.append(LineEvent(LineEventKind.MOVE, t, c, from_court=c - 1,
                                        note="quick swap"))
            else:
                self.slots[c] = Group(t, assumed=c != 1)
                events.append(LineEvent(LineEventKind.ARRIVAL, t, c, assumed=c != 1))
            self._last_change[c] = t
        return events

    def expire(self, t: float) -> list[LineEvent]:
        events = []
        for c, v in self.vacancies.items():
            if v.incoming is not None and t - (v.incoming_since or v.since) > (
                self.cfg.arrival_timeout_seconds
            ):
                events.append(LineEvent(LineEventKind.LOST, t, c, from_court=v.incoming_from))
                v.incoming = None
                v.incoming_from = None
            if v.removed is not None and t - v.since > self.cfg.restore_seconds:
                v.removed = None  # the departure is final
        return events


def net_departures(events: list[LineEvent]) -> list[tuple[float, int]]:
    """(time, court) of departures that were not later undone by a RESTORE."""
    restored = {e.ref for e in events if e.kind is LineEventKind.RESTORE}
    return [(e.t, e.court) for e in events
            if e.kind is LineEventKind.DEPARTURE and e.ref not in restored]
