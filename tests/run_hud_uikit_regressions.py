"""Run production HUD windows in a real UIKit simulator process on macOS."""
import argparse
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False, timeout=180):
    return subprocess.run(args, check=True, text=True, capture_output=capture, timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--window-source", type=Path,
                        default=ROOT / "app/Sources/HUD/MFHUDWindow.mm")
    parser.add_argument("--suite", choices=["windows", "input", "menu", "overlay", "game-reader"], default="windows")
    args = parser.parse_args()
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", capture=True).stdout.strip()
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture=True).stdout)
    candidates = [(runtime, device) for runtime, entries in devices["devices"].items()
                  if ".iOS-" in runtime for device in entries if device.get("isAvailable")]
    if not candidates:
        raise RuntimeError("An available iOS simulator is required for the UIKit regression")
    candidates.sort(key=lambda item: (item[1]["state"] != "Booted", "iPhone" not in item[1]["name"]))
    _, device = candidates[0]
    device_id = device["udid"]
    booted_here = device["state"] != "Booted"
    bundle_id = "org.baimifan.HUDWindowRegression"
    try:
        with tempfile.TemporaryDirectory(prefix="hud-uikit-") as directory:
            source = args.window_source
            if args.suite == "windows" and not source.exists():
                # Older revisions kept the window implementation inside the
                # delegate. Compile those exact bytes for the RED comparison.
                delegate = (ROOT / "app/Sources/HUD/MFHUDAppDelegate.mm").read_text()
                start = delegate.index("@implementation MFHUDWindow")
                end = start + re.search(r"(?m)^@end\s*$", delegate[start:]).end()
                source = Path(directory) / "legacy-window.mm"
                source.write_text('#import "MFHUDAppDelegate.h"\n' + delegate[start:end])
            app = Path(directory) / "HUDRegression.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": bundle_id,
                "CFBundleExecutable": "HUDRegression",
                "CFBundleName": "HUDRegression",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0",
                "MinimumOSVersion": "16.0",
                "UIDeviceFamily": [1, 2],
                "UILaunchScreen": {},
            }))
            if args.suite == "menu":
                for font in (ROOT / "app/Resources").rglob("NotoSansSC-subset.ttf"):
                    shutil.copy2(font, app / font.name)
            architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
            if args.suite == "windows":
                sources = [ROOT / "tests/hud_uikit_regressions.mm", source]
                # M5.66：MFHUDWindow 会记录「窗口命中 / 窗口穿透」，
                # 于是窗口实现多了一个 MFHUDLogLine 依赖，这里显式链上。
                log_source = ROOT / "app/Sources/HUD/MFHUDLog.m"
                if log_source.exists():
                    sources.append(log_source)
            elif args.suite == "input":
                sources = [ROOT / "tests/hud_input_bridge_regressions.mm",
                           ROOT / "app/Sources/HUD/MFHUDInputBridge.mm",
                           ROOT / "app/Sources/HUD/MFHUDTouchRouter.mm"]
                sources += [ROOT / f"app/Sources/Render/imgui/{name}.cpp"
                            for name in ("imgui", "imgui_draw", "imgui_tables", "imgui_widgets")]
            elif args.suite == "game-reader":
                sources = [ROOT / "tests/game_reader_base_regressions.mm"]
                sources += [ROOT / f"app/Sources/Game/{name}.mm"
                            for name in ("MFGameReader", "MFProjection", "Offsets", "MFSettings")]
                sources.append(ROOT / "app/Sources/Read/MFReadBackend.mm")
            else:
                sources = [ROOT / f"tests/hud_{args.suite}_regressions.mm",
                           ROOT / "app/Sources/Render/MFOverlayView.mm",
                           ROOT / "app/Sources/Render/MFImGuiContext.mm",
                           ROOT / "app/Sources/Render/imgui/backends/imgui_impl_metal.mm",
                           ROOT / "app/Sources/HUD/MFHUDLog.m"]
                sources += [ROOT / f"app/Sources/Render/imgui/{name}.cpp"
                            for name in ("imgui", "imgui_draw", "imgui_tables", "imgui_widgets")]
                if args.suite == "menu":
                    sources += [ROOT / "app/Sources/HUD/MFMenuUI.mm",
                                ROOT / "app/Sources/Game/MFSettings.mm",
                                ROOT / "app/Sources/HUD/MFHUDControl.mm",
                                ROOT / "app/Sources/HUD/MFHUDStartupStatus.mm"]
            run("xcrun", "--sdk", "iphonesimulator", "clang++", "-x", "objective-c++", "-fobjc-arc", "-std=c++17",
                "-target", f"{architecture}-apple-ios16.0-simulator", "-isysroot", sdk,
                "-I" + str(ROOT / "app/Sources/HUD"),
                "-I" + str(ROOT / "app/Sources/Game"),
                "-I" + str(ROOT / "app/Sources/Render/imgui"),
                "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "Foundation",
                "-framework", "CoreGraphics", "-framework", "Metal", "-framework", "MetalKit",
                *(str(path) for path in sources),
                "-o", str(app / "HUDRegression"))
            run("codesign", "--force", "--sign", "-", str(app))
            if booted_here:
                run("xcrun", "simctl", "boot", device_id)
            run("xcrun", "simctl", "bootstatus", device_id, "-b", timeout=300)
            run("xcrun", "simctl", "install", device_id, str(app))
            container = Path(run("xcrun", "simctl", "get_app_container", device_id,
                                 bundle_id, "data", capture=True).stdout.strip())
            output = container / "Documents" / "hud-regression-result.txt"
            output.parent.mkdir(parents=True, exist_ok=True)
            output.unlink(missing_ok=True)
            environment = os.environ.copy()
            environment["SIMCTL_CHILD_MF_REGRESSION_OUTPUT"] = str(output)
            marker = {"windows": "PASS: real UIKit", "input": "PASS: production HID bridge",
                      "menu": "PASS: production menu", "overlay": "PASS: production overlay",
                      "game-reader": "PASS: production game reader"}[args.suite]
            report = ""
            menu_captured = False
            launch_log = Path(directory) / "simctl-launch.log"
            with launch_log.open("w") as launch_output:
                # A short-lived UIKit fixture can finish before simctl's launch
                # acknowledgement. Poll its fresh result file independently of
                # that CLI; neither a launch return code nor a timeout is PASS.
                launcher = subprocess.Popen(["xcrun", "simctl", "launch",
                                              "--terminate-running-process", device_id, bundle_id],
                                             stdout=launch_output, stderr=subprocess.STDOUT, env=environment)
                try:
                    deadline = time.monotonic() + 180
                    while time.monotonic() < deadline:
                        report = output.read_text(errors="replace") if output.exists() else ""
                        if args.suite == "menu" and "READY: menu screenshot" in report and not menu_captured:
                            destination = ROOT / "test-results/menu.png"
                            destination.parent.mkdir(exist_ok=True)
                            run("xcrun", "simctl", "io", device_id, "screenshot", str(destination), timeout=30)
                            menu_captured = True
                        terminal_failure = "FAIL:" in report
                        if args.suite == "overlay":
                            terminal_failure = ("FAIL: production overlay" in report or
                                                "FAIL: main queue must" in report)
                        if marker in report or terminal_failure:
                            break
                        if launcher.poll() not in (None, 0) and not report:
                            break
                        time.sleep(0.25)
                finally:
                    if launcher.poll() is None:
                        launcher.terminate()
                        try:
                            launcher.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            launcher.kill()
                            launcher.wait(timeout=5)
            print(launch_log.read_text(errors="replace"), end="", flush=True)
            print(report or "No test result was written; test execution is unconfirmed.", flush=True)
            if marker not in report or "FAIL:" in report:
                raise SystemExit("UIKit window regression failed")
    finally:
        cleanup = [["xcrun", "simctl", "uninstall", device_id, bundle_id]]
        if booted_here:
            cleanup.append(["xcrun", "simctl", "shutdown", device_id])
        for command in cleanup:
            try:
                subprocess.run(command, capture_output=True, timeout=60)
            except subprocess.TimeoutExpired:
                print("Simulator cleanup timed out: " + " ".join(command), flush=True)


if __name__ == "__main__":
    main()
