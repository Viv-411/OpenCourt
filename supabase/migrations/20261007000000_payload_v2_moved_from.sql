-- Payload version 2: each court can say which court its group just moved up from, so the
-- app can show "moved up from court 1" instead of a court that silently changed hands. Set by
-- the sensor for a couple of minutes after a move; null otherwise and from version 1 sensors.
alter table public.court_status
    add column if not exists moved_from smallint check (moved_from >= 1);

create or replace function public.ingest_status(p_token text, p_payload jsonb)
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

    if coalesce((p_payload ->> 'version')::int, 0) not in (1, 2) then
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
            on_court_seconds, moved_from, updated_at
        ) values (
            v_site,
            v_number,
            v_court ->> 'state',
            v_court ->> 'light',
            greatest(0, (v_court ->> 'occupancy')::real),
            (v_court ->> 'clock_seconds')::int,
            (v_court ->> 'seconds_remaining')::int,
            (v_court ->> 'on_court_seconds')::int,
            (v_court ->> 'moved_from')::smallint,  -- version 2; null from version 1
            now()
        )
        on conflict (site_id, number) do update set
            state = excluded.state,
            light = excluded.light,
            occupancy = excluded.occupancy,
            clock_seconds = excluded.clock_seconds,
            seconds_remaining = excluded.seconds_remaining,
            on_court_seconds = excluded.on_court_seconds,
            moved_from = excluded.moved_from,
            updated_at = excluded.updated_at
        -- Skip no-op writes so Realtime only fires on real changes.
        where (c.state, c.light, c.occupancy, c.clock_seconds is null, c.moved_from)
            is distinct from (excluded.state, excluded.light, excluded.occupancy,
                              excluded.clock_seconds is null, excluded.moved_from)
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
