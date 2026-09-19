from pathlib import Path

import pytest
from pydantic import ValidationError

from opencourt.config import Config, Zones, load_config, load_zones, save_zones

ROOT = Path(__file__).resolve().parents[1]
SQ = [(0, 0), (1, 0), (1, 1)]


def test_example_config_loads():
    cfg = load_config(ROOT / "config" / "example.yaml", load_zone_file=False)
    assert cfg.timer.threshold_seconds > cfg.timer.warning_seconds


def test_example_zones_load():
    z = load_zones(ROOT / "config" / "zones.example.yaml")
    assert z.court_count >= 1


def test_courts_must_be_numbered_from_one():
    with pytest.raises(ValidationError):
        Zones(courts={2: SQ}, queue=SQ)


def test_warning_must_be_shorter_than_threshold():
    with pytest.raises(ValidationError):
        Config(timer={"threshold_seconds": 100, "warning_seconds": 100})


def test_light_pins_must_match_courts():
    with pytest.raises(ValidationError):
        Config(zones=Zones(courts={1: SQ}, queue=SQ), lights={"pins": {2: 17}})


def test_unknown_keys_are_rejected():
    with pytest.raises(ValidationError):
        Config(timer={"threshhold_seconds": 10})


def test_zones_round_trip(tmp_path):
    z = Zones(image_size=(640, 480), courts={1: SQ, 2: SQ}, queue=SQ)
    save_zones(z, tmp_path / "z.yaml")
    assert load_zones(tmp_path / "z.yaml") == z


def test_zones_file_is_loaded_relative_to_project(tmp_path):
    (tmp_path / "config").mkdir()
    save_zones(Zones(courts={1: SQ}, queue=SQ), tmp_path / "config" / "zones.yaml")
    (tmp_path / "config" / "main.yaml").write_text("zones_file: config/zones.yaml\n")
    cfg = load_config(tmp_path / "config" / "main.yaml")
    assert cfg.zones is not None and cfg.zones.court_count == 1


def test_ignore_areas_round_trip(tmp_path):
    z = Zones(courts={1: SQ}, queue=SQ, ignore=[[(5, 5), (6, 5), (6, 6)]])
    save_zones(z, tmp_path / "z.yaml")
    assert load_zones(tmp_path / "z.yaml").ignore == [[(5, 5), (6, 5), (6, 6)]]


def test_ignore_area_needs_three_points():
    with pytest.raises(ValidationError):
        Zones(courts={1: SQ}, queue=SQ, ignore=[[(0, 0), (1, 1)]])
