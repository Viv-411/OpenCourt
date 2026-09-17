# OpenCourt: notes for Claude

Read `docs/PLAN.md` first. It is the source of truth for design decisions.
`docs/PLAN_REVIEW.md` explains why v1 of the plan changed.

## What this is

A camera at a bank of public pickleball courts counts people on each court and in the
queue, and keeps a clock **per group** while someone is waiting. A court's amber light
turns on when its group's 20-minute time is up while others wait. A Supabase backend and a SwiftUI app
show live status. This is a passion project heading toward a real pilot. There is no
competition deadline.

## Non-negotiables

1. **Privacy.** Runtime code never writes frames or video, and never uses faces,
   appearance embeddings, ReID, or BoT-SORT. Only ByteTrack (motion only) is allowed.
   Only counts and states leave the device. `sensor/tests/test_privacy.py` enforces this:
   don't weaken it. Footage lives in `data/`, which is git-ignored. Never commit footage,
   frames, or screenshots of real people.
2. **Signal, don't enforce.** Wording is factual everywhere. The amber state reads
   "Time up" (the user's choice, 2026-09-16), never "violation", "cheating", and so on.
   The iOS test `stateWordingIsFactual` enforces this.
3. **A false amber is worse than a missed one.** When unsure, fail dark and give groups
   more time: when the camera is stale or degraded, while groups are changing
   (`ROTATING`), and whenever `line.py` can't tell who arrived (a fresh clock, never a
   restored or moved one without evidence). Changes that make lights *harsher* under
   uncertainty need a strong reason.
4. **The clock (and light) belongs to the group, not the court.** The court uses a shift-up
   rotation: when the group on court k leaves, courts 1…k−1 each move up one court,
   mid-game, and the line fills court 1. Groups never change order, so clocks move by
   position (`line.py`). Never reset a clock just because a court's occupants changed.
5. **Tracker IDs are short-lived.** Use them only for boundary crossings over seconds.
   Nothing may depend on an ID lasting.
6. **Any number of courts.** Nothing may assume a fixed count. Courts are numbered from
   the entrance. Simulator regression tests cover 2 and 4 courts strictly, and 8 loosely.

## Layout

- `sensor/`: Python 3.12 package `opencourt` (uv). The pure core has no OpenCV or torch
  imports. The vision and Pi extras are optional. See `sensor/README.md` for the module map.
- `backend/`: one Supabase migration plus pytest SQL tests on embedded Postgres
  (pgserver). The only write path is `ingest_status(p_token, p_payload)`.
- `docs/GUIDE.md`: plain-language tour of what's built, how to test it, and what's left.
- `ios/`: `OpenCourt.xcodeproj` (the `OpenCourt/` folder is synced automatically, so new
  files need no project edits) plus the `OpenCourtKit` Swift package with two libraries,
  `OpenCourtKit` and `OpenCourtSupabase`.
- `docs/`: the plan, the review, and the archived v1.
- `scripts/env.sh`: **source this first** in every shell (see "This machine").

## Commands

```bash
source scripts/env.sh
scripts/test-all.sh --fast                         # everything except the 2-hour simulations

cd sensor
uv run pytest -m "not slow"                        # fast unit tests
uv run pytest                                      # includes simulation regression tests (~1 min)
uv run ruff check src tests
uv run opencourt simulate --report --seed 1        # score the engine on a synthetic session
uv run opencourt simulate --report --courts 8      # any court count; --lane-outside for clean zones
uv run opencourt simulate --speed 20               # watch it (console lights)

cd backend && uv run pytest                        # SQL tests, no Docker needed

cd ios/OpenCourtKit && swift test                  # Swift Testing
cd ios && xcodebuild -project OpenCourt.xcodeproj -scheme OpenCourt \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
# app launch args: -demo (force demo data), -openSite <id>, -demoMinutes <n>
```

## Engineering conventions

- **Python.** Line length 100, ruff rules in `pyproject.toml`. Config is pydantic with
  `extra="forbid"`, so every new tunable goes in `config.py` **and**
  `config/example.yaml` with a comment.
- **Keep the core pure.** Detection, capture, GPIO, and HTTP are imported lazily and sit
  behind protocols (`Detector`, `FrameSource`, `LightDriver`, `Publisher`).
- **Payload contract.** If `Snapshot.to_payload` changes:
  1. Bump `PAYLOAD_VERSION`.
  2. Update `ingest_status` in a **new** migration (don't edit applied migrations once a
     real project exists).
  3. Regenerate the fixture with `OPENCOURT_UPDATE_FIXTURES=1 uv run pytest tests/test_contract.py`.
  4. Update the Swift models.
- **Evaluating engine changes.** Run `opencourt simulate --report` on several seeds and
  court counts (2, 4, 8; with and without `--lane-outside`) before and after. The metrics that matter, in order:
  1. `false DUE` and `first-game groups lit`, compared with the policy-only count;
  2. overstayers lit;
  3. departure recall and precision.

  The simulator is a stress test, not reality. Don't over-tune to it. Real footage and
  `opencourt evaluate` decide.
- **Swift.** Swift 6 strict concurrency, `@Observable` with `@MainActor` stores, iOS 17+.
  The app fetches as its source of truth, and Realtime only triggers a refetch.
- **SQL.** RLS on every table, `security definer` functions with `set search_path = ''`, and
  anon can only read.

## This machine (as of 2026-09-16)

- The Xcode license is accepted; `git`, `xcodebuild`, and the iOS Simulator work (iPhone 16
  Pro simulator available).
- `~/.local` is owned by root, so uv and its Python live in `~/.uv`. `source scripts/env.sh`
  puts them on `PATH`.
- The Python sandbox blocks `multiprocessing` pools. For parallel simulator runs, use
  separate processes (`xargs -P`).
- The GitHub remote is `origin` → https://github.com/Viv-411/OpenCourt.git (branch `main`).

## User decisions (2026-09-16)

- The amber state reads **"Time up"**. The prototype gives each group 20 minutes while
  others wait. Game-end or score detection is future work (PLAN §12).
- The same group keeps its game when it moves up, so the light follows it.
- Departing groups walk back to the entrance inside the fence, along the court lanes.
- People join the line in parties of 1–4 and team up into foursomes.
- Buffalo Grove, IL (BIPA). Test parks with 2, 4, 8, and more courts are available; the
  recommendation is to start with 4.

## Open questions (see PLAN.md §13)

- Light layout: one per court, or a panel at the line?
- Court layout and numbering at each park; whether there are divider fences.
- The 8-court case (groups hopping through several open courts) is the known weak spot.
