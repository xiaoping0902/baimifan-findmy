"""Exercise the IPA verifier's launch compatibility gate, without Xcode.

The fixture is a minimal Mach-O/signature envelope for the verifier, not a
launchable application. Device launch remains a separate acceptance check.
"""
import contextlib
import io
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import verify_ipa


class IPAEntitlementsTests(unittest.TestCase):
    def verify(self, extra):
        entitlements = {
            "platform-application": True,
            "com.apple.private.security.no-sandbox": True,
            "com.apple.private.security.storage.AppBundles": True,
            "com.apple.private.persona-mgmt": True,
            "com.apple.springboard.accessibility-window-hosting": True,
            "task_for_pid-allow": True,
            "com.apple.security.exception.iokit-user-client-class": ["AGXDeviceUserClient"],
            **extra,
        }
        xml = plistlib.dumps(entitlements)
        blob = struct.pack(">II", 0xFADE7171, 8 + len(xml)) + xml
        signature = struct.pack(">IIIII", 0xFADE0CC0, 20 + len(blob), 1, 5, 20) + blob
        header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
        command = struct.pack("<4I", 0x1D, 16, 48, len(signature))
        info = {
            "CFBundleDisplayName": "查找", "CFBundleIdentifier": "com.apple.findmy",
            "CFBundleName": "FindMy", "CFBundleExecutable": "FindMy",
            "MinimumOSVersion": "15.0",
        }
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "fixture.ipa"
            with zipfile.ZipFile(ipa, "w") as package:
                package.writestr("Payload/FindMy.app/Info.plist", plistlib.dumps(info))
                package.writestr("Payload/FindMy.app/FindMy", header + command + signature)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = verify_ipa.main(str(ipa))
            return result, output.getvalue()

    def test_rejects_entitlements_that_prevent_launch_on_a12_and_newer(self):
        # TrollStore's documented bans; removing the gate must fail this test.
        for key in ("com.apple.private.cs.debugger", "dynamic-codesigning",
                    "com.apple.private.skip-library-validation"):
            with self.subTest(key=key):
                result, output = self.verify({key: True})
                self.assertEqual(result, 1, output)
                self.assertIn(key, output)

    def test_accepts_hud_and_root_spawn_entitlements(self):
        result, output = self.verify({"com.apple.QuartzCore.displayable-context": True})
        self.assertEqual(result, 0, output)


if __name__ == "__main__":
    unittest.main()
