"""Zone geometry. Pure Python so the core runs without OpenCV."""

from __future__ import annotations

from collections.abc import Sequence

from .config import Zones
from .types import Point, Track, Zone


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


# A zone corner this close to the picture's edge is moved onto it. Nobody clicks the last
# pixel, but a corner that near means "to the edge"; and someone the frame cuts off (close to
# the camera, often in the line) has their foot point *on* the edge, which a zone stopping a
# few pixels short would miss entirely.
EDGE_SNAP_PX = 12.0


def snap_to_edges(poly: Sequence[Point], size: tuple[int, int]) -> list[Point]:
    w, h = size

    def snap(v: float, hi: int) -> float:
        if v <= EDGE_SNAP_PX:
            return 0.0
        if v >= hi - EDGE_SNAP_PX:
            return float(hi)
        return v

    return [(snap(x, w), snap(y, h)) for x, y in poly]


class ZoneMap:
    """Classifies a foot point into ``court_N``, ``queue`` or ``other``.

    Courts are checked before the queue; if polygons overlap the court wins, because
    standing on a court is the stronger claim.
    """

    def __init__(self, zones: Zones):
        size = zones.image_size

        def fit(poly: Sequence[Point]) -> list[Point]:
            return snap_to_edges(poly, size) if size else list(poly)

        self._size = size
        self._courts = sorted((n, fit(p)) for n, p in zones.courts.items())
        self._queue = fit(zones.queue)
        self._ignore = [fit(p) for p in zones.ignore]
        self.court_numbers = [n for n, _ in self._courts]

    def ignored(self, track: Track) -> bool:
        """A detection centred on something that isn't a person (drawn as an ignore area)."""
        if not self._ignore:
            return False
        x1, y1, x2, y2 = track.bbox
        centre = ((x1 + x2) / 2, (y1 + y2) / 2)
        return any(point_in_polygon(centre, poly) for poly in self._ignore)

    def classify(self, p: Point) -> str:
        if self._size:
            # Half a pixel inside the picture: a box cut off by the frame ends exactly on the
            # edge, where a point-in-polygon test could fall either way.
            w, h = self._size
            p = (min(max(p[0], 0.5), w - 0.5), min(max(p[1], 0.5), h - 0.5))
        for n, poly in self._courts:
            if point_in_polygon(p, poly):
                return Zone.court(n)
        if point_in_polygon(p, self._queue):
            return Zone.QUEUE
        return Zone.OTHER
