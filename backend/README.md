# OpenCourt backend (Supabase)

Postgres + auto REST + Realtime. The whole backend is one migration:
[`../supabase/migrations/20260916000000_init.sql`](../supabase/migrations/20260916000000_init.sql).
The `supabase/` folder lives at the repo root so the Supabase GitHub integration finds it.

| Object | Purpose |
|---|---|
| `sites`, `courts` | A bank of courts and its court numbers (1 = entry court, nearest the queue) |
| `devices` | Sensors allowed to publish; only a SHA-256 of each token is stored |
| `site_status`, `court_status` | Latest state; Realtime-enabled |
| `status_history` | One row per site per minute (counts and states only) |
| `site_overview` (view) | What the app lists: status + `age_seconds` + `is_stale` |
| `ingest_status(p_token, p_payload)` | The only write path, callable with the anon key |
| `register_device`, `revoke_device`, `prune_history` | Admin-only (service role / SQL editor) |

## Security model

- Row level security is on everywhere. Anon and authenticated users can **read** status.
  They can't write anything, and they can't see `devices`.
- A sensor gets the **anon key** plus its own **device token**, never the service-role key.
  `ingest_status` checks the token and only writes the device's own site.
- Payloads are validated: payload version, site match, known court numbers, and allowed
  states.
- `court_status` skips writes that change nothing, so Realtime only fires on real changes.
  Clock values are refreshed at least every 30 s, and clients count up locally in between.

## Set up a project

1. Create a project at supabase.com. Save the project ref, the anon key, and the database
   password.
2. Apply the schema, using one of:
   - **GitHub integration** (already connected): migrations in `supabase/migrations/` are
     applied when they land on `main`. Check Database → Migrations in the dashboard.
   - SQL editor: paste the migration, then `seed.sql` if you want demo sites.
   - CLI: `npx supabase login`, then `npx supabase link --project-ref <ref>`, then
     `npx supabase db push`.
3. Add your real site. Court numbers start at the queue.
   ```sql
   insert into sites (id, name, address, latitude, longitude)
   values ('my-park', 'My Park Pickleball', '…', 41.9, -87.6);
   insert into courts (site_id, number) select 'my-park', n from generate_series(1, 4) n;
   ```
4. Register the sensor in the SQL editor, which runs as the service role:
   ```sql
   select register_device('my-park', 'pi-1');   -- copy the token now; it is not stored
   ```
5. On the Pi, create `/etc/opencourt.env` with `chmod 600`:
   ```
   OPENCOURT_SUPABASE_ANON_KEY=<anon key>
   OPENCOURT_DEVICE_TOKEN=<token from step 4>
   ```
   Then in `sensor/config/local.yaml`, set `backend.enabled: true`,
   `backend.url: https://<ref>.supabase.co`, and `site_id: my-park`.
6. Optional: schedule `select prune_history(90);` daily with `pg_cron`.

### Demo without hardware

```bash
# after seeding, register a device for the simulator site:
#   select register_device('sim-site', 'simulator');
export OPENCOURT_SUPABASE_ANON_KEY=... OPENCOURT_DEVICE_TOKEN=...
cd sensor && uv run opencourt simulate --publish --site sim-site --speed 10 \
    -c config/local.yaml    # local.yaml has backend.url set
```

The iOS app pointed at the same project will show the simulated courts live.

## Tests

The SQL is tested on a throwaway local Postgres ([pgserver](https://pypi.org/project/pgserver/)),
with Supabase's roles and Realtime publication stubbed, so no Docker is needed:

```bash
source ../scripts/env.sh
uv sync && uv run pytest
```

`tests/fixtures/payload_v1.json` is a real sensor payload. The sensor's
`tests/test_contract.py` keeps it current, so any change to the payload format breaks one
side's tests until the other side is updated.
