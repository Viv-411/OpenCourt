#!/usr/bin/env bash
# Sample data for demo videos (see backend/demo_data.py). None of it is real.
#
#   scripts/demo-data.sh seed    # parks across the area, players, events, busy-times history
#   scripts/demo-data.sh live    # keep every park live while you record (Ctrl+C to stop)
#   scripts/demo-data.sh clear   # remove all of it
#
# Asks for the database password unless OPENCOURT_DB_PASSWORD is set. Never stored.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/env.sh"
cd "$ROOT/backend"
exec uv run python demo_data.py "$@"
