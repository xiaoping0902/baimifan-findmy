//
//  MFChainScan.h -- proc → proc_ro → task → vm_map → pmap 四跳偏移的自适应搜索
//
//  为什么要搜（M5.225）
//  ---------------------------------------------------------------------------
//  这条链在 iPad14,4 / iPadOS 16.1 上是硬编码验证过的：
//      proc + 0x18 → proc_ro
//      proc_ro + 0x08 → task
//      task + 0x28 → vm_map
//      vm_map + 0x40 → pmap
//      pmap + 0x00 → tte（页表根）
//
//  到 iPad8,11 / iPadOS 16.6.1（20G81）上，第 5 跳读 map + 0x40 直接触发断言：
//      [MF][Read] attachKFDPid(282) 失败 rc=-7 读 vm_map+0x40 (pmap) 失败
//
//  为什么前四跳没报错：中间几跳读回来的指针"像"内核地址（高 16 位全 1），
//  mf_addr_guard 的硬闸放行，于是错的值一路传下去，直到踩在野指针上才炸。
//  也就是说 —— 偏移错了的时候，这条链自己没有任何一步能发现。
//
//  这里的做法和 p_pid 的自适应扫描（mf_find_proc_by_pid 里的
//  mf_scan_p_pid_offset）一致：按「离历史默认值多远」的顺序枚举候选组合，
//  每一组都必须通过调用方给的判据才算数。判据不是"看起来像内核地址"，
//  而是"用这个根表能真的读回目标进程的 Mach-O 头 0xfeedfacf"。
//
//  这一层是纯逻辑：没有系统调用、没有内存分配、没有平台依赖。
//  候选顺序、去重、预算截断、提前退出都在这里，可离线回归
//  （tests/hud_chain_scan_regressions.cpp）。
//
//  这个头必须是 **C 兼容**的：MFKernelBridge.m 是 ObjC（不是 ObjC++），
//  不能用模板，所以这里用回调函数指针，不用 C++ 模板。
//
#ifndef MF_CHAIN_SCAN_H
#define MF_CHAIN_SCAN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 四跳偏移。字段顺序 = 沿链走的顺序。 */
typedef struct mfchain_offsets {
    uint32_t proc_ro;   /* proc      -> proc_ro            */
    uint32_t pr_task;   /* proc_ro   -> task               */
    uint32_t task_map;  /* task      -> vm_map             */
    uint32_t map_pmap;  /* vm_map    -> pmap               */
} mfchain_offsets;

/*
 * 候选池。每个数组的 **第 0 项是历史默认值**（iPad14,4 / 16.1 上验证过），
 * 搜索按「离默认值的索引距离」升序进行，所以默认组合永远第一个被尝试，
 * 老设备上等于没有引入任何额外读取。
 *
 * 为什么把 0x00 放进 pr_task 候选：struct proc_ro 的首字段在部分内核版本里
 * 就是 pr_task，偏移 0x00 是同一结构体的另一种布局，不是凭空猜的。
 */
#define MFCHAIN_PROC_RO_COUNT 4
#define MFCHAIN_PR_TASK_COUNT 3
#define MFCHAIN_TASK_MAP_COUNT 4
#define MFCHAIN_MAP_PMAP_COUNT 4

static const uint32_t mfchain_proc_ro_candidates[MFCHAIN_PROC_RO_COUNT] = {0x18u, 0x10u, 0x20u, 0x28u};
static const uint32_t mfchain_pr_task_candidates[MFCHAIN_PR_TASK_COUNT] = {0x08u, 0x00u, 0x10u};
static const uint32_t mfchain_task_map_candidates[MFCHAIN_TASK_MAP_COUNT] = {0x28u, 0x20u, 0x30u, 0x38u};
static const uint32_t mfchain_map_pmap_candidates[MFCHAIN_MAP_PMAP_COUNT] = {0x40u, 0x38u, 0x48u, 0x50u};

#define MFCHAIN_COMBINATIONS ((unsigned)(MFCHAIN_PROC_RO_COUNT * MFCHAIN_PR_TASK_COUNT * \
                                         MFCHAIN_TASK_MAP_COUNT * MFCHAIN_MAP_PMAP_COUNT))

/* 索引距离的最大值：把所有维度都挪到最后一个候选。 */
#define MFCHAIN_MAX_DISTANCE ((int)((MFCHAIN_PROC_RO_COUNT - 1) + (MFCHAIN_PR_TASK_COUNT - 1) + \
                                    (MFCHAIN_TASK_MAP_COUNT - 1) + (MFCHAIN_MAP_PMAP_COUNT - 1)))

static inline mfchain_offsets mfchain_default_offsets(void)
{
    mfchain_offsets o;
    o.proc_ro = mfchain_proc_ro_candidates[0];
    o.pr_task = mfchain_pr_task_candidates[0];
    o.task_map = mfchain_task_map_candidates[0];
    o.map_pmap = mfchain_map_pmap_candidates[0];
    return o;
}

static inline int mfchain_same(const mfchain_offsets *a, const mfchain_offsets *b)
{
    if (a == NULL || b == NULL) return 0;
    return a->proc_ro == b->proc_ro && a->pr_task == b->pr_task &&
           a->task_map == b->task_map && a->map_pmap == b->map_pmap;
}

/*
 * 第 nth 个候选（n < MFCHAIN_COMBINATIONS），顺序与 mfchain_search 完全一致。
 * 只给回归用：校验顺序、唯一性、以及"第一个一定是默认组合"。
 */
static inline int mfchain_candidate_at(unsigned nth, mfchain_offsets *out)
{
    if (out == NULL || nth >= MFCHAIN_COMBINATIONS) return 0;
    unsigned seen = 0;
    int d;
    for (d = 0; d <= MFCHAIN_MAX_DISTANCE; ++d) {
        unsigned a, b, c, e;
        for (a = 0; a < MFCHAIN_PROC_RO_COUNT; ++a) {
            for (b = 0; b < MFCHAIN_PR_TASK_COUNT; ++b) {
                for (c = 0; c < MFCHAIN_TASK_MAP_COUNT; ++c) {
                    for (e = 0; e < MFCHAIN_MAP_PMAP_COUNT; ++e) {
                        if ((int)a + (int)b + (int)c + (int)e != d) continue;
                        if (seen == nth) {
                            out->proc_ro = mfchain_proc_ro_candidates[a];
                            out->pr_task = mfchain_pr_task_candidates[b];
                            out->task_map = mfchain_task_map_candidates[c];
                            out->map_pmap = mfchain_map_pmap_candidates[e];
                            return 1;
                        }
                        ++seen;
                    }
                }
            }
        }
    }
    return 0;
}

/*
 * try_fn：用给定偏移走一遍链路并验证。返回 1 = 这组偏移可用，0 = 不可用。
 * ctx：调用方的上下文（探针结构体，存中间值用于诊断）。
 */
typedef int (*mfchain_try_fn)(void *ctx, const mfchain_offsets *offsets);

typedef struct mfchain_result {
    int found;              /* 1 = 找到可用组合 */
    int budget_exhausted;   /* 1 = 预算用完提前停（found 仍为 0） */
    unsigned attempts;      /* 实际尝试了几组 */
    mfchain_offsets offsets;/* found 时 = 命中的组合；否则 = 默认组合 */
} mfchain_result;

/*
 * 按距离升序搜索。max_attempts = 0 表示不限；> 0 时到预算即停（budget_exhausted = 1）。
 * 找到第一组可用组合立刻返回 —— 老设备上默认组合第一发就中，等价于没有扫描。
 */
static inline mfchain_result mfchain_search(mfchain_try_fn try_fn, void *ctx, unsigned max_attempts)
{
    mfchain_result result;
    result.found = 0;
    result.budget_exhausted = 0;
    result.attempts = 0;
    result.offsets = mfchain_default_offsets();

    if (try_fn == NULL) return result;

    int d;
    for (d = 0; d <= MFCHAIN_MAX_DISTANCE; ++d) {
        unsigned a, b, c, e;
        for (a = 0; a < MFCHAIN_PROC_RO_COUNT; ++a) {
            for (b = 0; b < MFCHAIN_PR_TASK_COUNT; ++b) {
                for (c = 0; c < MFCHAIN_TASK_MAP_COUNT; ++c) {
                    for (e = 0; e < MFCHAIN_MAP_PMAP_COUNT; ++e) {
                        if ((int)a + (int)b + (int)c + (int)e != d) continue;

                        mfchain_offsets probe;
                        probe.proc_ro = mfchain_proc_ro_candidates[a];
                        probe.pr_task = mfchain_pr_task_candidates[b];
                        probe.task_map = mfchain_task_map_candidates[c];
                        probe.map_pmap = mfchain_map_pmap_candidates[e];

                        ++result.attempts;
                        if (try_fn(ctx, &probe)) {
                            result.found = 1;
                            result.offsets = probe;
                            return result;
                        }
                        if (max_attempts != 0 && result.attempts >= max_attempts) {
                            result.budget_exhausted = result.found ? 0 : 1;
                            return result;
                        }
                    }
                }
            }
        }
    }
    return result;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MF_CHAIN_SCAN_H */
