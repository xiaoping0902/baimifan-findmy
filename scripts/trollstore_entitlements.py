"""Launch restrictions documented by TrollStore for iOS 15+ on A12+.

Source: https://github.com/opa334/TrollStore#banned-entitlements
TrollStore preserves these keys when signing; it cannot bypass the PPL ban.
"""

BANNED_ENTITLEMENTS = frozenset({
    "com.apple.private.cs.debugger",
    "dynamic-codesigning",
    "com.apple.private.skip-library-validation",
})


def incompatible_entitlements(entitlements):
    return sorted(BANNED_ENTITLEMENTS.intersection(entitlements))
