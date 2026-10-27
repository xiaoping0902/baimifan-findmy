#pragma once
#include <stdint.h>

/*
 * 设备/系统资格判定（M5.229 起按"能不能走到实证"放行，而不是按版本表放行）。
 *
 * 背景：旧门是 `major != 16 → 不支持`，理由是内置的 libkfd dynamic_info 只有
 * 一条 iOS 16 / arm64e 基线。这条门把两件不同的事混在一起：
 *   a) 结构性支持：proc→task 这一跳的形状（15 内嵌 / 16 经 proc_ro）
 *   b) 漏洞原语支持：physpuppet / smith / landa 各自覆盖哪些版本
 * 现在 a) 由 MFChainCalib.h v2 用"形状 + 0xfeedfacf 实证"覆盖，与版本号无关；
 * 这里只保留 b) 的判断，并把 15.x 一起放开 —— 成不成由 kopen 的返回值说话。
 *
 * 参考：
 *   kfd/libkfd/info/static_info.h   t1sz_boot（17 仅 T8120/T8103/T8112）
 *   kfd/libkfd/info.h:106-112
 *   MFChainCalib.h                  链形状枚举（1 跳 / 2 跳）
 *   felix-pb/kfd                    physpuppet 16.4 修、smith 16.5.1 修、
 *                                   landa 17.0 修
 *   TrollStore 2.x                  安装面覆盖 iOS 14.0–16.6.1（不越狱）
 */

enum {
    MF_DEVICE_SUPPORTED = 0,
    MF_DEVICE_UNSUPPORTED_OS = 1,
    MF_DEVICE_UNSUPPORTED_CHIP = 2
};

typedef struct {
    int status;
    int method;             /* Existing PUAF values: 0 physpuppet, 1 smith, 2 landa. */
    uint64_t pages;
    int major;
    int minor;
    int patch;
} MFDeviceConfiguration;

/*
 * 这个函数只回答"值不值得试"，不回答"一定成"：
 *   · iOS 16.0–16.6.1 + A12–A16（arm64e）：16.1 与 16.6.1 上都有 kopen rc=0 的
 *     真机记录，链路形状由 MFChainCalib 覆盖 —— 当前的主支持面。
 *   · iOS 15.0–15.8：同一代 arm64e 结构，physpuppet(CVE-2023-23536) 与
 *     landa(CVE-2023-41974) 都覆盖 15.x，TrollStore 2 也覆盖这一段；
 *     但 libkfd 的 patchfinder 是 16 形状，失败会在 kopen 里立刻返回。
 *     所以这里放行、由返回值裁决，不假装它已经验过。
 *   · A8–A11（iPhone 8/X、iPad 5/6/7）：kfd 的 perf 后端不适用，需另配 arm64
 *     后端，不在本轮范围。
 * CPU family 值是 Apple mach/machine.h 常量；M1 与 A14 同族、M2 与 A15 同族。
 */
static inline MFDeviceConfiguration mf_device_configuration(int major, int minor, int patch,
                                                            uint32_t cpu_family, uint64_t memory) {
    MFDeviceConfiguration c = {MF_DEVICE_UNSUPPORTED_OS, -1, 0, major, minor, patch};

    int os_ok = 0;
    if (major == 15 && minor >= 0 && minor <= 8) {
        os_ok = 1;
    } else if (major == 16 && minor >= 0 && minor <= 6 && !(minor == 6 && patch > 1)) {
        os_ok = 1;
    }
    if (!os_ok) return c;

    switch (cpu_family) {
        case 0x07d34b9f: /* A12 / A12X / A12Z */
        case 0x462504d2: /* A13 */
        case 0x1b588bb3: /* A14 / M1 */
        case 0xda33d83d: /* A15 / M2 */
        case 0x8765edea: /* A16 */
            break;
        default:
            c.status = MF_DEVICE_UNSUPPORTED_CHIP;
            return c;
    }

    c.status = MF_DEVICE_SUPPORTED;

    /*
     * 原语按"修在哪一版"挑：
     *   physpuppet  CVE-2023-23536  16.4   修 → 15.x / 16.0–16.3
     *   smith       CVE-2023-32434  16.5.1 修 → 16.4 / 16.5.0
     *   landa       CVE-2023-41974  17.0   修 → 16.5.1–16.6.1
     * 15.x 上 landa 也可用，但 physpuppet 在 16.1/16.6.1 上有过真机记录，
     * 这里给 15.x 选同一族的最小惊讶值。
     */
    if (major == 15) {
        c.method = 0;
    } else if (minor <= 3) {
        c.method = 0;
    } else if (minor == 4 || (minor == 5 && patch == 0)) {
        c.method = 1;
    } else {
        c.method = 2;
    }

    /*
     * [M5.236] puaf_pages：landa（16.5.1+）也从 3072 降到 1024。
     *
     * 真机证据（panic-full-2026-10-27-170458，iPad8,11 / 16.6.1）：
     *     pmap_remove_pv: PVH entry at pai 150632 is locked down
     *         (0x6200000000000000), cannot remove @pmap_data.c:2504
     * 这不是我们读越界（那次是 copy_validate），而是 landa 的 PUAF 在页表里
     * 留下被 lock 的 PV 表项；游戏启动后内核回收物理页，pmap_remove_pv 撞上
     * 就 panic。dangling 页越多，撞上的概率越大 —— 3072 页是给 M 系列大内存
     * 定的，对这台 8GB iPad 属于过量。先降到 1024，把"被锁 PVH"数量压小。
     */
    c.pages = memory >= 5ULL * 1024 * 1024 * 1024 ? 1024 : 512;
    return c;
}

static inline int mf_device_method_allowed(MFDeviceConfiguration c, int method) {
    if (c.status != MF_DEVICE_SUPPORTED) return 0;
    if (method == 0) return c.major == 15 || c.minor <= 3;
    if (method == 1) return c.major == 16 && (c.minor == 4 || (c.minor == 5 && c.patch == 0));
    if (method == 2) return c.major == 16 && (c.minor > 5 || (c.minor == 5 && c.patch >= 1));
    return 0;
}
