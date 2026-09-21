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
4. **The clock (and light) belongs to the group, not the court, and nothing may assume a
   turnover custom.** Some parks shift up (groups below move up a court mid-game, the line
   fills court 1); at others the next group takes the freed court directly. `line.py`
   works both out from evidence. A new group off the line can land on *any* court. Never
   reset a clock just because a court's occupants changed, and never hand an old clock to
   people who might be new.
5. **Tracker IDs are short-lived.** Use them only for boundary crossings over seconds.
   Nothing may depend on an ID lasting.
6. **Any number of courts.** Nothing may assume a fixed count. Courts are numbered from
   the entrance. Simulator regression tests cover 2 and 4 courts strictly, and 8 loosely.

## Layout

- `sensor/`: Python 3.12 package `opencourt` (uv). The pure core has no OpenCV or torch
  imports. The vision and Pi extras are optional. See `sensor/README.md` for the module map.
- `supabase/`: the Supabase project files (migrations, seed, config) at the repo root, where
  the Supabase GitHub integration expects them. `backend/` holds the README and the pytest
  SQL tests (embedded Postgres via pgserver). The only write path is
  `ingest_status(p_token, p_payload)`. New schema changes go in a **new** migration file.
- `docs/GUIDE.md`: plain-language tour of what's built, how to test it, and what's left.
- `ios/`: `OpenCourt.xcodeproj` (the `OpenCourt/` folder is synced automatically, so new
  files need no project edits) plus the `OpenCourtKit` Swift package with two libraries,
  `OpenCourtKit` and `OpenCourtSupabase`.
- `docs/`: the plan, the review, and the archived v1.
- `scripts/env.sh`: **source this first** in every shell (see "This machine").
- `sensor/tools/`: dev-only scripts for recorded footage (empty-court still, foot heatmaps,
  annotated video). They are *outside* the `opencourt` package on purpose, so the privacy
  test can keep proving the deployed code never writes images; they write only into the
  git-ignored `sensor/data/`.

## Working with real footage

```bash
cd sensor
uv run opencourt detect data/footage/clip.MOV --fps 10 --imgsz 1280 --device mps   # once, ~1/3 real time
uv run python tools/footage_background.py data/footage/clip.MOV                   # empty-court still
uv run python tools/footage_heatmap.py data/footage/clip.tracks.jsonl data/footage/clip.background.jpg out.jpg --zones data/zones/clip.yaml
uv run opencourt replay --tracks data/footage/clip.tracks.jsonl -c data/configs/clip.yaml --events data/footage/clip.events.jsonl
uv run python tools/render_annotated.py data/footage/clip.MOV --tracks data/footage/clip.tracks.jsonl -c data/configs/clip.yaml
```

Per-clip zones and configs live in `sensor/data/zones/` and `sensor/data/configs/`
(git-ignored, alongside the footage). First clip: `Pickleball_Rick_Drazner_Test1.MOV`
(2026-09-18, 5 friends, night, one full court + part of the second, camera at head height
on the near corner).

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
# app launch args: -demo, -skipWelcome, -signedIn (demo), -tab courts|events|you,
#   -view list|map, -openSite <id>, -openEvent <n>, -newEvent, -demoMinutes <n>
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
- Supabase project `inkvqajxepcaqjubhfye` (us-west-2) has the schema applied. Keys/tokens live
  in `ios/Config/Secrets.xcconfig` and `sensor/.env` (git-ignored); the DB password is not
  stored anywhere in the repo — ask the user if DDL is needed (connect via the session pooler
  with psycopg from `backend/`). Never commit keys or the password.

## Working style (user feedback, 2026-09-17)

- Small, obvious improvements (wording, labels, a confusing display): just make them, don't
  ask. Mention them in the summary.

## User decisions (2026-09-16)

- The amber state reads **"Time up"**. The prototype gives each group 20 minutes while
  others wait. Game-end or score detection is future work (PLAN §12).
- The same group keeps its game when it moves up, so the light follows it. But the system
  must not depend on shifting up: at many parks the next group simply takes the freed court.
- Parks: Rick Drazner (2 courts) first, then Mike Rylko (8 lighted courts).
- Departing groups walk back to the entrance inside the fence, along the court lanes.
- People join the line in parties of 1–4 and team up into foursomes.
- Buffalo Grove, IL (BIPA). Test parks with 2, 4, 8, and more courts are available; the
  recommendation is to start with 4.

## App and community features (2026-09-19)

- Tabs: Courts (live status, busy-times chart, favourites, directions), Events
  (tournaments / open play / clinics / leagues / socials, sign-ups), You (account, profile,
  your events). Browsing never requires an account; posting and signing up do.
- Backend: `supabase/migrations/20260919000000_community.sql` (profiles, events,
  event_registrations, `event_listing`, `site_busy_hours`, `register_for_event`). Sign-ups
  are private to the player and organizer; others see counts. Profiles are visible only to
  signed-in players.
- **No court booking.** Public courts are first-come-first-served; only the park district
  can reserve them by permit. Events carry a `courts_reserved` flag instead. Don't build
  booking of public courts unless the district runs reservations.
- Demo mode (`-demo`) mirrors the real parks: `mike-rylko` (8 courts), `rick-drazner`
  (2 courts), plus `demo-offline`.
- **Location** (2026-09-21): the Courts tab sorts parks by distance and shows how far each
  one is. `LocationStore` (app target) wraps CoreLocation; the maths is `Nearby.swift` in the
  kit, so it stays testable and framework-free. The phone's position is used on the device
  only — never published, stored in the database, or attached to anything a person posts.
  Ask for it in context (the card in the list), never on first launch.

## Open questions (see PLAN.md §13)

- Light layout: one per court, or a panel at the line?
- Court layout and numbering at each park; whether there are divider fences.
- The 8-court case (groups hopping through several open courts) is the known weak spot.
