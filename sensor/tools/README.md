# Development tools (not part of the deployed sensor)

Scripts here help *develop* against recorded footage. They are deliberately **outside**
`src/opencourt/`, the package that runs on the Pi, so the privacy guarantee in
`docs/PLAN.md` §3 stays provable: nothing the Pi runs can write an image or a video
(`tests/test_privacy.py` scans the package).

These tools *do* write images and video, so the rules for them are:

- They read footage from `data/footage/` and write only into the git-ignored `data/`
  directory. Nothing they produce is ever committed.
- Output is for the person who recorded the footage, to check the system's accuracy.
  Delete it together with the footage when evaluation is done.

| Script | What it makes |
|---|---|
| `footage_background.py` | An empty-court still (median of many frames: moving people vanish) |
| `footage_heatmap.py` | Where people's feet were over the whole clip, over that still |
| `render_annotated.py` | A copy of the clip with zones, feet, counts, court states and clocks drawn on |
| `make_pi_clip.py` | A short benchmark clip for a Pi: same frame size, 10 fps, easy-to-decode MPEG-4 |
| `pi_bench.py` | Times the detector on that clip and logs temperature and throttling (boxes only) |
| `compare_runs.py` | Whether two machines' runs agree: detections and engine events (reads only) |

`scripts/pi-bench.sh` runs the last two on a Pi and compares against the Mac's reference.
