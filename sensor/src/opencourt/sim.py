"""Synthetic court simulator.

Produces what the detector+tracker would produce — foot points with ephemeral, unreliable
track IDs — for a bank of courts running the shift-up rotation, together with ground truth.
This lets the whole system (engine, lights, backend, app) run before any footage exists.

What it models (docs/PLAN.md §2):

* any number of courts, laid out in rows of up to four, numbered from the entrance/queue;
* a group that finishes walks back toward the entrance along the lane between the court
  lines and the fence — through the lower courts' space when ``lane_in_zones`` is set;
* the groups below then move up one court (mid-game) and the next group takes court 1;
* parties of 1-4 arrive and merge into foursomes (occasionally a pair plays singles);
* some groups quietly overstay; water breaks; ball chases; bystanders;
* detector/tracker noise: misses, ID switches, false positives.

It is deliberately *not* a faithful model of real video. Real-footage evaluation
(``opencourt evaluate``) is still required.
"""

from __future__ import annotations

import math
import random
from collections.abc import Iterator
from dataclasses import dataclass, field

from .config import Config, Zones
from .types import Observation, Point, Track

W, H = 1920, 1080
COURT_X0, COURT_GAP = 260.0, 12.0
TOP, BOTTOM = 120.0, 1040.0
PER_ROW = 4
QUEUE_BOX = (40.0, 180.0, 230.0, 620.0)  # x1, y1, x2, y2 — at the entrance, beside court 1
GATE: Point = (140.0, 700.0)  # entrance, just below the queue
CORRIDOR_X = 245.0  # 'other' strip between the queue and the first court column

Box = tuple[float, float, float, float]


def _rows(courts: int) -> int:
    return math.ceil(courts / PER_ROW)


def _cols(courts: int) -> int:
    return min(courts, PER_ROW)


def court_box(c: int, courts: int) -> Box:
    """The fenced court box (playing area + lane), in pixels."""
    r, col = divmod(c - 1, PER_ROW)
    cw = (W - 20 - COURT_X0) / _cols(courts)
    rh = (BOTTOM - TOP) / _rows(courts)
    x1 = COURT_X0 + col * cw
    y1 = TOP + r * rh
    return (x1, y1, x1 + cw - COURT_GAP, y1 + rh - COURT_GAP)


def lane_height(courts: int) -> float:
    return max(36.0, 0.1 * (BOTTOM - TOP) / _rows(courts))


def lane_y(c: int, courts: int) -> float:
    _, _, _, y2 = court_box(c, courts)
    return y2 - lane_height(courts) / 2


def _box_poly(b: Box) -> list[Point]:
    x1, y1, x2, y2 = b
    return [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]


def sim_zones(courts: int, lane_in_zones: bool = True) -> Zones:
    """``lane_in_zones=False`` is the recommended calibration when the camera can separate the
    walking lane from the court; ``True`` is the harder case where it can't."""
    polys = {}
    for c in range(1, courts + 1):
        x1, y1, x2, y2 = court_box(c, courts)
        if not lane_in_zones:
            y2 -= lane_height(courts)
        polys[c] = _box_poly((x1, y1, x2, y2))
    return Zones(image_size=(W, H), courts=polys, queue=_box_poly(QUEUE_BOX))


def sim_config(courts: int = 4, lane_in_zones: bool = True, **overrides) -> Config:
    cfg = Config(site_id="sim-site", zones=sim_zones(courts, lane_in_zones))
    return cfg.model_copy(update=overrides) if overrides else cfg


@dataclass
class SimParams:
    courts: int = 4
    fps: float = 8.0
    duration_seconds: float = 2 * 3600.0
    seed: int = 0
    game_median_seconds: float = 900.0
    game_sigma: float = 0.22  # lognormal shape
    overstay_prob: float = 0.2  # group quietly plays a second game
    # (until_seconds, people per court-hour) — piecewise arrival schedule, scaled by courts
    arrivals: list[tuple[float, float]] = field(
        default_factory=lambda: [(1200.0, 4.0), (5400.0, 20.0), (1e12, 6.0)]
    )
    party_sizes: dict[int, float] = field(
        default_factory=lambda: {1: 0.15, 2: 0.35, 3: 0.1, 4: 0.4}
    )
    singles_prob: float = 0.06  # a forming group plays as a pair
    start_short_group_after: float = 300.0  # an incomplete group plays after waiting this long
    breaks_per_court_hour: float = 1.0
    ball_chases_per_court_minute: float = 0.3
    shift_delay: tuple[float, float] = (5.0, 45.0)
    walk_speed: float = 140.0  # px/s
    # detector / tracker noise
    miss_prob: float = 0.08
    id_switch_per_second: float = 0.03
    reassign_after_miss_prob: float = 0.5
    false_positives_per_frame: float = 0.05
    bystanders: int = 2
    foot_noise_px: float = 4.0


# ------------------------------------------------------------------------------------------


@dataclass
class _Person:
    pos: Point
    track_id: int
    path: list[Point] = field(default_factory=list)
    visible: bool = True
    home: Point | None = None  # where to drift around when idle
    busy_until: float = 0.0  # ball chase / break
    return_to: Point | None = None

    @property
    def target(self) -> Point:
        return self.path[-1] if self.path else self.pos

    def go(self, *waypoints: Point) -> None:
        self.path = list(waypoints)

    @property
    def arrived(self) -> bool:
        return not self.path


@dataclass
class TruthGroup:
    gid: int
    size: int = 4
    on_since: float | None = None  # stepped onto courts
    first_game_end: float | None = None
    leave_at: float | None = None
    overstays: bool = False


@dataclass
class TruthDeparture:
    t: float
    court: int
    gid: int
    overstayed: bool


@dataclass
class _Group:
    truth: TruthGroup
    members: list[_Person]
    capacity: int = 4
    state: str = "queued"  # queued | walking_on | playing | moving | leaving | gone
    court: int | None = None
    ready_at: float = 0.0
    queued_at: float = 0.0
    on_break: bool = False

    @property
    def full(self) -> bool:
        return len(self.members) >= self.capacity


@dataclass(frozen=True)
class FrameTruth:
    t: float
    slots: dict[int, TruthGroup | None]  # court -> group currently assigned there
    queue_people: int


class CourtSim:
    def __init__(self, p: SimParams):
        self.p = p
        self.n = p.courts
        self.rng = random.Random(p.seed)
        self.t = 0.0
        self.dt = 1.0 / p.fps
        self._next_tid = 1
        self._next_gid = 1
        self.groups: list[_Group] = []
        self.slots: dict[int, _Group | None] = {c: None for c in range(1, self.n + 1)}
        self.queue: list[_Group] = []
        self.departures: list[TruthDeparture] = []
        self.finished: list[TruthGroup] = []
        self.bystanders = [self._person(self._rand_other()) for _ in range(p.bystanders)]
        self._fp: list[tuple[_Person, float]] = []
        mean_party = sum(k * w for k, w in p.party_sizes.items()) / sum(p.party_sizes.values())
        self._mean_party = mean_party
        self._next_arrival = self._draw_arrival(0.0)
        # Start with every court mid-game.
        for c in self.slots:
            g = self._new_group(4, [self._court_spot(c, i) for i in range(4)])
            elapsed = self.rng.uniform(0, p.game_median_seconds)
            self._start_game(g, -elapsed)
            g.state, g.court = "playing", c
            for i, m in enumerate(g.members):
                m.home = self._court_spot(c, i)
            self.slots[c] = g

    # -- helpers ----------------------------------------------------------------------------

    def _tid(self) -> int:
        self._next_tid += 1
        return self._next_tid

    def _person(self, pos: Point) -> _Person:
        return _Person(pos=pos, track_id=self._tid(), home=pos)

    def _new_group(self, capacity: int, positions: list[Point]) -> _Group:
        tg = TruthGroup(self._next_gid, size=capacity)
        self._next_gid += 1
        g = _Group(tg, [self._person(pos) for pos in positions], capacity=capacity)
        self.groups.append(g)
        return g

    def _game_length(self) -> float:
        return self.p.game_median_seconds * math.exp(self.rng.gauss(0, self.p.game_sigma))

    def _start_game(self, g: _Group, t: float) -> None:
        g.truth.size = len(g.members)
        g.truth.on_since = t
        g.truth.first_game_end = t + self._game_length()
        g.truth.overstays = self.rng.random() < self.p.overstay_prob
        g.truth.leave_at = g.truth.first_game_end + (
            self._game_length() if g.truth.overstays else 0.0
        )

    def _court_spot(self, c: int, i: int) -> Point:
        x1, y1, x2, y2 = court_box(c, self.n)
        y2 -= lane_height(self.n)  # players stay out of the lane
        fx = [0.3, 0.7, 0.3, 0.7][i % 4]
        fy = [0.2, 0.2, 0.8, 0.8][i % 4]
        return (x1 + fx * (x2 - x1), y1 + fy * (y2 - y1))

    def _inside(self, c: int, pos: Point) -> bool:
        x1, y1, x2, y2 = court_box(c, self.n)
        return x1 <= pos[0] <= x2 and y1 <= pos[1] <= y2 - lane_height(self.n)

    def _exit_path(self, c: int, pos: Point) -> list[Point]:
        """Down to the lane, along it toward the entrance (through lower courts), out."""
        ly = lane_y(c, self.n)
        return [(pos[0], ly), (COURT_X0 + 10, ly), (CORRIDOR_X, ly), GATE,
                (GATE[0], GATE[1] + 60)]

    def _queue_spot(self, idx: int) -> Point:
        x1, y1, x2, y2 = QUEUE_BOX
        row, col = divmod(idx, 2)
        return (x1 + 50 + col * 80, y1 + 30 + (row * 40) % (y2 - y1 - 50))

    def _rand_other(self) -> Point:
        return (self.rng.uniform(20, COURT_X0 - 30), self.rng.uniform(QUEUE_BOX[3] + 150, H - 10))

    def _draw_arrival(self, now: float) -> float:
        per_court_hour = next(r for until, r in self.p.arrivals if now < until)
        parties_per_second = per_court_hour * self.n / self._mean_party / 3600.0
        if parties_per_second <= 0:
            return now + 60.0
        return now + self.rng.expovariate(parties_per_second)

    def _party_size(self) -> int:
        sizes, weights = zip(*self.p.party_sizes.items(), strict=True)
        return self.rng.choices(sizes, weights)[0]

    # -- world update -----------------------------------------------------------------------

    def _move(self, m: _Person) -> None:
        budget = self.p.walk_speed * self.dt
        while m.path and budget > 0:
            tx, ty = m.path[0]
            dx, dy = tx - m.pos[0], ty - m.pos[1]
            d = math.hypot(dx, dy)
            if d <= budget:
                m.pos = (tx, ty)
                m.path.pop(0)
                budget -= d
            else:
                m.pos = (m.pos[0] + dx / d * budget, m.pos[1] + dy / d * budget)
                budget = 0

    def _arrived(self, g: _Group) -> bool:
        return all(m.arrived for m in g.members)

    def _send(self, g: _Group, targets: list[Point]) -> None:
        for m, tgt in zip(g.members, targets, strict=False):
            m.go(tgt)
            m.home = tgt
            m.busy_until = 0.0
            m.return_to = None

    def _arrive_party(self) -> None:
        people = self._party_size()
        while people > 0:
            last = self.queue[-1] if self.queue else None
            if last is None or last.full:
                cap = 2 if self.rng.random() < self.p.singles_prob else 4
                last = _Group(TruthGroup(self._next_gid, size=cap), [], capacity=cap,
                              queued_at=self.t)
                self._next_gid += 1
                self.groups.append(last)
                self.queue.append(last)
            take = min(people, last.capacity - len(last.members))
            for _ in range(take):
                m = self._person((GATE[0], GATE[1] + 60))
                last.members.append(m)
            people -= take
        self._compact_queue()

    def _compact_queue(self) -> None:
        idx = 0
        for g in self.queue:
            for m in g.members:
                spot = self._queue_spot(idx)
                if m.target != spot and m.return_to is None:
                    m.go(spot)
                idx += 1

    def _world_step(self) -> None:
        t, p, rng = self.t, self.p, self.rng

        while t >= self._next_arrival:
            self._arrive_party()
            self._next_arrival = self._draw_arrival(self._next_arrival)

        # Departures: any playing group whose game is over leaves toward the entrance.
        for c, g in self.slots.items():
            if g is not None and g.state == "playing" and t >= (g.truth.leave_at or 0):
                g.state = "leaving"
                self.slots[c] = None
                self.departures.append(TruthDeparture(t, c, g.truth.gid, g.truth.overstays))
                for m in g.members:
                    m.go(*self._exit_path(c, m.pos))
                    m.return_to = None

        # Shift-up: fill empty courts from the court below, top-down; court 1 from the queue.
        for c in range(self.n, 0, -1):
            if self.slots[c] is not None:
                continue
            if c > 1:
                below = self.slots.get(c - 1)
                if below is None or below.state != "playing" or below.on_break:
                    continue
            else:
                below = self.queue[0] if self.queue else None
                if below is None or not self._arrived(below) or not below.members:
                    continue
                if not below.full and t - below.queued_at < p.start_short_group_after:
                    continue
            if below.ready_at == 0.0:
                below.ready_at = t + rng.uniform(*p.shift_delay)
                continue
            if t < below.ready_at:
                continue
            below.ready_at = 0.0
            if c > 1:
                self.slots[c - 1] = None
                below.state = "moving"
            else:
                self.queue.pop(0)
                below.state = "walking_on"
                self._start_game(below, t)
                self._compact_queue()
            self.slots[c] = below
            below.court = c
            self._send(below, [self._court_spot(c, i) for i in range(len(below.members))])

        for g in self.groups:
            if g.state in ("moving", "walking_on") and self._arrived(g):
                g.state = "playing"
            elif g.state == "leaving" and self._arrived(g):
                g.state = "gone"
                self.finished.append(g.truth)
        self.groups = [g for g in self.groups if g.state != "gone"]

        # Breaks and ball chases for playing groups.
        for c, g in self.slots.items():
            if g is None or g.state != "playing":
                continue
            if not g.on_break and rng.random() < p.breaks_per_court_hour / 3600 * self.dt:
                g.on_break = True
                dur = rng.uniform(40, 120)
                for m in g.members[:2]:
                    m.return_to, m.busy_until = m.home, t + dur
                    m.go((m.pos[0], lane_y(c, self.n)), (CORRIDOR_X, lane_y(c, self.n)))
            for m in g.members:
                if m.return_to is None and rng.random() < (
                    p.ball_chases_per_court_minute / 60 * self.dt / 4
                ):
                    x1, _, x2, _ = court_box(c, self.n)
                    m.return_to, m.busy_until = m.home, t + rng.uniform(2, 5)
                    m.go((rng.choice([x1 - 8, x2 + 8]), m.pos[1]))
                if m.return_to is not None and t >= m.busy_until:
                    back = m.return_to
                    if m.pos[0] <= CORRIDOR_X + 1:  # returning from a break
                        m.go((CORRIDOR_X, lane_y(c, self.n)), (back[0], lane_y(c, self.n)), back)
                    else:
                        m.go(back)
                    m.return_to = None
                elif m.return_to is None and m.arrived and m.home is not None:
                    hx, hy = m.home
                    m.go((hx + rng.uniform(-40, 40), hy + rng.uniform(-60, 60)))
            if g.on_break and all(
                m.return_to is None and self._inside(c, m.pos) for m in g.members
            ):
                g.on_break = False

        for b in self.bystanders:
            if b.arrived:
                b.go(self._rand_other())

        for g in self.groups:
            for m in g.members:
                self._move(m)
        for b in self.bystanders:
            self._move(b)

    # -- sensing ----------------------------------------------------------------------------

    def _people(self) -> list[_Person]:
        return [m for g in self.groups for m in g.members] + self.bystanders

    def _sense(self) -> tuple[Track, ...]:
        p, rng = self.p, self.rng
        tracks = []
        switch_p = p.id_switch_per_second * self.dt
        for m in self._people():
            if not (0 <= m.pos[0] <= W and 0 <= m.pos[1] <= H):
                continue
            if rng.random() < p.miss_prob:
                m.visible = False
                continue
            if not m.visible and rng.random() < p.reassign_after_miss_prob:
                m.track_id = self._tid()
            m.visible = True
            if rng.random() < switch_p:
                m.track_id = self._tid()
            x = m.pos[0] + rng.gauss(0, p.foot_noise_px)
            y = m.pos[1] + rng.gauss(0, p.foot_noise_px)
            tracks.append(Track.at_foot(x, y, m.track_id))
        if rng.random() < p.false_positives_per_frame:
            ghost = self._person((rng.uniform(0, W), rng.uniform(0, H)))
            self._fp.append((ghost, self.t + rng.uniform(0.2, 2.0)))
        self._fp = [(g, until) for g, until in self._fp if until > self.t]
        for g, _ in self._fp:
            tracks.append(Track.at_foot(*g.pos, g.track_id))
        return tuple(tracks)

    def _truth(self) -> FrameTruth:
        x1, y1, x2, y2 = QUEUE_BOX
        in_queue = sum(1 for m in self._people()
                       if x1 <= m.pos[0] <= x2 and y1 <= m.pos[1] <= y2)
        slots = {c: (g.truth if g is not None else None) for c, g in self.slots.items()}
        return FrameTruth(self.t, slots, in_queue)

    def run(self) -> Iterator[tuple[Observation, FrameTruth]]:
        n = int(self.p.duration_seconds * self.p.fps)
        for i in range(n):
            self.t = i * self.dt
            self._world_step()
            yield Observation(self.t, self._sense()), self._truth()
