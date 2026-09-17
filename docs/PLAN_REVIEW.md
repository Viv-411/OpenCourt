# Review of Plan v1

Review of the first-draft plan (`archive-plan-v1.md`), written 2026-09-16.
Every point marked **Changed** has been applied in [`PLAN.md`](PLAN.md).

> **Later update (same day).** After this review, the user made three decisions:
>
> - The light now reads **"Time up."**
> - The prototype uses a fixed 20-minute timer per group.
> - Rotation tracking was redesigned as an event-driven line model (PLAN §6).
>
> Points B and C below describe the thinking at the time of the review.

---

## What's strong

1. **Risk goes first, and development happens on the Mac.** The plan gets real
   footage before writing vision code and only moves to the Pi once the pipeline
   works. That ordering is right.
2. **The privacy line is concrete.** It says why ByteTrack is used instead of
   BoT-SORT, bans appearance embeddings, and forbids storing frames. These are
   rules the code can follow, not vague promises.
3. **The light is framed as a stand-in for the existing norm** ("second game in
   progress"), not as a new time limit. This is the most important idea in the
   project, and the plan handles it well.
4. **No queue means no clock.** Pressure applies only when someone is actually
   waiting, which is the fairest rule and the easiest to defend.
5. **Uses the feet, not the center of the box.** Taking the bottom-center of each
   bounding box is the right call for deciding whether someone is on the court.
6. **The state machine is pure and tested.** Timer logic is kept separate from
   the camera and hardware, so it can be tested cheaply.
7. **Scope is disciplined.** It skips score and ball tracking and has an explicit
   out-of-scope list.
8. **It never acts on a single frame.** Counts are smoothed first.

---

## What's wrong or missing

### A. The rotation model in the plan doesn't match how the court works. *(Critical)*

The plan's diagram says "Court 3 clears, then everyone shifts." You described a
different model: **any** group that finishes leaves, every group *below* it moves
up one court, and the next group from the queue takes Court 1.

In that model, a group plays one game in total but may play it across several
courts. That breaks the plan's rule that "the timer belongs to the court and
resets when that court's occupants change." When the Court 2 group moves to
Court 3, Court 3's occupants change, so under the plan the clock resets. That
means **a group can play forever by being shifted up**, and every shift wipes
its clock.

**Changed.** The clock now belongs to the *group* and moves with it when groups
shift up. The system never needs to recognize the group to do this, because the
order of groups is fixed: if the group on Court *k* leaves, the groups on Courts
1 to *k*−1 each move up one court. Clocks can therefore be moved by position,
with no tracking across the move.

### B. The rotation detector contradicts its own premise. *(Critical)*

The plan says a water break won't count as a rotation because the rule requires
people both leaving and arriving. But §5 says tracker IDs are lost all the time.
If two players leave for water and come back, they come back with **new IDs**.
That looks exactly like two people leaving and two different people arriving,
which counts as a rotation, so their clock resets.

**Changed.** Rotations are now recognized as a pattern across courts
("episodes") instead of by matching individual IDs:

- A departure from Court *k* causes changes on Courts 1 through *k*.
- Courts above *k* stay unchanged.
- If a group entered Court 1, the queue should shrink.
- Changes on a single court with no change in the queue, where the court is
  occupied again at the end, are treated as a **break**, not a rotation.

Tracker IDs are only used to count boundary crossings over a few seconds. A new
ID that appears already *inside* a court is never counted as an arrival.

### C. False alarms and missed alarms are not equally bad. *(Important)*

The whole idea depends on the light being neutral and correct. One false amber
on a group that is honestly finishing its first game ends that. The plan
treats the threshold as roughly an average ("a game takes about 15 minutes"),
but recreational game lengths vary a lot.

**Changed.**

- The threshold is set from a **high percentile** (around the 85th–90th) of the
  measured game lengths, not the average.
- Every uncertain situation **fails dark** (lights off): a blocked camera,
  stale frames, poor detection, or a rotation the system can't make sense of.
- The system also shows a **Degraded** state so the app doesn't display
  confident nonsense.

### D. There's no "empty court" state, and the plan wrongly assumes courts never sit empty.

In your model, a court is empty between one group leaving and the next group
moving up. The app's main job is to show *free courts*, but the state table has
no state for that.

**Changed.** Added an `EMPTY` state. The inference logic also expects
temporary emptiness during a rotation.

### E. The queue reset is too easy to trigger.

`queue_count == 0` for 60 seconds resets every clock. If the one person waiting
steps out of the queue area to talk to a friend, everyone gets a fresh 20
minutes.

**Changed.** The queue has to be empty for longer before it counts as empty
(default 180 s) than it has to be occupied before it counts as occupied
(default 60 s). Both values are in the config.

### F. The wait-time formula is wrong.

`(queue_count / 4) × avg_game_length` ignores how many courts there are. Four
courts free up groups about four times as fast as one. It also ignores how far
along each group already is.

**Changed.** The group clocks already estimate when each court will free up.
The wait estimate now:

1. Starts from each group's remaining expected time.
2. Adds one full game length for each later round.
3. Sorts all of those times.
4. Reads off the time at the position of the newly arriving group.

### G. The backend has no security or staleness model.

- It doesn't say how the Pi authenticates. The easy shortcut is to put the
  Supabase *service key* on a device sitting in a park, which is a bad idea.
- It doesn't say what the app shows when the Pi dies. A dead power bank would
  leave the app showing hours-old "live" data.

**Changed.**

- The Pi calls a single `ingest_status` database function, using a per-device
  token that is stored only as a hash in the database. The public (anon) key can
  only *read* status. Row-level security is on for every table.
- The Pi sends a heartbeat. Both the app and the database treat status older
  than 60 seconds as **offline**.

### H. The plan says the system never records video, but its first step is recording video.

Step 0 records 1–2 hours of strangers, and the demo video was going to show real
players. That doesn't contradict the privacy promise, since the promise is about
the *deployed system*, but the plan has to say this plainly or it looks
dishonest.

**Changed.** Added a "Development footage" policy:

- Get permission from the park district first, or film friends who agree.
- Keep footage on your own machine only, and never commit it to git (it's in
  `.gitignore`).
- Delete it after labeling and evaluation.
- Blur faces in anything shown publicly.

A test in the codebase also fails if any runtime code writes frames to disk.

### I. ByteTrack at 2–4 frames per second is a hidden risk.

ByteTrack links detections between frames by how much their boxes overlap.
Pickleball players move a lot in 300 ms, so at 2–4 FPS their boxes often won't
overlap from one frame to the next and the IDs will break constantly.

**Changed.**

- The target is now at least 8 FPS. The model is exported to NCNN at a lower
  input resolution, and the Hailo add-on is the fallback.
- A tuned tracker config is included.
- The episode detector depends much less on IDs lasting (see B).

### J. Lights: the hardware notes have two gotchas.

- Common WS2812 libraries (`rpi_ws281x`) **don't work on the Pi 5**.
- Small LEDs are close to invisible in direct sunlight.
- One Pi driving lights on three or four courts means long cable runs.

**Changed.**

- The recommended light is now plain 12 V amber beacons or LED strips switched
  through a MOSFET. `gpiozero.PWMLED` can pulse them.
- The software treats lights as a pluggable driver, so "one light per court"
  and "one panel at the queue" are just a config choice (to be decided after
  the site visit).

### K. The framing is inconsistent.

§1 calls the hardware an "enforcement unit" that "enforces court rotation."
That contradicts the core message: the system *signals* and people decide.

**Changed.** The wording is now **signal**, not enforce, throughout.

### L. Claims that go further than the evidence.

- "That space is empty": you can only say you *found* no product that addresses
  rotation. Occupancy sensing is a mature field (parking, meeting rooms).
- The BIPA paragraph reads like legal advice. It's a reasonable design stance,
  not a legal opinion.
- "A game takes about 15 minutes" is stated before anything was measured.

**Changed.** These are now worded as findings or assumptions.

### M. The build order leaves the cheapest work until week 3.

The pure state machine, simulator, backend, and app don't depend on footage at
all. They can be built *while* footage is still being gathered.

**Changed.** The build sequence now runs two tracks in parallel. There is also
a **synthetic court simulator**, which produces tracker-like detections with
missed detections, ID switches, and bystanders. It lets the whole system,
including the app, run end to end before any footage exists.

### N. Competition material is no longer relevant.

This is now a passion project with the goal of real deployment, so the
Congressional App Challenge sections, deadlines, and video checklist are
removed. What matters more now:

- the park district relationship,
- durability,
- running more than one site,
- a written privacy statement you can post at the court.

### O. Smaller fixes

- **Missing states.** The state machine has no answer for "court was empty and
  someone walks onto it" or "the system just started while groups are already
  playing." It now has an explicit starting assumption: a group already on
  court when the system boots is given the full time.
- **Singles.** Group size is now configurable.
- **Warning pulse.** The pulse before the deadline can itself start an argument
  ("you've got 2 minutes"). It's kept but can be turned off
  (`warning_seconds: 0`).
- **Logging.** It now writes snapshots once a minute (counts and states only),
  not every frame.
- **Time zones.** Timestamps are stored in UTC, and the app shows local time.
