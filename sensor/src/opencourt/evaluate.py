"""Scoring the engine against ground truth: simulated runs and hand-labeled footage."""

from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .config import Config
from .engine import Engine
from .line import Group, net_departures
from .signals import court_signal
from .sim import CourtSim, SimParams
from .smoothing import Sustained
from .types import CourtState, Health


@dataclass
class DepartureMatch:
    truth: list[tuple[float, int]]
    detected: list[tuple[float, int]]
    matched: int

    @property
    def recall(self) -> float:
        return self.matched / len(self.truth) if self.truth else 1.0

    @property
    def precision(self) -> float:
        return self.matched / len(self.detected) if self.detected else 1.0


def match_departures(truth: list[tuple[float, int]], detected: list[tuple[float, int]],
                     slack: float = 90.0) -> DepartureMatch:
    """Greedy one-to-one match on the same court within ``slack`` seconds."""
    used: set[int] = set()
    matched = 0
    for t, court in sorted(detected):
        best, best_dt = None, slack
        for i, (tt, tc) in enumerate(truth):
            if i in used or tc != court:
                continue
            if abs(t - tt) <= best_dt:
                best, best_dt = i, abs(t - tt)
        if best is not None:
            used.add(best)
            matched += 1
    return DepartureMatch(truth, detected, matched)


@dataclass
class SimReport:
    duration: float
    departures: DepartureMatch
    events: dict[str, int]
    false_due_seconds: float  # engine DUE on a group whose time is not up (settled courts only)
    missed_due_seconds: float  # oracle DUE (past grace) while engine is not DUE
    due_seconds_oracle: float
    first_game_accusations: int  # groups lit DUE while still in their first game
    first_game_accusations_policy: int  # same, for the oracle: caused by the threshold itself
    overstayers: int
    overstayers_lit: int
    overstayers_should_light: int
    notes: list[str] = field(default_factory=list)

    def summary(self) -> str:
        d = self.departures
        lines = [
            f"simulated {self.duration / 60:.0f} min",
            f"departures: truth={len(d.truth)} detected={len(d.detected)} "
            f"matched={d.matched} recall={d.recall:.2f} precision={d.precision:.2f}",
            f"line events: {self.events}",
            f"oracle DUE time: {self.due_seconds_oracle / 60:.1f} min",
            f"false DUE: {self.false_due_seconds / 60:.1f} min   "
            f"missed DUE: {self.missed_due_seconds / 60:.1f} min",
            f"first-game groups lit DUE: {self.first_game_accusations} "
            f"(policy alone would light {self.first_game_accusations_policy})",
            f"overstaying groups: {self.overstayers}  should light: "
            f"{self.overstayers_should_light}  lit: {self.overstayers_lit}",
        ]
        return "\n".join(lines + self.notes)


def evaluate_sim(params: SimParams, cfg: Config, grace_seconds: float = 90.0) -> SimReport:
    sim = CourtSim(params)
    engine = Engine(cfg, wall_clock=lambda: 0.0)
    oracle_gate = Sustained(cfg.queue.on_seconds, cfg.queue.off_seconds)
    dt = 1.0 / params.fps

    false_due = missed_due = oracle_due_total = 0.0
    oracle_due_since: dict[int, float | None] = {}
    # Truth reassigns a court the instant a group decides to leave or move; real people take
    # a few seconds to walk. Don't score those transitions.
    settle = 45.0
    last_change: dict[int, tuple[int | None, float]] = {}
    first_game_lit: set[int] = set()
    first_game_lit_oracle: set[int] = set()
    lit_groups: set[int] = set()
    should_light: set[int] = set()

    for obs, truth in sim.run():
        snap = engine.step(obs)
        oracle_gate.update(obs.t, truth.queue_people >= cfg.queue.min_people)
        for cs in snap.courts:
            tg = truth.slots.get(cs.number)
            gid = tg.gid if tg is not None else None
            if last_change.get(cs.number, (object(), 0.0))[0] != gid:
                last_change[cs.number] = (gid, obs.t)
            settled = obs.t - last_change[cs.number][1] > settle
            og = Group(tg.on_since) if tg is not None and tg.on_since is not None else None
            osig = court_signal(og, obs.t, health=Health.OK, waiting=oracle_gate.state,
                                waiting_since=oracle_gate.since, timer=cfg.timer)
            o_due = osig.state is CourtState.DUE
            e_due = cs.signal.state is CourtState.DUE
            if o_due:
                oracle_due_total += dt
                oracle_due_since.setdefault(cs.number, obs.t)
                if tg is not None:
                    should_light.add(tg.gid)
                    if tg.first_game_end is not None and obs.t < tg.first_game_end:
                        first_game_lit_oracle.add(tg.gid)
            else:
                oracle_due_since.pop(cs.number, None)
            if e_due and not o_due and tg is not None and settled:
                false_due += dt
            since = oracle_due_since.get(cs.number)
            if o_due and not e_due and since is not None and obs.t - since > grace_seconds:
                missed_due += dt
            if e_due and tg is not None:
                lit_groups.add(tg.gid)
                if tg.first_game_end is not None and obs.t < tg.first_game_end:
                    first_game_lit.add(tg.gid)

    all_truth = sim.finished + [g.truth for g in sim.groups]
    overstayers = {g.gid for g in all_truth if g.overstays and g.on_since is not None}
    kinds: dict[str, int] = {}
    for r in engine.event_log:
        kinds[r.kind.value] = kinds.get(r.kind.value, 0) + 1
    return SimReport(
        duration=params.duration_seconds,
        departures=match_departures([(d.t, d.court) for d in sim.departures],
                                    net_departures(engine.event_log)),
        events=kinds,
        false_due_seconds=false_due,
        missed_due_seconds=missed_due,
        due_seconds_oracle=oracle_due_total,
        first_game_accusations=len(first_game_lit),
        first_game_accusations_policy=len(first_game_lit_oracle),
        overstayers=len(overstayers),
        overstayers_lit=len(overstayers & lit_groups),
        overstayers_should_light=len(overstayers & should_light),
    )


# -- footage labels --------------------------------------------------------------------------


@dataclass
class Labels:
    clip: str
    departures: list[tuple[float, int]]
    games: list[tuple[float, float]]  # (start, end) seconds into the clip

    @classmethod
    def load(cls, path: str | Path) -> Labels:
        with open(path) as f:
            raw = yaml.safe_load(f) or {}
        return cls(
            clip=raw.get("clip", ""),
            departures=[(_ts(d["t"]), int(d["court"])) for d in raw.get("departures", [])],
            games=[(_ts(g["start"]), _ts(g["end"])) for g in raw.get("games", [])],
        )


def _ts(v: str | float | int) -> float:
    """Accept seconds or "[h:]mm:ss" timestamps."""
    if isinstance(v, (int, float)):
        return float(v)
    parts = [float(p) for p in str(v).split(":")]
    total = 0.0
    for p in parts:
        total = total * 60 + p
    return total


def game_length_stats(games: list[tuple[float, float]]) -> dict[str, float]:
    lengths = sorted(e - s for s, e in games if e > s)
    if not lengths:
        return {}

    def pct(q: float) -> float:
        if len(lengths) == 1:
            return lengths[0]
        k = (len(lengths) - 1) * q
        lo, hi = int(k), min(int(k) + 1, len(lengths) - 1)
        return lengths[lo] + (lengths[hi] - lengths[lo]) * (k - lo)

    return {
        "n": float(len(lengths)),
        "median": statistics.median(lengths),
        "p85": pct(0.85),
        "p90": pct(0.90),
        "max": lengths[-1],
    }
