"""Runs the migration on a throwaway local Postgres (pgserver) with Supabase's roles and
realtime publication stubbed, so the SQL can be tested without Docker."""

from __future__ import annotations

import tempfile
from pathlib import Path

import psycopg
import pytest

ROOT = Path(__file__).resolve().parents[2] / "supabase"

SUPABASE_STUBS = """
do $$ begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
-- Supabase grants table privileges to anon/authenticated by default; RLS does the gating.
alter default privileges in schema public grant all on tables to anon, authenticated;
create publication supabase_realtime;

-- Supabase's auth schema, reduced to what the migrations use. auth.uid() reads the JWT
-- subject the same way Supabase does; tests set it with set_config.
create schema if not exists auth;
create table if not exists auth.users (
    id uuid primary key default gen_random_uuid(),
    email text,
    raw_user_meta_data jsonb not null default '{}'::jsonb
);
create or replace function auth.uid() returns uuid language sql stable as $f$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$f$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
"""


@pytest.fixture(scope="session")
def server():
    import pgserver

    srv = pgserver.get_server(tempfile.mkdtemp(), cleanup_mode="stop")
    yield srv
    srv.cleanup()


@pytest.fixture
def db(server):
    """A fresh database per test, migrated and seeded."""
    name = f"t_{abs(hash(object()))}"
    admin_uri = server.get_uri()
    with psycopg.connect(admin_uri, autocommit=True) as a:
        a.execute(f'create database "{name}"')
    uri = server.get_uri(name)
    with psycopg.connect(uri, autocommit=True) as conn:
        conn.execute(SUPABASE_STUBS)
        for f in sorted((ROOT / "migrations").glob("*.sql")):
            conn.execute(f.read_text())
        conn.execute((ROOT / "seed.sql").read_text())
        conn.execute("grant all on all tables in schema public to service_role")
        yield conn
    with psycopg.connect(admin_uri, autocommit=True) as a:
        a.execute(f'drop database "{name}" with (force)')
