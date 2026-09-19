-- OpenCourt: one-shot setup for a fresh Supabase project (all migrations + seed).
-- Generated from supabase/migrations/*.sql and supabase/seed.sql; do not edit by hand.
begin;
-- OpenCourt backend schema (docs/PLAN.md §9).
--
-- Security model:
--   * Row level security is on for every table.
--   * The anon/authenticated roles can only READ public status.
--   * Sensors never hold the service-role key. They call ingest_status() with the anon key
--     plus a per-device token; only the token's SHA-256 is stored.
--   * Nothing here stores images, identities, or per-person data: counts and states only.

-- ---------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------

create table public.sites (
    id          text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    name        text not null,
    address     text,
    latitude    double precision check (latitude between -90 and 90),
    longitude   double precision check (longitude between -180 and 180),
    timezone    text not null default 'America/Chicago',
    stale_after_seconds integer not null default 60 check (stale_after_seconds > 0),
    created_at  timestamptz not null default now()
);
comment on table public.sites is 'A bank of courts watched by one sensor.';

create table public.courts (
    site_id     text not null references public.sites (id) on delete cascade,
    number      smallint not null check (number between 1 and 32),
    label       text,
    primary key (site_id, number)
);
comment on column public.courts.number is 'Numbered from the queue: 1 is the entry court.';

create table public.devices (
    id          uuid primary key default gen_random_uuid(),
    site_id     text not null references public.sites (id) on delete cascade,
    name        text not null,
    token_hash  bytea not null unique,
    created_at  timestamptz not null default now(),
    last_seen_at timestamptz,
    revoked_at  timestamptz
);
comment on table public.devices is 'Sensors allowed to publish. Only token hashes are stored.';

create table public.site_status (
    site_id           text primary key references public.sites (id) on delete cascade,
    health            text not null check (health in ('warming_up', 'ok', 'degraded')),
    queue_count       real not null check (queue_count >= 0),
    queue_waiting     boolean not null,
    wait_seconds      integer check (wait_seconds >= 0),
    next_free_seconds integer check (next_free_seconds >= 0),
    groups_ahead      integer not null default 0 check (groups_ahead >= 0),
    generated_at      timestamptz not null,
    updated_at        timestamptz not null default now()
);

create table public.court_status (
    site_id           text not null,
    number            smallint not null,
    state             text not null check (state in
                        ('unknown', 'empty', 'rotating', 'idle', 'active', 'warning', 'due')),
    light             text not null check (light in ('off', 'pulse', 'solid')),
    occupancy         real not null check (occupancy >= 0),
    clock_seconds     integer check (clock_seconds >= 0),
    seconds_remaining integer check (seconds_remaining >= 0),
    on_court_seconds  integer check (on_court_seconds >= 0),
    updated_at        timestamptz not null default now(),
    primary key (site_id, number),
    foreign key (site_id, number) references public.courts (site_id, number) on delete cascade
);

-- One row per site per minute. Counts and states only.
create table public.status_history (
    site_id      text not null references public.sites (id) on delete cascade,
    bucket       timestamptz not null,
    health       text not null,
    queue_count  real not null,
    wait_seconds integer,
    courts       jsonb not null,  -- [{number, state, occupancy}]
    primary key (site_id, bucket)
);

-- ---------------------------------------------------------------------------------------
-- Row level security: public read of status, nothing else.
-- ---------------------------------------------------------------------------------------

alter table public.sites          enable row level security;
alter table public.courts         enable row level security;
alter table public.devices        enable row level security;
alter table public.site_status    enable row level security;
alter table public.court_status   enable row level security;
alter table public.status_history enable row level security;

create policy "public read" on public.sites          for select to anon, authenticated using (true);
create policy "public read" on public.courts         for select to anon, authenticated using (true);
create policy "public read" on public.site_status    for select to anon, authenticated using (true);
create policy "public read" on public.court_status   for select to anon, authenticated using (true);
create policy "public read" on public.status_history for select to anon, authenticated using (true);
-- devices: no policies => no access except service_role.

revoke all on public.devices from anon, authenticated;
revoke insert, update, delete on public.sites, public.courts, public.site_status,
    public.court_status, public.status_history from anon, authenticated;
grant select on public.sites, public.courts, public.site_status, public.court_status,
    public.status_history to anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Read model for clients: one row per site with staleness computed on the server clock.
-- ---------------------------------------------------------------------------------------

create view public.site_overview
with (security_invoker = true) as
select
    s.id,
    s.name,
    s.address,
    s.latitude,
    s.longitude,
    s.timezone,
    (select count(*) from public.courts c where c.site_id = s.id)::int as court_count,
    st.health,
    st.queue_count,
    st.queue_waiting,
    st.wait_seconds,
    st.next_free_seconds,
    st.groups_ahead,
    st.updated_at,
    extract(epoch from (now() - st.updated_at))::int as age_seconds,
    (st.updated_at is null
        or now() - st.updated_at > make_interval(secs => s.stale_after_seconds)) as is_stale
from public.sites s
left join public.site_status st on st.site_id = s.id;

grant select on public.site_overview to anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Device ingest
-- ---------------------------------------------------------------------------------------

create function public.ingest_status(p_token text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_device  public.devices%rowtype;
    v_site    text;
    v_court   jsonb;
    v_number  smallint;
    v_known   int;
begin
    if p_token is null or length(p_token) < 32 then
        raise exception 'invalid device token' using errcode = '28000';
    end if;

    select * into v_device
    from public.devices
    where token_hash = sha256(convert_to(p_token, 'UTF8'))
      and revoked_at is null;
    if not found then
        raise exception 'invalid device token' using errcode = '28000';
    end if;
    v_site := v_device.site_id;

    if coalesce((p_payload ->> 'version')::int, 0) <> 1 then
        raise exception 'unsupported payload version %', p_payload ->> 'version'
            using errcode = '22023';
    end if;
    if p_payload ->> 'site_id' is distinct from v_site then
        raise exception 'payload site % does not match device site %',
            p_payload ->> 'site_id', v_site using errcode = '42501';
    end if;
    if jsonb_typeof(p_payload -> 'courts') <> 'array' then
        raise exception 'courts must be an array' using errcode = '22023';
    end if;

    insert into public.site_status as s (
        site_id, health, queue_count, queue_waiting, wait_seconds, next_free_seconds,
        groups_ahead, generated_at, updated_at
    ) values (
        v_site,
        p_payload ->> 'health',
        greatest(0, (p_payload #>> '{queue,count}')::real),
        coalesce((p_payload #>> '{queue,waiting}')::boolean, false),
        (p_payload #>> '{wait,wait_seconds}')::int,
        (p_payload #>> '{wait,next_free_seconds}')::int,
        coalesce((p_payload #>> '{wait,groups_ahead}')::int, 0),
        to_timestamp((p_payload ->> 'generated_at')::double precision),
        now()
    )
    on conflict (site_id) do update set
        health = excluded.health,
        queue_count = excluded.queue_count,
        queue_waiting = excluded.queue_waiting,
        wait_seconds = excluded.wait_seconds,
        next_free_seconds = excluded.next_free_seconds,
        groups_ahead = excluded.groups_ahead,
        generated_at = excluded.generated_at,
        updated_at = excluded.updated_at;

    for v_court in select * from jsonb_array_elements(p_payload -> 'courts') loop
        v_number := (v_court ->> 'number')::smallint;
        select count(*) into v_known
        from public.courts where site_id = v_site and number = v_number;
        if v_known = 0 then
            raise exception 'unknown court % for site %', v_number, v_site
                using errcode = '23503';
        end if;

        insert into public.court_status as c (
            site_id, number, state, light, occupancy, clock_seconds, seconds_remaining,
            on_court_seconds, updated_at
        ) values (
            v_site,
            v_number,
            v_court ->> 'state',
            v_court ->> 'light',
            greatest(0, (v_court ->> 'occupancy')::real),
            (v_court ->> 'clock_seconds')::int,
            (v_court ->> 'seconds_remaining')::int,
            (v_court ->> 'on_court_seconds')::int,
            now()
        )
        on conflict (site_id, number) do update set
            state = excluded.state,
            light = excluded.light,
            occupancy = excluded.occupancy,
            clock_seconds = excluded.clock_seconds,
            seconds_remaining = excluded.seconds_remaining,
            on_court_seconds = excluded.on_court_seconds,
            updated_at = excluded.updated_at
        -- Skip no-op writes so Realtime only fires on real changes.
        where (c.state, c.light, c.occupancy, c.clock_seconds is null)
            is distinct from (excluded.state, excluded.light, excluded.occupancy,
                              excluded.clock_seconds is null)
           or now() - c.updated_at > interval '30 seconds';
    end loop;

    insert into public.status_history (site_id, bucket, health, queue_count, wait_seconds, courts)
    values (
        v_site,
        date_trunc('minute', now()),
        p_payload ->> 'health',
        greatest(0, (p_payload #>> '{queue,count}')::real),
        (p_payload #>> '{wait,wait_seconds}')::int,
        (
            select coalesce(jsonb_agg(jsonb_build_object(
                'number', (c ->> 'number')::int,
                'state', c ->> 'state',
                'occupancy', (c ->> 'occupancy')::real
            ) order by (c ->> 'number')::int), '[]'::jsonb)
            from jsonb_array_elements(p_payload -> 'courts') as c
        )
    )
    on conflict (site_id, bucket) do nothing;

    update public.devices set last_seen_at = now() where id = v_device.id;
end;
$$;

revoke all on function public.ingest_status(text, jsonb) from public;
grant execute on function public.ingest_status(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Admin helpers (service_role / SQL editor only)
-- ---------------------------------------------------------------------------------------

-- Returns the plaintext token ONCE. Store it on the device in /etc/opencourt.env.
create function public.register_device(p_site text, p_name text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_token text := replace(gen_random_uuid()::text, '-', '')
                 || replace(gen_random_uuid()::text, '-', '');
begin
    insert into public.devices (site_id, name, token_hash)
    values (p_site, p_name, sha256(convert_to(v_token, 'UTF8')));
    return v_token;
end;
$$;

create function public.revoke_device(p_device uuid)
returns void
language sql
security definer
set search_path = ''
as $$
    update public.devices set revoked_at = now() where id = p_device and revoked_at is null;
$$;

create function public.prune_history(p_keep_days int default 90)
returns bigint
language sql
security definer
set search_path = ''
as $$
    with gone as (
        delete from public.status_history
        where bucket < now() - make_interval(days => p_keep_days)
        returning 1
    )
    select count(*) from gone;
$$;

revoke all on function public.register_device(text, text) from public, anon, authenticated;
revoke all on function public.revoke_device(uuid) from public, anon, authenticated;
revoke all on function public.prune_history(int) from public, anon, authenticated;
grant execute on function public.register_device(text, text) to service_role;
grant execute on function public.revoke_device(uuid) to service_role;
grant execute on function public.prune_history(int) to service_role;

-- ---------------------------------------------------------------------------------------
-- Realtime: clients subscribe to status changes.
-- ---------------------------------------------------------------------------------------

alter publication supabase_realtime add table public.site_status, public.court_status;
-- Community features: player profiles, events (tournaments, open play, clinics, leagues,
-- socials), event sign-ups, and a "busy times" view built from the minute-by-minute history.
--
-- Nothing here comes from the camera. Everything a person posts is tied to their account,
-- and row level security limits what others can see:
--   * anyone can browse events and busy times;
--   * signed-in players can see each other's display names and skill levels;
--   * a player's sign-ups are visible to them and to the event's organizer, nobody else;
--   * only the organizer can edit or cancel an event.

-- ---------------------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------------------

create table public.profiles (
    id           uuid primary key references auth.users (id) on delete cascade,
    display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
    skill_level  numeric(3, 2) check (skill_level between 1.0 and 8.0),  -- DUPR-style scale
    home_site    text references public.sites (id) on delete set null,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);
comment on table public.profiles is 'One per account. Display name and optional self-rated skill.';

alter table public.profiles enable row level security;
create policy "signed-in players can read profiles" on public.profiles
    for select to authenticated using (true);
create policy "players create their own profile" on public.profiles
    for insert to authenticated with check (id = auth.uid());
create policy "players edit their own profile" on public.profiles
    for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke all on public.profiles from anon;
grant select, insert, update on public.profiles to authenticated;

create function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
    new.updated_at := now();
    return new;
end;
$$;
create trigger profiles_touch before update on public.profiles
    for each row execute function public.touch_updated_at();

-- Every new account gets a profile, named from sign-up metadata or the email's local part.
create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    insert into public.profiles (id, display_name)
    values (
        new.id,
        left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
                      split_part(new.email, '@', 1), 'Player'), 40)
    )
    on conflict (id) do nothing;
    return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
    for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------

create table public.events (
    id              uuid primary key default gen_random_uuid(),
    organizer_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
    kind            text not null check (kind in ('tournament', 'open_play', 'clinic', 'league', 'social')),
    title           text not null check (char_length(btrim(title)) between 3 and 80),
    description     text not null default '' check (char_length(description) <= 2000),
    site_id         text references public.sites (id) on delete set null,
    location_name   text check (char_length(location_name) <= 120),
    starts_at       timestamptz not null,
    ends_at         timestamptz,
    format          text not null default 'doubles' check (format in ('doubles', 'singles', 'mixed', 'any')),
    skill_min       numeric(3, 2) check (skill_min between 1.0 and 8.0),
    skill_max       numeric(3, 2) check (skill_max between 1.0 and 8.0),
    capacity        integer check (capacity between 2 and 512),
    fee_cents       integer not null default 0 check (fee_cents between 0 and 100000),
    -- The organizer holds a park-district permit for the courts. Public courts are
    -- first-come-first-served otherwise; the app can't reserve them.
    courts_reserved boolean not null default false,
    contact         text check (char_length(contact) <= 200),
    status          text not null default 'scheduled' check (status in ('scheduled', 'cancelled')),
    created_at      timestamptz not null default now(),
    check (ends_at is null or ends_at > starts_at),
    check (skill_min is null or skill_max is null or skill_max >= skill_min),
    check (site_id is not null or location_name is not null)
);
create index events_starts_at on public.events (starts_at);
create index events_site on public.events (site_id, starts_at);

alter table public.events enable row level security;
create policy "anyone can browse events" on public.events
    for select to anon, authenticated using (true);
create policy "signed-in players post events" on public.events
    for insert to authenticated
    with check (organizer_id = auth.uid() and starts_at > now() - interval '1 hour');
create policy "organizers edit their events" on public.events
    for update to authenticated
    using (organizer_id = auth.uid()) with check (organizer_id = auth.uid());
create policy "organizers delete their events" on public.events
    for delete to authenticated using (organizer_id = auth.uid());
revoke insert, update, delete on public.events from anon;
grant select on public.events to anon, authenticated;
grant insert, update, delete on public.events to authenticated;

-- ---------------------------------------------------------------------------------------
-- Sign-ups
-- ---------------------------------------------------------------------------------------

create table public.event_registrations (
    event_id   uuid not null references public.events (id) on delete cascade,
    user_id    uuid not null references auth.users (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (event_id, user_id)
);
create index event_registrations_user on public.event_registrations (user_id);

alter table public.event_registrations enable row level security;
create policy "players see their own sign-ups" on public.event_registrations
    for select to authenticated using (user_id = auth.uid());
create policy "organizers see who signed up" on public.event_registrations
    for select to authenticated using (exists (
        select 1 from public.events e where e.id = event_id and e.organizer_id = auth.uid()));
revoke all on public.event_registrations from anon;
grant select on public.event_registrations to authenticated;
-- Signing up and withdrawing go through the functions below, which enforce capacity.

create function public.register_for_event(p_event uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
    v_user  uuid := auth.uid();
    v_event public.events%rowtype;
    v_taken int;
begin
    if v_user is null then
        raise exception 'sign in to sign up' using errcode = '28000';
    end if;
    select * into v_event from public.events where id = p_event for update;
    if not found then
        raise exception 'event not found' using errcode = 'P0002';
    end if;
    if v_event.status = 'cancelled' then
        raise exception 'this event was cancelled' using errcode = 'P0001';
    end if;
    if v_event.starts_at < now() then
        raise exception 'this event has already started' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.event_registrations
               where event_id = p_event and user_id = v_user) then
        return;
    end if;
    select count(*) into v_taken from public.event_registrations where event_id = p_event;
    if v_event.capacity is not null and v_taken >= v_event.capacity then
        raise exception 'this event is full' using errcode = 'P0001';
    end if;
    insert into public.event_registrations (event_id, user_id) values (p_event, v_user);
end;
$$;

create function public.unregister_from_event(p_event uuid)
returns void language sql security definer set search_path = '' as $$
    delete from public.event_registrations where event_id = p_event and user_id = auth.uid();
$$;

revoke all on function public.register_for_event(uuid) from public, anon;
revoke all on function public.unregister_from_event(uuid) from public, anon;
grant execute on function public.register_for_event(uuid) to authenticated;
grant execute on function public.unregister_from_event(uuid) to authenticated;

-- What the app lists: events with the park name, the organizer's display name and how many
-- have signed up (a count only; who signed up stays private). Deliberately runs with the
-- view owner's rights (not security_invoker) so the count includes everyone's sign-ups
-- without exposing whose they are.
create view public.event_listing as
select
    e.id, e.organizer_id, e.kind, e.title, e.description, e.site_id, e.location_name,
    e.starts_at, e.ends_at, e.format, e.skill_min, e.skill_max, e.capacity, e.fee_cents,
    e.courts_reserved, e.contact, e.status, e.created_at,
    s.name as site_name,
    p.display_name as organizer_name,
    (select count(*) from public.event_registrations r where r.event_id = e.id)::int
        as registered_count
from public.events e
left join public.sites s on s.id = e.site_id
left join public.profiles p on p.id = e.organizer_id;
grant select on public.event_listing to anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- Busy times
-- ---------------------------------------------------------------------------------------

-- Typical crowd by weekday and hour (site local time) over the last eight weeks.
create view public.site_busy_hours
with (security_invoker = true) as
select
    h.site_id,
    extract(isodow from h.bucket at time zone s.timezone)::int as weekday,  -- 1 = Monday
    extract(hour from h.bucket at time zone s.timezone)::int as hour,
    round(avg(h.queue_count)::numeric, 1) as avg_waiting,
    round(avg((
        select avg(case when c ->> 'state' in ('empty', 'unknown') then 0 else 1 end)
        from jsonb_array_elements(h.courts) c
    ))::numeric, 2) as courts_in_use,
    count(*)::int as samples
from public.status_history h
join public.sites s on s.id = h.site_id
where h.bucket > now() - interval '8 weeks' and h.health = 'ok'
group by h.site_id, 2, 3;
grant select on public.site_busy_hours to anon, authenticated;

-- Sites for the simulator (`opencourt simulate --publish`) and the real pilot parks.
insert into public.sites (id, name, address, latitude, longitude, timezone) values
    ('sim-site',  'Simulator',              null,              41.8800, -87.6300, 'America/Chicago'),
    -- The real pilot sites (Buffalo Grove Park District). Coordinates are the park entrances;
    -- refine to the courts after the site visit.
    ('rick-drazner', 'Rick Drazner Park',          '401 Aptakisic Rd, Buffalo Grove, IL',      42.1590, -87.9590, 'America/Chicago'),
    ('mike-rylko',   'Mike Rylko Community Park',  '1000 N Buffalo Grove Rd, Buffalo Grove, IL', 42.1683, -87.9681, 'America/Chicago')
on conflict (id) do nothing;

insert into public.courts (site_id, number, label)
select s.id, n, 'Court ' || n
from public.sites s cross join generate_series(1, 4) as n
where s.id = 'sim-site'
on conflict do nothing;

insert into public.courts (site_id, number, label)
select 'rick-drazner', n, 'Court ' || n from generate_series(1, 2) as n
on conflict do nothing;

insert into public.courts (site_id, number, label)
select 'mike-rylko', n, 'Court ' || n from generate_series(1, 8) as n
on conflict do nothing;
commit;
