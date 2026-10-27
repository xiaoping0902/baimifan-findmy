// Portable regression for the runtime chain calibration (MFChainCalib.h).
//
// 背景：proc → task → vm_map → pmap 三跳过去写死在 0x18/0x28/0x40（16.1 验证过），
// 到 16.6.1 上 proc→task 那一跳漂了，读出来的 vm_map 连内核地址都不是。
//
// 这里锁住四件事：
//   1. 由窄到宽：默认布局必须第一发就中被探测，老设备不多付代价；
//   2. 阶段二/三只在前面不成立时才展开，且能命中正确组合；
//   3. 全部不成立时如实报失败，尝试次数有明确上界，不死循环；
//   4. 枚举顺序不重复、阶段边界正确 —— 否则预算和报告都会骗人。
//
// 不需要内核、不需要设备：probe 回调由假读取器提供。
#include <cstdio>
#include <cstring>
#include <set>
#include <tuple>

#include "../app/Sources/Kernel/MFChainCalib.h"

static int failures = 0;
static int checks = 0;

static void Check(bool condition, const char *message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

namespace {

struct Target {
    mfcal_offsets want;
    unsigned calls = 0;
};

int ProbeOnly(void *ctx, const mfcal_offsets *offsets) {
    auto *t = static_cast<Target *>(ctx);
    ++t->calls;
    return mfcal_same(offsets, &t->want) ? 1 : 0;
}

int ProbeNever(void *ctx, const mfcal_offsets *offsets) {
    (void)offsets;
    auto *calls = static_cast<unsigned *>(ctx);
    ++calls[0];
    return 0;
}

mfcal_offsets MakeOffsets(unsigned proc_task, unsigned task_map, unsigned map_pmap) {
    mfcal_offsets o;
    o.proc_task = proc_task;
    o.task_map = task_map;
    o.map_pmap = map_pmap;
    return o;
}

}  // namespace

// 历史默认布局（16.1 上验证过的那套）必须一发命中。
static void TestLegacyFirst() {
    Target t;
    t.want = MakeOffsets(0x18u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "the documented 16.1 layout must be found");
    Check(r.stage == 1, "the legacy layout must be hit during the narrowest stage");
    Check(r.offsets.proc_task == 0x18u, "proc_task must be the legacy 0x18");
    Check(r.offsets.task_map == 0x28u, "task_map must stay at 0x28");
    Check(r.offsets.map_pmap == 0x40u, "map_pmap must stay at 0x40");
    Check(t.calls == r.probed, "probe calls must equal the reported count");
    Check(r.probed == 4u, "0x18 is the fourth candidate, so four probes are expected");
    Check(r.budget_exhausted == 0, "a hit is never a budget stop");

    mfcal_offsets legacy = mfcal_legacy_offsets();
    Check(mfcal_same(&legacy, &t.want), "mfcal_legacy_offsets must describe the same layout");
}

// 第一发就是 0x00（最省）时不能多探。
static void TestFirstProbe() {
    Target t;
    t.want = MakeOffsets(0x00u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "proc_task=0 must be found");
    Check(r.probed == 1u, "the very first candidate is proc_task=0, so exactly one probe");
    Check(t.calls == 1u, "a first-probe hit must not keep probing");
}

// proc→task 落在一个不常见的位置（16.6.1 就是这种）时，阶段一必须覆盖它。
static void TestShiftedProcTask() {
    Target t;
    t.want = MakeOffsets(0x1d8u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "a proc_task far from 0x18 must still be reached in stage 1");
    Check(r.stage == 1, "stage 1 already covers the whole proc range");
    Check(r.offsets.proc_task == 0x1d8u, "the found offset must be the one that worked");
    Check(r.probed == 0x1d8u / 8u + 1u, "probe count must match the candidate position");
}

// pmap 也漂了：阶段二才放开那一跳。
static void TestStage2Pmap() {
    Target t;
    t.want = MakeOffsets(0x18u, 0x28u, 0x48u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "an off-default map_pmap must be found in stage 2");
    Check(r.stage == 2, "map_pmap alternatives belong to stage 2");
    Check(r.offsets.map_pmap == 0x48u, "the found map_pmap must be the one that worked");
    Check(r.probed > MFCAL_STAGE1_COUNT, "stage 2 can only start after every stage 1 candidate failed");
}

// map 那一跳也漂了：阶段三才放开 task 内部扫描。
static void TestStage3TaskMap() {
    Target t;
    t.want = MakeOffsets(0x50u, 0x30u, 0x38u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "a moved task_map must be found in stage 3");
    Check(r.stage == 3, "task_map alternatives belong to stage 3");
    Check(r.offsets.task_map == 0x30u, "the found task_map must be the one that worked");
    Check(r.offsets.map_pmap == 0x38u, "the found map_pmap must be the one that worked");
    Check(r.probed > MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT,
          "stage 3 can only start after stages 1 and 2 are exhausted");
}

// 全部不成立：如实报失败，而且尝试次数正好等于上界。
static void TestNothingWorks() {
    unsigned calls = 0;
    mfcal_result r = mfcal_run(ProbeNever, &calls, 0);

    Check(r.found == 0, "no combination works, so the search must fail");
    Check(r.probed == MFCAL_MAX_PROBES, "failure must come only after every candidate was tried");
    Check(calls == MFCAL_MAX_PROBES, "probe calls must equal the candidate bound");
    Check(r.budget_exhausted == 0, "an unlimited run is never a budget stop");
    Check(r.stage == 0, "a failed run must not claim a stage");

    mfcal_offsets legacy = mfcal_legacy_offsets();
    Check(mfcal_same(&r.offsets, &legacy), "a failed run must still report the legacy layout for diagnostics");
}

// 预算截断：到点就停并标记，不能假装"全试过了"。
static void TestBudget() {
    unsigned calls = 0;
    mfcal_result r = mfcal_run(ProbeNever, &calls, 5);

    Check(r.found == 0, "a truncated run cannot claim success");
    Check(r.probed == 5u, "the budget must stop the run exactly at the limit");
    Check(calls == 5u, "the budget must also bound the probe calls");
    Check(r.budget_exhausted == 1, "a truncated run must be labelled budget-exhausted");

    unsigned one = 0;
    mfcal_result r2 = mfcal_run(ProbeNever, &one, 1);
    Check(r2.probed == 1u && r2.budget_exhausted == 1, "a budget of one must stop after one probe");
}

// 枚举契约：总数、无重复、阶段边界、proc_task 在阶段一内单调。
static void TestEnumeration() {
    std::set<std::tuple<unsigned, unsigned, unsigned>> seen;
    unsigned previous_proc_task = 0;
    bool first = true;

    const unsigned limit = mfcal_total_probes();
    Check(limit == MFCAL_MAX_PROBES, "total probes must match the documented bound");

    for (unsigned i = 0; i < limit; ++i) {
        mfcal_offsets o;
        Check(mfcal_probe_at(i, &o) == 1, "every index below the bound must resolve");

        if (i < MFCAL_STAGE1_COUNT) {
            Check(o.task_map == 0x28u, "stage 1 must keep task_map at the primary value");
            Check(o.map_pmap == 0x40u, "stage 1 must keep map_pmap at the primary value");
            if (!first) {
                Check(o.proc_task > previous_proc_task, "stage 1 must walk proc_task upwards without gaps");
            }
            previous_proc_task = o.proc_task;
            first = false;
        } else if (i < MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT) {
            Check(o.task_map == 0x28u, "stage 2 must keep task_map at the primary value");
            Check(o.map_pmap != 0x40u, "stage 2 must not repeat the pmap value that stage 1 already tried");
        } else {
            Check(o.task_map != 0x28u, "stage 3 must skip the task_map value that stages 1 and 2 already tried");
        }

        auto key = std::make_tuple(static_cast<unsigned>(o.proc_task),
                                   static_cast<unsigned>(o.task_map),
                                   static_cast<unsigned>(o.map_pmap));
        Check(seen.insert(key).second, "the probe order must not contain duplicates");
    }

    Check(seen.size() == limit, "the enumeration must cover exactly the declared bound");

    mfcal_offsets out;
    Check(mfcal_probe_at(limit, &out) == 0, "an out-of-range index must be rejected");
    Check(mfcal_total_probes() == MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT + MFCAL_STAGE3_COUNT,
          "the bound must decompose into the three stages");
    Check(MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT + MFCAL_STAGE3_COUNT == MFCAL_MAX_PROBES,
          "the stage counts must add up to the declared bound");

    mfcal_result null_run = mfcal_run(nullptr, nullptr, 0);
    Check(null_run.found == 0 && null_run.probed == 0, "a null probe must produce an empty result");
}

// 关键候选必须真的在列表里，否则"通用"是假的。
static void TestCoverage() {
    std::set<unsigned> proc_tasks;
    std::set<unsigned> task_maps;
    std::set<unsigned> map_pmaps;
    for (unsigned i = 0; i < mfcal_total_probes(); ++i) {
        mfcal_offsets o;
        mfcal_probe_at(i, &o);
        proc_tasks.insert(o.proc_task);
        task_maps.insert(o.task_map);
        map_pmaps.insert(o.map_pmap);
    }

    Check(proc_tasks.count(0x18u) == 1, "the legacy proc_task 0x18 must be covered");
    Check(proc_tasks.count(0x1d8u) == 1, "deep proc offsets such as 0x1d8 must be covered");
    Check(proc_tasks.size() == MFCAL_PROC_COUNT, "every 8-byte slot in the proc range must be covered");
    Check(task_maps.count(0x28u) == 1, "the documented task_map 0x28 must be covered");
    Check(task_maps.size() == MFCAL_TASK_COUNT, "every 8-byte slot in the task range must be covered");
    Check(map_pmaps.count(0x40u) == 1, "the compiled-in map_pmap 0x40 must be covered");
    Check(map_pmaps.size() >= MFCAL_MAP_PMAP_STAGE2_COUNT, "the pmap alternatives must be covered");
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (std::strcmp(argv[1], "legacy-first") == 0) TestLegacyFirst();
    else if (std::strcmp(argv[1], "first-probe") == 0) TestFirstProbe();
    else if (std::strcmp(argv[1], "shifted-proc-task") == 0) TestShiftedProcTask();
    else if (std::strcmp(argv[1], "stage2-pmap") == 0) TestStage2Pmap();
    else if (std::strcmp(argv[1], "stage3-task-map") == 0) TestStage3TaskMap();
    else if (std::strcmp(argv[1], "nothing-works") == 0) TestNothingWorks();
    else if (std::strcmp(argv[1], "budget") == 0) TestBudget();
    else if (std::strcmp(argv[1], "enumeration") == 0) TestEnumeration();
    else if (std::strcmp(argv[1], "coverage") == 0) TestCoverage();
    else return 2;

    std::printf("%s: chain-calib %s (%d checks)\n", failures ? "FAIL" : "PASS", argv[1], checks);
    return failures ? 1 : 0;
}
