# OpenCourt sensor

Runs on a Raspberry Pi 5 with a wide camera. Counts people on each court and in the queue,
keeps a clock per group while someone is waiting, drives one amber light per court, and
publishes status to the backend. See [`../docs/PLAN.md`](../docs/PLAN.md) for the design.

**Privacy:** frames never leave memory. Nothing in `src/` writes images or video, and
`tests/test_privacy.py` fails if anything tries to. Only counts and states are published.

## Layout

| Module | Role |
|---|---|
| `types.py`, `config.py` | Data types; YAML config validated with pydantic |
| `geometry.py` | Foot point → zone (`court_N`, `queue`, `other`) |
| `smoothing.py` | Rolling medians and hysteresis |
| `crossings.py` | Zone-boundary crossings from short-lived tracker IDs (dwell, excursions, handoff) |
| `activity.py` | Per-court empty/fill events; a ledger of recent crossings |
| `line.py` | The ordered group line: move-ups, departures, arrivals, breaks, quick swaps |
| `signals.py` | Court state + light from a group's clock |
| `estimate.py` | Wait estimates |
| `engine.py` | Wires the pure pieces together: observation in, snapshot out |
| `sim.py`, `evaluate.py` | Synthetic court with ground truth; scoring |
| `detect.py`, `capture.py` | YOLO + ByteTrack; Pi camera / USB / video file |
| `lights.py`, `publish.py`, `runner.py` | GPIO lights, backend publisher, camera loop |
| `calibrate.py`, `overlay.py`, `cli.py` | Zone tool, debug window, `opencourt` CLI |

## Develop (Mac)

```bash
source ../scripts/env.sh          # uv + Python 3.12 on this machine
uv sync                           # core + dev tools
uv run pytest                     # all tests (add -m "not slow" to skip 2-hour sims)
uv run ruff check src tests

uv run opencourt simulate --report                      # score the engine (4 courts)
uv run opencourt simulate --report --courts 8 --seed 2  # any number of courts
uv run opencourt simulate --speed 20                    # watch it run (console lights)
```

With footage (needs the vision extra: `uv sync --extra vision`):

```bash
uv run opencourt calibrate --source data/footage/clip.mp4 --courts 4
uv run opencourt replay data/footage/clip.mp4 --show --events data/clip.events.jsonl
uv run opencourt evaluate --labels labels/clip.yaml --events data/clip.events.jsonl --games
```

## Deploy (Raspberry Pi 5, Raspberry Pi OS Bookworm 64-bit)

```bash
sudo apt install -y python3-picamera2 python3-lgpio
curl -LsSf https://astral.sh/uv/install.sh | sh
git clone https://github.com/Viv-411/OpenCourt.git && cd OpenCourt/sensor
uv venv --system-site-packages --python /usr/bin/python3   # picamera2 comes from apt
uv sync --extra vision --extra pi
uv run opencourt export-model --imgsz 640     # -> yolo11n_ncnn_model; set detector.model
cp config/example.yaml config/local.yaml      # edit: site_id, capture, lights.pins, backend
uv run opencourt calibrate --source picamera --courts 4
uv run opencourt check-config
uv run opencourt run --lights console         # sanity check, then install the service:
sudo cp systemd/opencourt.service /etc/systemd/system/ && sudo systemctl enable --now opencourt
```

Check the logged FPS: the target is ≥ 8. If it's lower, drop `detector.imgsz` to 480 before
reaching for the AI HAT.

### Lights wiring

Each court's light is a 12 V amber beacon or LED strip switched by a logic-level N-channel
MOSFET (e.g. IRLZ44N or a MOSFET breakout): gate ← BCM pin through 220 Ω with a 10 kΩ
pull-down, source → ground shared with the Pi, drain → light's negative lead, light's
positive → 12 V. Put pins in `lights.pins`. Test with `opencourt run --lights gpio` and a
queue of volunteers.
