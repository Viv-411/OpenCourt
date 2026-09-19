"""``opencourt`` command line."""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys
import time
from pathlib import Path

from . import __version__
from .config import Config, load_config, load_zones
from .line import LineEvent, LineEventKind

SENSOR_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = SENSOR_ROOT / "config" / "local.yaml"


def _config_path(arg: str | None) -> Path:
    if arg:
        return Path(arg)
    if DEFAULT_CONFIG.exists():
        return DEFAULT_CONFIG
    return SENSOR_ROOT / "config" / "example.yaml"


def _load(args, need_zones: bool = True) -> tuple[Path, Config]:
    path = _config_path(args.config)
    cfg = load_config(path, load_zone_file=need_zones)
    if getattr(args, "zones", None):
        cfg = cfg.model_copy(update={"zones": load_zones(args.zones)})
        Config.model_validate(cfg.model_dump())
    return path, cfg


def _publisher(cfg: Config, enabled: bool):
    from .publish import NullPublisher, SupabasePublisher

    if enabled or cfg.backend.enabled:
        return SupabasePublisher(cfg.backend, cfg.site_id)
    return NullPublisher()


# -- commands -----------------------------------------------------------------------------


def cmd_run(args) -> int:
    from .capture import open_source
    from .detect import YoloTracker
    from .engine import Engine
    from .lights import make_lights
    from .publish import HistoryWriter
    from .runner import Sinks, history_path, run_camera

    path, cfg = _load(args)
    zones = cfg.require_zones()
    engine = Engine(cfg)
    sinks = Sinks(
        lights=make_lights(cfg.lights, args.lights),
        publisher=_publisher(cfg, args.publish),
        history=HistoryWriter(cfg.history, cfg.site_id, history_path(path, cfg.history.path)),
    )
    overlay = None
    if args.show:
        from .overlay import Overlay

        overlay = Overlay(zones)
    detector = YoloTracker(cfg.detector, SENSOR_ROOT)
    run_camera(engine, lambda: open_source(cfg.capture, args.source), detector, sinks, overlay)
    return 0


def cmd_detect(args) -> int:
    """Run the detector over a recording once and cache the boxes (never the frames)."""
    from .capture import VideoFileSource
    from .detect import YoloTracker
    from .trackfile import TrackFileHeader, write_frame, write_header

    _, cfg = _load(args, need_zones=False)
    det_cfg = cfg.detector.model_copy(update={
        k: v for k, v in {"imgsz": args.imgsz, "confidence": args.conf,
                          "device": args.device}.items() if v is not None})
    src = VideoFileSource(args.video, args.fps)
    out = Path(args.out or str(Path(args.video).with_suffix("")) + ".tracks.jsonl")
    detector = YoloTracker(det_cfg, SENSOR_ROOT)
    total = src.frame_count / src.fps if src.frame_count else 0
    t0 = time.monotonic()
    n = people = 0
    with open(out, "w") as f:
        write_header(f, TrackFileHeader(video=Path(args.video).name, fps=src.fps,
                                        size=(src.width, src.height), model=det_cfg.model,
                                        imgsz=det_cfg.imgsz, step=src.step))
        for t, frame in src.frames():
            tracks = detector(frame)
            write_frame(f, t, tracks)
            n += 1
            people += len(tracks)
            if n % 200 == 0:
                rate = n / (time.monotonic() - t0)
                print(f"  {t / 60:5.1f}/{total / 60:.1f} min  {rate:5.1f} frames/s  "
                      f"avg {people / n:.1f} people/frame", file=sys.stderr)
    src.close()
    print(f"wrote {out} ({n} frames, {n / (time.monotonic() - t0):.1f} frames/s)",
          file=sys.stderr)
    return 0


def cmd_replay(args) -> int:
    from .engine import Engine
    from .lights import make_lights
    from .publish import NullPublisher
    from .runner import Sinks, run_camera

    _, cfg = _load(args)
    zones = cfg.require_zones()
    engine = Engine(cfg)
    events_path = Path(args.events) if args.events else None
    events_f = open(events_path, "w") if events_path else None  # noqa: SIM115
    progress = {"last": 0.0}

    def on_snapshot(snap):
        if snap.t - progress["last"] >= 60:
            progress["last"] = snap.t
            courts = " ".join(f"C{c.number}:{c.signal.state.value[:4]}/{c.occupancy:.0f}"
                              for c in snap.courts)
            print(f"{snap.t / 60:6.1f} min  queue={snap.queue_count:.0f}  {courts}",
                  file=sys.stderr)
        for e in snap.events:
            print(_event_line(e), file=sys.stderr)

    sinks = Sinks(
        lights=make_lights(cfg.lights, args.lights or "console",
                           clock=lambda: engine.last_frame_t or 0.0),
        publisher=NullPublisher(),
        events=events_f,
        on_snapshot=on_snapshot,
    )
    if args.tracks:
        # Cached detections: no video decoding, no detector, seconds instead of minutes.
        from .trackfile import read

        _, frames = read(args.tracks)
        try:
            for obs in frames:
                sinks.handle(engine.step(obs))
        finally:
            sinks.close()
    else:
        from .capture import VideoFileSource
        from .detect import YoloTracker

        overlay = None
        if args.show:
            from .overlay import Overlay

            overlay = Overlay(zones)
        detector = YoloTracker(cfg.detector, SENSOR_ROOT)
        fps = args.fps or cfg.capture.target_fps
        run_camera(engine, lambda: VideoFileSource(args.video, fps, realtime=args.realtime),
                   detector, sinks, overlay, reconnect=False)
    if events_f:
        events_f.close()
        print(f"wrote {events_path}", file=sys.stderr)
    _print_event_summary(engine.event_log)
    return 0


def cmd_simulate(args) -> int:
    from .engine import Engine
    from .evaluate import evaluate_sim
    from .lights import make_lights
    from .sim import CourtSim, SimParams, sim_zones

    path = _config_path(args.config)
    base = load_config(path, load_zone_file=False)
    cfg = base.model_copy(update={"zones": sim_zones(args.courts, not args.lane_outside)})
    if args.site:
        cfg = cfg.model_copy(update={"site_id": args.site})
    params = SimParams(courts=args.courts, duration_seconds=args.minutes * 60, seed=args.seed,
                       fps=args.fps, shift_up_prob=args.shift_up)
    if args.report:
        print(evaluate_sim(params, cfg).summary())
        return 0

    publisher = _publisher(cfg, args.publish)
    engine = Engine(cfg)
    sim = CourtSim(params)
    lights = make_lights(cfg.lights, args.lights or "console", clock=lambda: sim.t)
    start = time.monotonic()
    last_print = -math.inf
    try:
        for obs, _truth in sim.run():
            snap = engine.step(obs)
            for c in snap.courts:
                lights.set(c.number, c.signal.light)
            publisher.submit(snap)
            for e in snap.events:
                print(_event_line(e), file=sys.stderr)
            if obs.t - last_print >= args.print_every:
                last_print = obs.t
                print(_status_line(snap), file=sys.stderr)
            if args.speed > 0:
                delay = start + obs.t / args.speed - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
    except KeyboardInterrupt:
        pass
    finally:
        lights.close()
        publisher.close()
    _print_event_summary(engine.event_log)
    return 0


def cmd_calibrate(args) -> int:
    from .calibrate import calibrate

    out = Path(args.out)
    existing = load_zones(out) if out.exists() else None
    ok = calibrate(args.source, args.courts, out, existing)
    return 0 if ok else 1


def cmd_evaluate(args) -> int:
    from .evaluate import Labels, game_length_stats, match_departures

    labels = Labels.load(args.labels)
    if args.games:
        stats = game_length_stats(labels.games)
        if not stats:
            print("no games labeled")
            return 1
        print(f"games labeled: {stats['n']:.0f}")
        for k in ("median", "p85", "p90", "max"):
            print(f"  {k:>6}: {stats[k] / 60:5.1f} min ({stats[k]:.0f} s)")
        suggested = math.ceil(stats["p90"] / 30) * 30
        print(f"suggested timer.threshold_seconds: {suggested}  "
              f"(p90 rounded up; see docs/PLAN.md §5)")
        print(f"suggested estimate.typical_game_seconds: {round(stats['median'])}")
    if args.events:
        with open(args.events) as f:
            events = [json.loads(line) for line in f if line.strip()]
        restored = {e.get("ref") for e in events if e["kind"] == "restore"}
        detected = [(e["t"], e["court"]) for e in events
                    if e["kind"] == "departure" and e.get("ref") not in restored]
        m = match_departures(labels.departures, detected, slack=args.slack)
        print(f"departures: labeled={len(m.truth)} detected={len(m.detected)} "
              f"matched={m.matched} recall={m.recall:.2f} precision={m.precision:.2f}")
    return 0


def cmd_check(args) -> int:
    path, cfg = _load(args)
    print(f"config: {path}")
    print(f"site: {cfg.site_id}")
    if cfg.zones is None:
        print("zones: MISSING — run `opencourt calibrate`")
        return 1
    print(f"zones: {cfg.zones.court_count} courts, image {cfg.zones.image_size}")
    print(f"threshold: {cfg.timer.threshold_seconds / 60:.1f} min, "
          f"warning {cfg.timer.warning_seconds:.0f} s")
    print(f"lights: {cfg.lights.driver} pins={cfg.lights.pins}")
    b = cfg.backend
    if b.enabled:
        missing = [n for n, v in ((b.anon_key_env, b.anon_key), (b.device_token_env,
                                                                  b.device_token)) if not v]
        print(f"backend: {b.url} " + (f"MISSING env {missing}" if missing else "ok"))
    else:
        print("backend: disabled")
    return 0


def cmd_export(args) -> int:
    from .detect import export_ncnn

    print(export_ncnn(args.model, args.imgsz))
    return 0


# -- helpers ------------------------------------------------------------------------------


def _event_line(e: LineEvent) -> str:
    what = {
        LineEventKind.DEPARTURE: f"group left court {e.court}",
        LineEventKind.RESTORE: f"court {e.court}: same group back from a break",
        LineEventKind.MOVE: f"group moved up court {e.from_court} -> {e.court} (clock follows)",
        LineEventKind.ARRIVAL: f"new group on court {e.court}"
                               + (" (start time assumed)" if e.assumed else ""),
        LineEventKind.LOST: f"court {e.court}: group moving up from {e.from_court} never arrived",
    }[e.kind]
    return f"[{e.t / 60:6.1f} min] {what}" + (f"  ({e.note})" if e.note else "")


def _status_line(snap) -> str:
    def clock(sig) -> str:
        return "     " if sig.clock_seconds is None else f"{sig.clock_seconds / 60:4.1f}m"

    courts = "  ".join(f"C{c.number} {c.signal.state.value:<8}{clock(c.signal)}"
                       for c in snap.courts)
    wait = snap.wait.wait_seconds
    w = f"{wait / 60:.0f}m" if wait is not None else "-"
    return f"{snap.t / 60:6.1f} min | queue {snap.queue_count:2.0f} | wait {w:>4} | {courts}"


def _print_event_summary(events: list[LineEvent]) -> None:
    kinds: dict[str, int] = {}
    for e in events:
        kinds[e.kind.value] = kinds.get(e.kind.value, 0) + 1
    print(f"line events: {kinds or 'none'}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="opencourt", description=__doc__)
    p.add_argument("--version", action="version", version=__version__)
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    def with_config(sp):
        sp.add_argument("-c", "--config", help="config YAML (default: config/local.yaml, "
                                               "else config/example.yaml)")
        sp.add_argument("--zones", help="override the zones file")
        return sp

    sp = with_config(sub.add_parser("run", help="run live on a camera"))
    sp.add_argument("--source", help="override capture: picamera | usb:N | path")
    sp.add_argument("--lights", choices=["none", "console", "gpio"])
    sp.add_argument("--publish", action="store_true", help="force-enable the backend")
    sp.add_argument("--show", action="store_true", help="debug overlay window (not recorded)")
    sp.set_defaults(func=cmd_run)

    sp = with_config(sub.add_parser("detect", help="run the detector over footage once and "
                                                   "cache the boxes for fast replays"))
    sp.add_argument("video")
    sp.add_argument("--out", help="default: <video>.tracks.jsonl next to the video")
    sp.add_argument("--fps", type=float, default=10.0, help="frames per second to process")
    sp.add_argument("--imgsz", type=int, help="detector input size (default from config)")
    sp.add_argument("--conf", type=float, help="detector confidence (default from config)")
    sp.add_argument("--device", help="cpu | mps (default from config)")
    sp.set_defaults(func=cmd_detect)

    sp = with_config(sub.add_parser("replay", help="run the pipeline on recorded footage"))
    sp.add_argument("video", nargs="?", help="the recording (not needed with --tracks)")
    sp.add_argument("--tracks", help="cached detections from `opencourt detect` (fast)")
    sp.add_argument("--events", help="write line events as JSON lines")
    sp.add_argument("--fps", type=float, help="processing frame rate (default: capture.target_fps)")
    sp.add_argument("--realtime", action="store_true")
    sp.add_argument("--lights", choices=["none", "console"])
    sp.add_argument("--show", action="store_true")
    sp.set_defaults(func=cmd_replay)

    sp = sub.add_parser("simulate", help="run the engine on the synthetic court")
    sp.add_argument("-c", "--config")
    sp.add_argument("--courts", type=int, default=4)
    sp.add_argument("--shift-up", type=float, default=0.8,
                    help="how often a freed court is taken by the group below moving up "
                         "(1 = always cascade, 0 = always straight off the line)")
    sp.add_argument("--lane-outside", action="store_true",
                    help="zones exclude the walking lane (the recommended calibration)")
    sp.add_argument("--minutes", type=float, default=120)
    sp.add_argument("--seed", type=int, default=0)
    sp.add_argument("--fps", type=float, default=8.0)
    sp.add_argument("--speed", type=float, default=0,
                    help="x real time (0 = as fast as possible; 1 = live demo)")
    sp.add_argument("--print-every", type=float, default=60, help="status line every N sim-s")
    sp.add_argument("--lights", choices=["none", "console"])
    sp.add_argument("--publish", action="store_true", help="send snapshots to the backend")
    sp.add_argument("--site", help="override site_id (e.g. a demo site in the backend)")
    sp.add_argument("--report", action="store_true", help="score against ground truth")
    sp.set_defaults(func=cmd_simulate)

    sp = sub.add_parser("calibrate", help="click zone polygons on a frame")
    sp.add_argument("--source", required=True, help="video path | usb:N | picamera")
    sp.add_argument("--courts", type=int, required=True)
    sp.add_argument("--out", default=str(SENSOR_ROOT / "config" / "zones.yaml"))
    sp.set_defaults(func=cmd_calibrate)

    sp = sub.add_parser("evaluate", help="score replay events against hand labels")
    sp.add_argument("--labels", required=True)
    sp.add_argument("--events", help="JSON lines from `opencourt replay --events`")
    sp.add_argument("--games", action="store_true", help="game-length stats + threshold")
    sp.add_argument("--slack", type=float, default=90)
    sp.set_defaults(func=cmd_evaluate)

    sp = with_config(sub.add_parser("check-config", help="validate config and environment"))
    sp.set_defaults(func=cmd_check)

    sp = sub.add_parser("export-model", help="export YOLO to NCNN for the Pi")
    sp.add_argument("--model", default="yolo11n.pt")
    sp.add_argument("--imgsz", type=int, default=640)
    sp.set_defaults(func=cmd_export)
    return p


def _load_dotenv(path: Path) -> None:
    """Load KEY=VALUE lines from sensor/.env (git-ignored) without overriding the environment."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def main(argv: list[str] | None = None) -> int:
    _load_dotenv(SENSOR_ROOT / ".env")
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if not args.verbose:
        logging.getLogger("httpx").setLevel(logging.WARNING)  # one line per publish is noise
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
