"""Zone geometry. Pure Python so the core runs without OpenCV."""

from __future__ import annotations

from collections.abc import Sequence

from .config import Zones
from .types import Point, Zone


def point_in_polygon(p: Point, poly: Sequence[Point]) -> bool:
    """Even-odd ray casting. Points exactly on an edge may land either way, which is fine
    for foot points: the dwell requirement absorbs boundary jitter."""
    x, y = p
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            x_cross = xi + (y - yi) * (xj - xi) / (yj - yi)
            if x < x_cross:
                inside = not inside
        j = i
    return inside


class ZoneMap:
    """Classifies a foot point into ``court_N``, ``queue`` or ``other``.

    Courts are checked before the queue; if polygons overlap the court wins, because
    standing on a court is the stronger claim.
    """

    def __init__(self, zones: Zones):
        self._courts = sorted(zones.courts.items())
        self._queue = zones.queue
        self.court_numbers = [n for n, _ in self._courts]

    def classify(self, p: Point) -> str:
        for n, poly in self._courts:
            if point_in_polygon(p, poly):
                return Zone.court(n)
        if point_in_polygon(p, self._queue):
            return Zone.QUEUE
        return Zone.OTHER
