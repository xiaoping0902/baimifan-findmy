//
//  MFCalibrate.m -- KFD page-table direct read: offset calibration + self-verification
//
//  Offsets come from the kfdmemdump project (kfd_bridge.c / offsets.m), which
//  implements the same cross-process read on this SoC family:
//
//      proc --[+0x18]--> proc_ro --[+0x8]--> task
//      task --[+0x28]--> vm_map --[+0x40]--> pmap
//      pmap --[+0x00]--> root table VA (TTBR0, 16 KB granule, T0SZ=17)
//
//  Every step is verified against the values libkfd already knows
//  (current_proc / current_task / current_map / current_pmap), so a wrong
//  offset fails loudly instead of silently reading garbage. The final check
//  walks the page tables and reads our own Mach-O header (0xfeedfacf).
//
//  Safety rules kept from earlier iterations:
//    1. every kernel read is checked against the kernel VA window first
//       (a user address once reached copy_validate -> panic -> reboot)
//    2. 64-bit values are assembled from two 32-bit reads (sem_open gives 4 bytes)
//    3. mf_kclose() always runs, even on failure
//
#import "MFCalibrate.h"
#import "MFKernelBridge.h"
#import <mach-o/dyld.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/* ---------------- kernel address window ---------------- */
/*
 * On arm64 a kernel address is "top 16 bits all ones", not a fixed 0xfffffe
 * prefix:
 *     0xfffffe00_...  kbase / proc / task / vm_map
 *     0xfffffdf0_...  pmap and other zone objects
 * An earlier build used 0xfffffe0000000000 as the lower bound and wrongly
 * rejected such a pmap (M5.100 shipped: cpmap = 0xfffffdf0d63d1cb0).
 */
#define MF_KADDR_MIN 0xffff000000000000ULL
#define MF_KADDR_MAX 0xffffffffffffffffULL

static inline bool mf_is_kaddr(uint64_t a)
{
    return a >= MF_KADDR_MIN && a <= MF_KADDR_MAX;
}

/* ---------------- struct offsets (verified at runtime) ---------------- */
#define MF_OFF_PROC_LIST_PREV 0x08ULL  /* proc    -> list link used to walk      */
#define MF_OFF_PROC_PID       0x60ULL  /* proc    -> p_pid                       */
#define MF_OFF_PROC_RO        0x18ULL  /* proc    -> proc_ro                     */
#define MF_OFF_PROC_RO_TASK   0x08ULL  /* proc_ro -> task                        */
#define MF_OFF_TASK_MAP       0x28ULL  /* task    -> vm_map                      */
#define MF_OFF_VM_MAP_PMAP    0x40ULL  /* vm_map  -> pmap                        */
#define MF_OFF_PMAP_TTE       0x00ULL  /* pmap    -> root table VA               */

/* ---------------- 16 KB page geometry (T1SZ = 17) ---------------- */
#define MF_T1SZ        17ULL
#define MF_PG_SHIFT    14ULL
#define MF_PG_SIZE     (1ULL << MF_PG_SHIFT)
#define MF_PG_OFF(v)   ((uint64_t)(v) & (MF_PG_SIZE - 1ULL))

/* Apple XNU pmap macros (same values kfdmemdump uses) */
#define MF_TTE_VALID           0x1ULL
#define MF_PTE_TYPE_VALID      0x3ULL
#define MF_TTE_TYPE_MASK       0x2ULL
#define MF_TTE_TYPE_TABLE      0x2ULL
#define MF_TTE_TYPE_BLOCK      0x0ULL
#define MF_PA_MASK             0x0000fffffffff000ULL
#define MF_PTE_COMPRESSED      0x8000000000000000ULL
#define MF_PTE_COMPRESSED_ALT  0x4000000000000000ULL

#define MF_L1_OFFMASK  0x0000000fffffffffULL
#define MF_L1_INDEX    0x00007ff000000000ULL
#define MF_L2_OFFMASK  0x0000000001ffffffULL
#define MF_L2_INDEX    0x0000000ffe000000ULL
#define MF_L3_OFFMASK  0x0000000000003fffULL
#define MF_L3_INDEX    0x0000000001ffc000ULL

#define MF_L1_SHIFT 36ULL
#define MF_L2_SHIFT 25ULL
#define MF_L3_SHIFT 14ULL

typedef struct {
    uint64_t kernel_proc, kernel_task;
    uint64_t current_proc, current_task;
    uint64_t current_map, current_pmap;
    uint64_t gVirtBase, gPhysBase, gPhysSize;
} mf_kaddr_t;

static mf_kaddr_t g_k;

/* ---------------- PAC strip ---------------- */
static uint64_t mf_unsign(uint64_t p)
{
    if (p == 0) return 0;
    uint64_t ptr_mask = (1ULL << (64 - MF_T1SZ)) - 1ULL;
    uint64_t pac_mask = ~ptr_mask;
    if (p & (1ULL << 55)) return p | pac_mask;
    return p & ~pac_mask;
}

/* ---------------- safe reads ---------------- */
static bool k32(uint64_t a, uint32_t *out)
{
    if (!out || !mf_is_kaddr(a)) return false;
    return mf_kread32(a, out) == 0;
}

static bool k64(uint64_t a, uint64_t *out)
{
    uint32_t lo = 0, hi = 0;
    if (!out || !mf_is_kaddr(a)) return false;
    if (!k32(a, &lo)) return false;
    if (!k32(a + 4, &hi)) return false;
    *out = ((uint64_t)hi << 32) | lo;
    return true;
}

static bool pa_in_range(uint64_t pa, uint64_t len)
{
    if (g_k.gPhysSize == 0 || pa < g_k.gPhysBase) return false;
    uint64_t off = pa - g_k.gPhysBase;
    return off < g_k.gPhysSize && len <= g_k.gPhysSize - off;
}

/* physical -> kernel VA (physmap alias) */
static bool pa_to_kva(uint64_t pa, uint64_t *kva)
{
    if (!kva || !pa_in_range(pa, 1)) return false;
    *kva = g_k.gVirtBase + (pa - g_k.gPhysBase);
    return mf_is_kaddr(*kva);
}

/* ---------------- page-table walk (root table is a kernel VA) ---------------- */
static bool va_to_pa(uint64_t tt, uint64_t va, uint64_t *pa_out)
{
    uint64_t tte = 0;
    if (!pa_out || !mf_is_kaddr(tt)) return false;
    *pa_out = 0;

    uint64_t idx = (va & MF_L1_INDEX) >> MF_L1_SHIFT;
    if (!k64(tt + idx * 8, &tte)) return false;
    if ((tte & MF_TTE_VALID) != MF_TTE_VALID) return false;
    if ((tte & MF_TTE_TYPE_MASK) == MF_TTE_TYPE_BLOCK) {
        *pa_out = ((tte & MF_PA_MASK & ~MF_L1_OFFMASK) | (va & MF_L1_OFFMASK));
        return pa_in_range(*pa_out, 1);
    }
    if (!pa_to_kva(tte & MF_PA_MASK, &tt)) return false;

    idx = (va & MF_L2_INDEX) >> MF_L2_SHIFT;
    if (!k64(tt + idx * 8, &tte)) return false;
    if ((tte & MF_TTE_VALID) != MF_TTE_VALID) return false;
    if ((tte & MF_TTE_TYPE_MASK) == MF_TTE_TYPE_BLOCK) {
        *pa_out = ((tte & MF_PA_MASK & ~MF_L2_OFFMASK) | (va & MF_L2_OFFMASK));
        return pa_in_range(*pa_out, 1);
    }
    if (!pa_to_kva(tte & MF_PA_MASK, &tt)) return false;

    idx = (va & MF_L3_INDEX) >> MF_L3_SHIFT;
    uint64_t pte = 0;
    if (!k64(tt + idx * 8, &pte)) return false;
    if ((pte & MF_PTE_TYPE_VALID) != MF_PTE_TYPE_VALID) return false;
    if ((pte & MF_TTE_TYPE_MASK) != MF_TTE_TYPE_TABLE) return false;
    if (pte & (MF_PTE_COMPRESSED | MF_PTE_COMPRESSED_ALT)) return false;

    *pa_out = ((pte & MF_PA_MASK) | (va & MF_L3_OFFMASK));
    return pa_in_range(*pa_out, 1);
}

/* read user memory through a target pmap's page tables */
static bool kread_user(uint64_t tt, uint64_t uva, void *dst, size_t n)
{
    uint8_t *p = (uint8_t *)dst;
    size_t done = 0;
    while (done < n) {
        uint64_t pa = 0;
        if (!va_to_pa(tt, uva + done, &pa)) return false;
        uint64_t kva = 0;
        if (!pa_to_kva(pa, &kva)) return false;
        uint32_t v = 0;
        if (!k32(kva, &v)) return false;
        size_t take = (n - done < 4) ? (n - done) : 4;
        memcpy(p + done, &v, take);
        done += take;
    }
    return true;
}

/* ---------------- main ---------------- */
static NSString *run_locked(NSMutableDictionary *json)
{
    NSMutableString *log = [NSMutableString string];

    if (mf_kaddr_snapshot(&g_k.kernel_proc, &g_k.kernel_task, &g_k.current_proc,
                          &g_k.current_task, &g_k.current_map, &g_k.current_pmap,
                          &g_k.gVirtBase, &g_k.gPhysBase, &g_k.gPhysSize) != 0) {
        return @"FAIL: no g_kfd snapshot (kernel not open)";
    }

    struct { const char *name; uint64_t v; } checks[] = {
        {"kernel_proc",  g_k.kernel_proc},
        {"kernel_task",  g_k.kernel_task},
        {"current_proc", g_k.current_proc},
        {"current_task", g_k.current_task},
        {"current_map",  g_k.current_map},
        {"current_pmap", g_k.current_pmap},
        {"gVirtBase",    g_k.gVirtBase},
    };
    for (size_t i = 0; i < sizeof(checks) / sizeof(checks[0]); i++) {
        [log appendFormat:@"%-12s = %#llx\n", checks[i].name, (unsigned long long)checks[i].v];
        if (!mf_is_kaddr(checks[i].v)) {
            [log appendFormat:@"FAIL: %s outside kernel VA window\n", checks[i].name];
            return log;
        }
    }
    [log appendFormat:@"phys base=%#llx size=%#llx\n",
        (unsigned long long)g_k.gPhysBase, (unsigned long long)g_k.gPhysSize];

    /*
     * 1) Our own proc comes straight from libkfd's info_run(); no list walk needed.
     *    Walking allproc with the link at proc+0x0 stops after one hop (M5.102:
     *    walked=1). kfdmemdump advances with proc+0x8 (off_p_list_le_prev), so the
     *    loop below follows that field purely to report how many procs we see --
     *    we will need it when looking up the game process by pid.
     */
    uint64_t self_proc = g_k.current_proc;
    uint64_t cur = g_k.kernel_proc;
    int walked = 0;
    for (int i = 0; i < 4000 && mf_is_kaddr(cur); i++) {
        walked++;
        if (cur == self_proc) break;
        uint64_t next = 0;
        if (!k64(cur + MF_OFF_PROC_LIST_PREV, &next)) break;
        next = mf_unsign(next);
        if (next == 0 || next == cur || !mf_is_kaddr(next)) break;
        cur = next;
    }
    [log appendFormat:@"self_proc=%#llx (walked=%d)\n",
        (unsigned long long)self_proc, walked];
    if (!self_proc) return [log stringByAppendingString:@"FAIL: no self proc"];

    /* 2) proc -> proc_ro -> task */
    uint64_t proc_ro = 0, task = 0;
    if (!k64(self_proc + MF_OFF_PROC_RO, &proc_ro)) {
        return [log stringByAppendingString:@"FAIL: read proc_ro"];
    }
    proc_ro = mf_unsign(proc_ro);
    uint64_t task_raw = 0;
    if (!k64(proc_ro + MF_OFF_PROC_RO_TASK, &task_raw)) {
        return [log stringByAppendingString:@"FAIL: read pr_task"];
    }
    task = mf_unsign(task_raw);
    bool task_ok = (task == mf_unsign(g_k.current_task));
    [log appendFormat:@"proc_ro=%#llx task=%#llx %s\n",
        (unsigned long long)proc_ro, (unsigned long long)task,
        task_ok ? "OK == current_task" : "MISMATCH"];
    if (!task_ok) return [log stringByAppendingString:@"FAIL: proc_ro/pr_task offsets wrong"];

    /* 3) task -> vm_map */
    uint64_t map = 0;
    if (!k64(task + MF_OFF_TASK_MAP, &map)) {
        return [log stringByAppendingString:@"FAIL: read task->map"];
    }
    map = mf_unsign(map);
    bool map_ok = (map == mf_unsign(g_k.current_map));
    [log appendFormat:@"map=%#llx %s\n", (unsigned long long)map,
        map_ok ? "OK == current_map" : "MISMATCH"];
    if (!map_ok) return [log stringByAppendingString:@"FAIL: task->map offset wrong"];

    /* 4) vm_map -> pmap -> root table */
    uint64_t pmap_raw = 0;
    if (!k64(map + MF_OFF_VM_MAP_PMAP, &pmap_raw)) {
        return [log stringByAppendingString:@"FAIL: read vm_map->pmap"];
    }
    uint64_t pmap = mf_unsign(pmap_raw);
    bool pmap_ok = (pmap == mf_unsign(g_k.current_pmap));
    [log appendFormat:@"pmap raw=%#llx unsign=%#llx %s\n",
        (unsigned long long)pmap_raw, (unsigned long long)pmap,
        pmap_ok ? "OK == current_pmap" : "MISMATCH"];

    uint64_t tt = 0;
    if (!k64(pmap + MF_OFF_PMAP_TTE, &tt)) {
        return [log stringByAppendingString:@"FAIL: read pmap->tte"];
    }
    tt = mf_unsign(tt);
    [log appendFormat:@"root table tt=%#llx%s\n", (unsigned long long)tt,
        mf_is_kaddr(tt) ? "" : "  (NOT a kernel pointer)"];
    if (!mf_is_kaddr(tt)) return [log stringByAppendingString:@"FAIL: pmap->tte not a kernel VA"];

    /* 5) end-to-end self test: walk the tables and read our own Mach-O header */
    const uint64_t self_macho = (uint64_t)(uintptr_t)_dyld_get_image_header(0);
    uint32_t magic = 0;
    bool ok = kread_user(tt, self_macho, &magic, sizeof(magic));
    [log appendFormat:@"self Mach-O @ %#llx -> %s %#x\n",
        (unsigned long long)self_macho,
        ok ? "read" : "FAILED",
        ok ? magic : 0];
    if (!ok || magic != 0xfeedfacfU) {
        return [log stringByAppendingString:@"FAIL: page-table walk self-test did not return 0xfeedfacf"];
    }

    json[@"self_proc"] = @(self_proc);
    json[@"proc_ro"] = @(proc_ro);
    json[@"task"] = @(task);
    json[@"vm_map"] = @(map);
    json[@"pmap"] = @(pmap);
    json[@"pmap_tte"] = @(tt);
    json[@"self_macho"] = @(self_macho);
    json[@"ok"] = @YES;

    [log appendString:@"\nRESULT OK\n"
                       "  proc->proc_ro   = 0x18\n"
                       "  proc_ro->task   = 0x08\n"
                       "  task->map       = 0x28\n"
                       "  vm_map->pmap    = 0x40\n"
                       "  pmap->tte       = 0x00\n"
                       "  page-table walk verified (0xfeedfacf)\n"];
    return log;
}

NSString *MFCalibrateRun(NSString *jsonPath)
{
    if (!mf_is_open()) {
        return @"FAIL: kernel not open -- press 'start kernel' first";
    }

    NSMutableDictionary *json = [NSMutableDictionary dictionary];
    NSString *report = nil;

    @try {
        report = run_locked(json);
    } @finally {
        mf_kclose();
        json[@"closed"] = @(!mf_is_open());
    }

    if (jsonPath.length) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:json
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:NULL];
        [d writeToFile:jsonPath atomically:YES];
    }
    return report ?: @"FAIL: unknown";
}
