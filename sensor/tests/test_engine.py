"""Engine behaviour on hand-scripted scenes (two courts side by side, queue on the left)."""

from opencourt.config import Config, TimerConfig, Zones
from opencourt.engine import Engine
from opencourt.types import CourtState, Health, LightMode, Observation, Track

ZONES = Zones(
    courts={
        1: [(100, 0), (300, 0), (300, 400), (100, 400)],
        2: [(310, 0), (510, 0), (510, 400), (310, 400)],
    },
    queue=[(0, 0), (90, 0), (90, 400), (0, 400)],
)
C1 = [(150, 100), (250, 100), (150, 300), (250, 300)]
C2 = [(360, 100), (460, 100), (360, 300), (460, 300)]
QUEUE = [(20, 50), (60, 50), (20, 150), (60, 150)]
OUTSIDE = [(600, 450), (620, 450), (640, 450), (660, 450)]


def cfg(**timer) -> Config:
    return Config(zones=ZONES, timer=TimerConfig(**({"threshold_seconds": 600,
                                                    "warning_seconds": 60} | timer)))


class Scene:
    """People keep stable IDs unless told otherwise; frames at 2 fps."""

    def __init__(self, engine: Engine):
        self.engine = engine
        self.t = 0.0
        self.people: dict[int, tuple[float, float]] = {}
        self.snap = None

    def place(self, ids, spots):
        for i, p in zip(ids, spots, strict=True):
            self.people[i] = p

    def remove(self, ids):
        for i in ids:
            self.people.pop(i, None)

    def run(self, seconds, fps=2.0):
        for _ in range(int(seconds * fps)):
            tracks = tuple(Track.at_foot(x, y, i) for i, (x, y) in self.people.items())
            self.snap = self.engine.step(Observation(self.t, tracks))
            self.t += 1 / fps
        return self.snap

    def court(self, n):
        return self.snap.courts[n - 1].signal


def test_warmup_then_idle_without_queue():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    snap = s.run(10)
    assert snap.health is Health.WARMING_UP
    assert s.court(1).state is CourtState.UNKNOWN
    snap = s.run(3000)
    assert snap.health is Health.OK
    assert s.court(1).state is CourtState.IDLE and s.court(1).light is LightMode.OFF
    assert s.court(2).state is CourtState.IDLE


def test_no_queue_means_no_light_ever():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.run(7200)
    assert s.court(1).light is LightMode.OFF


def test_queue_starts_clock_and_light_comes_on():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    s.run(60)
    s.place(range(20, 24), QUEUE)
    s.run(400)
    assert s.court(1).state is CourtState.ACTIVE
    s.run(170)  # queue smoothing delays the start by ~15 s
    assert s.court(1).state is CourtState.WARNING and s.court(1).light is LightMode.PULSE
    s.run(100)
    assert s.court(1).state is CourtState.DUE and s.court(1).light is LightMode.SOLID
    assert s.snap.wait.groups_ahead == 1


def test_short_queue_absence_does_not_reset_clock():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)  # both courts taken, so the line is really held up
    s.run(60)
    s.place(range(20, 24), QUEUE)
    s.run(400)
    s.remove(range(20, 24))
    s.run(60)  # < off_seconds
    s.place(range(20, 24), QUEUE)
    s.run(100)
    assert s.court(1).clock_seconds > 500


def test_rotation_on_court_2_moves_court_1_clock_up():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    s.run(60)
    s.place(range(20, 24), QUEUE)
    s.run(700)
    assert s.court(2).state is CourtState.DUE
    clock1 = s.court(1).clock_seconds

    # Court 2's group leaves the courts ...
    s.place(range(5, 9), OUTSIDE)
    s.run(20)
    s.remove(range(5, 9))
    s.run(10)
    # ... court 1's group moves up, and the queue group walks onto court 1.
    s.place(range(1, 5), C2)
    s.run(15)
    s.place(range(20, 24), C1)
    s.place(range(30, 34), QUEUE)  # someone else is still waiting
    s.run(60)

    kinds = [(e.kind.value, e.court) for e in s.engine.event_log]
    assert ("departure", 2) in kinds
    assert ("move", 2) in kinds
    assert ("arrival", 1) in kinds
    # Court 2 now carries the old court-1 clock (it did NOT reset) ...
    assert s.court(2).clock_seconds >= clock1
    # ... and the new court-1 group starts fresh.
    assert s.court(1).clock_seconds < 120


QUEUE2 = [(30, 200), (70, 200), (30, 300), (70, 300)]


def test_light_follows_group_that_moves_up():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    s.place(range(20, 24), QUEUE)
    s.place(range(30, 34), QUEUE2)  # a second group behind them in line
    s.run(700)
    assert s.court(1).light is LightMode.SOLID

    s.place(range(5, 9), OUTSIDE)  # the group above leaves
    s.run(15)  # (a court empty this briefly is a changeover, not an open court)

    s.place(range(1, 5), C2)  # the lit group moves up
    s.run(8)
    assert s.court(1).state is CourtState.ROTATING  # held off while they walk over
    assert s.court(1).light is LightMode.OFF and s.court(2).light is LightMode.OFF
    s.place(range(20, 24), C1)  # and the line takes their old court
    s.run(30)
    assert s.court(2).light is LightMode.SOLID  # the light (and clock) moved with the group
    assert s.court(1).light is LightMode.OFF  # the new group's clock is fresh


def test_brief_water_break_keeps_the_clock():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    s.place(range(20, 24), QUEUE)
    s.run(700)
    assert s.court(1).state is CourtState.DUE
    s.place(range(1, 5), OUTSIDE)  # everyone steps out
    s.run(40)
    s.place(range(1, 5), C1)  # and comes back
    s.run(30)
    assert s.court(1).state is CourtState.DUE


def test_stale_camera_fails_dark():
    e = Engine(cfg())
    s = Scene(e)
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    s.place(range(20, 24), QUEUE)
    s.run(700)
    assert s.court(1).light is LightMode.SOLID
    snap = e.tick(s.t + 30)  # no frames for 30 s
    assert snap.health is Health.DEGRADED
    assert all(c.signal.light is LightMode.OFF for c in snap.courts)


def test_no_light_while_a_court_is_open():
    # People in line could walk onto court 2, so the group on court 1 isn't keeping them off.
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(20, 24), QUEUE)
    s.run(700)
    assert s.court(1).light is LightMode.OFF
    assert s.court(1).state is CourtState.ACTIVE  # the line is waiting; the clock isn't running
    # Only the first minute counted (an empty court that short could be a changeover).
    assert s.court(1).clock_seconds < 120


def test_an_open_court_pauses_clocks_without_resetting_them():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    s.place(range(20, 24), QUEUE)
    s.run(400)
    before = s.court(1).clock_seconds
    s.place(range(5, 9), OUTSIDE)  # court 2's group leaves, and nobody takes it for a while
    s.run(200)
    paused = s.court(1).clock_seconds
    assert paused <= before + 90  # counted only the first minute or so (could be a changeover)
    s.place(range(40, 44), C2)  # a new group takes court 2
    s.run(60)
    after = s.court(1).clock_seconds
    assert after >= paused + 40  # running again, from where it stopped, not from zero
    assert after <= before + 160  # and most of the 200 s open spell wasn't counted


def test_payload_contains_no_track_ids_or_positions():
    s = Scene(Engine(cfg(), wall_clock=lambda: 1_700_000_000.0))
    s.place(range(1, 5), C1)
    s.run(60)
    payload = s.snap.to_payload("site")
    flat = repr(payload)
    assert "track" not in flat and "bbox" not in flat and "foot" not in flat
    assert payload["courts"][0]["number"] == 1
    assert payload["generated_at"] == 1_700_000_000.0


def test_ignore_area_drops_a_post_detected_as_a_person():
    post = [(200, 50), (240, 50), (240, 250), (200, 250)]  # inside court 1
    zones = Zones(courts=ZONES.courts, queue=ZONES.queue, ignore=[post])
    s = Scene(Engine(Config(zones=zones)))
    s.place([99], [(220, 240)])  # a "person" whose box centre sits on the post
    s.run(60)
    assert s.snap.courts[0].occupancy == 0
    s.place(range(1, 5), C1)
    s.run(60)
    assert s.snap.courts[0].occupancy == 4


def test_a_court_someone_just_left_reads_open_when_nobody_waits():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.run(60)
    s.place(range(1, 5), OUTSIDE)
    s.run(20)
    assert s.court(1).state is CourtState.EMPTY  # not "changing": nobody is waiting


def test_no_wait_while_a_court_is_open():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)  # court 2 stays open
    s.place(range(20, 22), QUEUE[:2])  # two people wait anyway (say, for partners)
    s.run(200)
    assert s.snap.wait.wait_seconds == 0


def test_the_app_is_told_which_court_a_group_moved_up_from():
    s = Scene(Engine(cfg()))
    s.place(range(1, 5), C1)
    s.place(range(5, 9), C2)
    s.run(120)
    s.place(range(5, 9), OUTSIDE)  # court 2's group leaves
    s.run(15)
    s.place(range(1, 5), C2)  # court 1's group moves up
    s.run(40)
    assert s.snap.courts[1].moved_from == 1
    assert s.snap.to_payload("x")["courts"][1]["moved_from"] == 1
    s.run(150)
    assert s.snap.courts[1].moved_from is None  # shown for a couple of minutes, then not


def test_a_group_that_left_the_line_is_the_group_on_the_open_court():
    # Nobody is followed from the line to the court (the path is out of view, new IDs
    # appear): the line shrinking and a group appearing within a minute is enough.
    e = Engine(cfg())
    s = Scene(e)
    s.place(range(1, 5), C1)
    s.run(60)
    s.place(range(20, 22), QUEUE[:2])
    s.run(60)
    s.remove(range(20, 22))  # they leave the line...
    s.run(15)
    s.place(range(30, 32), C2[:2])  # ...and two people turn up on court 2
    s.run(40)
    arrivals = [ev for ev in e.event_log if ev.kind.value == "arrival" and ev.court == 2]
    assert arrivals and not arrivals[-1].assumed
