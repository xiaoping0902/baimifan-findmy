#pragma once
#include <stdint.h>

enum {
    MF_DEVICE_SUPPORTED = 0,
    MF_DEVICE_UNSUPPORTED_OS = 1,
    MF_DEVICE_UNSUPPORTED_CHIP = 2
};

typedef struct {
    int status;
    int method;             /* Existing PUAF values: 0 physpuppet, 1 smith, 2 landa. */
    uint64_t pages;
    int minor;
    int patch;
} MFDeviceConfiguration;

/* The bundled dynamic_info table is iOS 16 / arm64e only. App installation
 * support is wider than this backend. Never reuse this table for iOS 15 or
 * A8-A11, and never infer support merely from an OS version upper bound.
 * CPU family values are Apple's mach/machine.h constants; M1 shares A14's
 * family, M2 shares A15's. This is a configuration eligibility check, not
 * evidence of successful kernel access on every device in those families. */
static inline MFDeviceConfiguration mf_device_configuration(int major, int minor, int patch,
                                                            uint32_t cpu_family, uint64_t memory) {
    MFDeviceConfiguration c = {MF_DEVICE_UNSUPPORTED_OS, -1, 0, minor, patch};
    if (major != 16 || minor < 0 || patch < 0 || minor > 6 || (minor == 6 && patch > 1)) return c;
    switch (cpu_family) {
        case 0x07d34b9f: /* A12 / A12X / A12Z */
        case 0x462504d2: /* A13 */
        case 0x1b588bb3: /* A14 / M1 */
        case 0xda33d83d: /* A15 / M2 */
        case 0x8765edea: /* A16 */
            break;
        default: c.status = MF_DEVICE_UNSUPPORTED_CHIP; return c;
    }
    c.status = MF_DEVICE_SUPPORTED;
    /* physpuppet was patched in 16.4; smith in 16.5.1. Preserve the
     * validated 16.1 physpuppet route rather than trying landa there. */
    c.method = minor <= 3 ? 0 : (minor < 5 || (minor == 5 && patch == 0) ? 1 : 2);
    c.pages = memory >= 5ULL * 1024 * 1024 * 1024 ? (c.method == 0 ? 1024 : 3072) : 512;
    return c;
}

static inline int mf_device_method_allowed(MFDeviceConfiguration c, int method) {
    if (c.status != MF_DEVICE_SUPPORTED) return 0;
    if (method == 0) return c.minor <= 3;
    if (method == 1) return c.minor < 5 || (c.minor == 5 && c.patch == 0);
    if (method == 2) return c.minor > 5 || (c.minor == 5 && c.patch >= 1);
    return 0;
}
