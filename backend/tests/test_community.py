"""Profiles, events, sign-ups and busy times (supabase/migrations/*_community.sql)."""

import datetime as dt
import json
import uuid

import psycopg
import pytest

NOW = dt.datetime.now(dt.timezone.utc)


def make_user(db, email="a@example.com", name=None):
    db.execute("reset role")
    meta = json.dumps({"display_name": name} if name else {})
    return db.execute("insert into auth.users (email, raw_user_meta_data) values (%s, %s) "
                      "returning id", (email, meta)).fetchone()[0]


def act_as(db, user):
    db.execute("reset role")
    if user is None:
        db.execute("select set_config('request.jwt.claim.sub', '', false)")
        db.execute("set role anon")
    else:
        db.execute("select set_config('request.jwt.claim.sub', %s, false)", (str(user),))
        db.execute("set role authenticated")


def post_event(db, **over):
    e = dict(kind="tournament", title="Fall Classic", site_id="rick-drazner",
             starts_at=NOW + dt.timedelta(days=3), capacity=2, format="doubles")
    e.update(over)
    cols = ", ".join(e)
    vals = ", ".join(["%s"] * len(e))
    return db.execute(f"insert into public.events ({cols}) values ({vals}) returning id",
                      list(e.values())).fetchone()[0]


def test_signup_creates_a_profile(db):
    u = make_user(db, "sam@example.com", "Sam")
    v = make_user(db, "lee@example.com")
    act_as(db, u)
    names = dict(db.execute("select id, display_name from public.profiles").fetchall())
    assert names[u] == "Sam" and names[v] == "lee"


def test_google_accounts_use_their_google_name(db):
    db.execute("insert into auth.users (email, raw_user_meta_data) values (%s, %s)",
               ("pat@gmail.com", json.dumps({"full_name": "Pat Rivera", "name": "Pat"})))
    name = db.execute("select display_name from public.profiles p join auth.users u "
                      "on u.id = p.id where u.email = 'pat@gmail.com'").fetchone()[0]
    assert name == "Pat Rivera"


def test_profiles_are_private_to_signed_in_players(db):
    make_user(db)
    act_as(db, None)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        db.execute("select * from public.profiles")


def test_players_edit_only_their_own_profile(db):
    u, v = make_user(db, "u@x.com"), make_user(db, "v@x.com")
    act_as(db, u)
    db.execute("update public.profiles set display_name = 'U2', skill_level = 3.5")
    db.execute("reset role")
    rows = dict(db.execute("select id, display_name from public.profiles").fetchall())
    assert rows[u] == "U2" and rows[v] == "v"


def test_anyone_can_browse_events_but_only_players_post(db):
    u = make_user(db)
    act_as(db, u)
    post_event(db)
    act_as(db, None)
    rows = db.execute("select title, site_name, organizer_name, registered_count "
                      "from public.event_listing").fetchall()
    assert rows == [("Fall Classic", "Rick Drazner Park", "a", 0)]
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        post_event(db)


def test_cannot_post_as_someone_else_or_in_the_past(db):
    u, v = make_user(db, "u@x.com"), make_user(db, "v@x.com")
    act_as(db, u)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        post_event(db, organizer_id=v)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        post_event(db, starts_at=NOW - dt.timedelta(days=1))


def test_event_needs_a_place(db):
    act_as(db, make_user(db))
    with pytest.raises(psycopg.errors.CheckViolation):
        post_event(db, site_id=None)
    post_event(db, site_id=None, location_name="Willow Stream Park")


def test_only_the_organizer_can_edit(db):
    u, v = make_user(db, "u@x.com"), make_user(db, "v@x.com")
    act_as(db, u)
    ev = post_event(db)
    act_as(db, v)
    db.execute("update public.events set title = 'Hijacked' where id = %s", (ev,))
    act_as(db, u)
    assert db.execute("select title from public.events").fetchone()[0] == "Fall Classic"
    db.execute("update public.events set status = 'cancelled' where id = %s", (ev,))


def test_sign_up_respects_capacity_and_is_private(db):
    org, a, b, c = (make_user(db, f"{n}@x.com") for n in "oabc")
    act_as(db, org)
    ev = post_event(db, capacity=2)
    for who in (a, b):
        act_as(db, who)
        db.execute("select public.register_for_event(%s)", (ev,))
        db.execute("select public.register_for_event(%s)", (ev,))  # twice is harmless
    act_as(db, c)
    with pytest.raises(psycopg.errors.RaiseException, match="full"):
        db.execute("select public.register_for_event(%s)", (ev,))
    # counts are public, identities are not
    assert db.execute("select registered_count from public.event_listing").fetchone()[0] == 2
    assert db.execute("select count(*) from public.event_registrations").fetchone()[0] == 0
    act_as(db, a)
    assert db.execute("select count(*) from public.event_registrations").fetchone()[0] == 1
    act_as(db, org)
    assert db.execute("select count(*) from public.event_registrations").fetchone()[0] == 2
    act_as(db, a)
    db.execute("select public.unregister_from_event(%s)", (ev,))
    act_as(db, c)
    db.execute("select public.register_for_event(%s)", (ev,))  # a spot opened up


def test_sign_up_rules(db):
    org, a = make_user(db, "o@x.com"), make_user(db, "a@x.com")
    act_as(db, org)
    ev = post_event(db)
    db.execute("update public.events set status = 'cancelled' where id = %s", (ev,))
    act_as(db, a)
    with pytest.raises(psycopg.errors.RaiseException, match="cancelled"):
        db.execute("select public.register_for_event(%s)", (ev,))
    with pytest.raises(psycopg.errors.NoDataFound):
        db.execute("select public.register_for_event(%s)", (uuid.uuid4(),))
    act_as(db, None)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        db.execute("select public.register_for_event(%s)", (ev,))


def test_busy_hours_from_history(db):
    db.execute("reset role")
    for minutes in range(0, 60, 10):
        db.execute(
            "insert into public.status_history (site_id, bucket, health, queue_count, courts) "
            "values ('rick-drazner', date_trunc('hour', now()) - interval '1 day' + %s * interval '1 minute', "
            "'ok', 4, %s)",
            (minutes, json.dumps([{"number": 1, "state": "active", "occupancy": 4},
                                  {"number": 2, "state": "empty", "occupancy": 0}])))
    act_as(db, None)
    row = db.execute("select avg_waiting, courts_in_use, samples from public.site_busy_hours "
                     "where site_id = 'rick-drazner'").fetchone()
    assert (float(row[0]), float(row[1]), row[2]) == (4.0, 0.5, 6)


def test_rls_on_every_new_table(db):
    rows = dict(db.execute(
        "select relname, relrowsecurity from pg_class c join pg_namespace n "
        "on n.oid = c.relnamespace where n.nspname = 'public' and relname in "
        "('profiles', 'events', 'event_registrations')").fetchall())
    assert rows == {"profiles": True, "events": True, "event_registrations": True}
