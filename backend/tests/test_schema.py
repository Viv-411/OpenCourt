import json
import time

import psycopg
import pytest


def payload(site="sim-site", **over):
    p = {
        "version": 1,
        "site_id": site,
        "generated_at": time.time(),
        "health": "ok",
        "queue": {"count": 6.0, "waiting": True},
        "wait": {"next_free_seconds": 120, "wait_seconds": 900, "groups_ahead": 2},
        "courts": [
            {"number": n, "state": "active", "light": "off", "occupancy": 4.0,
             "clock_seconds": 300, "seconds_remaining": 900, "on_court_seconds": 600}
            for n in (1, 2, 3, 4)
        ],
    }
    p.update(over)
    return p


def as_role(conn, role):
    conn.execute(f"set role {role}")


def register(conn, site="sim-site"):
    as_role(conn, "service_role")
    token = conn.execute("select public.register_device(%s, 'pi-1')", (site,)).fetchone()[0]
    conn.execute("reset role")
    return token


def ingest(conn, token, p):
    conn.execute("select public.ingest_status(%s, %s::jsonb)", (token, json.dumps(p)))


def test_device_can_publish_with_anon_role(db):
    token = register(db)
    as_role(db, "anon")
    ingest(db, token, payload())
    row = db.execute("select health, queue_count, wait_seconds, is_stale, court_count "
                     "from public.site_overview where id = 'sim-site'").fetchone()
    assert row == ("ok", 6.0, 900, False, 4)
    states = db.execute("select number, state from public.court_status "
                        "where site_id = 'sim-site' order by number").fetchall()
    assert states == [(1, "active"), (2, "active"), (3, "active"), (4, "active")]


def test_only_token_hash_is_stored(db):
    token = register(db)
    stored = db.execute("select token_hash from public.devices").fetchone()[0]
    assert token.encode() not in bytes(stored)
    assert len(token) >= 32


def test_bad_token_rejected(db):
    register(db)
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.InvalidAuthorizationSpecification):
        ingest(db, "x" * 64, payload())


def test_revoked_token_rejected(db):
    token = register(db)
    as_role(db, "service_role")
    dev = db.execute("select id from public.devices").fetchone()[0]
    db.execute("select public.revoke_device(%s)", (dev,))
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.InvalidAuthorizationSpecification):
        ingest(db, token, payload())


def test_device_cannot_write_another_site(db):
    token = register(db, "sim-site")
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        ingest(db, token, payload(site="rick-drazner", courts=[]))


def test_unknown_court_rejected(db):
    token = register(db)
    p = payload()
    p["courts"].append({**p["courts"][0], "number": 9})
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        ingest(db, token, p)


def test_invalid_state_rejected(db):
    token = register(db)
    p = payload()
    p["courts"][0]["state"] = "cheating"
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.CheckViolation):
        ingest(db, token, p)


def test_wrong_version_rejected(db):
    token = register(db)
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        ingest(db, token, payload(version=2))


def test_anon_cannot_write_tables_directly(db):
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        db.execute("update public.site_status set health = 'ok'")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        db.execute("insert into public.sites (id, name) values ('evil', 'x')")


def test_anon_cannot_see_devices_or_register(db):
    register(db)
    as_role(db, "anon")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        db.execute("select * from public.devices")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        db.execute("select public.register_device('sim-site', 'x')")


def test_staleness(db):
    token = register(db)
    as_role(db, "anon")
    ingest(db, token, payload())
    db.execute("reset role")
    db.execute("update public.site_status set updated_at = now() - interval '5 minutes'")
    as_role(db, "anon")
    stale, age = db.execute("select is_stale, age_seconds from public.site_overview "
                            "where id = 'sim-site'").fetchone()
    assert stale and age >= 299
    # a site that never reported is stale too
    assert db.execute("select is_stale from public.site_overview "
                      "where id = 'sim-site'").fetchone()[0]


def test_history_one_row_per_minute(db):
    token = register(db)
    as_role(db, "anon")
    for _ in range(3):
        ingest(db, token, payload())
    rows = db.execute("select courts from public.status_history").fetchall()
    assert len(rows) == 1
    assert rows[0][0][0] == {"number": 1, "state": "active", "occupancy": 4.0}
    assert "clock_seconds" not in rows[0][0][0]


def test_realtime_publication_includes_status_tables(db):
    tables = {r[0] for r in db.execute(
        "select tablename from pg_publication_tables where pubname = 'supabase_realtime'")}
    assert tables == {"site_status", "court_status"}


def test_rls_enabled_everywhere(db):
    rows = db.execute("select relname, relrowsecurity from pg_class c "
                      "join pg_namespace n on n.oid = c.relnamespace "
                      "where n.nspname = 'public' and c.relkind = 'r'").fetchall()
    assert rows and all(enabled for _, enabled in rows), rows


def test_null_wait_is_allowed(db):
    token = register(db)
    as_role(db, "anon")
    ingest(db, token, payload(health="warming_up",
                              wait={"next_free_seconds": None, "wait_seconds": None,
                                    "groups_ahead": 0}))
    assert db.execute("select wait_seconds from public.site_status").fetchone()[0] is None


def test_real_sensor_payload_is_accepted(db):
    """Contract with sensor/src/opencourt/engine.py (fixture from sensor/tests/test_contract.py)."""
    from pathlib import Path

    fixture = Path(__file__).parent / "fixtures" / "payload_v1.json"
    p = json.loads(fixture.read_text())
    token = register(db)
    as_role(db, "anon")
    ingest(db, token, p)
    n = db.execute("select count(*) from public.court_status").fetchone()[0]
    assert n == len(p["courts"])
