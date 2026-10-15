"""Launch checks for this app's unsandboxed UIKit and HUD roles.

Source: https://github.com/opa334/TrollStore#banned-entitlements
TrollStore preserves these keys when signing; it cannot bypass the PPL ban.

This app must also avoid forcing a builtin sandbox profile while requesting
no-sandbox. On iPadOS 16.6.1, the M5.60 viewservice profile caused the kernel
to kill the process during execve with "failed to assign builtin profile".
This is an app configuration rule, not another universal TrollStore ban.
"""

BANNED_ENTITLEMENTS = frozenset({
    "com.apple.private.cs.debugger",
    "dynamic-codesigning",
    "com.apple.private.skip-library-validation",
})


def incompatible_entitlements(entitlements):
    incompatible = BANNED_ENTITLEMENTS.intersection(entitlements)
    if (entitlements.get("com.apple.private.security.no-sandbox") is True
            and "com.apple.private.sandbox.profile" in entitlements):
        incompatible = incompatible.union({"com.apple.private.sandbox.profile"})
    return sorted(incompatible)
