#!/usr/bin/env bash
# Run every test suite in the repo. Usage: scripts/test-all.sh [--fast]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/env.sh"
MARK=()
[[ "${1:-}" == "--fast" ]] && MARK=(-m "not slow")

echo "== sensor =="
(cd "$ROOT/sensor" && uv run ruff check src tests && uv run pytest ${MARK[@]+"${MARK[@]}"})

echo "== backend =="
(cd "$ROOT/backend" && uv run pytest)

echo "== ios (OpenCourtKit) =="
if [[ "${DEVELOPER_DIR:-}" == /Library/Developer/CommandLineTools ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
fi
(cd "$ROOT/ios/OpenCourtKit" && swift test 2>&1 | tail -3)
