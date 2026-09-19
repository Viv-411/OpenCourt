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
