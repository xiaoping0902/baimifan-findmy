"""Run production HUD windows in a real UIKit simulator process on macOS."""
import argparse
import json
import platform
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False, timeout=180):
    return subprocess.run(args, check=True, text=True, capture_output=capture, timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--window-source", type=Path,
                        default=ROOT / "app/Sources/HUD/MFHUDWindow.mm")
    parser.add_argument("--suite", choices=["windows", "input"], default="windows")
    args = parser.parse_args()
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", capture=True).stdout.strip()
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture=True).stdout)
    candidates = [(runtime, device) for runtime, entries in devices["devices"].items()
                  if ".iOS-" in runtime for device in entries if device.get("isAvailable")]
    if not candidates:
        raise RuntimeError("An available iOS simulator is required for the UIKit regression")
    candidates.sort(key=lambda item: ("iPad" not in item[1]["name"], item[1]["state"] != "Booted"))
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
            architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
            sources = ([ROOT / "tests/hud_uikit_regressions.mm", source]
                       if args.suite == "windows" else [ROOT / "tests/hud_input_bridge_regressions.mm",
                           ROOT / "app/Sources/HUD/MFHUDInputBridge.mm",
                           ROOT / "app/Sources/HUD/MFHUDTouchRouter.mm"])
            run("xcrun", "--sdk", "iphonesimulator", "clang++", "-fobjc-arc", "-std=c++17",
                "-target", f"{architecture}-apple-ios16.0-simulator", "-isysroot", sdk,
                "-I" + str(ROOT / "app/Sources/HUD"),
                "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "Foundation",
                "-framework", "CoreGraphics",
                *(str(path) for path in sources),
                "-o", str(app / "HUDRegression"))
            run("codesign", "--force", "--sign", "-", str(app))
            if booted_here:
                run("xcrun", "simctl", "boot", device_id)
            run("xcrun", "simctl", "bootstatus", device_id, "-b", timeout=300)
            run("xcrun", "simctl", "install", device_id, str(app))
            result = subprocess.run(["xcrun", "simctl", "launch", "--console",
                                     "--terminate-running-process", device_id, bundle_id],
                                    text=True, capture_output=True, timeout=90)
            print(result.stdout, end="")
            print(result.stderr, end="")
            marker = "PASS: real UIKit" if args.suite == "windows" else "PASS: production HID bridge"
            if result.returncode or marker not in result.stdout or "FAIL:" in result.stderr:
                raise SystemExit("UIKit window regression failed")
    finally:
        subprocess.run(["xcrun", "simctl", "uninstall", device_id, bundle_id], capture_output=True)
        if booted_here:
            subprocess.run(["xcrun", "simctl", "shutdown", device_id], capture_output=True)


if __name__ == "__main__":
    main()
