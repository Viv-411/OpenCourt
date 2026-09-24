#!/usr/bin/env bash
# Can this Raspberry Pi run OpenCourt? Times the detector on a 3-minute clip of real
# footage and checks the Pi reaches the same answers as the Mac.
#
# On the Pi, with the repo cloned and sensor/data/pi-bench/ copied over from the Mac
# (the clip, the NCNN models, the config and the Mac's reference results):
#
#   scripts/pi-bench.sh              # both model sizes, 640 then 480
#   SIZES=640 scripts/pi-bench.sh    # just one
#
# Everything is also written to sensor/data/pi-bench/results/report.txt. The clip shows
# real people: it stays in the git-ignored data/ folder on your own machines.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bench="$root/sensor/data/pi-bench"
results="$bench/results"
mkdir -p "$results"
exec > >(tee "$results/report.txt") 2>&1

echo "== OpenCourt Pi benchmark, $(date '+%Y-%m-%d %H:%M') =="
# The subshell keeps "no such file" quiet off a Pi (the redirect fails before `tr` runs).
board="$( (tr -d '\0' < /proc/device-tree/model) 2>/dev/null || uname -n)"
arch="$(uname -m)"
ram_mb="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)"
disk_gb="$(df -Pm "$root" | awk 'NR == 2 {print int($4 / 1024)}')"
ram_text=""
[ "$ram_mb" -gt 0 ] && ram_text=" | ${ram_mb} MB RAM"
echo "board: $board | $arch$ram_text | ${disk_gb} GB free"

# 64-bit ARM (a Pi, or a Mac as "arm64") and x86_64 (a mini PC) can all run it.
if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ] && [ "$arch" != "x86_64" ]; then
    echo
    echo "This OS is 32-bit ($arch). The detector's libraries only exist for 64-bit systems."
    echo "Reflash with Raspberry Pi OS (64-bit) using Raspberry Pi Imager, then run this again."
    echo "(A Pi 1, Pi Zero or original Pi 2 can't run 64-bit at all.)"
    exit 1
fi
if [ ! -f "$bench/clip.mp4" ] || [ ! -d "$bench/reference" ]; then
    echo
    echo "Missing $bench. Copy sensor/data/pi-bench/ over from the Mac first."
    exit 1
fi
if [ "$ram_mb" -gt 0 ] && [ "$ram_mb" -lt 1800 ]; then
    echo "warning: under 2 GB of RAM; the detector alone needs about 500 MB."
fi
if [ "$disk_gb" -lt 3 ]; then
    echo "warning: under 3 GB free; the libraries need about 2 GB."
fi

echo
echo "== installing (first run only; a few minutes) =="
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
cd "$root/sensor"
uv sync --extra vision --no-dev --quiet
if ! uv run python -c "import cv2" 2>/dev/null; then
    echo "OpenCV can't load its system libraries. Install them, then run this again:"
    echo "  sudo apt install -y libgl1 libglib2.0-0"
    exit 1
fi

echo
echo "== engine check: the Mac's detections, replayed here =="
uv run opencourt replay --tracks "$bench/reference/mac-640.tracks.jsonl" \
    -c "$bench/config.yaml" --events "$results/engine-check.events.jsonl" >/dev/null 2>&1
if cmp -s "$bench/reference/mac-640.events.jsonl" "$results/engine-check.events.jsonl"; then
    echo "SAME: the engine reached exactly the Mac's events."
else
    echo "DIFFERENT: the engine disagreed with the Mac on identical input (please report)."
fi

for size in ${SIZES:-640 480}; do
    echo
    echo "== detector at imgsz $size (1,799 frames; on a slow board this takes a while) =="
    uv run python tools/pi_bench.py "$bench/clip.mp4" \
        --model "$bench/models/yolo11n_${size}_ncnn_model" --imgsz "$size" \
        --out "$results/pi-$size.tracks.jsonl" --label "Pi, imgsz $size"
    uv run opencourt replay --tracks "$results/pi-$size.tracks.jsonl" \
        -c "$bench/config.yaml" --events "$results/pi-$size.events.jsonl" >/dev/null 2>&1
    echo
    echo "-- compared with the Mac at the same size --"
    uv run python tools/compare_runs.py "$bench/reference/mac-$size" "$results/pi-$size" || true
done

echo
echo "Done. Full report: $results/report.txt"
