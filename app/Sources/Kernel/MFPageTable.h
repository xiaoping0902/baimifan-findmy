//
//  MFPageTable.h -- the page-table walk that M5.107 verified on device
//
//  Three levels (16 KB granule, T1SZ = 17), 16 KB page/table mask, and every
//  physical address resolved through ptov_table first (mf_phys_to_kv).
//
//  M5.107 evidence: root = pmap->tte, walk of our own Mach-O returned
//  0xfeedfacf; the kernel half (ttbr1 + kbase) did too; the single-window
//  conversion failed with kread-failed. So this file is a copy of proven code,
//  not a guess.
//
#ifndef MF_PAGE_TABLE_H
#define MF_PAGE_TABLE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Translate va through root (a kernel VA of the root table). 0 = ok. */
int mfpt_translate(uint64_t root, uint64_t va, uint64_t *pa);

/* Read n bytes from the target address space into dst. 0 = ok, <0 = error. */
int mfpt_read(uint64_t root, uint64_t va, void *dst, size_t n);

/* Read one 32-bit word. 0 = ok. */
int mfpt_probe32(uint64_t root, uint64_t va, uint32_t *out);

/*
 * Lowest present page at or after `start` (searched through the target's own
 * L1/L2/L3 tables, so it costs a bounded number of descriptor reads and never
 * probes unmapped memory). 0 = found, *va_out = page-aligned VA.
 */
int mfpt_lowest_mapped_page(uint64_t root, uint64_t start, uint64_t *va_out);

/* Number of pages translated / failed since the last reset (diagnostics). */
void mfpt_stats(uint64_t *translated, uint64_t *failed);
void mfpt_stats_reset(void);

/* [M5.117] v2p page-cache hit/miss counters, and manual invalidation when the
 * target changes (the cache also invalidates itself whenever root changes). */
void mfpt_cache_stats(uint64_t *hit, uint64_t *miss);
void mfpt_cache_reset(void);

/*
 * [M5.123] Dump the raw descriptors of all three levels for one VA into buf.
 * Returns the walk result code (0 = translated). Pure diagnostics: it does not
 * touch the v2p cache, so it always shows what the tables really say.
 */
int mfpt_walk_trace(uint64_t root, uint64_t va, char *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* MF_PAGE_TABLE_H */
