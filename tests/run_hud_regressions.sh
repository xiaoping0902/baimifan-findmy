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
# M5.66：停止链路改成「通知 + 看门狗」，所以 MFHUDLauncher 现在依赖
# MFHUDControl（需要 QuartzCore 的 CACurrentMediaTime）。缺了它会报
# Undefined symbols: _MFHUDPIDFilePath / _OBJC_CLASS_$_MFHUDControl。
launcher_sources=(tests/hud_launcher_regressions.mm app/Sources/HUD/MFHUDLauncher.mm
                  app/Sources/HUD/MFHUDStartupStatus.mm)
for source in app/Sources/HUD/MFHUDControl.mm; do
    if [[ -f "$source" ]]; then launcher_sources+=("$source"); fi
done
clang++ -fobjc-arc -std=c++17 -Iapp/Sources/HUD \
    -framework Foundation -framework QuartzCore -lproc \
    "${launcher_sources[@]}" -o "$(dirname "$binary")/hud-launcher-regressions"
"$(dirname "$binary")/hud-launcher-regressions"
clang++ -fobjc-arc -std=c++17 -Iapp/Sources/HUD \
    -framework Foundation -framework QuartzCore -lproc \
    tests/hud_lifecycle_regressions.mm app/Sources/HUD/MFHUDLauncher.mm \
    app/Sources/HUD/MFHUDStartupStatus.mm app/Sources/HUD/MFHUDControl.mm \
    -o "$(dirname "$binary")/hud-lifecycle-regressions"
lifecycle_failed=0
for lifecycle_case in retain-request failed-stop blocked-main session-isolation startup-cleanup startup-timeout foreign-pid same-executable-pid missing-birth readonly-lock restart reap legacy-record console-reopen cancel-start terminal-report; do
    if ! "$(dirname "$binary")/hud-lifecycle-regressions" "$lifecycle_case"; then lifecycle_failed=1; fi
done
if [[ "$lifecycle_failed" != 0 ]]; then exit 1; fi
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
