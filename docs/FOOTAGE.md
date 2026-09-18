# Recording the first footage

Everything so far has been proven on a simulator. This recording is the first time the
vision part meets reality. The point is **not** a polished video: it's a fixed camera
watching a court while people actually come and go, so I can check that the detector,
the zone drawing, and the "who is on the court" logic hold up.

**One court is enough for the first recording.** The logic works for any number of
courts (there's a 1-court regression test), and with one court there's no shifting-up to
worry about. Two courts (both of Rick Drazner) is better if the angle allows, because then
I can also see a group moving between courts, but don't sacrifice height for it.

## What the frame has to include

From one fixed spot, the camera must see all of these at once:

1. **The whole court**, both baselines, with some run-off behind them (players step back
   past the baseline constantly, and that must not look like leaving).
2. **Where people wait.** The paddle rack, the bench, the bit of fence where the line
   forms. This is the "line" zone; without it there is no clock and no light.
3. **The path on and off the court**: the gate or gap in the fence people walk through.

The camera should be **high and off to the side**. Higher is the single biggest win: from
above, the people on the court and the people waiting land on different parts of the
image and can't overlap. Eye level is the worst case (everyone lines up behind everyone).
Aim for 3 m (10 ft) or more: the top of the fence, a light pole, bleachers, a step ladder,
a car roof, a tall tripod. A phone clamp on a fence post works well.

Quick test: from the spot, can you clearly see the far baseline *and* the waiting area
without either being hidden behind the near players? If yes, it's good.

## Phone settings

- Landscape. Widest lens (0.5× on iPhone) if that's what it takes to fit everything.
- 1080p at 30 fps is plenty. 4K isn't needed and makes huge files.
- Lock focus and exposure (tap and hold on the court until "AE/AF LOCK" shows), so the
  image doesn't pulse when someone in white walks by.
- Mounted, not handheld. Not even a little movement: the zones are drawn in pixels.
- Plug into a power bank. Recording in the sun for an hour can overheat a phone; keep it
  shaded if you can (a cap over it, or record in the evening).
- Expect roughly 4–6 GB per hour. Check free space first.

## How long, and when

- **First outing: two short test clips (5 minutes each) from two different spots**, plus
  a photo of each spot. That's enough for me to say which angle works before you invest an
  hour.
- **Then one continuous recording of 45–60 minutes at a time when people are actually
  waiting.** Weekday evening or weekend morning at Drazner. The valuable moments are
  groups finishing and new groups walking on; I want at least 3 of those.
- Keep the recording running through everything: water breaks, ball chases, someone
  standing by the fence chatting. The messy parts are the useful parts.

## Take notes while it records (2 minutes of your time, worth a lot)

On your phone's notes or paper, with the time on the video clock:

- when each group **finishes and walks off** (`departure`, which court);
- when a new group **starts playing** (`start`, which court);
- when a game **ends** (the paddle tap at the net), if you notice it;
- anything odd: a group took a break and came back, someone swapped in, a kid ran
  across the court.

Approximate is fine (within 10–15 seconds). The format I'll use is in
`sensor/labels/README.md`; I can turn your notes into it.

## Afterwards

1. AirDrop the clips to the Mac into `sensor/data/footage/` (git-ignored; nothing in that
   folder is ever uploaded). Name them like `2026-09-20-drazner-pos1.mov`.
2. Tell me. I run calibration (draw the zones on one frame), replay the footage through
   the pipeline, and compare against your notes. Then we'll know what to fix.

## Privacy and courtesy

- This is development footage, kept on your Mac and deleted once it's been used
  (PLAN.md §3). Don't post it.
- People generally don't mind a phone on a fence, but if anyone asks, the honest
  answer is: "I'm building a court-availability app; this never leaves my laptop and
  doesn't identify anyone." If someone objects, stop.
- Email the park district before the long recording (PLAN.md §10). For a 5-minute
  angle test, use your judgement.

## Which park, and the Rylko layout

- **Rick Drazner (2 courts)** first: one spot sees both courts, no cascade complexity.
- **Mike Rylko (8 courts as 4 + 4)** later. Half the bank (one row of 4) from one high
  spot is exactly the right demo target; the system treats that as a 4-court site. Both
  rows would need two cameras, which is a later problem.
