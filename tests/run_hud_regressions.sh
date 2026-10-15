#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sources=(tests/hud_regressions.mm)
for source in app/Sources/HUD/MFHUDWindowHost.mm app/Sources/HUD/MFHUDStartupStatus.m; do
    if [[ -f "$source" ]]; then sources+=("$source"); fi
done
binary="$(mktemp -d)/hud-regressions"
trap 'rm -rf "$(dirname "$binary")"' EXIT
clang++ -fobjc-arc -std=c++17 -Iapp/Sources/HUD \
    -framework Foundation -framework QuartzCore "${sources[@]}" -o "$binary"
"$binary"
