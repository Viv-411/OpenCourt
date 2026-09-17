# Labeling footage

Labels are the ground truth that `opencourt evaluate` scores against. One YAML file per clip.
The clip itself stays in `data/footage/` and is never committed (docs/PLAN.md §3).

```yaml
clip: 2026-09-20-sat-am-pos1.mp4   # file name only, for reference
camera_position: "NE light pole, ~3.5 m"
courts: 4                          # numbered from the queue: 1 = entry court
notes: "sunny, 6-10 people waiting most of the time"

# Every time a group LEAVES THE COURTS (not when a group moves up a court).
# t is when the last player of the group steps off. Use seconds or "[h:]mm:ss".
departures:
  - {t: "4:12", court: 3}
  - {t: "9:40", court: 1}

# Start and end of every game you can see completely. Start = first serve, end = last point
# (paddle tap). These set the timer threshold (`opencourt evaluate --games`).
games:
  - {start: "0:35", end: "14:02", court: 2}
  - {start: "4:50", end: "19:31", court: 1}

# Optional: anything the system should NOT treat as a rotation.
breaks:
  - {t: "11:05", court: 2, what: "two players to the water fountain"}
```

Workflow:

```bash
opencourt calibrate --source data/footage/clip.mp4 --courts 4 --out config/zones.yaml
opencourt replay data/footage/clip.mp4 --events data/clip.events.jsonl --show
opencourt evaluate --labels labels/clip.yaml --events data/clip.events.jsonl --games
```

Tips: watch at 2-4x speed and write timestamps as you go; label at least 3 rotations and
10 games per camera position before trusting the numbers.
