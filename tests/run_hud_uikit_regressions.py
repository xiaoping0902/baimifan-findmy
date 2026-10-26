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
    print("RUN: " + " ".join(map(str, args)), flush=True)
    return subprocess.run(args, check=True, text=True, capture_output=capture, timeout=timeout)


def finish_launcher(launcher):
    if launcher.poll() is None:
        launcher.terminate()
        try:
            launcher.wait(timeout=5)
        except subprocess.TimeoutExpired:
            launcher.kill()
            launcher.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--window-source", type=Path,
                        default=ROOT / "app/Sources/HUD/MFHUDWindow.mm")
    parser.add_argument("--suite", choices=["windows", "input", "menu", "overlay", "game-reader", "drawing", "projection"], default="windows")
    args = parser.parse_args()
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", capture=True).stdout.strip()
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture=True).stdout)
    candidates = [(runtime, device) for runtime, entries in devices["devices"].items()
                  if ".iOS-" in runtime for device in entries if device.get("isAvailable")]
    if not candidates:
        raise RuntimeError("An available iOS simulator is required for the UIKit regression")
    candidates.sort(key=lambda item: (item[1]["state"] != "Booted", "iPhone" not in item[1]["name"]))
    runtime, device = candidates[0]
    print(f"Simulator: {device['name']} runtime={runtime} state={device['state']} udid={device['udid']}", flush=True)
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
            if args.suite in ("menu", "overlay", "drawing"):
                # Match production's first-choice asset. Testing the old tiny
                # subset alone hid coverage failures behind fallback glyphs.
                font = ROOT / "app/Resources/NotoSansSC-full.ttf"
                shutil.copy2(font, app / font.name)
            architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
            if args.suite == "windows":
                sources = [ROOT / "tests/hud_uikit_regressions.mm", source]
                shield = ROOT / "app/Sources/HUD/MFHUDCaptureShieldView.mm"
                if shield.exists():
                    sources.append(shield)
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
            elif args.suite == "projection":
                sources = [ROOT / "tests/hud_projection_regressions.mm",
                           ROOT / "app/Sources/Game/MFProjection.mm"]
            elif args.suite == "game-reader":
                sources = [ROOT / "tests/game_reader_base_regressions.mm"]
                sources += [ROOT / f"app/Sources/Game/{name}.mm"
                            for name in ("MFGameReader", "MFProjection", "Offsets", "MFSettings",
                                         "MFUEReader", "MFUEOffsets", "MFUEGNames")]
                sources += [ROOT / "app/Sources/Read/MFReadBackend.mm",
                            ROOT / "tests/mfpt_page_table_stubs.c",
                            ROOT / "app/Sources/HUD/MFHUDLog.m"]
            else:
                sources = [ROOT / f"tests/hud_{args.suite}_regressions.mm",
                           ROOT / "app/Sources/Render/MFOverlayView.mm",
                           ROOT / "app/Sources/Render/MFImGuiContext.mm",
                           ROOT / "app/Sources/Render/MFStyle.mm",
                           ROOT / "app/Sources/Render/imgui/backends/imgui_impl_metal.mm",
                           ROOT / "app/Sources/HUD/MFHUDCaptureShieldView.mm",
                           ROOT / "app/Sources/HUD/MFHUDLog.m"]
                sources += [ROOT / f"app/Sources/Render/imgui/{name}.cpp"
                            for name in ("imgui", "imgui_draw", "imgui_tables", "imgui_widgets")]
                if args.suite == "menu":
                    sources += [ROOT / "app/Sources/HUD/MFMenuUI.mm",
                                ROOT / "app/Sources/HUD/MFMenuPanel.mm",
                                ROOT / "app/Sources/HUD/MFHUDIslandView.mm",
                                ROOT / "app/Sources/Game/MFSettings.mm",
                                ROOT / "app/Sources/HUD/MFHUDControl.mm",
                                ROOT / "app/Sources/HUD/MFHUDStartupStatus.mm"]
                elif args.suite == "drawing":
                    # Production drawing, settings and projection. The fixture
                    # injects synthetic frames at the acquisition boundary and
                    # fails on any remote read; no kernel or game process is used.
                    # Link the production panel stats/tracer-origin and item-name
                    # helpers used by the current drawing delegate as well.
                    sources += [ROOT / "app/Sources/HUD/MFDrawingLayer.mm",
                                ROOT / "app/Sources/HUD/MFRadar.mm",
                                ROOT / "app/Sources/HUD/MFMenuPanel.mm"]
                    sources.append(ROOT / "app/Sources/Game/MFBones.mm")
                    sources += [ROOT / f"app/Sources/Game/{name}.mm" for name in (
                        "MFGameReader", "MFUEReader", "MFUEOffsets", "MFProjection", "Offsets",
                        "MFSettings", "MFGearCatalog", "MFGearReader", "MFUEGNames", "MFItemTable",
                        "MFItemNames")]
                    sources += [ROOT / "app/Sources/Read/MFReadBackend.mm",
                                ROOT / "app/Sources/Read/MFExternalFeed.mm",
                                ROOT / "tests/mfpt_page_table_stubs.c"]
            run("xcrun", "--sdk", "iphonesimulator", "clang++", "-x", "objective-c++", "-fobjc-arc", "-std=c++17",
                *(["-DMF_UI_TEST_HOOKS=1"] if args.suite == "menu" else []),
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
            if args.suite == "menu":
                # This suite needs a visible WindowServer-backed surface for
                # its real Metal screenshot, beyond the booted device used by
                # the headless geometry fixtures.
                for attempt in range(2):
                    try:
                        run("open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", device_id, timeout=60)
                        break
                    except subprocess.TimeoutExpired:
                        if attempt == 1:
                            raise
                        # Intel hosted runners have timed out launching the
                        # Simulator UI after bootstatus succeeds. Retry its UI
                        # launch once; the actual GPU/PNG checks remain required.
                        print("Retrying Simulator UI launch after its 60s timeout", flush=True)
            run("xcrun", "simctl", "install", device_id, str(app))
            container = Path(run("xcrun", "simctl", "get_app_container", device_id,
                                 bundle_id, "data", capture=True).stdout.strip())
            output = container / "Documents" / "hud-regression-result.txt"
            output.parent.mkdir(parents=True, exist_ok=True)
            output.unlink(missing_ok=True)
            screenshot_ack = output.with_name("hud-regression-screenshot-done")
            menu_screenshots = (("menu", ""), ("menu-drawing", ".drawing"), ("menu-loot", ".loot"))
            for name, suffix in menu_screenshots:
                Path(str(screenshot_ack) + suffix).unlink(missing_ok=True)
                if args.suite == "menu":
                    (ROOT / "test-results" / f"{name}.png").unlink(missing_ok=True)
            environment = os.environ.copy()
            environment["SIMCTL_CHILD_MF_REGRESSION_OUTPUT"] = str(output)
            environment["SIMCTL_CHILD_MF_REGRESSION_SCREENSHOT_ACK"] = str(screenshot_ack)
            marker = {"windows": "PASS: real UIKit", "input": "PASS: production HID bridge",
                      "menu": "PASS: production menu", "overlay": "PASS: production overlay",
                      "game-reader": "PASS: production game reader",
                      "drawing": "PASS: production drawing consumes synthetic frames",
                      "projection": "PASS: production projection geometry and invalid-input rejection"}[args.suite]
            report = ""
            menu_captured = set()
            launch_log = Path(directory) / "simctl-launch.log"
            with launch_log.open("w") as launch_output:
                # A short-lived UIKit fixture can finish before simctl's launch
                # acknowledgement. Poll its fresh result file independently of
                # that CLI; neither a launch return code nor a timeout is PASS.
                launcher = subprocess.Popen(["xcrun", "simctl", "launch",
                                              "--terminate-running-process", device_id, bundle_id],
                                             stdout=launch_output, stderr=subprocess.STDOUT, env=environment)
                try:
                    deadline = time.monotonic() + 240
                    next_launch_report = time.monotonic()
                    while time.monotonic() < deadline:
                        report = output.read_text(errors="replace") if output.exists() else ""
                        if time.monotonic() >= next_launch_report:
                            print(f"Launch progress: status={launcher.poll()} result_bytes={len(report)}", flush=True)
                            next_launch_report = time.monotonic() + 30
                        ready_screenshot = next(((name, suffix) for name, suffix in menu_screenshots
                                                 if f"READY: {name} screenshot" in report and name not in menu_captured), None)
                        if args.suite == "menu" and ready_screenshot is not None:
                            name, suffix = ready_screenshot
                            # The fresh fixture report proves launch completed.
                            # Release a CLI still awaiting its acknowledgement
                            # before asking a second simctl client for the image.
                            # No --console option was used, so the app stays live.
                            print(f"{name} READY; simctl launch status={launcher.poll()}; releasing launch CLI", flush=True)
                            finish_launcher(launcher)
                            destination = ROOT / "test-results" / f"{name}.png"
                            destination.parent.mkdir(exist_ok=True)
                            destination.unlink(missing_ok=True)
                            # A newly booted hosted simulator may stall its
                            # first screenshot request after its Metal frame.
                            # Retry that utility once; still require a complete
                            # PNG and the live fixture's acknowledgement.
                            for attempt in range(2):
                                try:
                                    run("xcrun", "simctl", "io", device_id, "screenshot", str(destination), timeout=45)
                                    break
                                except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
                                    if attempt == 1:
                                        raise
                                    print("Retrying simulator menu screenshot after utility failure", flush=True)
                                    destination.unlink(missing_ok=True)
                            png = destination.read_bytes()
                            if not (png.startswith(b"\x89PNG\r\n\x1a\n") and
                                    png.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82")):
                                raise RuntimeError("The menu screenshot is not a complete PNG")
                            Path(str(screenshot_ack) + suffix).touch()
                            menu_captured.add(name)
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
                    # Preserve fixture output even when a simulator utility
                    # fails; otherwise a screenshot timeout hides its results.
                    report = output.read_text(errors="replace") if output.exists() else report
                    print(report or "No test result was written; test execution is unconfirmed.", flush=True)
                    if args.suite == "menu":
                        result_dir = ROOT / "test-results"
                        result_dir.mkdir(exist_ok=True)
                        (result_dir / "menu-result.txt").write_text(report)
                    finish_launcher(launcher)
                    print(launch_log.read_text(errors="replace"), end="", flush=True)
            if marker not in report or "FAIL:" in report:
                raise SystemExit("UIKit window regression failed")
            if args.suite == "menu" and len(menu_captured) != len(menu_screenshots):
                raise SystemExit("All three production menu screenshots are required")
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
