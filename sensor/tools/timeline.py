"""What did the engine think, moment by moment? A change log for a recorded clip.

Usage: uv run python tools/timeline.py data/footage/clip.tracks.jsonl -c data/configs/clip.yaml

Replays cached detections through the engine and prints a line whenever something a viewer
would notice changes: the line starts or stops counting as waiting, a court changes state
or light, or the engine decides who moved, left or arrived. Easier to check against "we
walked on at 0:50" than `replay`'s once-a-minute status. Reads boxes only. Dev-only (see
README).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SENSOR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SENSOR / "src"))

from opencourt import trackfile  # noqa: E402
from opencourt.config import load_config  # noqa: E402
from opencourt.engine import Engine  # noqa: E402


def mmss(t: float) -> str:
    m, s = divmod(int(t), 60)
    return f"{m}:{s:02d}"


def clock(seconds: float | None) -> str:
    return "" if seconds is None else f"  clock {mmss(seconds)}"


def run(tracks: str, config: str) -> None:
    cfg = load_config(config)
    engine = Engine(cfg)
    _, frames = trackfile.read(tracks)
    waiting = None
    courts: dict[int, tuple] = {}
    for obs in frames:
        snap = engine.step(obs)
        if snap is None:
            continue
        t = mmss(snap.t)
        if snap.queue_waiting != waiting:
            waiting = snap.queue_waiting
            word = "ON " if waiting else "off"
            print(f"{t:>6}  line waiting {word} ({snap.queue_count:.0f} in line)")
        for c in snap.courts:
            sig = c.signal
            key = (sig.state, sig.light)
            if courts.get(c.number) != key:
                courts[c.number] = key
                light = "" if sig.light.value == "off" else f"  LIGHT {sig.light.value}"
                # "on court" is ungated (since the group stepped on); "clock" only counts while
                # the current line has been waiting. A move must carry "on court" over.
                on = ("" if sig.on_court_seconds is None
                      else f"  on court {mmss(sig.on_court_seconds)}")
                print(f"{t:>6}  court {c.number}: {sig.state.value:<9} "
                      f"{c.occupancy:.0f} people{on}{clock(sig.clock_seconds)}{light}")
        for e in snap.events:
            where = (f"court {e.from_court} -> {e.court}" if e.from_court
                     else f"court {e.court}")
            note = f"  ({e.note})" if e.note else ""
            print(f"{t:>6}  ** {e.kind.value.upper()} {where}{note}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("tracks")
    p.add_argument("-c", "--config", required=True)
    a = p.parse_args()
    run(a.tracks, a.config)
