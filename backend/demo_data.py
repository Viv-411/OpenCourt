"""Sample data for demo videos: parks across the area, events, players, and live status.

    scripts/demo-data.sh seed    # load everything (only adds; safe to run again)
    scripts/demo-data.sh live    # keep every park "live" while you record (Ctrl+C to stop)
    scripts/demo-data.sh clear   # remove all of it and put the test parks back

NOTHING HERE IS REAL DATA. The parks are real places with outdoor pickleball (so the map
looks right), but every count, wait, light, event and player is invented. Say "sample data"
when you show it.

What it touches, so `clear` can undo all of it:
  * parks: new rows with ids starting `demo-`; the two test parks are shown under real names
    while the demo is loaded (sim-site as Green Slopes Park, demo-clip as Volz Park);
  * status and eight weeks of history for every park, the two pilot parks included (neither
    has a real sensor yet, so there is nothing real to lose);
  * players: accounts with `demo+...@example.com` addresses, which nobody can sign in to;
  * events: fixed ids (below), some organised by the real "Vivek Bharadwaj" account, which
    also gets sign-ups so its "You" tab looks lived in;
  * a publishing key for Rick Drazner Park, so `scripts/demo-clip.sh --rick-drazner` can play
    the recorded clip under the park it was filmed at.

Needs the database password in OPENCOURT_DB_PASSWORD (or it asks). Never stored.
"""

from __future__ import annotations

import datetime as dt
import getpass
import json
import math
import os
import random
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import ZoneInfo

import psycopg

PROJECT = "inkvqajxepcaqjubhfye"
TZ = ZoneInfo("America/Chicago")
NS = uuid.uuid5(uuid.NAMESPACE_URL, "https://github.com/Viv-411/OpenCourt/demo")
ENV_FILE = Path(__file__).resolve().parents[1] / "sensor" / ".env"
RD_DEVICE = "demo: recorded clip as Rick Drazner"
RD_TOKEN_VAR = "OPENCOURT_RICK_DRAZNER_DEMO_TOKEN"

# id, name shown, town, latitude, longitude, courts, how busy (0-1). Court counts and
# coordinates are the real parks' (pickleheads.com / OpenStreetMap, looked up 2026-10-12).
PARKS = [
    ("mike-rylko", "Mike Rylko Community Park", "Buffalo Grove", 42.16828, -87.96814, 8, 0.95),
    ("rick-drazner", "Rick Drazner Park", "Buffalo Grove", 42.15900, -87.95900, 2, 0.55),
    ("sim-site", "Green Slopes Park", "Arlington Heights", 42.10142, -87.97680, 4, 0.70),
    ("demo-clip", "Volz Park", "Arlington Heights", 42.08586, -87.99504, 2, 0.25),
    ("demo-chamber-park", "Chamber Park", "Wheeling", 42.14277, -87.91450, 6, 0.80),
    ("demo-dryden-park", "Dryden Park", "Arlington Heights", 42.06952, -87.97192, 6, 0.60),
    ("demo-wood-oaks-green", "Wood Oaks Green Park", "Northbrook", 42.13034, -87.88338, 3, 0.35),
    ("demo-stonegate-park", "Stonegate Park", "Northbrook", 42.10916, -87.86646, 6, 0.90),
    ("demo-hamilton-park", "Hamilton Park", "Palatine", 42.13014, -88.04612, 6, 0.50),
    ("demo-locust-park", "Locust Park", "Palatine", 42.11834, -88.02687, 2, 0.15),
]
# What the two test parks go back to on `clear`.
TEST_PARKS = {
    "sim-site": ("Simulator", None, 42.1520, -87.9600),
    "demo-clip": ("OpenCourt Demo", None, 42.1555, -87.9700),
}

# Invented players and clubs. (name, skill or None, home park id or None)
PLAYERS = [
    ("Northwest Picklers Club", None, "mike-rylko"), ("Coach Dana", 5.0, "demo-stonegate-park"),
    ("Dink & Drive League", None, "demo-chamber-park"), ("Priya S.", 3.5, "mike-rylko"),
    ("Marcus T.", 4.0, "mike-rylko"), ("Elena R.", 3.0, "rick-drazner"),
    ("Tom B.", 3.5, "demo-chamber-park"), ("Aisha K.", 4.5, "demo-stonegate-park"),
    ("Dev P.", 3.0, "sim-site"), ("Hannah L.", 2.5, "demo-hamilton-park"),
    ("Jorge M.", 4.0, "demo-dryden-park"), ("Mei C.", 3.5, "mike-rylko"),
    ("Sam O.", 3.0, "demo-locust-park"), ("Rachel G.", 3.5, "demo-wood-oaks-green"),
    ("Kofi A.", 4.5, "mike-rylko"), ("Lena W.", 2.5, "rick-drazner"),
    ("Arjun N.", 3.5, "demo-chamber-park"), ("Beth H.", 3.0, "demo-dryden-park"),
    ("Chris D.", 4.0, "demo-stonegate-park"), ("Nora F.", 3.5, "sim-site"),
    ("Omar Z.", 3.0, "demo-hamilton-park"), ("Grace Y.", 4.0, "mike-rylko"),
    ("Ben J.", 2.5, "demo-clip"), ("Tara V.", 3.5, "demo-chamber-park"),
    ("Luis E.", 4.5, "demo-stonegate-park"), ("Ivy Q.", 3.0, "mike-rylko"),
    ("Pete X.", 3.5, "demo-dryden-park"), ("Zoe U.", 4.0, "sim-site"),
    ("Raj I.", 3.0, "rick-drazner"), ("Kim S.", 3.5, "demo-hamilton-park"),
    ("Alex M.", 4.0, "mike-rylko"), ("Dana T.", 3.0, "demo-wood-oaks-green"),
]

# organiser (a PLAYERS name, or "ME" for the real Vivek Bharadwaj account), kind, title,
# description, park id, days from today, start hour, length in hours, format, skill min,
# skill max, capacity, fee in cents, courts reserved, how full (0-1), is ME going
EVENTS = [
    ("Northwest Picklers Club", "open_play", "Tuesday Night Open Play",
     "Drop in, put your paddle in the stack, and play. All levels welcome; games to 11, "
     "rotate after each game.", "mike-rylko", 1, 18, 3, "any", None, None, None, 0, False, 0.0,
     True),
    ("Northwest Picklers Club", "tournament", "Fall Classic Doubles",
     "Round-robin pools into single-elimination brackets. Bring a partner. Courts reserved "
     "with a park district permit; balls and water provided.", "mike-rylko", 12, 8, 7,
     "doubles", 3.0, 4.0, 32, 2500, True, 0.81, True),
    ("Coach Dana", "clinic", "Beginner Clinic: Dinks & Resets",
     "An hour on the soft game, then supervised play. Paddles available to borrow.",
     "demo-stonegate-park", 3, 10, 1.5, "any", None, 3.0, 8, 1000, True, 1.0, False),
    ("Coach Dana", "clinic", "Third-Shot Drop Workshop",
     "For 3.0-4.0 players who want a reliable drop. Small group, lots of reps.",
     "demo-stonegate-park", 8, 9, 2, "doubles", 3.0, 4.0, 12, 1500, True, 0.58, True),
    ("Dink & Drive League", "league", "Thursday Mixed Doubles League (Week 4)",
     "Six-week ladder league. Subs welcome: message the organiser if you can fill in.",
     "demo-chamber-park", 2, 18, 2.5, "mixed", 3.0, 4.5, 24, 0, True, 0.92, False),
    ("Dink & Drive League", "league", "Sunday Singles Ladder",
     "Challenge matches up and down the ladder. Results posted the same evening.",
     "demo-chamber-park", 5, 9, 3, "singles", 3.5, None, 16, 500, False, 0.69, False),
    ("ME", "open_play", "Saturday Morning Doubles at Rylko",
     "Informal doubles, 3.0-4.0. Four on, four off when it gets busy. I'll bring extra balls.",
     "mike-rylko", 4, 8, 3, "doubles", 3.0, 4.0, 16, 0, False, 0.75, True),
    ("ME", "social", "Rick Drazner Round Robin & Donuts",
     "Low-key round robin on both courts, partners rotate every game. Donuts on me.",
     "rick-drazner", 10, 9, 2, "doubles", None, None, 12, 0, False, 0.42, True),
    ("Marcus T.", "open_play", "Lunch Break Open Play",
     "Weekday lunch crowd. Quick games to 9 so everyone gets on.",
     "sim-site", 1, 12, 1.5, "any", None, None, None, 0, False, 0.0, False),
    ("Aisha K.", "tournament", "Stonegate 4.0+ Shootout",
     "Fast format, games to 15. Cash prizes for the top two teams.",
     "demo-stonegate-park", 17, 9, 6, "doubles", 4.0, None, 24, 4000, True, 0.5, False),
    ("Hannah L.", "social", "Glow Pickleball Night",
     "LED balls, music, snacks. Mixed doubles, partners rotate every game.",
     "demo-hamilton-park", 6, 19, 3, "mixed", None, None, 24, 500, False, 0.96, True),
    ("Jorge M.", "open_play", "Dryden Early Birds",
     "6:30 start, done by 8. Coffee after at the corner.",
     "demo-dryden-park", 2, 6.5, 1.5, "doubles", 3.0, None, None, 0, False, 0.0, False),
    ("Rachel G.", "clinic", "Kids & Parents Intro Clinic",
     "Ages 8 and up with a parent. Rules, scoring, and plenty of rallies.",
     "demo-wood-oaks-green", 11, 10, 1.5, "any", None, 2.5, 12, 0, True, 0.33, False),
    ("Northwest Picklers Club", "tournament", "Halloween Costume Scramble",
     "Blind-draw partners, costumes encouraged, prizes for best dressed. All levels.",
     "mike-rylko", 19, 13, 4, "doubles", None, None, 40, 1000, True, 0.65, False),
    ("Tom B.", "social", "New Players Meet-Up",
     "Just moved here or just starting? Come hit, meet people, and find regular partners.",
     "demo-locust-park", 7, 17.5, 1.5, "any", None, 3.0, 10, 0, False, 0.2, False),
]


def uid(kind: str, key: str) -> uuid.UUID:
    return uuid.uuid5(NS, f"{kind}:{key}")


def slug(name: str) -> str:
    return "".join(ch if ch.isalnum() else "-" for ch in name.lower()).strip("-")


def connect() -> psycopg.Connection:
    password = os.environ.get("OPENCOURT_DB_PASSWORD") or getpass.getpass("Database password: ")
    return psycopg.connect(
        f"postgresql://postgres.{PROJECT}:{password}@aws-0-us-west-2.pooler.supabase.com:5432/"
        "postgres?sslmode=require", autocommit=False)


def me(c: psycopg.Connection) -> uuid.UUID | None:
    row = c.execute("select id from public.profiles where display_name = 'Vivek Bharadwaj' "
                    "order by created_at limit 1").fetchone()
    return row[0] if row else None


# -- seed -----------------------------------------------------------------------------------


def seed(c: psycopg.Connection) -> None:
    for pid, name, town, lat, lon, courts, _ in PARKS:
        c.execute(
            "insert into public.sites (id, name, address, latitude, longitude, timezone) "
            "values (%s, %s, %s, %s, %s, 'America/Chicago') on conflict (id) do update set "
            "name = excluded.name, address = excluded.address, latitude = excluded.latitude, "
            "longitude = excluded.longitude where public.sites.id = any(%s)",  # pilot parks: as is
            (pid, name, f"{town}, IL", lat, lon, list(TEST_PARKS)))
        c.execute("insert into public.courts (site_id, number, label) select %s, n, "
                  "'Court ' || n from generate_series(1, %s) n on conflict do nothing",
                  (pid, courts))
    print(f"parks: {len(PARKS)}")

    for name, skill, home in PLAYERS:
        c.execute(
            "insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, "
            "raw_user_meta_data, created_at, updated_at) values (%s, "
            "'00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', %s, "
            "now(), %s, now(), now()) on conflict (id) do nothing",
            (uid("user", name), f"demo+{slug(name)}@example.com",
             json.dumps({"display_name": name})))
        c.execute("update public.profiles set display_name = %s, skill_level = %s, "
                  "home_site = %s where id = %s", (name, skill, home, uid("user", name)))
    print(f"players: {len(PLAYERS)} (demo+...@example.com; nobody can sign in to them)")

    mine = me(c)
    if mine is None:
        print("note: no 'Vivek Bharadwaj' account found; his events use a demo organiser")
    rng = random.Random(7)
    today = dt.datetime.now(TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    crowd = [uid("user", p[0]) for p in PLAYERS if p[1] is not None]
    for (org, kind, title, desc, park, days, hour, hours, fmt, smin, smax, cap, fee,
         reserved, full, going) in EVENTS:
        eid = uid("event", title)
        organizer = (mine or uid("user", PLAYERS[0][0])) if org == "ME" else uid("user", org)
        start = today + dt.timedelta(days=days, hours=hour)
        c.execute(
            "insert into public.events (id, organizer_id, kind, title, description, site_id, "
            "starts_at, ends_at, format, skill_min, skill_max, capacity, fee_cents, "
            "courts_reserved, status) values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"
            "'scheduled') on conflict (id) do update set starts_at = excluded.starts_at, "
            "ends_at = excluded.ends_at, status = 'scheduled'",
            (eid, organizer, kind, title, desc, park, start, start + dt.timedelta(hours=hours),
             fmt, smin, smax, cap, fee, reserved))
        want = round((cap or 22) * full) if cap else rng.randint(6, 18)
        signed = rng.sample(crowd, min(want, len(crowd)))
        if going and mine is not None:
            signed = signed[:max(0, want - 1)] + [mine]
        for user in dict.fromkeys(signed):
            c.execute("insert into public.event_registrations (event_id, user_id) values "
                      "(%s, %s) on conflict do nothing", (eid, user))
    print(f"events: {len(EVENTS)}")

    # Eight weeks of history so every park's "Busy times" chart is full: quiet mornings, a
    # weekday after-work peak, a weekend morning peak, scaled by how busy the park is.
    for pid, _, _, _, _, courts, busy in PARKS:
        c.execute(
            """
            insert into public.status_history (site_id, bucket, health, queue_count,
                                               wait_seconds, courts)
            select %(site)s, b, 'ok', q, (q * 150)::int,
                   (select jsonb_agg(jsonb_build_object(
                        'number', n, 'occupancy', 4,
                        'state', case when random() < least(1, q / 5 + 0.25) then 'idle'
                                      else 'empty' end) order by n)
                    from generate_series(1, %(courts)s) n)
            from (
                select b, greatest(0, round((%(busy)s * (0.7 + random() * 0.6) * (
                           7 * exp(-power(h - 18.5, 2) / 4)
                           + (case when dow >= 6 then 8 else 2.5 end) * exp(-power(h - 9.5, 2) / 3)
                       ))::numeric, 1))::real as q
                from generate_series(date_trunc('hour', now()) - interval '8 weeks',
                                     now() - interval '15 minutes', interval '15 minutes') b
                cross join lateral (
                    select extract(hour from b at time zone 'America/Chicago')
                               + extract(minute from b at time zone 'America/Chicago') / 60 as h,
                           extract(isodow from b at time zone 'America/Chicago') as dow) t
                where h between 6 and 22
            ) x
            on conflict (site_id, bucket) do nothing
            """, {"site": pid, "courts": courts, "busy": busy})
    print("history: eight weeks for every park")

    row = c.execute("select 1 from public.devices where site_id = 'rick-drazner' and name = %s "
                    "and revoked_at is null", (RD_DEVICE,)).fetchone()
    if row is None:
        token = c.execute("select public.register_device('rick-drazner', %s)",
                          (RD_DEVICE,)).fetchone()[0]
        lines = [ln for ln in ENV_FILE.read_text().splitlines()
                 if not ln.startswith(RD_TOKEN_VAR + "=")] if ENV_FILE.exists() else []
        ENV_FILE.write_text("\n".join([*lines, f"{RD_TOKEN_VAR}={token}"]) + "\n")
        print("clip key: issued for Rick Drazner Park, saved to sensor/.env")
    c.commit()
    write_status(c, {p[0]: Park.start(p) for p in PARKS})
    c.commit()
    print("\nLoaded. Parks stay 'live' only while this runs:  scripts/demo-data.sh live")


# -- clear ----------------------------------------------------------------------------------


def clear(c: psycopg.Connection) -> None:
    ids = [uid("event", e[2]) for e in EVENTS]
    c.execute("delete from public.events where id = any(%s)", (ids,))
    c.execute("delete from auth.users where email like 'demo+%%@example.com'")
    c.execute("delete from public.sites where id like 'demo-%%' and id <> 'demo-clip'")
    for pid, (name, address, lat, lon) in TEST_PARKS.items():
        c.execute("update public.sites set name = %s, address = %s, latitude = %s, "
                  "longitude = %s where id = %s", (name, address, lat, lon, pid))
    kept = ["mike-rylko", "rick-drazner", "sim-site", "demo-clip"]
    for table in ("status_history", "court_status", "site_status"):
        c.execute(f"delete from public.{table} where site_id = any(%s)", (kept,))  # noqa: S608
    c.execute("delete from public.devices where name = %s", (RD_DEVICE,))
    if ENV_FILE.exists():
        ENV_FILE.write_text("\n".join(
            ln for ln in ENV_FILE.read_text().splitlines()
            if not ln.startswith(RD_TOKEN_VAR + "=")) + "\n")
    c.commit()
    print("Cleared: demo parks, players, events, status and history are gone; "
          "'Simulator' and 'OpenCourt Demo' are back.")


# -- live -----------------------------------------------------------------------------------

THRESHOLD, WARNING, GAME = 1200.0, 120.0, 900.0


@dataclass
class Court:
    players: int = 0  # 0 = nobody on it
    on_since: float = 0.0
    held: float = 0.0  # seconds this group has played while others were held up
    game: float = GAME
    lingers: bool = False  # the occasional group that plays on past its time
    changing_until: float = 0.0


@dataclass
class Park:
    id: str
    busy: float
    courts: list[Court]
    queue: int = 0
    rng: random.Random = field(default_factory=random.Random)
    written_at: object = None

    @classmethod
    def start(cls, spec: tuple, now: float | None = None) -> Park:
        """A park already mid-session, so the first look isn't ten parks all just opening."""
        pid, _, _, _, _, n, busy = spec
        now = now or time.time()
        rng = random.Random(pid)
        courts = []
        for _ in range(n):
            if rng.random() < 0.25 + busy * 0.8:
                courts.append(Court(players=4 if rng.random() < 0.85 else 2,
                                    on_since=now - rng.uniform(60, 17 * 60),
                                    game=rng.uniform(12, 19) * 60, lingers=rng.random() < 0.3))
            else:
                courts.append(Court())
        park = cls(pid, busy, courts, rng=rng)
        if all(c.players for c in courts):
            park.queue = int(busy * rng.uniform(2, 11))
            for c in courts:  # they've had people waiting for part of their game
                c.held = rng.uniform(0.2, 0.9) * (now - c.on_since) if park.queue else 0
            if busy > 0.85 and len(courts) >= 6 and park.queue:  # show the lights working
                courts[-1].lingers, courts[-1].on_since, courts[-1].held = True, now - 1500, 1290
                courts[-2].lingers, courts[-2].on_since, courts[-2].held = True, now - 1200, 1000
        return park

    def step(self, now: float, dt_s: float) -> None:
        rng = self.rng
        # Parties arrive a little faster than a busy park's courts turn over, so busy parks
        # hold a line and quiet ones mostly don't.
        if rng.random() < self.busy * len(self.courts) * dt_s / 480:
            self.queue = min(3 * len(self.courts) + 2, self.queue + rng.choice([1, 2, 2, 4, 4]))
        elif self.queue and rng.random() < dt_s / 600:
            self.queue -= 1  # someone gives up
        full = all(c.players for c in self.courts)
        for c in self.courts:
            if not c.players:
                arriving = self.queue >= 2 or rng.random() < self.busy * dt_s / 240
                if arriving and now >= c.changing_until:
                    take = min(4, self.queue) if self.queue >= 2 else rng.choice([2, 4, 4])
                    self.queue = max(0, self.queue - take)
                    c.players, c.on_since, c.held = take, now, 0.0
                    c.game, c.lingers = rng.uniform(12, 19) * 60, rng.random() < 0.3
                continue
            if self.queue and full:
                c.held += dt_s
            played = now - c.on_since
            done = played > c.game and (not c.lingers or c.held > THRESHOLD + 420)
            if done and (self.queue or rng.random() < dt_s / 200):
                c.players, c.changing_until = 0, now + rng.uniform(10, 25)
            elif played > c.game and not self.queue and rng.random() < dt_s / 400:
                c.game += rng.uniform(10, 15) * 60  # nobody waiting: another game

    def snapshot(self, now: float) -> tuple[dict, list[dict]]:
        full = all(c.players for c in self.courts)
        waiting = self.queue > 0
        rows, remaining = [], []
        for i, c in enumerate(self.courts, start=1):
            if not c.players:
                changing = waiting and now < c.changing_until
                rows.append({"number": i, "state": "rotating" if changing else "empty",
                             "light": "off", "occupancy": 0, "clock": None, "remaining": None,
                             "on_court": None})
                continue
            played = now - c.on_since
            remaining.append(max(60.0, GAME - played) if played < GAME else 180.0)
            state, light, clock, left = "idle", "off", None, None
            if waiting:
                clock, left = c.held, max(0.0, THRESHOLD - c.held)
                if not full:
                    state = "active"  # a court is open: nobody is held up, so no light
                elif left <= 0:
                    state, light = "due", "solid"
                elif left <= WARNING:
                    state, light = "warning", "pulse"
                else:
                    state = "active"
            rows.append({"number": i, "state": state, "light": light, "occupancy": c.players,
                         "clock": clock, "remaining": left, "on_court": played})
        if not full:
            wait = next_free = 0.0
            ahead = 0
        else:
            remaining.sort()
            ahead = math.ceil(self.queue / 4)
            next_free = remaining[0]
            wait = (remaining[ahead] if ahead < len(remaining)
                    else remaining[-1] + GAME * (ahead // len(remaining)))
        site = {"queue": self.queue, "waiting": waiting, "wait": wait, "next_free": next_free,
                "ahead": ahead}
        return site, rows


def write_status(c: psycopg.Connection, parks: dict[str, Park]) -> None:
    now = time.time()
    for park in parks.values():
        seen = c.execute("select updated_at from public.site_status where site_id = %s",
                         (park.id,)).fetchone()
        # Someone else is publishing here (the recorded clip, the simulator): leave it alone
        # until they've been quiet for half a minute.
        if (seen and park.written_at is not None and seen[0] != park.written_at
                and (dt.datetime.now(dt.UTC) - seen[0]).total_seconds() < 30):
            continue
        site, rows = park.snapshot(now)
        park.written_at = c.execute(
            "insert into public.site_status as s (site_id, health, queue_count, queue_waiting, "
            "wait_seconds, next_free_seconds, groups_ahead, generated_at, updated_at) values "
            "(%s, 'ok', %s, %s, %s, %s, %s, now(), now()) on conflict (site_id) do update set "
            "health = 'ok', queue_count = excluded.queue_count, queue_waiting = "
            "excluded.queue_waiting, wait_seconds = excluded.wait_seconds, next_free_seconds = "
            "excluded.next_free_seconds, groups_ahead = excluded.groups_ahead, generated_at = "
            "now(), updated_at = now() returning updated_at",
            (park.id, site["queue"], site["waiting"], int(site["wait"]), int(site["next_free"]),
             site["ahead"])).fetchone()[0]
        for r in rows:
            c.execute(
                "insert into public.court_status (site_id, number, state, light, occupancy, "
                "clock_seconds, seconds_remaining, on_court_seconds, moved_from, updated_at) "
                "values (%s,%s,%s,%s,%s,%s,%s,%s,null,now()) on conflict (site_id, number) do "
                "update set state = excluded.state, light = excluded.light, occupancy = "
                "excluded.occupancy, clock_seconds = excluded.clock_seconds, seconds_remaining "
                "= excluded.seconds_remaining, on_court_seconds = excluded.on_court_seconds, "
                "moved_from = null, updated_at = now()",
                (park.id, r["number"], r["state"], r["light"], r["occupancy"],
                 None if r["clock"] is None else int(r["clock"]),
                 None if r["remaining"] is None else int(r["remaining"]),
                 None if r["on_court"] is None else int(r["on_court"])))
        c.execute(
            "insert into public.status_history (site_id, bucket, health, queue_count, "
            "wait_seconds, courts) values (%s, date_trunc('minute', now()), 'ok', %s, %s, %s) "
            "on conflict (site_id, bucket) do nothing",
            (park.id, site["queue"], int(site["wait"]),
             json.dumps([{"number": r["number"], "state": r["state"],
                          "occupancy": r["occupancy"]} for r in rows])))


def live(c: psycopg.Connection, every: float = 10.0) -> None:
    parks = {p[0]: Park.start(p) for p in PARKS}
    print(f"Keeping {len(parks)} parks live (sample data). Ctrl+C to stop.")
    last = time.time()
    try:
        while True:
            now = time.time()
            for park in parks.values():
                park.step(now, now - last)
            last = now
            write_status(c, parks)
            c.commit()
            busy = sum(p.queue for p in parks.values())
            lit = sum(r["light"] != "off" for p in parks.values() for r in p.snapshot(now)[1])
            print(f"  {dt.datetime.now():%H:%M:%S}  {busy} people in lines, {lit} lights on",
                  flush=True)
            time.sleep(max(1.0, every - (time.time() - now)))
    except KeyboardInterrupt:
        print("\nStopped. Parks will read 'offline' in about a minute.")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command not in ("seed", "live", "clear"):
        raise SystemExit(__doc__)
    with connect() as conn:
        {"seed": seed, "live": live, "clear": clear}[command](conn)
