#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sources=(tests/hud_regressions.mm)
for source in app/Sources/HUD/MFHUDWindowHost.mm app/Sources/HUD/MFHUDStartupStatus.mm; do
    if [[ -f "$source" ]]; then sources+=("$source"); fi
done
binary="$(mktemp -d)/hud-regressions"
trap 'rm -rf "$(dirname "$binary")"' EXIT
clang++ -fobjc-arc -std=c++17 -Iapp/Sources/HUD \
    -framework Foundation -framework QuartzCore "${sources[@]}" -o "$binary"
"$binary"
sudo mkdir -p /var/mobile/Library/Caches /var/mobile/Media/mf-debug
sudo chmod 777 /var/mobile/Library/Caches /var/mobile/Media/mf-debug
clang++ -fobjc-arc -std=c++17 -Iapp/Sources/HUD -framework Foundation -lproc \
    tests/hud_launcher_regressions.mm app/Sources/HUD/MFHUDLauncher.mm \
    app/Sources/HUD/MFHUDStartupStatus.mm -o "$(dirname "$binary")/hud-launcher-regressions"
"$(dirname "$binary")/hud-launcher-regressions"
