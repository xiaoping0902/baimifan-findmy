#include "../app/Sources/Kernel/MFPageTable.h"
#include "../app/Sources/Kernel/MFKernelBridge.h"
#include <stdio.h>

/*
 * UIKit regression fixtures never initialize a kernel read backend. Keep the
 * production MFReadBackend translation unit linkable without pulling kernel
 * access into simulator tests that intentionally exercise local data only.
 */
int mfpt_translate(uint64_t root, uint64_t va, uint64_t *pa) {
    (void)root;
    (void)va;
    (void)pa;
    return -1;
}

int mfpt_read(uint64_t root, uint64_t va, void *dst, size_t n) {
    (void)root;
    (void)va;
    (void)dst;
    (void)n;
    return -1;
}

int mfpt_read_partial(uint64_t root, uint64_t va, void *dst, size_t n, size_t *got) {
    (void)root;
    (void)va;
    (void)dst;
    (void)n;
    if (got) *got = 0;
    return -3;
}

void mfpt_cache_reset(void) {
}

int mf_pid_chain(int pid, uint64_t *proc, uint64_t *task, uint64_t *map,
                 uint64_t *pmap, uint64_t *root, char *report, size_t report_len) {
    (void)pid;
    (void)proc;
    (void)task;
    (void)map;
    (void)pmap;
    if (root) *root = 0;
    if (report && report_len) {
        snprintf(report, report_len,
                 "kernel access is disabled in UIKit regression fixtures");
    }
    return -1;
}
