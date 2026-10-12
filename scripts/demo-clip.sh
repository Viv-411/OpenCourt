#!/usr/bin/env bash
# Side-by-side demo: plays a recorded clip on this Mac while the app (on a phone or the
# simulator) follows it live, in the "OpenCourt Demo" park.
#
#   scripts/demo-clip.sh            # the annotated video (boxes, zones, court states)
#   scripts/demo-clip.sh --plain    # the original video
#   scripts/demo-clip.sh --rick-drazner   # show it under Rick Drazner Park, where it was
#                                         # filmed (needs scripts/demo-data.sh seed first)
#
# Open the app on "OpenCourt Demo" (or Rick Drazner Park) first. The clip's timings are compressed about 20x (its
# config says so): say "sped up" when presenting. Ctrl+C stops the replay.
#
# The first run, macOS asks to let Terminal control QuickTime Player: allow it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/env.sh"
cd "$ROOT/sensor"

NAME="Final_Test"
DIR="data/footage/test 2"
VIDEO="$DIR/$NAME.annotated.mp4"
SITE=()
for arg in "$@"; do
    case "$arg" in
        --plain) VIDEO="$DIR/$NAME.mov" ;;
        --rick-drazner)
            TOKEN="$(grep '^OPENCOURT_RICK_DRAZNER_DEMO_TOKEN=' .env 2>/dev/null | cut -d= -f2- || true)"
            [[ -n "$TOKEN" ]] || { echo "run scripts/demo-data.sh seed first"; exit 1; }
            export OPENCOURT_DEMO_DEVICE_TOKEN="$TOKEN"   # the clip's config reads this name
            SITE=(--site rick-drazner) ;;
        *) echo "unknown option: $arg"; exit 1 ;;
    esac
done
[[ -f "$VIDEO" ]] || { echo "no video at sensor/$VIDEO"; exit 1; }
[[ -f "data/footage/$NAME.tracks.jsonl" ]] || { echo "run scripts/review-clip.sh first"; exit 1; }

# Load the video, and start the replay loading in the background; both then start at the
# same agreed moment, however long either takes to get ready.
osascript -e 'tell application "QuickTime Player"' -e 'activate' \
          -e "open POSIX file \"$PWD/$VIDEO\"" -e 'end tell' >/dev/null
START=$(( $(date +%s) + 8 ))
PYTHONUNBUFFERED=1 uv run opencourt replay --tracks "data/footage/$NAME.tracks.jsonl" \
    -c "data/configs/$NAME.yaml" --realtime --publish --lights none --start-at "$START" ${SITE[@]+"${SITE[@]}"} &
REPLAY=$!
trap 'kill $REPLAY 2>/dev/null || true' INT TERM EXIT  # it may already have finished
while [ "$(date +%s)" -lt "$START" ]; do
    echo "starting in $(( START - $(date +%s) ))..."; sleep 1
done
osascript -e 'tell application "QuickTime Player"' -e 'set current time of document 1 to 0' \
          -e 'play document 1' -e 'end tell' >/dev/null
echo "playing; the app follows live. Ctrl+C to stop."
wait $REPLAY
