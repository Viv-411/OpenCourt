"""Per-court activity for the line model: empty/fill transitions and crossing evidence."""

from __future__ import annotations

from collections import deque

from .line import FillEvidence, Flows
from .smoothing import RollingMedian
from .types import Crossing, Zone, court_number


class FastOccupancy:
    """Lightly smoothed counts that catch the short empty spell between one group leaving a
    court and the next arriving. Emits ("empty"|"fill", court) transitions.

    A fill must hold for ``fill_confirm`` seconds, so a group walking *through* a court along
    the lane toward the entrance doesn't look like a group arriving to play."""

    def __init__(self, courts: list[int], window: float, empty_below: float, fill_at: float,
                 fill_confirm: float = 0.0, expected_confirm: float = 0.0):
        self._sm = {c: RollingMedian(window, history_seconds=0) for c in courts}
        self._empty_below = empty_below
        self._fill_at = fill_at
        self._fill_confirm = fill_confirm
        self._expected_confirm = expected_confirm
        self.expecting: set[int] = set()  # courts a group is known to be walking onto
        self._fill_since: dict[int, float] = {}
        self.empty: dict[int, bool] | None = None

    def update(self, t: float, counts: dict[int, int]) -> list[tuple[str, int]]:
        values = {c: sm.add(t, counts.get(c, 0)) for c, sm in self._sm.items()}
        if self.empty is None:
            self.empty = {c: v < self._fill_at for c, v in values.items()}
            return []
        out = []
        for c, v in values.items():
            if not self.empty[c] and v < self._empty_below:
                self.empty[c] = True
                out.append(("empty", c))
            elif self.empty[c]:
                if v < self._fill_at:
                    self._fill_since.pop(c, None)
                elif t - self._fill_since.setdefault(c, t) >= (
                    self._expected_confirm if c in self.expecting else self._fill_confirm
                ):
                    self.empty[c] = False
                    self._fill_since.pop(c, None)
                    out.append(("fill", c))
        return out


class CrossingLedger:
    """Recent zone crossings, kept for ``keep`` seconds, queryable per destination court."""

    def __init__(self, keep: float):
        self.keep = keep
        self._items: deque[Crossing] = deque()

    def add(self, t: float, crossings: list[Crossing]) -> None:
        self._items.extend(crossings)
        while self._items and self._items[0].t < t - self.keep:
            self._items.popleft()

    def into(self, court: int, since: float) -> FillEvidence:
        below = outside = queue = 0
        target = Zone.court(court)
        for x in self._items:
            if x.t < since or x.to_zone != target:
                continue
            src = court_number(x.from_zone)
            if src == court - 1:
                below += 1
            elif x.from_zone == Zone.QUEUE:
                queue += 1
            elif src is None:
                outside += 1
        return FillEvidence(from_below=below, from_outside=outside, from_queue=queue)

    def flows(self, court: int, since: float) -> Flows:
        """Everyone who crossed court ``court``'s boundary since ``since``, by direction."""
        f = dict(out_outside=0, out_down=0, out_up=0, in_below=0, in_above=0, in_queue=0,
                 in_other=0)
        me = Zone.court(court)
        for x in self._items:
            if x.t < since:
                continue
            if x.from_zone == me:
                other = court_number(x.to_zone)
                if other is None:
                    f["out_outside"] += 1
                elif other == court - 1:
                    f["out_down"] += 1
                elif other == court + 1:
                    f["out_up"] += 1
            elif x.to_zone == me:
                other = court_number(x.from_zone)
                if other == court - 1:
                    f["in_below"] += 1
                elif other == court + 1:
                    f["in_above"] += 1
                elif x.from_zone == Zone.QUEUE:
                    f["in_queue"] += 1
                else:
                    f["in_other"] += 1
        return Flows(**f)
