//
//  MFChainCalib.h -- proc → task → vm_map → pmap 三跳偏移的运行时校准
//
//  为什么需要它（M5.226）
//  ---------------------------------------------------------------------------
//  这三跳过去是写死的：proc+0x18 → proc_ro+0x08 → task+0x28 → map+0x40。
//  那套值在 iPad14,4 / iPadOS 16.1 上验证过，到 iPad8,11 / 16.6.1（20G81）
//  上就断了：
//      ro=0xffffffdd393eb700  task=0xffffffdfe9d86c80  map=0xffffeddcec69b400
//  map 那个值连内核地址都不是（内核 VA 从 0xfffffe0000000000 起），说明
//  "task + 0x28" 拿到的根本不是 vm_map —— 错的是 **proc → task** 这一跳。
//
//  社区实现（Dopamine 的 info.c）也印证了这一点：
//      iOS 15 基线：proc.task = 0x10，task.map = 0x28
//      iOS 16+    ：proc.task 字段被移除（task 改走 proc_ro），task.map 仍是 0x28
//  也就是说，随版本漂的是 proc 里的那一跳，以及可能还有后面的两跳。
//
//  所以这里不做「版本 → 偏移表」，改做「扫描 + 验证 + 缓存」：
//      1. 锚点用 kernel_proc（从 kernproc 符号直接取，可信）与 kernelbase；
//      2. 在 proc 里按区间扫 task 指针，不预设 proc_ro 在哪一跳；
//      3. 判据是硬的：这组偏移解出的页表根，必须能读回 kernelbase 的 Mach-O 头
//         （0xfeedfacf）—— 野指针编不出这个；
//      4. 命中即缓存，同一内核下所有进程通用。
//
//  搜索分三阶段，由窄到宽：绝大多数设备在第一阶段第一发就命中，
//  付的代价和写死时一样；只有前两阶段都不成立时才展开最贵的那一层。
//
//  这个头是纯逻辑：没有系统调用、没有内存分配、平台无关。
//  真实读取与页表验证由调用方通过 probe 回调注入，因此可以在 Windows 上
//  用假读取器完整回归（tests/hud_chain_calib_regressions.cpp）。
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

/* 三跳偏移。字段顺序 = 沿链走的顺序。 */
typedef struct mfcal_offsets {
    uint32_t proc_task;  /* proc    -> task     */
    uint32_t task_map;   /* task    -> vm_map   */
    uint32_t map_pmap;   /* vm_map  -> pmap     */
} mfcal_offsets;

/*
 * 探测回调：用给定偏移走一遍并验证。返回 1 = 这组可用。
 * 失败的实现必须自己保证"读不到就返回 0"，绝不能把错误的根表当成成功。
 */
typedef int (*mfcal_probe_fn)(void *ctx, const mfcal_offsets *offsets);

typedef struct mfcal_result {
    int found;              /* 1 = 找到可用组合 */
    int budget_exhausted;   /* 1 = 预算用完提前停（found 仍为 0） */
    unsigned probed;        /* 实际探测了多少组 */
    int stage;              /* 命中时：1/2/3 表示在第几阶段命中；否则 0 */
    mfcal_offsets offsets;  /* found 时 = 命中的组合 */
} mfcal_result;

/* ── 候选范围（集中在这里，方便一处调整）────────────────────────── */

/* proc 里找 task 指针：0x00 到 0x400，步长 8。 */
#define MFCAL_PROC_FIRST 0x000u
#define MFCAL_PROC_LAST 0x400u
#define MFCAL_PROC_STEP 8u

/* 阶段一：唯一假设 —— task.map=0x28、map.pmap=0x40（社区与上游共识值）。 */
#define MFCAL_TASK_MAP_PRIMARY 0x28u
#define MFCAL_MAP_PMAP_PRIMARY 0x40u

/* 阶段二：pmap 也漂了的情况，只放开 pmap 那一跳。
 * 首项 0x40 就是阶段一已经试过的那个值，因此阶段二从索引 1 开始，避免重复探测。 */
static const uint32_t mfcal_map_pmap_stage2[] = {0x40u, 0x38u, 0x48u, 0x30u, 0x50u};
#define MFCAL_MAP_PMAP_STAGE2_COUNT ((unsigned)(sizeof(mfcal_map_pmap_stage2) / sizeof(mfcal_map_pmap_stage2[0])))

/* 阶段三：map 那一跳也漂了，放开 task 内部扫描。
 * task_map=0x28 已经在阶段一/二试过，阶段三跳过它，否则同一组合会被探两次。 */
#define MFCAL_TASK_FIRST 0x000u
#define MFCAL_TASK_LAST 0x100u
#define MFCAL_TASK_STEP 8u

static const uint32_t mfcal_map_pmap_stage3[] = {0x40u, 0x38u, 0x48u, 0x30u, 0x50u};
#define MFCAL_MAP_PMAP_STAGE3_COUNT ((unsigned)(sizeof(mfcal_map_pmap_stage3) / sizeof(mfcal_map_pmap_stage3[0])))

/* ── 三阶段的组数：互不重叠是硬约束（回归里逐项校验）────────────── */

/* proc 区间内的候选数。 */
#define MFCAL_PROC_COUNT ((unsigned)((MFCAL_PROC_LAST - MFCAL_PROC_FIRST) / MFCAL_PROC_STEP + 1u))
/* task 区间内的候选数。 */
#define MFCAL_TASK_COUNT ((unsigned)((MFCAL_TASK_LAST - MFCAL_TASK_FIRST) / MFCAL_TASK_STEP + 1u))

/* 阶段一：task_map 与 map_pmap 都用主值。 */
#define MFCAL_STAGE1_COUNT (MFCAL_PROC_COUNT)
/* 阶段二：task_map 仍是主值，pmap 走其余候选（跳过首项 0x40）。 */
#define MFCAL_STAGE2_COUNT (MFCAL_PROC_COUNT * (MFCAL_MAP_PMAP_STAGE2_COUNT - 1u))
/* 阶段三：task_map 走其余候选（跳过 0x28），pmap 走全部候选。 */
#define MFCAL_STAGE3_COUNT (MFCAL_PROC_COUNT * (MFCAL_TASK_COUNT - 1u) * MFCAL_MAP_PMAP_STAGE3_COUNT)

#define MFCAL_MAX_PROBES ((unsigned)(MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT + MFCAL_STAGE3_COUNT))

/* 写死时的历史默认值，仅供报告里做对照。 */
static inline mfcal_offsets mfcal_legacy_offsets(void)
{
    mfcal_offsets o;
    o.proc_task = 0x18u; /* 16.1 上 proc+0x18 是 p_ro，再 +0x08 是 pr_task */
    o.task_map = MFCAL_TASK_MAP_PRIMARY;
    o.map_pmap = MFCAL_MAP_PMAP_PRIMARY;
    return o;
}

static inline int mfcal_same(const mfcal_offsets *a, const mfcal_offsets *b)
{
    if (a == NULL || b == NULL) return 0;
    return a->proc_task == b->proc_task && a->task_map == b->task_map &&
           a->map_pmap == b->map_pmap;
}

/*
 * 第 nth 个会被探测的组合（n < mfcal_total_probes），顺序与 mfcal_run 完全一致。
 * 只给回归用：校验顺序、唯一性、阶段边界。
 */
static inline unsigned mfcal_total_probes(void)
{
    return MFCAL_MAX_PROBES;
}

static inline int mfcal_probe_at(unsigned nth, mfcal_offsets *out)
{
    if (out == NULL || nth >= MFCAL_MAX_PROBES) return 0;

    /* 阶段一：task_map=主值，map_pmap=主值 */
    if (nth < MFCAL_STAGE1_COUNT) {
        out->proc_task = MFCAL_PROC_FIRST + nth * MFCAL_PROC_STEP;
        out->task_map = MFCAL_TASK_MAP_PRIMARY;
        out->map_pmap = MFCAL_MAP_PMAP_PRIMARY;
        return 1;
    }
    nth -= MFCAL_STAGE1_COUNT;

    /* 阶段二：task_map 仍是主值，pmap 从索引 1 起（跳过阶段一用过的 0x40） */
    if (nth < MFCAL_STAGE2_COUNT) {
        unsigned per_proc = MFCAL_MAP_PMAP_STAGE2_COUNT - 1u;
        unsigned proc_idx = nth / per_proc;
        unsigned pmap_idx = nth % per_proc + 1u;
        out->proc_task = MFCAL_PROC_FIRST + proc_idx * MFCAL_PROC_STEP;
        out->task_map = MFCAL_TASK_MAP_PRIMARY;
        out->map_pmap = mfcal_map_pmap_stage2[pmap_idx];
        return 1;
    }
    nth -= MFCAL_STAGE2_COUNT;

    /* 阶段三：task_map 跳过主值，pmap 走全部候选 */
    {
        unsigned per_proc = (MFCAL_TASK_COUNT - 1u) * MFCAL_MAP_PMAP_STAGE3_COUNT;
        unsigned proc_idx = nth / per_proc;
        unsigned rest = nth % per_proc;
        unsigned task_idx = rest / MFCAL_MAP_PMAP_STAGE3_COUNT;
        unsigned pmap_idx = rest % MFCAL_MAP_PMAP_STAGE3_COUNT;
        /* task_map=0x28 在列表里的位置：跳过它，保证与阶段一/二不重叠 */
        unsigned primary_task_idx = MFCAL_TASK_MAP_PRIMARY / MFCAL_TASK_STEP;
        if (task_idx >= primary_task_idx) task_idx += 1u;
        out->proc_task = MFCAL_PROC_FIRST + proc_idx * MFCAL_PROC_STEP;
        out->task_map = MFCAL_TASK_FIRST + task_idx * MFCAL_TASK_STEP;
        out->map_pmap = mfcal_map_pmap_stage3[pmap_idx];
        return 1;
    }
}

/*
 * 按「由窄到宽」跑完三个阶段，命中立刻返回。
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

    const unsigned limit = mfcal_total_probes();

    for (unsigned nth = 0; nth < limit; ++nth) {
        if (result.probed >= max_probes) {
            result.budget_exhausted = 1;
            return result;
        }

        mfcal_offsets candidate;
        if (!mfcal_probe_at(nth, &candidate)) break;

        /* 阶段标记只用于报告：阶段一只动 proc 那一跳；阶段二再动 pmap；
         * 阶段三连 task.map 也放开。 */
        if (nth < MFCAL_STAGE1_COUNT) {
            result.stage = 1;
        } else if (nth < MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT) {
            result.stage = 2;
        } else {
            result.stage = 3;
        }

        ++result.probed;
        if (probe(ctx, &candidate)) {
            result.found = 1;
            result.offsets = candidate;
            return result;
        }
    }

    result.stage = 0;
    return result;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MF_CHAIN_CALIB_H */
