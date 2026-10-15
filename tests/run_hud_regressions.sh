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
touch_sources=(tests/hud_touch_regressions.mm)
if [[ -f app/Sources/HUD/MFHUDTouchRouter.mm ]]; then
    touch_sources+=(app/Sources/HUD/MFHUDTouchRouter.mm)
fi
clang++ -fobjc-arc -std=c++17 -Iapp/Sources/HUD -framework Foundation -framework CoreGraphics \
    "${touch_sources[@]}" -o "$(dirname "$binary")/hud-touch-regressions"
"$(dirname "$binary")/hud-touch-regressions"
clang++ -std=c++17 -Iapp/Sources/Render -Iapp/Sources/Render/imgui \
    tests/imgui_touch_regressions.cpp app/Sources/Render/imgui/imgui.cpp \
    app/Sources/Render/imgui/imgui_draw.cpp app/Sources/Render/imgui/imgui_tables.cpp \
    app/Sources/Render/imgui/imgui_widgets.cpp -o "$(dirname "$binary")/imgui-touch-regressions"
"$(dirname "$binary")/imgui-touch-regressions"
