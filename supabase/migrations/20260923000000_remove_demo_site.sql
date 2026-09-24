-- Drop the placeholder park that shipped with the first schema. The pilot has two real
-- parks (Rick Drazner, Mike Rylko) and `sim-site` for the simulator, so it only cluttered
-- the app's list and map. Courts, status and history go with it (on delete cascade).
delete from public.sites where id = 'demo-site';

-- The simulator's row had a placeholder coordinate in downtown Chicago, which dragged the
-- app's map out across the state whenever it was framed with the real parks. Put it beside
-- the pilot sites in Buffalo Grove; nothing depends on where a fake site claims to be.
update public.sites set latitude = 42.1520, longitude = -87.9600 where id = 'sim-site';
