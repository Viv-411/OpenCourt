"""Annotated copy of a clip: what the system saw and decided, frame by frame.

Usage:
  uv run python tools/render_annotated.py data/footage/clip.MOV \\
      --tracks data/footage/clip.tracks.jsonl -c data/configs/clip.yaml \\
      [--out data/footage/clip.annotated.mp4] [--width 1280]

Draws the zones, a box and foot dot for every detection (colored by the zone the feet are
in), live counts, each court's state and clock, whether someone is waiting, and a ticker
of line events. Writes into the git-ignored data/ directory only. Dev-only (see README).
"""

import argparse
from pathlib import Path

import cv2
import numpy as np

from opencourt.cli import _event_line
from opencourt.config import load_config
from opencourt.engine import Engine
from opencourt.geometry import ZoneMap
from opencourt.trackfile import read
from opencourt.types import CourtState

ZONE_COLORS = {"queue": (255, 0, 255), "other": (0, 0, 255)}
COURT_COLORS = [(0, 255, 0), (255, 200, 0), (0, 200, 255), (255, 120, 120)]
STATE_COLORS = {
    CourtState.UNKNOWN: (160, 160, 160), CourtState.EMPTY: (220, 220, 220),
    CourtState.ROTATING: (255, 200, 0), CourtState.IDLE: (0, 200, 0),
    CourtState.ACTIVE: (0, 200, 0), CourtState.WARNING: (0, 190, 255),
    CourtState.DUE: (0, 140, 255),
}


def mmss(t: float) -> str:
    return f"{int(t // 60)}:{int(t % 60):02d}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--tracks", required=True)
    ap.add_argument("-c", "--config", required=True)
    ap.add_argument("--out")
    ap.add_argument("--width", type=int, default=1280)
    args = ap.parse_args()

    cfg = load_config(args.config)
    zones = cfg.require_zones()
    zm = ZoneMap(zones)
    engine = Engine(cfg, wall_clock=lambda: 0.0)
    header, frames = read(args.tracks)
    out_path = Path(args.out or str(Path(args.video).with_suffix("")) + ".annotated.mp4")

    cap = cv2.VideoCapture(args.video)
    src_fps = cap.get(cv2.CAP_PROP_FPS)
    W, H = header.size
    scale = args.width / W
    size = (args.width, int(H * scale))
    writer = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"avc1"),
                             src_fps / header.step, size)
    if not writer.isOpened():
        writer = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"mp4v"),
                                 src_fps / header.step, size)

    ticker: list[tuple[float, str]] = []
    idx = 0
    for obs in frames:
        target = round(obs.t * src_fps)
        while idx < target:  # skip the frames the detector didn't process
            cap.grab()
            idx += 1
        ok, frame = cap.read()
        idx += 1
        if not ok:
            break
        snap = engine.step(obs)
        for e in snap.events:
            ticker.append((obs.t, _event_line(e).split("] ", 1)[1]))

        # zones
        overlay = frame.copy()
        for n, poly in zones.courts.items():
            c = COURT_COLORS[(n - 1) % len(COURT_COLORS)]
            cv2.fillPoly(overlay, [np.array(poly, np.int32)], c)
        cv2.fillPoly(overlay, [np.array(zones.queue, np.int32)], ZONE_COLORS["queue"])
        frame = cv2.addWeighted(overlay, 0.18, frame, 0.82, 0)
        for n, poly in zones.courts.items():
            c = COURT_COLORS[(n - 1) % len(COURT_COLORS)]
            pts = np.array(poly, np.int32)
            cv2.polylines(frame, [pts], True, c, 3)
        cv2.polylines(frame, [np.array(zones.queue, np.int32)], True, ZONE_COLORS["queue"], 3)

        # people
        for tr in obs.tracks:
            zone = zm.classify(tr.foot)
            if zone.startswith("court_"):
                c = COURT_COLORS[(int(zone[6:]) - 1) % len(COURT_COLORS)]
            else:
                c = ZONE_COLORS[zone]
            x1, y1, x2, y2 = map(int, tr.bbox)
            cv2.rectangle(frame, (x1, y1), (x2, y2), c, 3)
            cv2.circle(frame, tuple(map(int, tr.foot)), 10, c, -1)
            cv2.circle(frame, tuple(map(int, tr.foot)), 10, (0, 0, 0), 2)

        frame = cv2.resize(frame, size)

        # status panel
        panel_h = 44 + 34 * (len(snap.courts) + 1)
        cv2.rectangle(frame, (0, 0), (520, panel_h), (20, 20, 20), -1)
        waiting = "someone waiting" if snap.queue_waiting else "nobody waiting"
        cv2.putText(frame, f"{mmss(obs.t)}   line: {snap.queue_count:.0f} ({waiting})",
                    (12, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
        for i, cs in enumerate(snap.courts):
            sig = cs.signal
            clock = "" if sig.clock_seconds is None else f"  clock {mmss(sig.clock_seconds)}"
            light = {"off": "", "pulse": "  LIGHT PULSING", "solid": "  LIGHT ON"}[sig.light.value]
            txt = f"court {cs.number}: {sig.state.value:<8} {cs.occupancy:.0f} people{clock}{light}"
            cv2.putText(frame, txt, (12, 70 + 34 * i), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                        STATE_COLORS[sig.state], 2)

        # recent events
        recent = [(t, s) for t, s in ticker if obs.t - t < 15][-3:]
        for i, (t, s) in enumerate(reversed(recent)):
            y = size[1] - 20 - 34 * i
            cv2.rectangle(frame, (0, y - 26), (size[0], y + 8), (20, 20, 20), -1)
            cv2.putText(frame, f"{mmss(t)}  {s}", (12, y), cv2.FONT_HERSHEY_SIMPLEX, 0.75,
                        (0, 255, 255), 2)
        writer.write(frame)

    writer.release()
    cap.release()
    print(out_path)


if __name__ == "__main__":
    main()
