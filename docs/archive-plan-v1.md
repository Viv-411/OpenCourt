# OpenCourt — Project Plan

**Congressional App Challenge 2026**
**Submission deadline: Monday, October 26, 2026, 12:00 pm ET**
**Target submission date: October 23**
**Plan revised: September 16, 2026 — 40 days remaining**

---

## 1. What OpenCourt Is

A camera system that watches a bank of public pickleball courts, tracks
occupancy and the waiting queue, and enforces court rotation with a per-court
signal light. A native iOS app shows live status so players know where to go
before driving over.

Three components:

- **Sensor + enforcement unit** — Raspberry Pi with camera, driving one light per court
- **Backend** — receives counts, serves live state
- **iOS app** — live court status, wait estimates

---

## 2. The Problem

**Layer 1 — you can't tell which court is free.** Players drive over, find
everything full, drive somewhere else. Existing apps are user-reported and
therefore empty.

**Layer 2 — people don't rotate off, and no one can make them.** The norm is
one game, then vacate. Groups on the back courts stay for multiple games. Once
one group does it, everyone does. Asked for the score, some groups simply lie.

**Information cannot fix Layer 2.** Everyone waiting already knows what's
happening. The failure is that enforcing the norm requires a personal
confrontation with people who will dispute it.

### The mechanism

The light does not shame players. It removes the interpersonal cost from the
person waiting.

Today, asking a group to rotate is an accusation with no evidence. With the
light, the waiting player doesn't accuse anyone — they point. "You're hogging
the court" becomes "the light's on." A neutral party made the call and it isn't
arguable.

---

## 3. Why This Isn't Already Solved

Pickleball computer vision is a real industry, and **all of it is match
analytics** — line calls, shot classification, heat maps, highlights.
PlayReplay (official at PPA/MLP events), Wingfield, DinkVision, and several
open-source YOLO pipelines all target players and coaches.

**None of them address court availability or rotation compliance.** That space
is empty. The current solution is a paddle rack and the honor system.

---

## 4. How This Court Actually Works

Players queue in a single line at one spot. When the exit court finishes,
everything shifts up:

```
    queue ──► Court 1 ──► Court 2 ──► Court 3 ──► leave
             (entry)                  (exit)
```

Court 3 clears → Court 2's group moves to 3 → Court 1's group moves to 2 →
next group from the queue takes Court 1.

### What this means for the design

**Each court needs its own timer and its own light.** Groups arrive on their
court at different times, so "how long have you been here" is a per-court
question. Courts also change occupants outside a clean cascade — a group leaves
early, a single player swaps out. The timer belongs to the court and resets when
*that court's* occupants change.

**A court does not go empty during a rotation.** One group walks off as another
walks on. Detection must be based on *who moved*, not on emptiness.

---

## 5. Identity vs. Continuity — the Privacy Line

The system needs to know that the four figures on Court 2 are different figures
from the four who were there before. It does **not** need to know who anyone is.

**What we use:** ephemeral tracker IDs from ByteTrack. IDs are assigned from
motion and bounding-box overlap between adjacent frames. They are integers with
no meaning outside the current session, they reset constantly, and they cannot
be used to recognize anyone tomorrow or at another court.

**What we never use:**

- Face detection or face recognition
- Appearance embeddings or re-identification features — **this is why we use
  ByteTrack and not BoT-SORT**, which can use appearance for re-association
- Any identifier persisted beyond the current rotation window
- Stored or transmitted frames

Illinois has the Biometric Information Privacy Act, the strictest in the
country, with a private right of action. It regulates creating and possessing
biometric identifiers — not merely storing source images — and requires written
informed consent before collection, which cannot be obtained from the public at
a park. Motion-based tracker IDs are not biometric identifiers. Appearance
embeddings are much closer to the line. Stay on the safe side by design, and say
so in the video.

### The 90-second rule

**Tracker IDs will not survive 20 minutes.** They break on occlusion, on frame
exit, and when players cross. Never build logic that assumes ID persistence over
long periods.

Only ask tracking to do short work: a rotation is a burst of boundary crossings
within roughly 90 seconds. Detect that event and reset the timer on it. Between
rotations, only a stable count is needed.

---

## 6. Scope

### In scope

- Person detection and ephemeral motion tracking across a 2–3 court bank
- Per-court occupancy; queue count at the waiting area
- Rotation event detection via short-horizon boundary crossings
- Per-court timer + per-court GPIO light
- Native iOS app showing live status
- Count/timestamp logging

### Explicitly out of scope

- **Score and ball tracking.** Hardest CV problem, most crowded space, and no
  value — players already know the score.
- Face detection, recognition, or appearance-based re-identification
- Permanent installation, weatherproofing, solar power
- Push notifications (stretch — requires APNs setup)
- Reservations or booking

**Rule for the next 40 days:** when time runs short, cut from stretch goals.
Never expand scope.

---

## 7. The Timer

### Threshold

**Start at 20 minutes, then validate against measured data.**

Measure actual game lengths from week-1 footage and set the threshold from that
rather than from an estimate. If games run 12 minutes, 20 is too generous. If
they run 22, it's too tight.

### The legitimacy problem, and the framing that fixes it

The park district has **no posted time rule**. The norm is game completion.
A 20-minute timer therefore invents a rule nobody adopted, and the exact people
this targets will say "there's no 20-minute rule here" — and be correct.

**Do not present it as a time limit. Present it as a proxy for the existing
norm:**

> A game takes about 15 minutes. If you've been on this court for 20, you're
> into your second game while people are waiting.

Label the light state **"second game in progress,"** not "time expired." The
light isn't asserting a new rule; it's flagging a violation of the rule that
already exists.

### State machine, per court

| State | Condition | Light |
|---|---|---|
| `IDLE` | Court occupied, queue empty | Off |
| `ACTIVE` | Queue non-empty, timer running | Off |
| `WARNING` | ≤ 2 minutes remain | Slow amber pulse |
| `DUE` | Timer expired | Solid amber |

```
IDLE    → ACTIVE   queue_count >= 1 sustained 60s AND court_occupancy >= 2
ACTIVE  → WARNING  seconds_remaining <= 120
WARNING → DUE      seconds_remaining <= 0
any     → ACTIVE   rotation_event(court) fires          [reset timer]
any     → IDLE     queue_count == 0 sustained 60s       [reset timer]
```

**If nobody is waiting, no timer runs and no light turns on.** This is what
makes the system defensible: pressure only when pressure is warranted.

### Rotation event detection

A rotation on court *N* fires when, within a 90-second window:

- 2 or more tracker IDs previously inside `COURT_N` exit it and do not return, **and**
- 2 or more tracker IDs not previously inside `COURT_N` enter it and remain

Requiring two, not one, prevents a single player swapping out from resetting the
clock. Requiring both directions prevents a water break from counting.

### Light design

- **Amber, not red.** "Second game," not "you are cheating."
- Warning state before due state — give the group notice.
- Visible to everyone including the queue. A shared norm, not a targeting device.

---

## 8. Hardware

| Item | Notes |
|---|---|
| Raspberry Pi 5 (4GB or 8GB) | |
| Pi Camera Module 3 **Wide** | Wide FOV matters — must cover 2–3 courts |
| microSD 32GB+ | |
| USB-C PSU (5V/5A official) | Pi 5 is power-hungry |
| USB-C power bank, 20,000mAh+ | Field testing |
| 3 x amber LED beacons or WS2812 strips | One per court |
| MOSFET board or relay | If beacons exceed GPIO current |
| Tripod or fence clamp, elevated | Height matters enormously for separation |
| *Optional:* Hailo-8L AI HAT | Contingency only if CPU inference is too slow |

**Camera placement is the single highest-leverage physical decision.** Higher
and more side-on gives better separation between courts and between playing and
waiting. Test multiple positions in week 1 before mounting anything.

---

## 9. Software Stack

### Pi (Python 3.11)

| Purpose | Library |
|---|---|
| Detection + tracking | `ultralytics` (YOLO11n), ByteTrack tracker |
| Camera capture | `picamera2` (Pi Camera) or `opencv-python` (USB) |
| Geometry / polygons | `opencv-python` (`cv2.pointPolygonTest`) |
| GPIO | `gpiozero` with `lgpio` backend |
| HTTP client | `httpx` |
| Config | YAML via `pyyaml` |
| Service | `systemd` unit for autostart |

**Pi 5 GPIO warning:** `RPi.GPIO` does not work on Pi 5. Use `gpiozero`, which
uses `lgpio` underneath.

**Speed:** if CPU inference is too slow, export the model to NCNN
(`model.export(format="ncnn")`) before reaching for the Hailo HAT. Target is
only 2–4 FPS.

### Backend

**Supabase** — Postgres, auto-generated REST, Realtime subscriptions, and auth
in one service. Realtime means the iOS app gets pushed updates instead of
polling. Already familiar territory.

Tables: `courts`, `court_status`, `status_history`.

### iOS (Swift 6 / SwiftUI)

| Purpose | Framework |
|---|---|
| UI | SwiftUI |
| State | `@Observable` (Observation framework) |
| Networking / realtime | `supabase-swift` SDK |
| Map | MapKit |
| Distribution | TestFlight (requires $99 Apple Developer Program) |

Push notifications are a **stretch goal** — they need APNs certificates and a
server-side trigger, and that is not where the remaining days should go.

---

## 10. Build Sequence

The ordering principle: **front-load the riskiest unknown, and develop on the
Mac against recorded video for as long as possible.** Iterating on a Pi is slow.
Move to hardware only once the pipeline works.

### Step 0 — Footage (this weekend, no code)

Record 1–2 hours at the real court, from a fixed position, at a time when people
are actually waiting. Get at least two rotations on camera. Try three camera
positions and three times of day.

Then hand-label: note the timestamp of every rotation, and time several games
start to finish. This becomes both the test set and the source for the timer
threshold.

**Everything downstream depends on how separable "playing" and "waiting" look in
this footage. Nothing can be predicted from a desk.**

### Step 1 — Detection on recorded video (Mac)

```python
from ultralytics import YOLO
model = YOLO("yolo11n.pt")
results = model.track(
    source="court.mp4",
    classes=[0],              # person only
    tracker="bytetrack.yaml", # motion-only, no appearance
    persist=True,
)
```

Confirm people are detected reliably at the distances in the footage. If
detection fails at the far court, that's a camera placement problem — go back to
Step 0 before writing more code.

### Step 2 — Calibration tool

A small script that displays one frame and lets you click polygon vertices,
saving them to `config.yaml`. One polygon per court, plus one for the queue
area. You will re-run this every time the camera moves, so make it quick to use.

### Step 3 — Zone classification

For each detection, take the **bottom-center of the bounding box** (approximate
foot position), not the centroid. A player standing behind a baseline has a box
that overlaps the court even when their feet are outside it.

Apply `cv2.pointPolygonTest` against each zone. Output per-frame counts.

### Step 4 — Temporal smoothing

Never act on a single frame. Rolling 30-second median for every count. Verify
the smoothed counts against the footage by hand.

### Step 5 — Rotation detection

Using tracker IDs, implement the 90-second crossing rule from §7. Test against
the rotations hand-labeled in Step 0. **This is the hardest logic in the
project** — budget real time for it.

### Step 6 — Timer state machine

Write this as **pure functions with unit tests**, taking a sequence of
`(timestamp, court_occupancy, queue_count, rotation_event)` and returning states.
No camera, no hardware.

Feed it synthetic sequences: nobody waiting, someone arrives mid-game, rotation
fires during warning state, queue empties while due. This is where subtle bugs
hide, and it's the cheapest part to get right.

### Step 7 — Port to Pi + lights

Only now. Same pipeline code, different capture source. Add `gpiozero` output
for the three lights. Verify frame rate; drop resolution or export to NCNN if
needed.

### Step 8 — Backend

Supabase project, tables, and a `POST` from the Pi every few seconds carrying
counts, timer states, and seconds remaining. Nothing else.

### Step 9 — iOS app

Court list and map, per-court status, queue length, wait estimate. Subscribe to
Supabase Realtime for live updates.

Wait estimate: `(queue_count / 4) x measured_avg_game_length`.

### Step 10 — Field test

Run the whole system at the real court. Watch it. Note every wrong decision it
makes and fix the worst two.

### Step 11 — Video and submission

---

## 11. Timeline — 40 Days

| Week | Dates | Goal |
|---|---|---|
| 1 | Sep 16–22 | Steps 0–2. Footage, detection working, calibration tool. **Email park district.** |
| 2 | Sep 23–29 | Steps 3–5. Zone classification, smoothing, rotation detection. |
| 3 | Sep 30–Oct 6 | Steps 6–7. State machine + unit tests, port to Pi, lights working. |
| 4 | Oct 7–13 | Steps 8–9. Backend and iOS app. End-to-end. |
| 5 | Oct 14–20 | Step 10. Field testing, bug fixes, README, AI-use log. |
| 6 | Oct 21–23 | Step 11. Film and edit the video, write submission answers, **submit Oct 23.** |
| — | Oct 26, 12:00 pm ET | Hard deadline. Do not plan to use Oct 24–26. |

---

## 12. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Playing vs. waiting not separable in footage | **High** | Camera height and angle. Test in week 1, before any other work. |
| Tracker IDs too unstable for rotation detection | **High** | 90-second window only. Fall back to occupancy-change heuristics if crossings prove unreliable. |
| Far court too small for reliable detection | Medium | Reposition camera; reduce to 2 courts if needed |
| iOS build consumes more time than planned | Medium | Ship the simplest SwiftUI list view; map and polish are optional |
| Pi inference too slow | Low | NCNN export, then Hailo HAT |
| Park district slow to respond | Medium | CAC submission does not depend on them |
| Running out of time | **High** | Cut stretch goals. A working narrow demo beats a broken broad one. |

---

## 13. Stretch Goals — Only After Step 10 Works

1. **Paddle-tap game-end detection.** All four players converge at the net to tap
   paddles at game end — a spatial pattern detectable from positions alone, no
   ball tracking. Layers on top of the timer.
2. Push notifications ("your turn is in ~10 minutes")
3. Historical busy-hour patterns
4. Night operation

---

## 14. Congressional App Challenge Requirements

- App created after October 30, 2025 ✓
- **Demo video, max 3 minutes** — the primary artifact judges evaluate
- Judges may request source code; keep the repo clean with an honest README
- **AI assistance permitted but must be fully disclosed**, and cannot be the
  entirety of technical development. **Keep a running log as you go.**
- Teams up to 4; at least half must live or attend school in the district

### The demo video

The best 30 seconds available: camera sees three occupied courts and two people
waiting, Court 3's timer hits 20 minutes, its light goes amber, the cascade
fires, all three timers reset, lights go out. It makes the argument visually
with no narration.

Submission answers to prepare:
- What inspired you to create this app?
- What technical difficulty did you face? *(Rotation detection from unstable
  tracker IDs, and a state machine robust to detection flicker.)*

---

## 15. Open Items — This Week

- [ ] Confirm the congressional district is participating and register
- [ ] Confirm home vs. school district (they may differ; either is allowed)
- [ ] Record court footage — **blocking everything else**
- [ ] Measure real game lengths from footage; set the timer threshold
- [ ] Email park district: pilot permission, supportive quote for the video
- [ ] Apple Developer Program enrollment ($99) if TestFlight distribution is wanted
- [ ] Solo or team of up to 4?
- [ ] Check whether "OpenCourt" is already in use

### Park district email

The ask is now larger than before: with no posted time rule, you're proposing
they *adopt* a norm rather than enforce an existing one. That's a longer
conversation, which makes sending it this week more important, not less.

Frame it as: a system that supports the court's existing one-game rotation
custom, stores no images and identifies nobody, offered as a pilot on one bank
of courts. Ask for pilot permission and a supportive quote.
