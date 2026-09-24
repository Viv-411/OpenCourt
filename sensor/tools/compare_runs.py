"""Did two machines get the same answer? Compare two benchmark runs.

Usage: uv run python tools/compare_runs.py data/pi-bench/reference/mac-640 \
           data/pi-bench/results/pi-640

Each argument is a path prefix with a `.tracks.jsonl` (from tools/pi_bench.py) and, if
present, an `.events.jsonl` (from `opencourt replay --tracks ... --events ...`). Identical
files are the best case. Different CPUs can round the last digits of a box differently,
which is harmless as long as the same people are found and the engine reaches the same
events; this reports which of those it is. Dev-only (see README).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# A box counts as "the same box" when it overlaps its partner this much.
SAME_BOX_IOU = 0.9
# Events are the same when they agree on what happened and differ this little in time.
EVENT_SLACK_S = 1.0


def load_tracks(path: Path) -> list[tuple[float, list[list[float]]]]:
    with open(path) as f:
        next(f)  # header
        return [(d["t"], d["tracks"]) for d in map(json.loads, f) if d]


def load_events(path: Path) -> list[dict] | None:
    if not path.exists():
        return None
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def iou(a: list[float], b: list[float]) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def match_boxes(a: list[list[float]], b: list[list[float]]) -> list[float]:
    """Greedy best-overlap pairing; returns the IoU of each pair made."""
    pairs = sorted(((iou(x, y), i, j) for i, x in enumerate(a) for j, y in enumerate(b)),
                   reverse=True)
    used_a, used_b, out = set(), set(), []
    for score, i, j in pairs:
        if score <= 0 or i in used_a or j in used_b:
            continue
        used_a.add(i)
        used_b.add(j)
        out.append(score)
    return out


def same_event(x: dict, y: dict) -> bool:
    keys = ("kind", "court", "from_court")
    return (all(x.get(k) == y.get(k) for k in keys)
            and abs(x["t"] - y["t"]) <= EVENT_SLACK_S)


def compare(ref: str, other: str) -> int:
    a_tracks = load_tracks(Path(ref + ".tracks.jsonl"))
    b_tracks = load_tracks(Path(other + ".tracks.jsonl"))
    print(f"reference: {ref}\nother:     {other}\n")

    if a_tracks == b_tracks:
        print(f"detections: IDENTICAL ({len(a_tracks)} frames, every box the same)")
        tracks_ok = True
    else:
        frames = min(len(a_tracks), len(b_tracks))
        same_count = boxes = same_boxes = 0
        for (_, a), (_, b) in zip(a_tracks, b_tracks, strict=False):  # may differ in length
            same_count += len(a) == len(b)
            boxes += max(len(a), len(b))
            same_boxes += sum(s >= SAME_BOX_IOU for s in match_boxes(a, b))
        count_pct = 100 * same_count / frames if frames else 0
        box_pct = 100 * same_boxes / boxes if boxes else 100
        print(f"detections: {len(a_tracks)} vs {len(b_tracks)} frames")
        print(f"  same number of people : {count_pct:.1f}% of frames")
        print(f"  same boxes            : {box_pct:.1f}% (overlap ≥ {SAME_BOX_IOU:.0%})")
        tracks_ok = len(a_tracks) == len(b_tracks) and count_pct >= 98 and box_pct >= 97

    a_events = load_events(Path(ref + ".events.jsonl"))
    b_events = load_events(Path(other + ".events.jsonl"))
    events_ok = True
    if a_events is not None and b_events is not None:
        unmatched_b = list(b_events)
        only_a = []
        for e in a_events:
            hit = next((x for x in unmatched_b if same_event(e, x)), None)
            if hit:
                unmatched_b.remove(hit)
            else:
                only_a.append(e)
        events_ok = not only_a and not unmatched_b
        print(f"\nengine events: {len(a_events)} vs {len(b_events)}, "
              f"{len(a_events) - len(only_a)} the same")
        for e in only_a:
            print(f"  only in reference: {e['kind']} court {e['court']} at {e['t']:.1f}s")
        for e in unmatched_b:
            print(f"  only in other    : {e['kind']} court {e['court']} at {e['t']:.1f}s")

    print()
    if a_tracks == b_tracks and events_ok:
        print("SAME OUTPUT: identical detections and events.")
    elif tracks_ok and events_ok:
        print("SAME RESULT: tiny numeric differences (normal between different CPUs), "
              "same people found, same events.")
    else:
        print("DIFFERENT: the runs disagree beyond rounding. See the numbers above.")
    return 0 if tracks_ok and events_ok else 1


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    sys.exit(compare(sys.argv[1], sys.argv[2]))
