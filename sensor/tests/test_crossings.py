from opencourt.crossings import CrossingDetector

C1, C2, OTHER, Q = "court_1", "court_2", "other", "queue"


def run(det, seq):
    """seq: list of (t, [(tid, zone, pos)])"""
    out = []
    for t, frame in seq:
        out += det.update(t, frame)
    return out


def walk(tid, zones, t0=0.0, dt=0.5, pos=(0.0, 0.0)):
    return [(t0 + i * dt, [(tid, z, pos)]) for i, z in enumerate(zones)]


def test_crossing_requires_settling_on_both_sides():
    det = CrossingDetector(dwell=1.0, ttl=10, excursion_seconds=0)
    xs = run(det, walk(1, [Q] * 4 + [C1] * 4))
    assert [(x.from_zone, x.to_zone) for x in xs] == [(Q, C1)]


def test_new_track_inside_court_is_not_an_entry():
    det = CrossingDetector(dwell=1.0, ttl=10, handoff_radius=0)
    assert run(det, walk(7, [C1] * 10)) == []


def test_boundary_jitter_is_ignored():
    det = CrossingDetector(dwell=1.0, ttl=10, excursion_seconds=0)
    xs = run(det, walk(1, [C1] * 4 + [OTHER, C1, OTHER, C1] * 3))
    assert xs == []


def test_excursion_to_same_court_is_suppressed():
    det = CrossingDetector(dwell=1.0, ttl=30, excursion_seconds=8)
    xs = run(det, walk(1, [C1] * 4 + [OTHER] * 6 + [C1] * 4 + [C1] * 30))
    assert xs == []


def test_real_exit_is_reported_after_excursion_window():
    det = CrossingDetector(dwell=1.0, ttl=60, excursion_seconds=8)
    xs = run(det, walk(1, [C1] * 4 + [OTHER] * 40))
    assert [(x.from_zone, x.to_zone) for x in xs] == [(C1, OTHER)]
    assert xs[0].t == 3.0  # keeps the time it actually happened


def test_court_to_court_move_is_immediate():
    det = CrossingDetector(dwell=1.0, ttl=10, excursion_seconds=8)
    xs = run(det, walk(1, [C1] * 4 + [C2] * 4))
    assert [(x.from_zone, x.to_zone) for x in xs] == [(C1, C2)]


def test_exit_then_other_court_reports_both_legs():
    det = CrossingDetector(dwell=1.0, ttl=30, excursion_seconds=8)
    xs = run(det, walk(1, [C1] * 4 + [OTHER] * 4 + [C2] * 4))
    assert [(x.from_zone, x.to_zone) for x in xs] == [(C1, OTHER), (OTHER, C2)]


def test_handoff_bridges_an_id_switch_at_the_boundary():
    det = CrossingDetector(dwell=1.0, ttl=10, handoff_radius=50, handoff_seconds=1.5,
                           excursion_seconds=0)
    seq = walk(1, [C1] * 4, pos=(100, 100))
    seq += walk(2, [OTHER] * 4, t0=2.0, pos=(110, 110))  # new ID right where 1 vanished
    xs = run(det, seq)
    assert [(x.track_id, x.from_zone, x.to_zone) for x in xs] == [(2, C1, OTHER)]


def test_no_handoff_when_far_away():
    det = CrossingDetector(dwell=1.0, ttl=10, handoff_radius=50, excursion_seconds=0)
    seq = walk(1, [C1] * 4, pos=(100, 100)) + walk(2, [OTHER] * 4, t0=2.0, pos=(500, 500))
    assert run(det, seq) == []


def test_tracks_expire():
    det = CrossingDetector(dwell=1.0, ttl=5)
    run(det, walk(1, [C1] * 4))
    run(det, [(100.0, [])])
    assert det.live_tracks == 0
