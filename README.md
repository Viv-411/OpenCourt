# OpenCourt

Public pickleball courts run on an honor system: when every court is full, you play one
game and rotate off. OpenCourt watches a bank of courts, counts players and the people
waiting, and gives each group 20 minutes while others wait. When a group's time is up, an
amber light comes on at their court, and it follows them if they move up a court. The light takes the confrontation out of it: nobody has to accuse
anyone, they can just point at the light. A phone app shows the same status from home.

It never identifies anyone. It doesn't record or store video, and it can't recognise a
person. It counts people and notices when a group changes.

| Part | Where | Status |
|---|---|---|
| Sensor (Raspberry Pi 5 + camera) | [`sensor/`](sensor/) | Engine, simulator, CLI, and Pi runtime done; waiting on real footage |
| Backend (Supabase) | [`backend/`](backend/) | Schema, security, and tests done; needs a Supabase project |
| iOS app (SwiftUI) | [`ios/`](ios/) | Runs in the iOS Simulator on demo data |

- **Start here:** [`docs/GUIDE.md`](docs/GUIDE.md) covers what's built, how to test it,
  and what's left.
- Recording footage: [`docs/FOOTAGE.md`](docs/FOOTAGE.md)
- Plan: [`docs/PLAN.md`](docs/PLAN.md)
- Review of the first draft: [`docs/PLAN_REVIEW.md`](docs/PLAN_REVIEW.md)

```bash
scripts/test-all.sh --fast      # every suite, skipping the long simulations
```
