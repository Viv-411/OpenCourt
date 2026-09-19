"""Configuration: YAML files validated with pydantic.

Two files:

* the main config (``config/example.yaml``) — tuning, lights, backend, camera;
* a zones file (written by ``opencourt calibrate``) — polygons in image pixels.

The main config references the zones file by path so re-running calibration never
clobbers hand-written comments in the main config.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .types import Point


class _Model(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Zones(_Model):
    """Polygons in image pixel coordinates. Courts are numbered from the queue (1 = entry)."""

    image_size: tuple[int, int] | None = None  # (width, height) the polygons were drawn on
    courts: dict[int, list[Point]]
    queue: list[Point]
    # Things the detector mistakes for people (a sign post, a pole, a trash can). Any
    # detection centred inside one of these is dropped. Drawn once at install time.
    ignore: list[list[Point]] = Field(default_factory=list)

    @field_validator("courts")
    @classmethod
    def _courts_contiguous(cls, v: dict[int, list[Point]]) -> dict[int, list[Point]]:
        if not v:
            raise ValueError("at least one court polygon is required")
        if sorted(v) != list(range(1, len(v) + 1)):
            raise ValueError(f"courts must be numbered 1..N from the queue, got {sorted(v)}")
        for n, poly in v.items():
            if len(poly) < 3:
                raise ValueError(f"court {n} polygon needs at least 3 points")
        return v

    @field_validator("queue")
    @classmethod
    def _queue_poly(cls, v: list[Point]) -> list[Point]:
        if len(v) < 3:
            raise ValueError("queue polygon needs at least 3 points")
        return v

    @field_validator("ignore")
    @classmethod
    def _ignore_polys(cls, v: list[list[Point]]) -> list[list[Point]]:
        for i, poly in enumerate(v):
            if len(poly) < 3:
                raise ValueError(f"ignore area {i + 1} needs at least 3 points")
        return v

    @property
    def court_count(self) -> int:
        return len(self.courts)


class SmoothingConfig(_Model):
    window_seconds: float = Field(30.0, gt=0)


class TrackingConfig(_Model):
    zone_dwell_seconds: float = Field(1.0, ge=0)  # a zone change must hold this long
    track_ttl_seconds: float = Field(10.0, gt=0)  # forget tracks unseen this long
    handoff_radius_px: float = Field(60.0, ge=0)  # new ID near a just-lost one inherits its zone
    handoff_seconds: float = Field(1.5, ge=0)
    excursion_seconds: float = Field(8.0, ge=0)  # leave-and-return to the same court is ignored


class QueueConfig(_Model):
    min_people: int = Field(1, ge=1)
    on_seconds: float = Field(60.0, ge=0)
    off_seconds: float = Field(180.0, ge=0)


class CourtConfig(_Model):
    occupied_min_people: float = Field(1.5, gt=0)  # smoothed count at or above => occupied
    players_per_group: int = Field(4, ge=1)


class RotationConfig(_Model):
    """How court turnover is read (docs/PLAN.md §6)."""

    fast_window_seconds: float = Field(6.0, gt=0)  # light smoothing to catch brief empty spells
    empty_below_people: float = Field(0.5, gt=0)  # fast count below this = court empty
    fill_confirm_seconds: float = Field(10.0, ge=0)  # people must stay this long to count as a fill
    # ... but only this long on a court a group is known to be moving onto (groups sometimes
    # move up twice in a row when several courts are open).
    expected_fill_confirm_seconds: float = Field(3.0, ge=0)
    # How long an empty court above still counts as the place a group moves up into.
    shift_window_seconds: float = Field(1800.0, gt=0)
    restore_seconds: float = Field(180.0, ge=0)  # same group back from a break within this
    arrival_timeout_seconds: float = Field(150.0, gt=0)  # a group moving up must arrive by then
    evidence_min_people: int = Field(2, ge=1)  # crossings needed to believe where people came from
    # Quick swap (court never looked empty): this many left AND this many came from below.
    turnover_min_people: int = Field(3, ge=1)
    turnover_window_seconds: float = Field(120.0, gt=0)
    turnover_check_seconds: float = Field(1.0, gt=0)
    queue_lookback_seconds: float = Field(20.0, ge=0)
    # A track that left the line still counts as coming from the line for this long (people
    # cross the walkway on their way to a court).
    queue_transit_seconds: float = Field(60.0, ge=0)
    # After a court empties, wait for crossings to arrive before deciding moved-up vs left
    # (exits are reported up to tracking.excursion_seconds late).
    decide_delay_seconds: float = Field(10.0, ge=0)
    decide_lookback_seconds: float = Field(30.0, ge=0)


class TimerConfig(_Model):
    threshold_seconds: float = Field(1200.0, gt=0)
    warning_seconds: float = Field(120.0, ge=0)  # 0 disables the warning pulse


class EstimateConfig(_Model):
    typical_game_seconds: float = Field(900.0, gt=0)
    min_remaining_seconds: float = Field(60.0, ge=0)
    overdue_remaining_seconds: float = Field(180.0, ge=0)


class HealthConfig(_Model):
    warmup_seconds: float | None = None  # defaults to smoothing window
    stale_frame_seconds: float = Field(10.0, gt=0)


class LightsConfig(_Model):
    driver: Literal["none", "console", "gpio"] = "none"
    pins: dict[int, int] = Field(default_factory=dict)  # court number -> BCM pin
    active_high: bool = True
    pulse_fade_seconds: float = Field(1.0, gt=0)


class BackendConfig(_Model):
    enabled: bool = False
    url: str = ""  # https://<project>.supabase.co
    anon_key_env: str = "OPENCOURT_SUPABASE_ANON_KEY"
    device_token_env: str = "OPENCOURT_DEVICE_TOKEN"
    heartbeat_seconds: float = Field(15.0, gt=0)
    min_interval_seconds: float = Field(2.0, ge=0)
    timeout_seconds: float = Field(5.0, gt=0)

    @property
    def anon_key(self) -> str | None:
        return os.environ.get(self.anon_key_env)

    @property
    def device_token(self) -> str | None:
        return os.environ.get(self.device_token_env)


class DetectorConfig(_Model):
    model: str = "yolo11n.pt"
    tracker: str = "trackers/bytetrack_opencourt.yaml"
    imgsz: int = Field(640, ge=160)
    confidence: float = Field(0.25, ge=0, le=1)
    device: str | None = None  # "cpu", "mps", ... ; None lets ultralytics choose


class CaptureConfig(_Model):
    source: Literal["picamera", "usb", "file"] = "picamera"
    path: str | None = None  # file path, or USB device index as a string
    width: int = 1920
    height: int = 1080
    target_fps: float = Field(8.0, gt=0)


class HistoryConfig(_Model):
    path: str | None = "data/history.jsonl"
    interval_seconds: float = Field(60.0, gt=0)


class Config(_Model):
    site_id: str = "demo-site"
    zones_file: str = "config/zones.yaml"
    zones: Zones | None = None  # inline zones (tests/sim) take precedence over zones_file

    smoothing: SmoothingConfig = SmoothingConfig()
    tracking: TrackingConfig = TrackingConfig()
    queue: QueueConfig = QueueConfig()
    court: CourtConfig = CourtConfig()
    rotation: RotationConfig = RotationConfig()
    timer: TimerConfig = TimerConfig()
    estimate: EstimateConfig = EstimateConfig()
    health: HealthConfig = HealthConfig()
    lights: LightsConfig = LightsConfig()
    backend: BackendConfig = BackendConfig()
    detector: DetectorConfig = DetectorConfig()
    capture: CaptureConfig = CaptureConfig()
    history: HistoryConfig = HistoryConfig()

    @model_validator(mode="after")
    def _check(self) -> Config:
        if self.timer.warning_seconds >= self.timer.threshold_seconds:
            raise ValueError("timer.warning_seconds must be less than timer.threshold_seconds")
        if self.zones is not None:
            unknown = set(self.lights.pins) - set(self.zones.courts)
            if unknown:
                raise ValueError(f"lights.pins refers to unknown courts {sorted(unknown)}")
        return self

    @property
    def warmup_seconds(self) -> float:
        if self.health.warmup_seconds is not None:
            return self.health.warmup_seconds
        return self.smoothing.window_seconds

    def require_zones(self) -> Zones:
        if self.zones is None:
            raise ValueError("zones not loaded; run `opencourt calibrate` first")
        return self.zones


def load_zones(path: str | Path) -> Zones:
    with open(path) as f:
        return Zones.model_validate(yaml.safe_load(f))


def save_zones(zones: Zones, path: str | Path) -> None:
    data = zones.model_dump(mode="json")
    data["courts"] = {int(k): [list(p) for p in v] for k, v in data["courts"].items()}
    data["queue"] = [list(p) for p in data["queue"]]
    data["ignore"] = [[list(p) for p in poly] for poly in data.get("ignore", [])]
    if not data["ignore"]:
        del data["ignore"]
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        f.write("# Written by `opencourt calibrate`. "
                "Pixel coordinates; courts numbered from the queue.\n")
        yaml.safe_dump(data, f, sort_keys=False)


def load_config(path: str | Path, *, load_zone_file: bool = True) -> Config:
    """Load the main config. Relative paths inside it resolve against the config's directory's
    parent (the ``sensor/`` project root) so the service can run from any cwd."""
    path = Path(path)
    with open(path) as f:
        raw = yaml.safe_load(f) or {}
    cfg = Config.model_validate(raw)
    root = path.resolve().parent.parent
    if cfg.zones is None and load_zone_file:
        zpath = Path(cfg.zones_file)
        if not zpath.is_absolute():
            zpath = root / zpath
        if zpath.exists():
            cfg = cfg.model_copy(update={"zones": load_zones(zpath)})
            Config.model_validate(cfg.model_dump())  # re-run cross-field checks
    return cfg


def resolve(cfg_path: str | Path, rel: str) -> Path:
    """Resolve a path from the config relative to the sensor project root."""
    p = Path(rel)
    return p if p.is_absolute() else Path(cfg_path).resolve().parent.parent / p
