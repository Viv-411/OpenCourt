-- Demo data for local development and the simulator (`opencourt simulate --publish`).
insert into public.sites (id, name, address, latitude, longitude, timezone) values
    ('demo-site', 'Demo Park — Courts 1-4', '100 Example Ave', 41.8781, -87.6298, 'America/Chicago'),
    ('sim-site',  'Simulator',              null,              41.8800, -87.6300, 'America/Chicago')
on conflict (id) do nothing;

insert into public.courts (site_id, number, label)
select s.id, n, 'Court ' || n
from public.sites s cross join generate_series(1, 4) as n
where s.id in ('demo-site', 'sim-site')
on conflict do nothing;
