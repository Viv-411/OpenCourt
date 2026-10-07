-- A 2-court park for showing a recorded clip side by side with the app (scripts/demo-clip.sh
-- replays the clip's detections in real time and publishes them here). Kept apart from the
-- real parks and from `sim-site`, whose 4 courts would show stale states for the 2 the clip
-- doesn't have. Remove after the presentations with:
--   delete from public.sites where id = 'demo-clip';
insert into public.sites (id, name, address, latitude, longitude, timezone) values
    ('demo-clip', 'OpenCourt Demo', null, 42.1555, -87.9700, 'America/Chicago')
on conflict (id) do nothing;

insert into public.courts (site_id, number, label)
select 'demo-clip', n, 'Court ' || n from generate_series(1, 2) as n
on conflict do nothing;
