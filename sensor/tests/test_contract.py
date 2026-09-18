"""The payload the sensor publishes is the backend's input contract. The fixture below is
ingested by backend/tests/test_schema.py; regenerate it with
``OPENCOURT_UPDATE_FIXTURES=1 uv run pytest tests/test_contract.py``."""

import json
import os
from pathlib import Path

from opencourt.engine import Engine
from opencourt.sim import CourtSim, SimParams, sim_config

FIXTURE = Path(__file__).resolve().parents[2] / "backend" / "tests" / "fixtures" / "payload_v1.json"


def sample_payload() -> dict:
    cfg = sim_config(4)
    engine = Engine(cfg, wall_clock=lambda: 1_790_000_000.0)
    # First moment with someone waiting and a court past its threshold: exercises every field.
    for obs, _ in CourtSim(SimParams(duration_seconds=7200, seed=1)).run():
        snap = engine.step(obs)
        states = {c.signal.state.value for c in snap.courts}
        if snap.queue_waiting and "due" in states and snap.wait.wait_seconds:
            return snap.to_payload("sim-site")
    raise AssertionError("simulation never produced a busy snapshot")


def test_payload_matches_backend_fixture():
    payload = sample_payload()
    if os.environ.get("OPENCOURT_UPDATE_FIXTURES"):
        FIXTURE.write_text(json.dumps(payload, indent=2) + "\n")
    assert json.loads(FIXTURE.read_text()) == payload, (
        "payload changed: update backend/supabase ingest_status and regenerate the fixture"
    )
