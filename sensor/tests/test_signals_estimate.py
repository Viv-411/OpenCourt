import pytest

from opencourt.config import EstimateConfig, TimerConfig
from opencourt.estimate import estimate_wait
from opencourt.line import Group
from opencourt.signals import court_signal, rotating
from opencourt.types import CourtState, Health, LightMode


def sig(group, now, waiting=True, since=0.0, health=Health.OK, timer=None):
    return court_signal(group, now, health=health, waiting=waiting,
                        waiting_since=since if waiting else None,
                        timer=timer or TimerConfig(threshold_seconds=1200, warning_seconds=120))


def test_unknown_when_not_healthy():
    for h in (Health.WARMING_UP, Health.DEGRADED):
        s = sig(Group(0), 5000, health=h)
        assert s.state is CourtState.UNKNOWN and s.light is LightMode.OFF


def test_empty_and_idle():
    assert sig(None, 100).state is CourtState.EMPTY
    s = sig(Group(0), 5000, waiting=False)
    assert s.state is CourtState.IDLE and s.light is LightMode.OFF
    assert s.clock_seconds is None and s.on_court_seconds == 5000


@pytest.mark.parametrize("now,state,light", [
    (100, CourtState.ACTIVE, LightMode.OFF),
    (1079, CourtState.ACTIVE, LightMode.OFF),
    (1081, CourtState.WARNING, LightMode.PULSE),
    (1200, CourtState.DUE, LightMode.SOLID),
    (9999, CourtState.DUE, LightMode.SOLID),
])
def test_threshold_states(now, state, light):
    s = sig(Group(0), now)
    assert (s.state, s.light) == (state, light)


def test_clock_only_counts_time_someone_was_waiting():
    # Group has played 40 min; someone started waiting 5 min ago -> not due.
    s = sig(Group(0), 2400, since=2100)
    assert s.state is CourtState.ACTIVE
    assert s.clock_seconds == 300 and s.seconds_remaining == 900


def test_group_that_arrived_after_the_queue_formed_counts_from_arrival():
    s = sig(Group(1000), 1500, since=0)
    assert s.clock_seconds == 500


def test_warning_can_be_disabled():
    t = TimerConfig(threshold_seconds=1200, warning_seconds=0)
    assert sig(Group(0), 1150, timer=t).state is CourtState.ACTIVE


def test_rotating_holds_light_off():
    s = rotating(sig(Group(0), 5000))
    assert s.state is CourtState.ROTATING and s.light is LightMode.OFF


EC = EstimateConfig(typical_game_seconds=900, min_remaining_seconds=60,
                    overdue_remaining_seconds=180)


def test_empty_court_means_no_wait():
    w = estimate_wait([None, 100.0], queue_count=0, players_per_group=4, cfg=EC)
    assert w.next_free_seconds == 0 and w.wait_seconds == 0


def test_wait_uses_remaining_time_per_court():
    # Remaining: 800, 300, 180 (overdue). Queue has 1 group, so newcomer needs 2nd release.
    w = estimate_wait([100.0, 600.0, 1000.0], queue_count=4, players_per_group=4, cfg=EC)
    assert w.next_free_seconds == 180
    assert w.groups_ahead == 1
    assert w.wait_seconds == 300


def test_wait_wraps_into_later_rounds():
    # One court, 2 groups ahead: releases at 300, 1200, 2100 -> newcomer gets the 3rd.
    w = estimate_wait([600.0], queue_count=8, players_per_group=4, cfg=EC)
    assert w.wait_seconds == 2100


def test_partial_group_counts_as_a_group():
    w = estimate_wait([600.0], queue_count=2, players_per_group=4, cfg=EC)
    assert w.groups_ahead == 1


def test_more_courts_means_shorter_waits():
    one = estimate_wait([450.0], 8, 4, EC).wait_seconds
    four = estimate_wait([450.0] * 4, 8, 4, EC).wait_seconds
    assert four < one


def test_no_courts():
    w = estimate_wait([], 4, 4, EC)
    assert w.wait_seconds is None
