import json

import httpx

from opencourt.cli import main
from opencourt.config import BackendConfig, Config, HistoryConfig
from opencourt.engine import Engine
from opencourt.lights import ConsoleLights
from opencourt.publish import HistoryWriter, SupabasePublisher, Throttle
from opencourt.sim import sim_zones
from opencourt.types import LightMode, Observation, Track


def snapshots(n=5, dt=1.0):
    e = Engine(Config(zones=sim_zones(2)), wall_clock=lambda: 123.0)
    return [e.step(Observation(i * dt, (Track.at_foot(400, 400, 1),))) for i in range(n)]


def test_throttle_heartbeat_and_change():
    clock = [0.0]
    th = Throttle(min_interval=2, heartbeat=15, clock=lambda: clock[0])
    s = snapshots(1)[0]
    assert th.should_send(s)
    clock[0] = 5
    assert not th.should_send(s)  # unchanged
    clock[0] = 16
    assert th.should_send(s)  # heartbeat


def test_supabase_publisher_posts_rpc(monkeypatch):
    monkeypatch.setenv("OPENCOURT_SUPABASE_ANON_KEY", "anon")
    monkeypatch.setenv("OPENCOURT_DEVICE_TOKEN", "tok")
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(204)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    pub = SupabasePublisher(BackendConfig(enabled=True, url="https://x.supabase.co/"), "site-1",
                            client=client, start_thread=False)
    pub.send_now(snapshots(1)[0].to_payload("site-1"))
    req = seen[0]
    assert req.url.path == "/rest/v1/rpc/ingest_status"
    assert req.headers["apikey"] == "anon"
    body = json.loads(req.content)
    assert body["p_token"] == "tok"
    assert body["p_payload"]["site_id"] == "site-1"


def test_publisher_thread_survives_failures(monkeypatch):
    monkeypatch.setenv("OPENCOURT_SUPABASE_ANON_KEY", "anon")
    monkeypatch.setenv("OPENCOURT_DEVICE_TOKEN", "tok")
    calls = []

    def handler(request):
        calls.append(1)
        return httpx.Response(500 if len(calls) == 1 else 204)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    pub = SupabasePublisher(BackendConfig(enabled=True, url="https://x", min_interval_seconds=0),
                            "s", client=client)
    pub.submit(snapshots(1)[0])
    import time
    deadline = time.time() + 5
    while pub.sent == 0 and time.time() < deadline:
        time.sleep(0.05)
    pub.close()
    assert pub.failed == 1 and pub.sent == 1


def test_history_writer_samples_by_interval(tmp_path):
    path = tmp_path / "h.jsonl"
    w = HistoryWriter(HistoryConfig(interval_seconds=2), "s", path)
    for s in snapshots(5):
        w.submit(s)
    lines = path.read_text().splitlines()
    assert len(lines) == 3  # t = 0, 2, 4
    assert json.loads(lines[0])["site_id"] == "s"


def test_console_lights_only_report_changes(capsys):
    import sys
    lights = ConsoleLights(stream=sys.stdout)
    lights.set(1, LightMode.OFF)
    lights.set(1, LightMode.OFF)
    lights.set(1, LightMode.SOLID)
    lights.close()
    out = capsys.readouterr().out.splitlines()
    assert len(out) == 3 and "solid" in out[1] and "off" in out[2]


def test_cli_simulate_runs(capsys):
    assert main(["simulate", "--minutes", "3", "--courts", "2", "--lights", "none"]) == 0
    assert "line events" in capsys.readouterr().err


def test_cli_check_config_on_example(capsys):
    from opencourt.cli import SENSOR_ROOT
    code = main(["check-config", "-c", str(SENSOR_ROOT / "config" / "example.yaml"),
                 "--zones", str(SENSOR_ROOT / "config" / "zones.example.yaml")])
    assert code == 0
    assert "4 courts" in capsys.readouterr().out


def test_cli_evaluate_games(tmp_path, capsys):
    labels = tmp_path / "l.yaml"
    labels.write_text(
        "clip: x\n"
        "departures:\n  - {t: '1:00', court: 2}\n"
        "games:\n  - {start: '0:00', end: '12:00'}\n  - {start: 0, end: 900}\n"
        "  - {start: '1:00:00', end: '1:20:00'}\n"
    )
    events = tmp_path / "e.jsonl"
    events.write_text("\n".join(json.dumps(e) for e in [
        {"kind": "departure", "t": 70, "court": 2, "ref": 1},
        {"kind": "departure", "t": 500, "court": 1, "ref": 2},
        {"kind": "restore", "t": 560, "court": 1, "ref": 2},
    ]) + "\n")
    assert main(["evaluate", "--labels", str(labels), "--games", "--events", str(events)]) == 0
    out = capsys.readouterr().out
    assert "suggested timer.threshold_seconds" in out
    assert "recall=1.00" in out
