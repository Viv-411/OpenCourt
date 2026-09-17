from opencourt.config import Zones
from opencourt.geometry import ZoneMap, point_in_polygon
from opencourt.smoothing import RollingMedian, Sustained
from opencourt.types import Track

SQUARE = [(0, 0), (10, 0), (10, 10), (0, 10)]


def test_point_in_polygon():
    assert point_in_polygon((5, 5), SQUARE)
    assert not point_in_polygon((15, 5), SQUARE)
    assert not point_in_polygon((-1, -1), SQUARE)
    concave = [(0, 0), (10, 0), (10, 10), (5, 5), (0, 10)]
    assert not point_in_polygon((5, 8), concave)
    assert point_in_polygon((5, 2), concave)


def test_foot_point_is_bottom_center():
    t = Track((10, 20, 30, 100))
    assert t.foot == (20, 100)
    assert Track.at_foot(50, 60).foot == (50, 60)


def test_zone_map_prefers_courts_over_queue():
    zones = Zones(
        courts={1: SQUARE, 2: [(20, 0), (30, 0), (30, 10), (20, 10)]},
        queue=[(-5, -5), (12, -5), (12, 12), (-5, 12)],  # overlaps court 1
    )
    zm = ZoneMap(zones)
    assert zm.classify((5, 5)) == "court_1"
    assert zm.classify((25, 5)) == "court_2"
    assert zm.classify((11, 11)) == "queue"
    assert zm.classify((100, 100)) == "other"


def test_rolling_median_rejects_single_frame_spikes():
    rm = RollingMedian(window=10)
    for i in range(20):
        rm.add(i * 0.5, 4)
    assert rm.add(10.0, 0) == 4  # one dropped frame changes nothing
    assert rm.value_at(3.0) == 4


def test_rolling_median_window_expires():
    rm = RollingMedian(window=5)
    for i in range(10):
        rm.add(i, 4)
    for i in range(10, 20):
        rm.add(i, 0)
    assert rm.value == 0
    assert rm.value_at(9) == 4


def test_sustained_asymmetric_hysteresis():
    s = Sustained(on_seconds=60, off_seconds=180)
    assert not s.update(0, True)
    assert not s.update(59, True)
    assert s.update(60, True)
    assert s.since == 0  # backdated to when the condition started
    assert s.update(100, False)
    assert s.update(279, False)  # still on: needs 180 s of false
    assert not s.update(280, False)
    assert s.since is None


def test_sustained_brief_gap_does_not_reset():
    s = Sustained(on_seconds=10, off_seconds=60)
    s.update(0, True)
    s.update(10, True)
    s.update(20, False)
    s.update(50, True)  # back before off_seconds elapsed
    assert s.state and s.since == 0
