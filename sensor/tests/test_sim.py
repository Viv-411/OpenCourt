"""End-to-end: engine against the synthetic court. These numbers are regression guards, not
claims about real-world accuracy (see docs/PLAN.md §10 Track B)."""

import pytest

from opencourt.evaluate import evaluate_sim
from opencourt.sim import CourtSim, SimParams, sim_config


def test_sim_is_deterministic():
    a = [len(o.tracks) for o, _ in CourtSim(SimParams(duration_seconds=60, seed=3)).run()]
    b = [len(o.tracks) for o, _ in CourtSim(SimParams(duration_seconds=60, seed=3)).run()]
    assert a == b


@pytest.mark.parametrize("courts", [1, 2, 3, 5, 8, 12])
def test_sim_supports_any_court_count(courts):
    sim = CourtSim(SimParams(courts=courts, duration_seconds=1800, seed=1))
    for _ in sim.run():
        pass
    assert sim.departures
    zones = sim_config(courts).zones
    assert zones.court_count == courts


def test_parties_merge_into_groups():
    sim = CourtSim(SimParams(courts=2, duration_seconds=3600, seed=2))
    sizes = set()
    for _ in sim.run():
        pass
    for g in sim.finished:
        sizes.add(g.size)
    assert 4 in sizes


@pytest.mark.slow
@pytest.mark.parametrize("courts", [2, 4])
@pytest.mark.parametrize("lane_in_zones", [False, True])
@pytest.mark.parametrize("shift_up_prob", [0.0, 0.5, 1.0])
@pytest.mark.parametrize("seed", [1, 2, 3])
def test_engine_on_busy_two_hour_session(courts, lane_in_zones, shift_up_prob, seed):
    """Both customs must work: groups moving up (shift_up_prob=1) and a new group taking the
    court that just freed up (shift_up_prob=0)."""
    r = evaluate_sim(SimParams(courts=courts, duration_seconds=7200, seed=seed,
                               shift_up_prob=shift_up_prob),
                     sim_config(courts, lane_in_zones))
    # Lighting a group whose time isn't up is the failure that matters most.
    assert r.false_due_seconds <= 90, r.summary()
    assert r.first_game_accusations <= r.first_game_accusations_policy + 2, r.summary()
    assert r.departures.recall >= 0.8, r.summary()
    if not lane_in_zones:  # the recommended calibration must also catch the overstayers
        assert r.overstayers_lit >= r.overstayers_should_light - 1, r.summary()


@pytest.mark.slow
@pytest.mark.parametrize("shift_up_prob", [0.0, 0.5, 1.0])
def test_engine_on_eight_courts(shift_up_prob):
    """Bigger bank, zones drawn the recommended way (walking lane excluded)."""
    r = evaluate_sim(SimParams(courts=8, duration_seconds=7200, seed=3,
                               shift_up_prob=shift_up_prob),
                     sim_config(8, lane_in_zones=False))
    assert r.false_due_seconds <= 5 * 60, r.summary()
    assert r.departures.recall >= 0.85, r.summary()


@pytest.mark.slow
@pytest.mark.parametrize("shift_up_prob", [0.0, 1.0])
def test_walking_lane_inside_the_zones_still_never_lights_the_wrong_group(shift_up_prob):
    """The harder calibration: people walking to a far court cross the lower courts."""
    r = evaluate_sim(SimParams(courts=4, duration_seconds=7200, seed=3,
                               shift_up_prob=shift_up_prob),
                     sim_config(4, lane_in_zones=True))
    assert r.false_due_seconds <= 90, r.summary()


@pytest.mark.slow
def test_noise_free_sim_is_near_perfect():
    p = SimParams(duration_seconds=3600, seed=7, miss_prob=0, id_switch_per_second=0,
                  false_positives_per_frame=0, bystanders=0, ball_chases_per_court_minute=0,
                  breaks_per_court_hour=0)
    r = evaluate_sim(p, sim_config(4, lane_in_zones=False))
    assert r.departures.recall >= 0.9, r.summary()
    assert r.false_due_seconds == 0, r.summary()
