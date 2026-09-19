#!/usr/bin/env bash
# Draw zones on a recording, replay it through the engine, and open the annotated result.
#
#   scripts/review-clip.sh <video filename in sensor/data/footage/> <number of courts> [--skip-draw]
#
# Everything it writes goes under sensor/data/ (git-ignored, never uploaded).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/env.sh"
cd "$ROOT/sensor"

VIDEO="data/footage/$(basename "${1:?video filename}")"
COURTS="${2:?number of courts}"
SKIP_DRAW="${3:-}"
NAME="$(basename "${VIDEO%.*}")"
ZONES="data/zones/$NAME.yaml"
CONFIG="data/configs/$NAME.yaml"
TRACKS="data/footage/$NAME.tracks.jsonl"
mkdir -p data/zones data/configs

[[ -f "$VIDEO" ]] || { echo "no such recording: $VIDEO"; exit 1; }

if [[ "$SKIP_DRAW" != "--skip-draw" ]]; then
  echo "== Draw the zones (a window opens; press S to save when done) =="
  EDIT=(); [[ -f "$ZONES" ]] && EDIT=(--edit)
  uv run opencourt calibrate --source "$VIDEO" --courts "$COURTS" --out "$ZONES" ${EDIT[@]+"${EDIT[@]}"}
fi

if [[ ! -f "$CONFIG" ]]; then
  cat > "$CONFIG" <<CFG
# Replay settings for $NAME (git-ignored; lives with the footage).
zones_file: zones/$NAME.yaml   # relative to sensor/data/
timer:
  threshold_seconds: 180   # 3 minutes instead of 20, so "time up" can happen in a short clip
  warning_seconds: 30
history:
  path: null
CFG
fi

if [[ ! -f "$TRACKS" ]]; then
  echo "== Finding people in the video (one time, about a third of the clip's length) =="
  uv run opencourt detect "$VIDEO" --fps 10 --imgsz 1280 --conf 0.2 --device mps
fi

echo "== Replaying =="
uv run opencourt replay --tracks "$TRACKS" -c "$CONFIG" --events "data/footage/$NAME.events.jsonl" --lights none

echo "== Rendering the annotated video (a couple of minutes) =="
OUT="$(uv run python tools/render_annotated.py "$VIDEO" --tracks "$TRACKS" -c "$CONFIG" | tail -1)"
echo "$OUT"
open "$OUT"
