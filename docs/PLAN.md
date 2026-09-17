# OpenCourt — Project Plan (v2)

**Revised:** 2026-09-16 (second pass after the user's answers). v1 is archived in [`archive-plan-v1.md`](archive-plan-v1.md), and
[`PLAN_REVIEW.md`](PLAN_REVIEW.md) explains every change.
**Status:** passion project aimed at a real pilot. There is no competition deadline.

---

## 1. What OpenCourt is

Public pickleball courts run on an honor system. When every court is full, you play
one game, step off, and the next group in line rotates on. When groups ignore that,
the only way to object is to confront strangers, so most people just wait or leave.

OpenCourt watches a bank of courts and does four things:

- **Counts** the people on each court and in the waiting line.
- **Keeps a clock for each group** while someone is waiting.
- **Shows an amber light** at a court whose group's time is up: 20 minutes on court while
  others wait. If the group moves up a court, its time and its light move with it. The
  light goes out when the group leaves. If nobody is waiting, no clock runs and no light
  comes on.
- **Publishes live status** to a phone app: which courts are busy, how many people are
  waiting, and roughly how long the wait is.

**The system signals. It does not enforce.** The light takes the confrontation out of
asking a group to rotate. Instead of accusing a group, the person waiting can point at
the light. Something neutral made the call.

### Components

| Component | Where | What |
|---|---|---|
| **Sensor unit** | Raspberry Pi 5 + wide camera at the court | On-device detection, zone counting, group clocks, lights |
| **Backend** | Supabase | Receives status snapshots and serves them live |
| **iOS app** | SwiftUI | Live court status, queue length, wait estimate |

---

## 2. How the court actually works (the "shift-up" rotation)

Courts are numbered 1…N **starting from the entrance**, where the line forms. Players wait
in a single line by the entrance.

```
  entrance/line ──► Court 1 ──► Court 2 ──► Court 3 ──► Court 4
                     (entry)                             (farthest)
```

**When any group finishes its game, it leaves.** Every group on a court *below* it moves
up one court, *keeping the game it is playing*. Then the next group in line takes Court 1.

> Example: the Court 3 group finishes and leaves. The Court 2 group moves to Court 3,
> the Court 1 group moves to Court 2, and the next group in line takes Court 1.
> The Court 4 group isn't affected.

What the user described (2026-09-16):

- A group that is leaving walks back toward the entrance *inside the fence*, along the
  lane between the court lines and the fence. That means it passes the lower courts.
  Players usually wait for walkers to pass before serving.
- People join the line in parties of 1–4 and usually team up into foursomes. Singles are
  rare but happen.
- The park district is in Buffalo Grove, Illinois.
- Parks with 2, 4, 8, and more courts are all available for testing.

### Consequences for the design

1. **The clock belongs to the group, not the court.** A group that moves up keeps its
   clock, and its light moves with it (§5). Otherwise every shift would reset the clock,
   and a group could play forever by being moved up.
2. **Groups never change order.** The groups on the courts behave like an ordered list:
   leaving removes an item, the items below slide up, and new items enter at Court 1.
   Clocks can therefore be moved by *position*. The system never needs to recognize a
   group.
3. **Courts are briefly empty** between one group leaving and the next arriving. The
   system uses those gaps, plus people seen crossing between zones, to follow the line
   (§6).
4. **People walking through a court along the lane are not arrivals.** Someone only
   counts as arriving on a court after staying there about 10 seconds. Where the camera
   can tell them apart, **draw the court zones to exclude the walking lane** (§6).

## 3. Privacy: counting people and tracking order, never identity

The system needs to know *that* the people on a court changed. It never needs to know
*who* anyone is.

**What it uses:** short-lived tracker IDs from ByteTrack. ByteTrack matches people only
by motion and box overlap. IDs are integers with no meaning beyond a few seconds, they
reset constantly, and they are used only to count boundary crossings.

**What it never uses or does:**

- Face detection or recognition.
- Appearance embeddings or re-identification. This is why it uses ByteTrack and not
  BoT-SORT with ReID.
- Keeping any person-level identifier longer than the short tracking window.
- Storing or sending frames. Frames exist only in memory on the Pi. **This is enforced
  by a test** that fails if runtime code writes images or video.

**What leaves the Pi:** counts, court states, clock seconds, and wait estimates.

**Legal framing.** Illinois BIPA regulates biometric identifiers, such as face geometry,
and requires written consent that can't be collected at a public park. Motion-based
integer IDs are not biometric identifiers, and appearance embeddings would be much
closer to the line. So the design stays well clear of that line. *This is a design
stance, not legal advice. Before a real deployment, ask the park district's counsel to
review the privacy statement.*

### Development footage policy

The *deployed* system never records. *Developing* it requires recorded footage, and
that's fine, as long as it's handled this way:

- Film only with park district permission, or film friends who agree to it.
- Keep footage on your own machine under `data/footage/`. It's git-ignored and never
  uploaded.
- Delete footage once labeling and evaluation are done.
- Blur faces in anything shown publicly (pitch video, social media).

### Posted notice

Post a short sign at the court: what the system counts, that it doesn't record or
identify anyone, and a contact.

---

## 4. Scope

### In scope

- Person detection and short-lived motion tracking over a bank of 2–4 courts.
- Occupancy for each court, and a count of people in the queue area.
- Detecting shift-up rotations and moving group clocks along with them.
- A light state for each court, driven through a pluggable light driver.
- Wait estimates.
- Supabase backend with device authentication and staleness handling.
- iOS app: court list, status for each court, wait time, and an offline/stale state.
- A synthetic court simulator for building and testing everything without footage.
- Snapshot logging once a minute (counts and states only).

### Out of scope

- Score and ball tracking.
- Face detection, recognition, or appearance-based re-identification.
- Weatherproof permanent installation and solar power (after the pilot).
- Push notifications (stretch).
- Reservations or booking.

---

## 5. Group clocks and light states

### Queue gate (with hysteresis)

- **Someone is waiting** once the smoothed queue count has been ≥ `queue.min_people`
  for `queue.on_seconds` (default 60 s).
- **Nobody is waiting** once it has been below that for `queue.off_seconds`
  (default 180 s). This is longer on purpose, so someone briefly stepping out of the
  queue doesn't reset every clock.
- `waiting_since` is the moment the queue became occupied.

### Clock

Each group on the courts has an `on_since` time (when it stepped onto Court 1, or onto
an empty court). While someone is waiting:

```
clock = now − max(group.on_since, waiting_since)
remaining = threshold − clock
```

The clock only counts time during which someone was waiting. If someone arrives while
a group is 30 minutes in, that group gets a full threshold's worth of time to finish its
current game.

### Court states

| State | Condition | Light |
|---|---|---|
| `UNKNOWN` | Warming up, camera stale, or system degraded | Off (fail dark) |
| `EMPTY` | No group on court | Off |
| `ROTATING` | Someone just stepped off this court, or a group is moving onto it | Off until it's clear who is on the court |
| `IDLE` | Group on court, nobody waiting | Off |
| `ACTIVE` | Someone waiting, `remaining > warning_seconds` | Off |
| `WARNING` | `0 < remaining ≤ warning_seconds` | Slow pulse (disabled if `warning_seconds: 0`) |
| `DUE` | `remaining ≤ 0` | Solid amber |

The label shown for `DUE` is **"Time up"**; for `WARNING` it's "Almost time." The wording
is factual, never accusing (no "violation," "cheating," and so on).

**The light follows the group.** When a group whose time is up moves from Court 2 to
Court 3, Court 2's light goes off, both courts show `ROTATING` while the group walks over,
and Court 3 lights up once they're there. The clock is never reset by the move.

### Threshold

**Prototype rule: 20 minutes per group** (`timer.threshold_seconds: 1200`). This is the
user's decision. Games are usually one game, and 20 minutes covers most of them. Still,
measure real game lengths (`opencourt evaluate --games`). If slow first games often go past
20 minutes, those groups will be lit while still in their first game. The simulator shows
this is the main source of such cases (§10).

Longer term, the goal is to light the court **when the game actually ends**, not after a
fixed time. See §12.

### Boot

After warm-up (one smoothing window), groups already on court get
`on_since = warm-up end` and are marked `assumed`. They get the full time.

---

## 6. Following the line

Short-lived tracker IDs are used only to count **boundary crossings**. A crossing is a
track that settled in zone A and then settled in zone B.

- A track first seen *inside* a court never counts as an arrival, because an ID switch
  would otherwise look like one.
- Zone changes must last ≥ `zone_dwell_seconds` before they count.
- Stepping off a court and back onto the same court within `excursion_seconds` (a ball
  chase) counts as nothing.
- A new ID that appears where another just vanished takes over that ID's zone ("handoff").
  This is positional only.

The line model (`sensor/src/opencourt/line.py`) is driven by events, and each court is
handled on its own, so it works for any number of courts:

| Event | Meaning |
|---|---|
| **Court c goes empty** | Light smoothing means the count was near zero for a few seconds. The engine waits `decide_delay_seconds` for crossings to arrive, then decides. If people were seen stepping onto the **open court above**, the group **moved up**, and its clock goes with it. Otherwise the group **left**, and a quick return can still undo that. |
| **Court c fills** (people stay ≥ `fill_confirm_seconds`) | The newcomers are one of these, in order: the group already known to be moving in; a **new group from the line** (Court 1); the group from the court below, if people were seen crossing up ("silent" move-up, which cascades down the line); **the same group back from a break**, if they were seen coming back from outside; otherwise **a new group with a fresh clock**. |
| **Quick swap** (a court never looked empty) | ≥ `turnover_min_people` left toward the entrance (not counting people walking through) **and** as many arrived from the court below (or from the line, for Court 1). That means a departure plus a move-up. |
| **Several open courts** | A group can move up twice before settling. Groups still walking are pushed up the chain of open courts. |

**Every fallback gives a younger clock.** If the engine isn't sure who is on a court, it
assumes a new group with a fresh clock. Uncertainty can delay a light but never turn one
on early. A group already on court when the system starts gets the full time.

### Calibration guidance

- Number courts from the entrance and line (Court 1), following the order groups move up.
- Each court zone covers the playing area plus the run-off behind the baselines.
- **Leave the walking lane between the court lines and the fence out of the court zones**
  if the camera can separate it. Otherwise, the fill confirmation and the pass-through
  rule handle it (the simulator tests both ways).
- The line (queue) zone covers where people wait at the entrance, and touches the path
  onto Court 1.

## 7. Wait estimate

Inputs: each group's ungated elapsed time, `typical_game_seconds` (median measured game
length), queue count, and group size.

1. Each court has a remaining time: 0 if empty, `max(min_remaining, typical − elapsed)`
   if the group is within its typical game length, and `overdue_remaining` if it is past
   it.
2. Each court then frees up at `r_i, r_i + L, r_i + 2L, …`.
3. Merge and sort all of those times across courts.
4. A new arrival is behind `ceil(queue_count / group_size)` groups, so their estimate is
   departure number `(groups_ahead + 1)` in that sorted list.

The app also shows **next court free in ~X min**.

---

## 8. Hardware

| Item | Notes |
|---|---|
| Raspberry Pi 5 (8 GB) | |
| Pi Camera Module 3 **Wide** | Wide field of view is needed to cover the bank. |
| microSD 64 GB (A2) | |
| Official 27 W USB-C PSU | Most power banks only supply 3 A. That works if there are no USB peripherals. |
| USB-C PD power bank, 20,000 mAh+ | For field tests. Expect a few hours. |
| Amber lights | **12 V beacons or plain amber LED strip, switched with a logic-level MOSFET.** Do not use WS2812: `rpi_ws281x` doesn't support the Pi 5. Must be sunlight-visible. |
| 12 V supply for lights | |
| Elevated mount (tripod or fence clamp, 3 m or higher) | Height is the biggest factor in separating courts and the queue. It also clears windscreens. |
| *Optional:* Raspberry Pi AI HAT+ (Hailo) | Only if NCNN on the CPU can't reach about 8 FPS. |

**Light layout is decided after the site visit.** The options are one light per court
(long cable runs) or one labeled panel at the queue (a single short run). The software
handles either through `lights.pins`.

**Frame rate:** target at least 8 FPS. ByteTrack matches boxes by overlap, so at 2–4 FPS
fast-moving players break tracks constantly. Export YOLO to NCNN at `imgsz` 480–640.

---

## 9. Software

### Sensor (`sensor/`, Python 3.12, uv)

| Purpose | Choice |
|---|---|
| Detection and tracking | `ultralytics` YOLO11n with ByteTrack (tuned `trackers/bytetrack_opencourt.yaml`) |
| Capture | `picamera2` (Pi), OpenCV (USB or video file) |
| Geometry | Pure-Python point-in-polygon, with no OpenCV in the core |
| Config | YAML validated with pydantic |
| GPIO | `gpiozero` with `lgpio` (`RPi.GPIO` doesn't work on the Pi 5) |
| HTTP | `httpx`, with a background thread that always sends only the latest snapshot |
| Service | `systemd` |

The core logic (zones, smoothing, crossings, activity, line model, signals, estimate) is
**pure and has no heavy dependencies**. Vision and Pi libraries are optional extras.

### Backend (`backend/`, Supabase)

- `sites`, `courts`, `devices` (device token stored as a SHA-256 hash), `site_status`,
  `court_status`, and `status_history`.
- The Pi calls `rpc/ingest_status(device_token, payload)`. It's a `SECURITY DEFINER`
  function that checks the token and upserts status.
- The public (anon) key can **only read** public views. Row-level security is on for
  every table.
- Realtime is enabled on `site_status` and `court_status`.
- A site is shown as **offline** if its last update is more than 60 s old.
- History is kept at one row per minute per site (counts and states only).

### iOS (`ios/`, Swift 6, SwiftUI, iOS 17+)

- `OpenCourtKit` Swift package: models, formatting, staleness, a status repository
  protocol, a Supabase-backed repository, and a demo repository.
- The app: a list of sites, a site detail screen (court cards, queue, wait time, next
  free court), stale/offline banners, and a demo mode.
- Map view comes later. Push notifications are a stretch goal.

---

## 10. Build sequence (two tracks in parallel)

### Track A: desk work (no footage needed). **Started 2026-09-16.**

1. Repo, tooling, and `CLAUDE.md`. ✅
2. Pure core: config, geometry, smoothing, crossings, line model, signals,
   estimate, all with unit tests. ✅
3. Synthetic simulator, plus an end-to-end evaluation of the engine against the
   simulator's ground truth. ✅
4. Runtime shell: detector, capture, lights, publisher, `run` / `replay` / `simulate` /
   `calibrate` / `evaluate` CLI, and a systemd unit. ✅ *(Written, but not yet run against
   a real camera, a video file, or GPIO.)*
5. Backend migration, RLS, the ingest function, and SQL tests. ✅ *(Tested on local
   Postgres. No Supabase project exists yet.)*
6. iOS kit and app with a demo repository. ✅ *(Builds and runs in the iOS Simulator;
   screenshots are in `docs/screenshots/`.)*
7. `simulate --publish`: the simulator drives the real backend, which feeds the real app.
   ⏳ Needs a Supabase project.

**What the simulator showed** (second design: the event-driven line model; busy 2-hour
sessions; noisy tracks with missed detections, ID switches, ghosts, bystanders, breaks, and
ball chases; departing groups walking the lane; parties merging into groups; 3 seeds each):

| Courts | Walking lane | Departures found | False departures | False "time up" | Overstaying groups lit |
|---|---|---|---|---|---|
| 2 | outside zones / inside zones | 100% / 100% | 0% / 0% | **0 min** | all |
| 4 | outside / inside | 94–100% / 94–100% | 0–11% / 0–5% | **0 min** | all but one |
| 8 | outside / inside | 92–98% / 92–98% | 9–13% | 0–5 min per 2 h | all |

Almost every "first-game group lit" case comes from the 20-minute rule itself: some
simulated first games run past 20 minutes. They are not detection errors.

The 8-court weakness: when several courts are open at once, groups hop up two courts
in a row, and the engine sometimes loses track of which group is which. This happens
mostly when the line is short, and possibly less often in real life than in the simulator.

Design lessons so far:

- Brief trips off the court (ball chases) must not count as crossings.
- Only decide "moved up" when people were actually seen stepping onto the court above.
- A court that never looks empty still needs a quick-swap rule.
- People walking through a court must stay long enough to count before they count as
  arriving.
- Lights stay off while groups are changing.

### Track B: field work (needs you at the court)

1. **Email the park district** (pilot permission, filming permission, a supportive
   quote).
2. **Record footage:** 1–2 h from a fixed, elevated position while people are waiting.
   Try 2–3 positions and times of day, and capture at least 3 rotations.
3. **Label it** using the format in `sensor/labels/README.md`: timestamps of every
   departure, and start/end times of each game.
4. Run `opencourt calibrate`, then `opencourt replay`, then `opencourt evaluate` on the
   footage. Fix whatever breaks.
5. Set the threshold from measured game lengths (`opencourt evaluate --games`).
6. Port to the Pi: NCNN export, check the frame rate, wire the lights.
7. **Field test** with lights on. Log every wrong decision and fix the worst ones.
8. Run a pilot with the posted notice.

### Milestones

| Target | Milestone |
|---|---|
| Week of Sep 21 | Track A items 2–4 done. Park district emailed. First footage recorded. |
| Week of Sep 28 | Backend and iOS demo end to end. Footage labeled and replay working. |
| Week of Oct 5 | Line model tuned on real footage. Game lengths measured. |
| Week of Oct 12 | Pi port, lights, first field test. |
| After | Pilot, then polish, stretch goals, and a second site. |

---

## 11. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Playing and waiting areas can't be told apart in footage | High | Elevated, side-on camera. Test positions first. |
| Tracker IDs too unstable | High | The line model uses court emptiness plus a few seconds of crossings. It never needs an ID to last. |
| Low FPS breaks ByteTrack | Medium | NCNN export, lower `imgsz`, tuned tracker, Hailo fallback |
| False amber ruins trust | Medium | Fail dark; every uncertain case hands out a *younger* clock; lights held during changes |
| Queue count polluted by spectators | Medium | Tight queue polygon, hysteresis, queue drop used only as supporting evidence |
| Far court too small to detect | Medium | Reposition the camera, or cover fewer courts |
| Park district says no | Medium | Offer a privacy statement and a pilot scope. The app-only mode (no lights) is a fallback. |
| Theft or weather | Medium | Short supervised pilots first, then a proper enclosure |

---

## 12. Future plans

1. **Detect the end of each game and light the court then** (the original hope). Two
   ways to get there:
   - *Game-end cue:* all four players meet at the net to tap paddles. This can be
     detected from positions alone, with no ball tracking and no identity.
   - *Score or rally tracking:* much harder (ball detection, and the score is only
     sometimes called out loud). Research this only after the timer prototype has been
     run at a real court.

   Either way, the 20-minute timer stays as a backstop.
2. **Larger banks (8 or more courts):** two or more cameras feeding one line model, which
   needs courts stitched together across views. The simulator already shows 8 courts in
   one view as the weaker case (§10).
3. Push notifications ("a court is likely free in about 10 min").
4. Busy-hour patterns from history.
5. Night operation.
6. Multiple sites.
7. An Android app, or a web page for people without iPhones.

---

## 13. Decisions and open questions

Answered on 2026-09-16:

- ✅ A group that moves up keeps playing the same game, so its clock and light move with it.
- ✅ Prototype rule: 20 minutes per group while others wait. The light reads "Time up."
  Game-end detection is future work (§12).
- ✅ It must work for any number of courts. **Start testing at a 4-court park** (see below).
- ✅ Departing groups walk back toward the entrance inside the fence, along the lane.
- ✅ Parties of 1–4 join the line and team up into foursomes. Singles are rare.
- ✅ Buffalo Grove, IL, so BIPA applies. The design stays clear of biometrics (§3).

**Which park to test at first: 4 courts.** It is the smallest bank where move-ups chain
across several courts, which is the hard part. It can still be covered by one wide
camera from one elevated spot. In the simulator, 2 and 4 courts had no false amber at all.

- The **2-court park** is a good place for a first half-hour of footage: checking camera
  height, detection range, and zone drawing, with little at stake.
- The **8-court park** comes later. It probably needs two camera positions, and it is the
  known weaker case in simulation.

Still open:

- [ ] Light layout: one light per court, or a panel at the line? Decide after the site
      visit.
- [ ] For each park: which court is "Court 1" (next to the entrance and line), and how
      the courts are laid out (one row, or two). This matters for zone drawing.
- [ ] Is there a divider fence or gate between neighbouring courts? It changes the paths
      groups take when they move up.
