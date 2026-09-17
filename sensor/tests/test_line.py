"""The shift-up line model (docs/PLAN.md §2, §6): clocks and lights follow groups."""

from opencourt.config import RotationConfig
from opencourt.line import CourtLine, FillEvidence, Flows, Group, LineEventKind, net_departures

NONE = FillEvidence()
FROM_QUEUE = FillEvidence(from_queue=4)
FROM_BELOW = FillEvidence(from_below=4)
BACK_FROM_BREAK = FillEvidence(from_outside=4)


def ev(value=NONE, per_court=None):
    per_court = per_court or {}
    return lambda c, since: per_court.get(c, value)


def make(*on_since, cfg=None):
    line = CourtLine(len(on_since), cfg or RotationConfig())
    line.seed(0.0, {c for c, t in enumerate(on_since, start=1) if t is not None})
    for c, t in enumerate(on_since, start=1):
        if t is not None:
            line.slots[c] = Group(t)
    return line


UP = Flows(out_up=4)
LEFT = Flows(out_outside=4)


def empty(line, c, t, flows=LEFT):
    """Court c empties at t; decide once the delay has passed."""
    line.on_empty(c, t)
    return line.decide(t + 100, lambda court, since: flows if court == c else Flows())


def clocks(line):
    return [g.on_since if g else None for g in line.slots.values()]


def kinds(events):
    return [e.kind for e in events]


def test_departure_from_court_3_shifts_lower_groups_up_with_their_clocks():
    line = make(400, 300, 200, 100)
    assert kinds(empty(line, 3, 1000)) == [LineEventKind.DEPARTURE]
    assert kinds(empty(line, 2, 1010, UP)) == [LineEventKind.MOVE]  # 2 -> 3
    assert line.is_rotating(3)
    assert kinds(empty(line, 1, 1020, UP)) == [LineEventKind.MOVE]  # 1 -> 2
    line.on_fill(3, 1030, ev())
    line.on_fill(2, 1040, ev())
    assert not line.is_rotating(3)
    assert kinds(line.on_fill(1, 1050, ev(FROM_QUEUE))) == [LineEventKind.ARRIVAL]
    assert clocks(line) == [1050, 400, 300, 100]  # court 4 untouched


def test_light_follows_the_group():
    """A group whose time is up moves from court 2 to court 3; the clock goes with it."""
    line = make(900, 50, None, 10)
    empty(line, 2, 1300, UP)  # seen crossing onto open court 3: a move, not a departure
    assert line.slots[2] is None and line.is_rotating(3)
    line.on_fill(3, 1320, ev())
    assert line.slots[3].on_since == 50


def test_top_court_leaves_with_nobody_waiting():
    line = make(400, 300)
    empty(line, 2, 1000)
    empty(line, 1, 1010, UP)
    line.on_fill(2, 1020, ev())
    assert clocks(line) == [None, 400]


def test_water_break_restores_the_same_clock():
    line = make(400, 300)
    events = empty(line, 2, 1000)
    assert kinds(events) == [LineEventKind.DEPARTURE]
    back = line.on_fill(2, 1090, ev(BACK_FROM_BREAK))
    assert kinds(back) == [LineEventKind.RESTORE]
    assert back[0].ref == events[0].ref
    assert clocks(line) == [400, 300]
    assert net_departures(events + back) == []


def test_unexplained_refill_gets_a_fresh_clock():
    """Nobody seen coming from anywhere: never restore an old clock on a maybe-new group."""
    line = make(400, 300)
    empty(line, 2, 1000)
    events = line.on_fill(2, 1090, ev())
    assert events[0].kind is LineEventKind.ARRIVAL and events[0].assumed
    assert line.slots[2].on_since == 1090


def test_restore_window_expires():
    line = make(400, 300)
    empty(line, 2, 1000)
    line.expire(1000 + RotationConfig().restore_seconds + 1)
    line.on_fill(2, 1500, ev(BACK_FROM_BREAK))
    assert line.slots[2].on_since == 1500


def test_court_1_refill_from_queue_is_a_new_group():
    line = make(400, 300)
    empty(line, 1, 1000)
    events = line.on_fill(1, 1030, ev(FROM_QUEUE))
    assert events[0].kind is LineEventKind.ARRIVAL and not events[0].assumed
    assert line.slots[1].on_since == 1030


def test_silent_shift_when_lower_court_never_looked_empty():
    # Court 3's group left; court 2's group moved up while court 1's moved into court 2
    # so quickly that court 2 never looked empty. People were seen crossing up.
    line = make(400, 300, 200)
    empty(line, 3, 1000)
    events = line.on_fill(3, 1130, ev(per_court={3: FROM_BELOW, 2: FROM_BELOW,
                                                 1: FROM_QUEUE}))
    assert [e.kind for e in events] == [LineEventKind.MOVE, LineEventKind.MOVE,
                                        LineEventKind.ARRIVAL]
    assert clocks(line)[1:] == [400, 300]
    assert line.slots[1].provisional and line.slots[1].on_since == 1130


def test_provisional_court_emptying_is_not_a_departure():
    line = make(400, 300, 200)
    empty(line, 3, 1000)
    line.on_fill(3, 1130, ev(per_court={3: FROM_BELOW}))  # court 2's group moved up
    assert line.slots[2].provisional
    line.on_empty(2, 1140)  # the move finishing, not a group leaving
    assert line.decide(1300, lambda c, s: LEFT) == []


def test_group_expected_to_move_in_can_be_lost():
    line = make(400, 300)
    empty(line, 2, 1000)
    empty(line, 1, 1010, UP)
    assert line.is_rotating(2)
    events = line.expire(1010 + RotationConfig().arrival_timeout_seconds + 1)
    assert kinds(events) == [LineEventKind.LOST]
    assert not line.is_rotating(2)


def test_quick_swap_on_court_1():
    line = make(400, 300)
    flows = {1: Flows(out_outside=4, in_queue=4)}

    def ledger(c, since):  # the crossings all happened at t=990
        return flows.get(c, Flows()) if since <= 990 else Flows()

    events = line.check_turnover(1000, ledger)
    assert kinds(events) == [LineEventKind.DEPARTURE, LineEventKind.ARRIVAL]
    assert clocks(line) == [1000, 300]
    assert line.check_turnover(1001, ledger) == []  # the same crossings are not counted twice


def test_quick_swap_up_the_line():
    line = make(400, 300, 200)
    flows = {3: Flows(out_outside=4, in_below=4), 2: Flows(out_up=4, in_below=4),
             1: Flows(out_up=4, in_queue=4)}
    events = line.check_turnover(1000, lambda c, since: flows.get(c, Flows()))
    assert kinds(events).count(LineEventKind.DEPARTURE) == 1
    assert clocks(line) == [1000, 400, 300]


def test_people_walking_through_are_not_a_swap():
    line = make(400, 300, 200)
    # A group from court 3 walks the lane through court 2 toward the entrance while nobody
    # moves up: court 2 sees 4 in from above and 4 out below.
    flows = {2: Flows(in_above=4, out_down=4)}
    assert line.check_turnover(1000, lambda c, since: flows.get(c, Flows())) == []
    assert clocks(line) == [400, 300, 200]


def test_two_person_break_is_not_a_swap():
    line = make(400, 300)
    flows = {2: Flows(out_outside=2, in_below=2)}
    assert line.check_turnover(1000, lambda c, since: flows.get(c, Flows())) == []


def test_groups_hop_through_several_empty_courts():
    """A group moved 1 -> 2 and, without settling, on to 3; then the next group moved up
    into 2. Both in-transit groups advance one step along the open courts."""
    line = make(700, None, None, None)
    empty(line, 1, 1000, UP)  # 1 -> 2
    assert line.vacancies[2].incoming.on_since == 700
    line.on_fill(1, 1020, ev(FROM_QUEUE))  # new group on court 1
    empty(line, 1, 1030, UP)  # ... which moves up too: 700 must have walked on to court 3
    assert line.vacancies[3].incoming.on_since == 700
    assert line.vacancies[2].incoming.on_since == 1020
    line.on_fill(3, 1200, ev())
    line.on_fill(2, 1200, ev())
    assert clocks(line) == [None, 1020, 700, None]


def test_step_out_next_to_an_open_court_is_not_a_move():
    line = make(400, None)
    empty(line, 1, 1000, LEFT)  # nobody crossed onto court 2
    assert not line.is_rotating(2)
    assert kinds(line.on_fill(1, 1060, ev(BACK_FROM_BREAK))) == [LineEventKind.RESTORE]
    assert clocks(line) == [400, None]


def test_quick_return_before_deciding_changes_nothing():
    line = make(400, 300)
    line.on_empty(2, 1000)
    assert line.on_fill(2, 1005, ev()) == []
    assert clocks(line) == [400, 300]


def test_group_arriving_above_before_decision_counts_as_move():
    line = make(400, 300, None)
    line.on_empty(2, 1000)  # undecided
    events = line.on_fill(3, 1008, ev(per_court={3: FROM_BELOW}))
    assert kinds(events) == [LineEventKind.MOVE]
    assert clocks(line) == [400, None, 300]


def test_seed_gives_everyone_full_time():
    line = CourtLine(3, RotationConfig())
    line.seed(50, {1, 3})
    assert line.slots[1].assumed and line.slots[1].on_since == 50
    assert line.slots[2] is None and 2 in line.vacancies
