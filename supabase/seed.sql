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
