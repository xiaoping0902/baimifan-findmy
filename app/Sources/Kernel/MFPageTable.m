//
//  MFPageTable.m -- 3-level 16 KB page-table walk, ptov-aware
//
//  Proven on device by M5.107 (see MFCalibrate.m for the instrument that
//  established it):
//      pmap->tte (offset 0) is the root; 3 levels; mask 0x0000FFFFFFFFC000;
//      PA -> KVA must go through ptov_table first, otherwise every child table
//      lands in the wrong window and the descriptors read as garbage.
//
//  Reads go through mf_kread32 only, so the kernel VA guard in MFKernelBridge
//  still applies to every access.
//
#import "MFPageTable.h"
#import "MFKernelBridge.h"

#include <string.h>

#define MFP_KADDR_MIN   0xffff000000000000ULL
#define MFP_MASK_16K    0x0000ffffffffc000ULL

#define MFP_TTE_VALID       0x1ULL
#define MFP_TTE_TYPE_MASK   0x2ULL
#define MFP_PTE_TYPE_VALID  0x3ULL
#define MFP_PTE_COMPRESSED  0x8000000000000000ULL
#define MFP_PTE_COMP_ALT    0x4000000000000000ULL

#define MFP_L1_OFFMASK  0x0000000fffffffffULL
#define MFP_L1_INDEX    0x00007ff000000000ULL
#define MFP_L2_OFFMASK  0x0000000001ffffffULL
#define MFP_L2_INDEX    0x0000000ffe000000ULL
#define MFP_L3_OFFMASK  0x0000000000003fffULL
#define MFP_L3_INDEX    0x0000000001ffc000ULL

#define MFP_L1_SHIFT  36ULL
#define MFP_L2_SHIFT  25ULL
#define MFP_L3_SHIFT  14ULL

#define MFP_PAGE_SIZE 0x4000ULL
#define MFP_PAGE_OFF(v) ((uint64_t)(v) & (MFP_PAGE_SIZE - 1ULL))

static uint64_t g_mfpt_translated;
static uint64_t g_mfpt_failed;

void mfpt_stats(uint64_t *translated, uint64_t *failed)
{
    if (translated) *translated = g_mfpt_translated;
    if (failed) *failed = g_mfpt_failed;
}

void mfpt_stats_reset(void)
{
    g_mfpt_translated = 0;
    g_mfpt_failed = 0;
}

static int mfp_is_kaddr(uint64_t a)
{
    return a >= MFP_KADDR_MIN;
}

static int mfp_k32(uint64_t a, uint32_t *out)
{
    if (!out || !mfp_is_kaddr(a)) return -1;
    return mf_kread32(a, out);
}

static int mfp_k64(uint64_t a, uint64_t *out)
{
    uint32_t lo = 0, hi = 0;
    if (!out || !mfp_is_kaddr(a)) return -1;
    if (mfp_k32(a, &lo) != 0) return -1;
    if (mfp_k32(a + 4, &hi) != 0) return -1;
    *out = ((uint64_t)hi << 32) | lo;
    return 0;
}

/* ptov_table first, then the main physmap: identical to libkfd's phystokv. */
static int mfp_phys_to_kva(uint64_t pa, uint64_t *kva)
{
    uint64_t v = mf_phys_to_kv(pa);
    if (v == 0 || !mfp_is_kaddr(v)) return -1;
    *kva = v;
    return 0;
}

int mfpt_translate(uint64_t root, uint64_t va, uint64_t *pa)
{
    uint64_t tt = root;
    uint64_t tte = 0;
    uint64_t idx;

    if (!pa) return -2;
    *pa = 0;
    if (!mfp_is_kaddr(root)) return -3;

    idx = (va & MFP_L1_INDEX) >> MFP_L1_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) return -4;
    if ((tte & MFP_TTE_VALID) != MFP_TTE_VALID) return -5;
    if ((tte & MFP_TTE_TYPE_MASK) == 0) {
        *pa = ((tte & MFP_MASK_16K & ~MFP_L1_OFFMASK) | (va & MFP_L1_OFFMASK));
        return 0;
    }
    if (mfp_phys_to_kva(tte & MFP_MASK_16K, &tt) != 0) return -6;

    idx = (va & MFP_L2_INDEX) >> MFP_L2_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) return -7;
    if ((tte & MFP_TTE_VALID) != MFP_TTE_VALID) return -8;
    if ((tte & MFP_TTE_TYPE_MASK) == 0) {
        *pa = ((tte & MFP_MASK_16K & ~MFP_L2_OFFMASK) | (va & MFP_L2_OFFMASK));
        return 0;
    }
    if (mfp_phys_to_kva(tte & MFP_MASK_16K, &tt) != 0) return -9;

    idx = (va & MFP_L3_INDEX) >> MFP_L3_SHIFT;
    if (mfp_k64(tt + idx * 8, &tte) != 0) return -10;
    if ((tte & MFP_PTE_TYPE_VALID) != MFP_PTE_TYPE_VALID) return -11;
    if (tte & (MFP_PTE_COMPRESSED | MFP_PTE_COMP_ALT)) return -12;

    *pa = ((tte & MFP_MASK_16K) | (va & MFP_L3_OFFMASK));
    return 0;
}

int mfpt_probe32(uint64_t root, uint64_t va, uint32_t *out)
{
    uint64_t pa = 0, kva = 0;
    uint32_t v = 0;

    if (!out) return -2;
    if (mfpt_translate(root, va, &pa) != 0) {
        g_mfpt_failed++;
        return -1;
    }
    if (mfp_phys_to_kva(pa, &kva) != 0) {
        g_mfpt_failed++;
        return -1;
    }
    if (mfp_k32(kva, &v) != 0) {
        g_mfpt_failed++;
        return -1;
    }
    g_mfpt_translated++;
    *out = v;
    return 0;
}

/*
 * Lowest present page at or after `start`, read straight out of the target's
 * own L1/L2/L3 tables. Bounded work: we stop at the first present L3 entry, and
 * we never probe (read) an unmapped page.
 */
int mfpt_lowest_mapped_page(uint64_t root, uint64_t start, uint64_t *va_out)
{
    uint64_t i1_first, i2_first;

    if (!va_out || !mfp_is_kaddr(root)) return -2;
    *va_out = 0;

    i1_first = (start & MFP_L1_INDEX) >> MFP_L1_SHIFT;
    i2_first = (start & MFP_L2_INDEX) >> MFP_L2_SHIFT;

    for (uint64_t i1 = i1_first; i1 < i1_first + 8 && i1 < 2048; i1++) {
        uint64_t e1 = 0, l2_kva = 0;
        uint64_t l1_base = i1 << MFP_L1_SHIFT;

        if (mfp_k64(root + i1 * 8, &e1) != 0) continue;
        if ((e1 & MFP_TTE_VALID) != MFP_TTE_VALID) continue;

        if ((e1 & MFP_TTE_TYPE_MASK) == 0) {        /* 64 GB block */
            *va_out = l1_base > start ? l1_base : (start & ~(MFP_PAGE_SIZE - 1ULL));
            return 0;
        }
        if (mfp_phys_to_kva(e1 & MFP_MASK_16K, &l2_kva) != 0) continue;

        uint64_t i2_from = (i1 == i1_first) ? i2_first : 0;
        for (uint64_t i2 = i2_from; i2 < 2048; i2++) {
            uint64_t e2 = 0, l3_kva = 0;
            uint64_t l2_base = l1_base + (i2 << MFP_L2_SHIFT);

            if (mfp_k64(l2_kva + i2 * 8, &e2) != 0) continue;
            if ((e2 & MFP_TTE_VALID) != MFP_TTE_VALID) continue;

            if ((e2 & MFP_TTE_TYPE_MASK) == 0) {    /* 32 MB block */
                *va_out = (i1 == i1_first && i2 == i2_first)
                              ? (start & ~(MFP_PAGE_SIZE - 1ULL))
                              : l2_base;
                return 0;
            }
            if (mfp_phys_to_kva(e2 & MFP_MASK_16K, &l3_kva) != 0) continue;

            for (uint64_t i3 = 0; i3 < 2048; i3++) {
                uint64_t e3 = 0;
                uint64_t page = l2_base + (i3 << MFP_L3_SHIFT);

                if (page < start) continue;
                if (mfp_k64(l3_kva + i3 * 8, &e3) != 0) continue;
                if ((e3 & MFP_PTE_TYPE_VALID) != MFP_PTE_TYPE_VALID) continue;
                if (e3 & (MFP_PTE_COMPRESSED | MFP_PTE_COMP_ALT)) continue;

                *va_out = page;
                return 0;
            }
        }
    }
    return -3;
}

int mfpt_read(uint64_t root, uint64_t va, void *dst, size_t n){

    unsigned char *p = (unsigned char *)dst;
    size_t done = 0;

    if (!dst || n == 0) return -2;

    while (done < n) {
        uint64_t cur = va + done;
        uint64_t page = cur & ~(MFP_PAGE_SIZE - 1ULL);
        uint64_t off = MFP_PAGE_OFF(cur);
        size_t take = (size_t)(MFP_PAGE_SIZE - off);
        uint64_t pa = 0, kva = 0;

        if (take > n - done) take = n - done;
        if (mfpt_translate(root, page, &pa) != 0) {
            g_mfpt_failed++;
            return -3;
        }
        if (mfp_phys_to_kva(pa, &kva) != 0) {
            g_mfpt_failed++;
            return -4;
        }
        /* 4 bytes at a time: that is all the sem_open primitive guarantees. */
        for (size_t i = 0; i < take; i += 4) {
            uint32_t v = 0;
            size_t copy = take - i < 4 ? take - i : 4;
            if (mfp_k32(kva + off + i, &v) != 0) {
                g_mfpt_failed++;
                return -5;
            }
            memcpy(p + done + i, &v, copy);
        }
        g_mfpt_translated++;
        done += take;
    }
    return 0;
}
