//
//  MFChainCalib.h -- proc → task → vm_map → pmap 的链模型与运行时校准（v2）
//
//  为什么改（M5.229）
//  ---------------------------------------------------------------------------
//  v1 只认识一种链形状：task = *(proc + A)，A 在 0..0x1000 里扫。
//  但这条链在 iOS 15 与 16 上根本不是同一个形状：
//
//      iOS 15（Dopamine info.c 基线）：proc.task    @0x10  → task   （一跳）
//      iOS 16（XNU proc_ro.h）：      proc.p_ro     @0x18  → proc_ro
//                                     proc_ro.pr_task @0x08 → task   （两跳）
//
//  证据：newosxbook / bsd/sys/proc_ro.h（xnu-8792）里 struct proc_ro 的头两个
//  字段就是 `struct proc *pr_proc; struct task *pr_task;`，所以 pr_task 在 +0x08；
//  Dopamine 的 info.c 则是 `proc.task = 0x10` 的 15 基线 + "iOS 16 起内嵌 task
//  被移除"。本工程自己的 MFKernelBridge.h 第 153-155 行也早写下了同一条五跳：
//      proc --[+0x18]--> proc_ro --[+0x08]--> task --[+0x28]--> map --[+0x40]--> pmap
//
//  所以 v1 的 84645 组里，**没有任何一组能表达 16.x 的真实形状**：它把
//  *(proc+0x18) 当成 task，于是下一步读的是 proc_ro+0x28，永远读不到 map。
//  扩窗（0x400 → 0x1000）只是把同一个错误形状试了更多次。
//
//  这一版把「形状」本身作为搜索维度：
//      stage 1：两条有文档依据的链，各打一发（16 先、15 后）
//      stage 2：第二跳/第一跳的邻域变体
//      stage 3：task.map 与 map.pmap 的邻域变体
//      stage 4：宽扫（两跳与一跳各扫一遍 0..0x1000）
//  命中判据仍然只有一条：这组偏移解出的页表根必须能读回 Mach-O 头
//  0xfeedfacf。换句话说，前四组是「按已知事实先验」，最后一组才是「不知道时兜底」；
//  支持范围内的设备应该在第 1~2 发就命中，扫描代价和写死时一样。
//
//  纯逻辑：没有系统调用、没有内存分配、平台无关。真实读取由 probe 回调注入，
//  因此可以在 Windows 上用假读取器完整回归（tests/hud_chain_calib_regressions.cpp）。
//
//  必须是 C 兼容的：MFKernelBridge.m 是 ObjC（不是 ObjC++），不能用模板。
//
#ifndef MF_CHAIN_CALIB_H
#define MF_CHAIN_CALIB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 一次链形状的完整描述。字段顺序 = 沿链走的顺序。 */
typedef struct mfcal_offsets {
    uint32_t proc_hop;    /* 1 = task 内嵌在 proc 里；2 = 中间还有一层 proc_ro  */
    uint32_t proc_task;   /* hop1：proc -> task 或 proc -> proc_ro            */
    uint32_t proc_task2;  /* hop2：proc_ro -> task（hop1 时无意义，填 0）      */
    uint32_t task_map;    /* task   -> vm_map                                */
    uint32_t map_pmap;    /* vm_map -> pmap                                  */
} mfcal_offsets;

/*
 * 探测回调：用给定形状走一遍并验证。返回 1 = 这组可用。
 * 失败的实现必须自己保证"读不到就返回 0"，绝不能把错误的根表当成成功。
 */
typedef int (*mfcal_probe_fn)(void *ctx, const mfcal_offsets *offsets);

typedef struct mfcal_result {
    int found;              /* 1 = 找到可用组合 */
    int budget_exhausted;   /* 1 = 预算用完提前停（found 仍为 0） */
    unsigned probed;        /* 实际探测了多少组 */
    int stage;              /* 命中时：1..4 表示在第几组命中；否则 0 */
    mfcal_offsets offsets;  /* found 时 = 命中的组合；否则 = 文档基线 */
} mfcal_result;

/* ── 有文档依据的两条基线（stage 1 的全部内容）──────────────────── */

/* iOS 16.x：proc -> p_ro @0x18 -> pr_task @0x08 -> map @0x28 -> pmap @0x40 */
static inline mfcal_offsets mfcal_baseline_ios16(void)
{
    mfcal_offsets o;
    o.proc_hop = 2u;
    o.proc_task = 0x18u;
    o.proc_task2 = 0x08u;
    o.task_map = 0x28u;
    o.map_pmap = 0x40u;
    return o;
}

/* iOS 15.x：proc -> task @0x10 -> map @0x28 -> pmap @0x40 */
static inline mfcal_offsets mfcal_baseline_ios15(void)
{
    mfcal_offsets o;
    o.proc_hop = 1u;
    o.proc_task = 0x10u;
    o.proc_task2 = 0u;
    o.task_map = 0x28u;
    o.map_pmap = 0x40u;
    return o;
}

/* 写死时代的默认值：报告里做对照用，也是失败时的"没找到"标注。 */
static inline mfcal_offsets mfcal_legacy_offsets(void)
{
    return mfcal_baseline_ios16();
}

/* ── 邻域变体（stage 2 / stage 3）────────────────────────────────── */

/* 两跳里的第二跳：proc_ro 里 pr_task 之外的邻居（结构变体/对齐不同）。 */
static const uint32_t mfcal_hop2_variants[] = {0x00u, 0x10u, 0x18u, 0x20u, 0x28u};

/*
 * 宽扫用的第二跳候选：把基线 0x08 也放回来。
 * 第 2 组只在"第一跳 = 0x18"这一列试过 0x08；宽扫要覆盖别的第一跳 × 0x08，
 * 否则 "p_ro 不在 0x18、pr_task 在 0x08" 这种最常见的漂移形态永远扫不到。
 */
static const uint32_t mfcal_hop2_sweep[] = {0x08u, 0x00u, 0x10u, 0x18u, 0x20u, 0x28u};

/* 一跳里的 proc.task 邻居（15.x 早期/晚期、A11 前的布局差异）。 */
static const uint32_t mfcal_hop1_variants[] = {0x00u, 0x08u, 0x18u, 0x20u, 0x30u};

/* task.map / vm_map.pmap 的邻居。首项是基线值，stage 3 跳过它。 */
static const uint32_t mfcal_task_map_variants[] = {0x28u, 0x20u, 0x30u, 0x18u, 0x38u};
static const uint32_t mfcal_map_pmap_variants[] = {0x40u, 0x38u, 0x48u, 0x30u, 0x50u};

#define MFCAL_ARR_COUNT(a) ((unsigned)(sizeof(a) / sizeof((a)[0])))

/* ── 宽扫区间（stage 4）──────────────────────────────────────────── */

/*
 * 上界 0x1000：iOS 16 起 proc.task 内嵌字段被移除，task 挪到 proc 之后；
 * 16.6.1 实测 0x000–0x400 没有可用的 task 指针（M5.227 全扫失败）。
 * 一个 513 候选的区间全扫也就几百毫秒，没必要为省这点时间把覆盖赌掉。
 *
 * 宽扫把"第一跳 × 第二跳"都放开：只扫第一跳的话，"p_ro 不在 0x18 且
 * pr_task 不在 0x08"这种组合永远扫不到 —— 而那正是"换台设备就漂"的形态。
 * 代价：513×6 ≈ 3k 发，按 M5.227 实测 21285 发 99 ms 折算约 16 ms。
 */
#define MFCAL_SWEEP_FIRST 0x0000u
#define MFCAL_SWEEP_LAST  0x1000u
#define MFCAL_SWEEP_STEP  8u

/* ── 组数（互不重叠是硬约束，回归里逐项校验）────────────────────── */

#define MFCAL_STAGE1_COUNT 2u
#define MFCAL_STAGE2_COUNT (MFCAL_ARR_COUNT(mfcal_hop2_variants) + MFCAL_ARR_COUNT(mfcal_hop1_variants))
#define MFCAL_STAGE3_COUNT ((MFCAL_ARR_COUNT(mfcal_task_map_variants) - 1u) * 2u + \
                            (MFCAL_ARR_COUNT(mfcal_map_pmap_variants) - 1u) * 2u)

/* 宽扫基数：0x1000/8 + 1 */
#define MFCAL_SWEEP_COUNT ((unsigned)((MFCAL_SWEEP_LAST - MFCAL_SWEEP_FIRST) / MFCAL_SWEEP_STEP + 1u))
/* 两跳宽扫 = 第一跳（跳过 0x18）× 第二跳全部候选。 */
#define MFCAL_SWEEP_SKIP_HOP2 1u
/* 一跳宽扫要跳掉的值：0x10（第 1 组）+ 0x00/0x08/0x18/0x20/0x30（第 2 组）。 */
#define MFCAL_SWEEP_SKIP_HOP1 6u
#define MFCAL_STAGE4_COUNT (((MFCAL_SWEEP_COUNT - MFCAL_SWEEP_SKIP_HOP2) * \
                             MFCAL_ARR_COUNT(mfcal_hop2_sweep)) + \
                            (MFCAL_SWEEP_COUNT - MFCAL_SWEEP_SKIP_HOP1))

#define MFCAL_MAX_PROBES ((unsigned)(MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT + \
                                     MFCAL_STAGE3_COUNT + MFCAL_STAGE4_COUNT))

static inline int mfcal_same(const mfcal_offsets *a, const mfcal_offsets *b)
{
    if (a == NULL || b == NULL) return 0;
    return a->proc_hop == b->proc_hop && a->proc_task == b->proc_task &&
           a->proc_task2 == b->proc_task2 && a->task_map == b->task_map &&
           a->map_pmap == b->map_pmap;
}

/*
 * 宽扫里要跳掉的第一跳值：0x10（第 1 组的 15 基线）+ 第 2 组的五个邻居。
 * 两跳那一侧不按值判断，而是整列跳过 0x18（见 stage 4 的索引重排），
 * 所以这里只需要一跳侧的判据。
 */
static inline int mfcal_sweep_skip_hop1(uint32_t proc_task)
{
    if (proc_task == 0x10u) return 1;
    for (unsigned i = 0; i < MFCAL_ARR_COUNT(mfcal_hop1_variants); ++i) {
        if (mfcal_hop1_variants[i] == proc_task) return 1;
    }
    return 0;
}

/* ── 迭代器：顺序、去重、边界全部集中在这里 ─────────────────────── */

typedef struct mfcal_iter {
    unsigned stage;   /* 1..4；0 = 还没开始 */
    unsigned index;   /* 组内序号 */
} mfcal_iter;

static inline void mfcal_iter_reset(mfcal_iter *it)
{
    if (it == NULL) return;
    it->stage = 1u;
    it->index = 0u;
}

/* 取下一组；返回 0 表示枚举结束。 */
static inline int mfcal_iter_next(mfcal_iter *it, mfcal_offsets *out)
{
    if (it == NULL || out == NULL) return 0;

    for (;;) {
        switch (it->stage) {
        case 1u:
            if (it->index == 0u) {
                *out = mfcal_baseline_ios16();
            } else if (it->index == 1u) {
                *out = mfcal_baseline_ios15();
            } else {
                it->stage = 2u;
                it->index = 0u;
                continue;
            }
            ++it->index;
            return 1;

        case 2u: {
            const unsigned hop2_n = MFCAL_ARR_COUNT(mfcal_hop2_variants);
            const unsigned hop1_n = MFCAL_ARR_COUNT(mfcal_hop1_variants);
            if (it->index < hop2_n) {
                /* 第二跳的邻居：第一跳固定在 0x18（16.x 的 p_ro）。
                 * 基线 0x08 不在这个表里，所以不会和第 1 组重复。 */
                *out = mfcal_baseline_ios16();
                out->proc_task2 = mfcal_hop2_variants[it->index];
                ++it->index;
                return 1;
            }
            if (it->index < hop2_n + hop1_n) {
                /* 第一跳的邻居：一跳形状（15.x 的内嵌 task）。
                 * 同理，基线 0x10 不在这个表里。 */
                *out = mfcal_baseline_ios15();
                out->proc_task = mfcal_hop1_variants[it->index - hop2_n];
                ++it->index;
                return 1;
            }
            it->stage = 3u;
            it->index = 0u;
            continue;
        }

        case 3u: {
            const unsigned map_n = MFCAL_ARR_COUNT(mfcal_task_map_variants);
            const unsigned pmap_n = MFCAL_ARR_COUNT(mfcal_map_pmap_variants);
            const unsigned per = (map_n - 1u) * 2u;       /* 每条基线 4 个 map 变体 */
            if (it->index < per) {
                unsigned shape = it->index % 2u;
                unsigned variant = it->index / 2u + 1u;   /* 跳过 0x28 */
                *out = shape == 0u ? mfcal_baseline_ios16() : mfcal_baseline_ios15();
                out->task_map = mfcal_task_map_variants[variant];
                ++it->index;
                return 1;
            }
            if (it->index < per + (pmap_n - 1u) * 2u) {
                unsigned rel = it->index - per;
                unsigned shape = rel % 2u;
                unsigned variant = rel / 2u + 1u;         /* 跳过 0x40 */
                *out = shape == 0u ? mfcal_baseline_ios16() : mfcal_baseline_ios15();
                out->map_pmap = mfcal_map_pmap_variants[variant];
                ++it->index;
                return 1;
            }
            it->stage = 4u;
            it->index = 0u;
            continue;
        }

        case 4u: {
            const unsigned sweep = MFCAL_SWEEP_COUNT;
            const unsigned hop2_b = MFCAL_ARR_COUNT(mfcal_hop2_sweep);
            const unsigned hop2_total = (sweep - MFCAL_SWEEP_SKIP_HOP2) * hop2_b;

            if (it->index < hop2_total) {
                /* 两跳：第一跳 × 第二跳都放开。
                 * 第一跳跳过 0x18（前三组已经把那一列试遍了），
                 * 所以索引 0..(sweep-2) 映射到 0、8、0x10、0x20、…、0x1000。 */
                unsigned a_idx = it->index / hop2_b;
                unsigned b_idx = it->index % hop2_b;
                uint32_t a = MFCAL_SWEEP_FIRST + a_idx * MFCAL_SWEEP_STEP;
                if (a >= 0x18u) a += MFCAL_SWEEP_STEP;
                ++it->index;
                *out = mfcal_baseline_ios16();
                out->proc_task = a;
                out->proc_task2 = mfcal_hop2_sweep[b_idx];
                return 1;
            }

            /* 一跳：内嵌 task 的宽扫，跳过第 1、2 组已经试过的值。 */
            unsigned p = it->index - hop2_total;
            uint32_t proc_task = 0;
            for (;;) {
                if (p >= sweep) {
                    it->stage = 0u;
                    return 0;
                }
                proc_task = MFCAL_SWEEP_FIRST + p * MFCAL_SWEEP_STEP;
                ++p;
                if (!mfcal_sweep_skip_hop1(proc_task)) break;
            }
            it->index = hop2_total + p;
            *out = mfcal_baseline_ios15();
            out->proc_task = proc_task;
            return 1;
        }

        default:
            return 0;
        }
    }
}

/* 第 nth 个会被探测的组合（n < mfcal_total_probes），顺序与 mfcal_run 完全一致。 */
static inline unsigned mfcal_total_probes(void)
{
    return MFCAL_MAX_PROBES;
}

static inline int mfcal_probe_at(unsigned nth, mfcal_offsets *out)
{
    if (out == NULL || nth >= mfcal_total_probes()) return 0;
    mfcal_iter it;
    mfcal_iter_reset(&it);
    for (unsigned i = 0;; ++i) {
        if (!mfcal_iter_next(&it, out)) return 0;
        if (i == nth) return 1;
    }
}

/*
 * 按「已知形状 → 邻域 → 宽扫」跑完，命中立刻返回。
 * max_probes = 0 表示用 MFCAL_MAX_PROBES 作为上界。
 */
static inline mfcal_result mfcal_run(mfcal_probe_fn probe, void *ctx, unsigned max_probes)
{
    mfcal_result result;
    result.found = 0;
    result.budget_exhausted = 0;
    result.probed = 0;
    result.stage = 0;
    result.offsets = mfcal_legacy_offsets();
    if (probe == NULL) return result;
    if (max_probes == 0u || max_probes > MFCAL_MAX_PROBES) max_probes = MFCAL_MAX_PROBES;

    mfcal_iter it;
    mfcal_iter_reset(&it);

    for (;;) {
        mfcal_offsets candidate;
        if (!mfcal_iter_next(&it, &candidate)) break;      /* 枚举结束：不是预算停 */

        if (result.probed >= max_probes) {
            result.budget_exhausted = 1;
            result.stage = 0;
            return result;
        }

        /* 迭代器只在该组的第一发之前推进 stage，所以取到的就是这一发所属组。 */
        result.stage = (int)it.stage;
        ++result.probed;
        if (probe(ctx, &candidate)) {
            result.found = 1;
            result.offsets = candidate;
            return result;
        }
    }

    result.stage = 0;
    result.budget_exhausted = 0;
    return result;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MF_CHAIN_CALIB_H */
