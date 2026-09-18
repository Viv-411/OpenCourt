-- OpenCourt: one-shot setup for the Supabase SQL editor (migration + seed).
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

-- Demo data for local development and the simulator (`opencourt simulate --publish`).
insert into public.sites (id, name, address, latitude, longitude, timezone) values
    ('demo-site', 'Demo Park — Courts 1-4', '100 Example Ave', 41.8781, -87.6298, 'America/Chicago'),
    ('sim-site',  'Simulator',              null,              41.8800, -87.6300, 'America/Chicago'),
    -- The real pilot sites (Buffalo Grove Park District). Coordinates are the park entrances;
    -- refine to the courts after the site visit.
    ('rick-drazner', 'Rick Drazner Park',          '401 Aptakisic Rd, Buffalo Grove, IL',      42.1590, -87.9590, 'America/Chicago'),
    ('mike-rylko',   'Mike Rylko Community Park',  '1000 N Buffalo Grove Rd, Buffalo Grove, IL', 42.1683, -87.9681, 'America/Chicago')
on conflict (id) do nothing;

insert into public.courts (site_id, number, label)
select s.id, n, 'Court ' || n
from public.sites s cross join generate_series(1, 4) as n
where s.id in ('demo-site', 'sim-site')
on conflict do nothing;

insert into public.courts (site_id, number, label)
select 'rick-drazner', n, 'Court ' || n from generate_series(1, 2) as n
on conflict do nothing;

insert into public.courts (site_id, number, label)
select 'mike-rylko', n, 'Court ' || n from generate_series(1, 8) as n
on conflict do nothing;
commit;
