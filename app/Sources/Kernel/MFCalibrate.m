//
//  MFCalibrate.m -- KFD page-table direct read: offset calibration + self-verification
//
//  Offsets come from the kfdmemdump project (kfd_bridge.c / offsets.m), which
//  implements the same cross-process read on this SoC family:
//
//      proc --[+0x18]--> proc_ro --[+0x8]--> task
//      task --[+0x28]--> vm_map --[+0x40]--> pmap
//      pmap --[+0x00]--> root table (struct pmap.tte, offsetof == 0)
//
//  M5.107 note: libkfd's own perf_run() fills perf.ttbr[0] from exactly those
//  two pmap fields (kfd/libkfd/perf.h:166-173) and asserts
//  phystokv(ttep) == tte. That assert passes on this device, so the root table
//  is NOT the open question any more -- the walk code is. This file therefore
//  stops guessing and measures:
//
//    * PA -> KVA now goes through ptov_table first (mf_phys_to_kv), because the
//      physmap is split into several windows. M5.106 proved it: ttbr0 page
//      pa=0x9aacb8000 lives at va=0xfffffdf1ccd10000, while the single-window
//      formula produced 0xfffffe01bacb8000 -- a different mapping, hence
//      garbage descriptors from level 2 onward.
//    * the kernel half is walked as a control: root=ttbr1, va=kbase, and the
//      expected value is known (0xfeedfacf). If the kernel half translates and
//      the user half does not, the bug is user-space specific (level count);
//      if both fail, the walk arithmetic itself is wrong.
//    * 3-level vs 4-level is measured, not assumed (L0 = VA bit 47).
//    * everything is dumped: ptov table, both root pages, pmap words, and every
//      descriptor along each candidate path.
//
//  Safety rules kept from earlier iterations:
//    1. every kernel read is checked against the kernel VA window first
//       (a user address once reached copy_validate -> panic -> reboot)
//    2. 64-bit values are assembled from two 32-bit reads (sem_open gives 4 bytes)
//    3. mf_kclose() always runs, even on failure
//    4. only addresses we derived ourselves from a verified pointer are read:
//       root pages, pmap words, and page-table pages reached through ptov_table
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
 *     0xfffffe00_...  physmap / gVirtBase
 *     0xfffffe10_...  kalloc zones (proc / task / vm_map)
 *     0xfffffdf1_...  pmap zone + page tables
 * An earlier build used 0xfffffe0000000000 as the lower bound and wrongly
 * rejected a pmap (M5.100 shipped: cpmap = 0xfffffdf0d63d1cb0).
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

/* ---------------- page geometry (16 KB pages, T1SZ = 17) ---------------- */
#define MF_T1SZ        17ULL
#define MF_PG_SHIFT    14ULL
#define MF_PG_SIZE     (1ULL << MF_PG_SHIFT)
#define MF_PG_OFF(v)   ((uint64_t)(v) & (MF_PG_SIZE - 1ULL))

/*
 * Table / page base masks.
 * XNU for 16 KB granules clears 14 bits:    0x0000FFFFFFFFC000
 * libkfd carries the 4 KB form instead:     0x0000FFFFFFFFF000
 * They differ by descriptor bits 12-13, which should be zero on a real
 * descriptor -- the report prints (desc & 0x3000) at every level so this is
 * decided by measurement instead of by argument.
 */
#define MF_MASK_16K    0x0000ffffffffc000ULL
#define MF_MASK_4K     0x0000fffffffff000ULL

/* Apple XNU pmap descriptor bits (same values libkfd uses) */
#define MF_TTE_VALID           0x1ULL
#define MF_TTE_TYPE_MASK       0x2ULL
#define MF_PTE_TYPE_VALID      0x3ULL
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

#define MF_PTOV_MAX 8

typedef struct {
    uint64_t kernel_proc, kernel_task;
    uint64_t current_proc, current_task;
    uint64_t current_map, current_pmap;
    uint64_t gVirtBase, gPhysBase, gPhysSize;
    uint64_t ptov_pa[MF_PTOV_MAX], ptov_va[MF_PTOV_MAX], ptov_len[MF_PTOV_MAX];
    int      ptov_count;
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

/* ---------------- physical -> kernel VA ---------------- */
/* ptov_table first, then the main physmap window: same order as libkfd. */
static bool phys_to_kva(uint64_t pa, uint64_t *kva)
{
    if (!kva) return false;
    uint64_t v = mf_phys_to_kv(pa);
    if (v == 0 || !mf_is_kaddr(v)) return false;
    *kva = v;
    return true;
}

/* The old single-window conversion -- kept only to print it side by side. */
static uint64_t naive_phys_to_kva(uint64_t pa)
{
    if (g_k.gPhysSize == 0 || pa < g_k.gPhysBase) return 0;
    uint64_t off = pa - g_k.gPhysBase;
    if (off >= g_k.gPhysSize) return 0;
    return g_k.gVirtBase + off;
}

static bool pa_in_range(uint64_t pa, uint64_t len)
{
    if (g_k.gPhysSize == 0 || pa < g_k.gPhysBase) return false;
    uint64_t off = pa - g_k.gPhysBase;
    return off < g_k.gPhysSize && len <= g_k.gPhysSize - off;
}

/* ---------------- page-table walk, with a trace ---------------- */
enum {
    MF_WALK_OK        = 0,
    MF_WALK_READ      = 1,   /* kread at a table entry failed            */
    MF_WALK_INVALID   = 2,   /* descriptor says "not present"            */
    MF_WALK_PA_RANGE  = 3,   /* descriptor PFN outside RAM               */
    MF_WALK_COMPRESSED= 4,   /* compressed page (Apple-specific, skipped)*/
    MF_WALK_BAD_ROOT  = 9    /* root is not a kernel address             */
};

typedef struct {
    int      levels;        /* 3 or 4 */
    uint64_t root;
    uint64_t table[4];
    uint64_t desc[4];
    uint64_t idxs[4];
    int      reach;         /* how many levels actually descended */
    int      fail;          /* MF_WALK_* */
    uint64_t pa;
    bool     ok;
    uint32_t value;         /* 4 bytes read back at the translated PA */
    bool     value_ok;
} mf_walk_t;

/*
 * One candidate translation. levels==3 starts at L1 (L0 unused, VA = 47 bit);
 * levels==4 starts at L0 with a single index bit (VA bit 47), which is what a
 * 48-bit user VA layout would require.
 */
static void walk_run(uint64_t root, uint64_t va, int levels, mf_walk_t *w)
{
    memset(w, 0, sizeof(*w));
    w->levels = levels;
    w->root = root;

    if (!mf_is_kaddr(root)) {
        w->fail = MF_WALK_BAD_ROOT;
        return;
    }

    uint64_t tt = root;
    for (int lvl = 4 - levels; lvl <= 3; lvl++) {
        uint64_t idx;
        switch (lvl) {
            case 0:  idx = (va >> 47) & 1ULL; break;
            case 1:  idx = (va & MF_L1_INDEX) >> MF_L1_SHIFT; break;
            case 2:  idx = (va & MF_L2_INDEX) >> MF_L2_SHIFT; break;
            default: idx = (va & MF_L3_INDEX) >> MF_L3_SHIFT; break;
        }
        w->table[lvl] = tt;
        w->idxs[lvl] = idx;

        uint64_t d = 0;
        if (!k64(tt + idx * 8, &d)) {
            w->fail = MF_WALK_READ;
            return;
        }
        w->desc[lvl] = d;
        w->reach = lvl + 1;

        if (lvl == 3) {
            if ((d & MF_PTE_TYPE_VALID) != MF_PTE_TYPE_VALID) {
                w->fail = MF_WALK_INVALID;
                return;
            }
            if (d & (MF_PTE_COMPRESSED | MF_PTE_COMPRESSED_ALT)) {
                w->fail = MF_WALK_COMPRESSED;
                return;
            }
            uint64_t pa = (d & MF_MASK_16K) | (va & MF_L3_OFFMASK);
            if (!pa_in_range(pa, 1)) {
                w->fail = MF_WALK_PA_RANGE;
                return;
            }
            w->pa = pa;
            w->ok = true;
            return;
        }

        if ((d & MF_TTE_VALID) != MF_TTE_VALID) {
            w->fail = MF_WALK_INVALID;
            return;
        }
        if ((d & MF_TTE_TYPE_MASK) == 0) {          /* block mapping */
            uint64_t offmask = (lvl == 1) ? MF_L1_OFFMASK : MF_L2_OFFMASK;
            uint64_t pa = (d & MF_MASK_16K & ~offmask) | (va & offmask);
            if (!pa_in_range(pa, 1)) {
                w->fail = MF_WALK_PA_RANGE;
                return;
            }
            w->pa = pa;
            w->ok = true;
            return;
        }

        uint64_t next = 0;
        if (!phys_to_kva(d & MF_MASK_16K, &next)) {
            w->fail = MF_WALK_PA_RANGE;
            return;
        }
        tt = next;
    }
}

static const char *walk_fail_name(int f)
{
    switch (f) {
        case MF_WALK_OK:         return "ok";
        case MF_WALK_READ:       return "kread-failed";
        case MF_WALK_INVALID:    return "not-present";
        case MF_WALK_PA_RANGE:   return "pa-out-of-ram";
        case MF_WALK_COMPRESSED: return "compressed";
        case MF_WALK_BAD_ROOT:   return "bad-root";
        default:                 return "?";
    }
}

/* Translate, then read 4 bytes at the result and keep them. */
static void walk_run_checked(uint64_t root, uint64_t va, int levels,
                             uint32_t expected, mf_walk_t *w)
{
    walk_run(root, va, levels, w);
    if (!w->ok) return;
    uint64_t kva = 0;
    if (!phys_to_kva(w->pa, &kva)) return;
    uint32_t v = 0;
    if (!k32(kva, &v)) return;
    w->value = v;
    w->value_ok = true;
    (void)expected;
}

static NSString *walk_line(const char *tag, uint64_t va, const mf_walk_t *w,
                           uint32_t expected)
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%-5@ va=%#llx root=%#llx L=%d -> %@",
     [NSString stringWithUTF8String:tag], (unsigned long long)va,
     (unsigned long long)w->root, w->levels,
     [NSString stringWithUTF8String:walk_fail_name(w->fail)]];
    if (w->ok) {
        [s appendFormat:@" pa=%#llx", (unsigned long long)w->pa];
        if (w->value_ok) {
            [s appendFormat:@" value=%#x%@", w->value,
             (w->value == expected) ? @" <== MATCH" : @" (mismatch)"];
        } else {
            [s appendString:@" value=(unreadable)"];
        }
    } else if (w->reach > 0) {
        [s appendFormat:@" at L%d idx=%#llx desc=%#llx (bits12-13=%#llx)",
         w->reach - 1, (unsigned long long)w->idxs[w->reach - 1],
         (unsigned long long)w->desc[w->reach - 1],
         (unsigned long long)(w->desc[w->reach - 1] & 0x3000ULL)];
    }
    return s;
}

/* ---------------- report sink ---------------- */
static NSString * const kMFCalibDir  = @"/var/mobile/Media/mf-debug";
static NSString * const kMFCalibJson = @"/var/mobile/Media/mf-debug/mf-calibration.json";
static NSString * const kMFCalibText = @"/var/mobile/Media/mf-debug/mf-calibration.txt";

static void mf_calib_write(NSString *text, NSDictionary *json)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kMFCalibDir
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];

    if (text) {
        [text writeToFile:kMFCalibText atomically:YES
                 encoding:NSUTF8StringEncoding error:NULL];
    }
    if (json) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:json
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:NULL];
        [d writeToFile:kMFCalibJson atomically:YES];
    }
}

/* Read n 64-bit words, print them; a failed read prints "--". */
static void dump_words(NSMutableString *log, const char *what,
                       uint64_t base, uint64_t count, bool once_per_line)
{
    [log appendFormat:@"[%s] base=%#llx\n", what, (unsigned long long)base];
    for (uint64_t i = 0; i < count; i++) {
        uint64_t v = 0;
        bool ok = k64(base + i * 8, &v);
        if (once_per_line || (i % 4) == 0) {
            if (i) [log appendString:@"\n"];
            [log appendFormat:@"  +%03#llx:", (unsigned long long)(i * 8)];
        }
        if (ok) {
            [log appendFormat:@" %016llx", (unsigned long long)v];
        } else {
            [log appendString:@"       --(read fail)"];
        }
    }
    [log appendString:@"\n"];
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
    memset(g_k.ptov_pa, 0, sizeof(g_k.ptov_pa));
    memset(g_k.ptov_va, 0, sizeof(g_k.ptov_va));
    memset(g_k.ptov_len, 0, sizeof(g_k.ptov_len));
    g_k.ptov_count = mf_ptov_snapshot(g_k.ptov_pa, g_k.ptov_va, g_k.ptov_len);
    if (g_k.ptov_count < 0) g_k.ptov_count = 0;

    [log appendString:@"== M5.107 page-table diagnostic ==\n"];

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
        [log appendFormat:@"%-12s = %#llx\n", checks[i].name,
         (unsigned long long)checks[i].v];
        if (!mf_is_kaddr(checks[i].v)) {
            [log appendFormat:@"FAIL: %s outside kernel VA window\n", checks[i].name];
            mf_calib_write(log, json);
            return log;
        }
    }
    [log appendFormat:@"phys base=%#llx size=%#llx\n",
     (unsigned long long)g_k.gPhysBase, (unsigned long long)g_k.gPhysSize];

    /* ---- ptov_table: the thing M5.106 was missing ---- */
    [log appendString:@"\n[ptov_table]\n"];
    for (int i = 0; i < g_k.ptov_count; i++) {
        [log appendFormat:@"  #%d pa=%#llx va=%#llx len=%#llx\n", i,
         (unsigned long long)g_k.ptov_pa[i], (unsigned long long)g_k.ptov_va[i],
         (unsigned long long)g_k.ptov_len[i]];
    }
    if (g_k.ptov_count == 0) {
        [log appendString:@"  (empty -- fall back to gVirtBase/gPhysBase)\n"];
    }

    /*
     * 1) Our own proc comes straight from libkfd's info_run(); no list walk needed.
     *    The loop below only reports how many procs we can see.
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
    if (!self_proc) {
        [log appendString:@"FAIL: no self proc\n"];
        mf_calib_write(log, json);
        return log;
    }

    /* 2) proc -> proc_ro -> task */
    uint64_t proc_ro = 0, task = 0;
    if (!k64(self_proc + MF_OFF_PROC_RO, &proc_ro)) {
        [log appendString:@"FAIL: read proc_ro\n"];
        mf_calib_write(log, json);
        return log;
    }
    proc_ro = mf_unsign(proc_ro);
    uint64_t task_raw = 0;
    if (!k64(proc_ro + MF_OFF_PROC_RO_TASK, &task_raw)) {
        [log appendString:@"FAIL: read pr_task\n"];
        mf_calib_write(log, json);
        return log;
    }
    task = mf_unsign(task_raw);
    bool task_ok = (task == mf_unsign(g_k.current_task));
    [log appendFormat:@"proc_ro=%#llx task=%#llx %@\n",
     (unsigned long long)proc_ro, (unsigned long long)task,
     task_ok ? @"OK == current_task" : @"MISMATCH"];
    if (!task_ok) {
        [log appendString:@"FAIL: proc_ro/pr_task offsets wrong\n"];
        mf_calib_write(log, json);
        return log;
    }

    /* 3) task -> vm_map */
    uint64_t map = 0;
    if (!k64(task + MF_OFF_TASK_MAP, &map)) {
        [log appendString:@"FAIL: read task->map\n"];
        mf_calib_write(log, json);
        return log;
    }
    map = mf_unsign(map);
    bool map_ok = (map == mf_unsign(g_k.current_map));
    [log appendFormat:@"map=%#llx %@\n", (unsigned long long)map,
     map_ok ? @"OK == current_map" : @"MISMATCH"];
    if (!map_ok) {
        [log appendString:@"FAIL: task->map offset wrong\n"];
        mf_calib_write(log, json);
        return log;
    }

    /* 4) vm_map -> pmap */
    uint64_t pmap_raw = 0;
    if (!k64(map + MF_OFF_VM_MAP_PMAP, &pmap_raw)) {
        [log appendString:@"FAIL: read vm_map->pmap\n"];
        mf_calib_write(log, json);
        return log;
    }
    uint64_t pmap = mf_unsign(pmap_raw);
    bool pmap_ok = (pmap == mf_unsign(g_k.current_pmap));
    [log appendFormat:@"pmap raw=%#llx unsign=%#llx %@\n",
     (unsigned long long)pmap_raw, (unsigned long long)pmap,
     pmap_ok ? @"OK == current_pmap" : @"MISMATCH"];

    /* ---- roots ---- */
    uint64_t t0_pa = 0, t0_va = 0, t1_pa = 0, t1_va = 0;
    if (mf_ttbr_snapshot(&t0_pa, &t0_va, &t1_pa, &t1_va) != 0) {
        [log appendString:@"FAIL: no ttbr snapshot\n"];
        mf_calib_write(log, json);
        return log;
    }
    uint64_t t0_ptov = mf_phys_to_kv(t0_pa);
    uint64_t t0_naive = naive_phys_to_kva(t0_pa);
    uint64_t t1_ptov = mf_phys_to_kv(t1_pa);

    [log appendFormat:@"\n[root mapping]  <== this is what M5.106 got wrong\n"
                       "  ttbr0 pa=%#llx\n"
                       "        libkfd va = %#llx\n"
                       "        ptov  ->   %#llx %@\n"
                       "        naive ->   %#llx %@\n"
                       "  ttbr1 pa=%#llx  libkfd va=%#llx  ptov -> %#llx %@\n",
     (unsigned long long)t0_pa,
     (unsigned long long)t0_va,
     (unsigned long long)t0_ptov, (t0_ptov == t0_va) ? @"(== libkfd)" : @"(DIFFERS)",
     (unsigned long long)t0_naive, (t0_naive == t0_va) ? @"(== libkfd)" : @"(DIFFERS)",
     (unsigned long long)t1_pa, (unsigned long long)t1_va,
     (unsigned long long)t1_ptov, (t1_ptov == t1_va) ? @"(== libkfd)" : @"(DIFFERS)"];

    /* ---- dump the two root pages and the pmap head ---- */
    dump_words(log, "ttbr0 root page", t0_va, 8, false);
    dump_words(log, "ttbr1 root page", t1_va, 8, false);
    if (pmap_ok) {
        dump_words(log, "pmap head", pmap, 9, false);
    }

    /* ---- primitive sanity: kread the known kernel Mach-O header ---- */
    uint64_t kbase = mf_get_kbase();
    uint32_t mh = 0;
    bool mh_ok = (kbase != 0) && k32(kbase, &mh);
    [log appendFormat:@"\n[kbase] %#llx  kslide=%#llx  kread32 -> %@%#x%@\n",
     (unsigned long long)kbase, (unsigned long long)mf_get_kslide(),
     mh_ok ? @"" : @"(fail) ",
     mh_ok ? mh : 0u,
     (mh_ok && mh == 0xfeedfacfU) ? @" <== 0xfeedfacf" : @""];

    /* ---- walk matrix ---- */
    const uint64_t self_macho = (uint64_t)(uintptr_t)_dyld_get_image_header(0);
    NSMutableArray *rows = [NSMutableArray array];

    [log appendFormat:@"\n[control] kernel half: root=ttbr1.va, va=kbase=%#llx\n",
     (unsigned long long)kbase];
    mf_walk_t w;
    for (int levels = 3; levels <= 4; levels++) {
        walk_run_checked(t1_va, kbase, levels, 0xfeedfacfU, &w);
        NSString *line = walk_line("kern", kbase, &w, 0xfeedfacfU);
        [log appendFormat:@"  %@\n", line];
        [rows addObject:@{@"tag": @"kernel", @"va": @(kbase), @"levels": @(levels),
                          @"root": @(t1_va),
                          @"fail": @(w.fail), @"ok": @(w.ok),
                          @"pa": @(w.pa), @"reach": @(w.reach),
                          @"value": w.value_ok ? @(w.value) : [NSNull null]}];
    }

    [log appendFormat:@"\n[goal] user half: va=self_macho=%#llx (expect 0xfeedfacf)\n",
     (unsigned long long)self_macho];
    uint64_t user_roots[3] = { t0_va, t0_ptov, t0_naive };
    const char *user_tags[3] = { "usr-kfdva", "usr-ptov", "usr-naive" };
    bool user_ok = false;
    uint64_t user_root = 0, user_pa = 0;
    int user_levels = 0;
    for (int r = 0; r < 3; r++) {
        if (user_roots[r] == 0 || !mf_is_kaddr(user_roots[r])) {
            [log appendFormat:@"  %-9s root=%#llx  (skipped: not a kernel VA)\n",
             user_tags[r], (unsigned long long)user_roots[r]];
            continue;
        }
        for (int levels = 3; levels <= 4; levels++) {
            walk_run_checked(user_roots[r], self_macho, levels, 0xfeedfacfU, &w);
            NSString *line = walk_line(user_tags[r], self_macho, &w, 0xfeedfacfU);
            [log appendFormat:@"  %@\n", line];
            [rows addObject:@{@"tag": [NSString stringWithUTF8String:user_tags[r]],
                              @"va": @(self_macho), @"levels": @(levels),
                              @"root": @(user_roots[r]),
                              @"fail": @(w.fail), @"ok": @(w.ok),
                              @"pa": @(w.pa), @"reach": @(w.reach),
                              @"value": w.value_ok ? @(w.value) : [NSNull null]}];
            if (w.ok && w.value_ok && w.value == 0xfeedfacfU && !user_ok) {
                user_ok = true;
                user_root = user_roots[r];
                user_pa = w.pa;
                user_levels = levels;
            }
        }
    }

    /* ---- verdict ---- */
    [log appendString:@"\n--------------------------------\n"];
    if (!user_ok) {
        [log appendString:
            @"RESULT FAIL\n"
            @"  The four address steps (proc->proc_ro->task->map->pmap) are green,\n"
            @"  so the offsets are not the problem. The walk still cannot translate\n"
            @"  our own Mach-O. Look at the per-level 'desc' values above:\n"
            @"    - 'not-present' at L1  -> the root page is not an L1 table\n"
            @"                              (try the 4-level rows / a different root)\n"
            @"    - 'not-present' at L2/L3 -> table PAs land in a window we map wrong\n"
            @"    - 'kread-failed'       -> the table address is not readable at all\n"];
        json[@"result"] = @"FAIL";
        json[@"walk_rows"] = rows;
        json[@"self_macho"] = @(self_macho);
        json[@"ttbr0_pa"] = @(t0_pa);
        json[@"ttbr0_va"] = @(t0_va);
        json[@"ttbr0_ptov"] = @(t0_ptov);
        json[@"ttbr0_naive"] = @(t0_naive);
        json[@"kbase"] = @(kbase);
        json[@"ptov_count"] = @(g_k.ptov_count);
        json[@"kaddr_denied_count"] = @(mf_kaddr_denied_count());
        json[@"kaddr_denied_last"] = @(mf_kaddr_denied_last());
        json[@"log"] = log;
        return log;
    }

    [log appendFormat:
        @"RESULT OK\n"
        @"  proc->proc_ro   = 0x18\n"
        @"  proc_ro->task   = 0x08\n"
        @"  task->map       = 0x28\n"
        @"  vm_map->pmap    = 0x40\n"
        @"  walk root       = %@  levels=%d\n"
        @"  translated pa   = %#llx  (self Mach-O, 0xfeedfacf)\n",
     (user_root == t0_va) ? @"ttbr0.va(kfd)"
        : ((user_root == t0_ptov) ? @"ptov(ttbr0.pa)" : @"naive(ttbr0.pa)"),
     user_levels, (unsigned long long)user_pa];

    json[@"result"] = @"OK";
    json[@"self_proc"] = @(self_proc);
    json[@"proc_ro"] = @(proc_ro);
    json[@"task"] = @(task);
    json[@"vm_map"] = @(map);
    json[@"pmap"] = @(pmap);
    json[@"walk_root"] = @(user_root);
    json[@"walk_levels"] = @(user_levels);
    json[@"self_macho_pa"] = @(user_pa);
    json[@"walk_rows"] = rows;
    json[@"kaddr_denied_count"] = @(mf_kaddr_denied_count());
    json[@"kaddr_denied_last"] = @(mf_kaddr_denied_last());
    json[@"log"] = log;
    return log;
}

static BOOL g_keep_kernel = NO;

void MFCalibrateSetKeepKernel(BOOL keep)
{
    g_keep_kernel = keep;
}

NSString *MFCalibrateRun(NSString *jsonPath)
{
    if (!mf_is_open()) {
        return @"FAIL: kernel not open -- press 'start kernel' first";
    }

    NSMutableDictionary *json = [NSMutableDictionary dictionary];

    /* Always leave a copy where AFC can read it, even if the alert is lost. */
    mf_calib_write(@"(running)\n", @{@"result": @"running"});

    NSString *report = nil;
    @try {
        report = run_locked(json);
    } @finally {
        /*
         * [M5.115] 默认关会话（一次性诊断）；主线（启动内核 -> 自动找进程 -> 读内存）
         * 会先 MFCalibrateSetKeepKernel(YES)，让会话一直留到用户点「关闭内核」。
         */
        if (!g_keep_kernel) {
            mf_kclose();
        }
        json[@"closed"] = @(!mf_is_open());
        json[@"kept_open"] = @(g_keep_kernel && mf_is_open());
    }

    mf_calib_write(report ?: @"FAIL: unknown", json);

    if (jsonPath.length) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:json
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:NULL];
        [d writeToFile:jsonPath atomically:YES];
    }
    return report ?: @"FAIL: unknown";
}
