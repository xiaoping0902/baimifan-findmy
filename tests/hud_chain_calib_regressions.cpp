// Portable regression for the runtime chain calibration (MFChainCalib.h v2).
//
// 背景（M5.227 → M5.229）：
//   v1 只认识一种链形状 —— task = *(proc + A)，A 在 0..0x1000 里扫。
//   但 iOS 15 与 16 的链形状不同：
//       15：proc.task @0x10          → task          （一跳）
//       16：proc.p_ro @0x18 → pr_task @0x08 → task   （两跳，xnu proc_ro.h）
//   所以 v1 的 84645 组里没有一组能表达 16.x 的真实形状，扩窗只是把错误的形状
//   多试了几千次。v2 把"形状"本身作为搜索维度，并把它锁在回归里。
//
// 这里锁住六件事：
//   1. 两条有文档依据的链分别在**第 1 / 第 2 发**命中（支持范围内不付扫描代价）；
//   2. 形状/邻域/宽扫四组各能命中，且组号如实上报；
//   3. 全部不成立时如实报失败，尝试次数正好等于上界；
//   4. 枚举无重复，且宽扫覆盖 0..0x1000 的每个 8 字节槽位（被前面组覆盖过的除外）；
//   5. 迭代器顺序 == mfcal_run 的探测顺序（否则预算与报告都会骗人）；
//   6. 编译期的组数常量与迭代器实际产出必须一致。
//
// 不需要内核、不需要设备：probe 回调由假读取器提供。
#include <cstdio>
#include <cstring>
#include <set>
#include <tuple>
#include <vector>

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

int ProbeRecord(void *ctx, const mfcal_offsets *offsets) {
    auto *seen = static_cast<std::vector<mfcal_offsets> *>(ctx);
    seen->push_back(*offsets);
    return 0;
}

mfcal_offsets Make(unsigned hop, unsigned proc_task, unsigned proc_task2,
                   unsigned task_map, unsigned map_pmap) {
    mfcal_offsets o;
    o.proc_hop = hop;
    o.proc_task = proc_task;
    o.proc_task2 = proc_task2;
    o.task_map = task_map;
    o.map_pmap = map_pmap;
    return o;
}

}  // namespace

// iOS 16 的文档链必须第一发命中：支持范围内不该为"扫描"付钱。
static void TestDocumentedIos16() {
    Target t;
    t.want = Make(2u, 0x18u, 0x08u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "the documented iOS 16 chain must be found");
    Check(r.stage == 1, "the documented iOS 16 chain belongs to the first group");
    Check(r.probed == 1u, "it must be the very first candidate");
    Check(t.calls == 1u, "a first-probe hit must not keep probing");
    Check(r.offsets.proc_hop == 2u, "the hit must keep the two-hop shape");
    Check(r.offsets.proc_task2 == 0x08u, "pr_task must be read at proc_ro+0x08");
    Check(mfcal_same(&r.offsets, &t.want), "the reported layout must be the one that worked");
    mfcal_offsets baseline = mfcal_legacy_offsets();
    Check(mfcal_same(&baseline, &t.want),
          "mfcal_legacy_offsets must now describe the two-hop baseline");
}

// iOS 15 的内嵌链必须第二发命中 —— 形状差异不能靠"扫得更宽"来兜。
static void TestDocumentedIos15() {
    Target t;
    t.want = Make(1u, 0x10u, 0x00u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "the documented iOS 15 chain must be found");
    Check(r.stage == 1, "the iOS 15 baseline is part of the first group");
    Check(r.probed == 2u, "it must be the second candidate, not a sweep result");
    Check(r.offsets.proc_hop == 1u, "the hit must keep the one-hop shape");
    Check(r.offsets.proc_task == 0x10u, "proc.task must be read at 0x10");
}

// 第二跳漂了（pr_task 不在 +0x08）：第二组放开。
static void TestSecondHopVariant() {
    Target t;
    t.want = Make(2u, 0x18u, 0x10u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "an off-default pr_task offset must be found");
    Check(r.stage == 2, "second-hop alternatives belong to the second group");
    Check(r.offsets.proc_task2 == 0x10u, "the found second hop must be the one that worked");
    Check(r.probed > MFCAL_STAGE1_COUNT, "group 2 can only start after group 1 is exhausted");
}

// task.map 漂了：第三组。
static void TestTaskMapMoved() {
    Target t;
    t.want = Make(2u, 0x18u, 0x08u, 0x30u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "a moved task_map must be found");
    Check(r.stage == 3, "task_map alternatives belong to the third group");
    Check(r.offsets.task_map == 0x30u, "the found task_map must be the one that worked");
}

// pmap 漂了（且是 15 内嵌形状）：第三组。
static void TestPmapMoved() {
    Target t;
    t.want = Make(1u, 0x10u, 0x00u, 0x28u, 0x38u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "an off-default map_pmap must be found");
    Check(r.stage == 3, "map_pmap alternatives belong to the third group");
    Check(r.offsets.map_pmap == 0x38u, "the found map_pmap must be the one that worked");
}

// 完全不在先验里：宽扫兜底（两跳）。
static void TestSweepTwoHop() {
    Target t;
    t.want = Make(2u, 0x1f8u, 0x08u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "a far-away proc offset must be reached by the two-hop sweep");
    Check(r.stage == 4, "the wide sweep is the fourth group");
    Check(r.offsets.proc_task == 0x1f8u, "the found offset must be the one that worked");
    Check(r.probed > MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT + MFCAL_STAGE3_COUNT,
          "group 4 can only start after groups 1-3 are exhausted");
}

// 完全不在先验里：宽扫兜底（一跳）。
static void TestSweepOneHop() {
    Target t;
    t.want = Make(1u, 0x2a0u, 0x00u, 0x28u, 0x40u);
    mfcal_result r = mfcal_run(ProbeOnly, &t, 0);

    Check(r.found == 1, "a far-away inline task must be reached by the one-hop sweep");
    Check(r.stage == 4, "the wide sweep is the fourth group");
    Check(r.offsets.proc_task == 0x2a0u, "the found offset must be the one that worked");
}

// 全部不成立：如实报失败，尝试次数正好等于上界。
static void TestNothingWorks() {
    unsigned calls = 0;
    mfcal_result r = mfcal_run(ProbeNever, &calls, 0);

    Check(r.found == 0, "no combination works, so the search must fail");
    Check(r.probed == MFCAL_MAX_PROBES, "failure must come only after every candidate was tried");
    Check(calls == MFCAL_MAX_PROBES, "probe calls must equal the candidate bound");
    Check(r.budget_exhausted == 0, "an unlimited run is never a budget stop");
    Check(r.stage == 0, "a failed run must not claim a stage");
    mfcal_offsets baseline = mfcal_legacy_offsets();
    Check(mfcal_same(&r.offsets, &baseline),
          "a failed run must still report the baseline for diagnostics");
}

// 预算截断：到点就停并标记，不能假装"全试过了"。
static void TestBudget() {
    unsigned calls = 0;
    mfcal_result r = mfcal_run(ProbeNever, &calls, 5);

    Check(r.found == 0, "a truncated run cannot claim success");
    Check(r.probed == 5u, "the budget must stop the run exactly at the limit");
    Check(calls == 5u, "the budget must also bound the probe calls");
    Check(r.budget_exhausted == 1, "a truncated run must be labelled budget-exhausted");
    Check(r.stage == 0, "a truncated run must not claim a stage");

    unsigned one = 0;
    mfcal_result r2 = mfcal_run(ProbeNever, &one, 1);
    Check(r2.probed == 1u && r2.budget_exhausted == 1, "a budget of one must stop after one probe");
}

// 枚举契约：总数、无重复、组边界、宽扫覆盖面。
static void TestEnumeration() {
    const unsigned limit = mfcal_total_probes();
    Check(limit == MFCAL_MAX_PROBES, "total probes must match the documented bound");
    Check(limit == MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT + MFCAL_STAGE3_COUNT + MFCAL_STAGE4_COUNT,
          "the bound must decompose into the four groups");

    std::set<std::tuple<unsigned, unsigned, unsigned, unsigned, unsigned>> seen;
    std::set<std::pair<unsigned, unsigned>> sweep_hop2;   /* (proc_task, proc_task2) */
    std::set<unsigned> sweep_hop1;
    unsigned group_counts[5] = {0, 0, 0, 0, 0};

    mfcal_iter it;
    mfcal_iter_reset(&it);
    mfcal_offsets o;
    unsigned produced = 0;
    while (mfcal_iter_next(&it, &o)) {
        // 注意：迭代器的 stage 在取下一发之后才前进，这里用"已产出数量"划分组。
        auto key = std::make_tuple(static_cast<unsigned>(o.proc_hop),
                                   static_cast<unsigned>(o.proc_task),
                                   static_cast<unsigned>(o.proc_task2),
                                   static_cast<unsigned>(o.task_map),
                                   static_cast<unsigned>(o.map_pmap));
        Check(seen.insert(key).second, "the probe order must not contain duplicates");

        if (produced < MFCAL_STAGE1_COUNT) {
            group_counts[1]++;
        } else if (produced < MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT) {
            group_counts[2]++;
            Check(o.map_pmap == 0x40u, "group 2 must keep map_pmap at the baseline");
        } else if (produced < MFCAL_STAGE1_COUNT + MFCAL_STAGE2_COUNT + MFCAL_STAGE3_COUNT) {
            group_counts[3]++;
        } else {
            group_counts[4]++;
            if (o.proc_hop == 2u) {
                Check(o.map_pmap == 0x40u && o.task_map == 0x28u,
                      "the two-hop sweep must keep the baseline map/pmap");
                sweep_hop2.insert(std::make_pair(static_cast<unsigned>(o.proc_task),
                                                 static_cast<unsigned>(o.proc_task2)));
            } else {
                Check(o.map_pmap == 0x40u && o.task_map == 0x28u,
                      "the one-hop sweep must keep the baseline map/pmap");
                sweep_hop1.insert(o.proc_task);
            }
        }
        ++produced;
    }

    Check(produced == MFCAL_MAX_PROBES, "the iterator must yield exactly the declared bound");
    Check(group_counts[1] == MFCAL_STAGE1_COUNT, "group 1 must yield exactly its declared count");
    Check(group_counts[2] == MFCAL_STAGE2_COUNT, "group 2 must yield exactly its declared count");
    Check(group_counts[3] == MFCAL_STAGE3_COUNT, "group 3 must yield exactly its declared count");
    Check(group_counts[4] == MFCAL_STAGE4_COUNT, "group 4 must yield exactly its declared count");

    // 宽扫必须覆盖 0..0x1000 的每个 8 字节槽位，只跳过前面各组已验证过的组合。
    static const unsigned hop2_b[] = {0x08u, 0x00u, 0x10u, 0x18u, 0x20u, 0x28u};
    for (unsigned off = 0; off <= MFCAL_SWEEP_LAST; off += MFCAL_SWEEP_STEP) {
        if (off == 0x18u) {
            for (unsigned b = 0; b < 6u; ++b) {
                Check(sweep_hop2.count(std::make_pair(off, hop2_b[b])) == 0,
                      "the two-hop sweep must skip the column groups 1-2 already tried");
            }
        } else {
            for (unsigned b = 0; b < 6u; ++b) {
                Check(sweep_hop2.count(std::make_pair(off, hop2_b[b])) == 1,
                      "the two-hop sweep must cover every first-hop slot against every second-hop variant");
            }
        }
        bool covered_hop1 = (off == 0x10u) || (off == 0x00u) || (off == 0x08u) ||
                            (off == 0x18u) || (off == 0x20u) || (off == 0x30u);
        if (covered_hop1) {
            Check(sweep_hop1.count(off) == 0, "the one-hop sweep must skip values already tried");
        } else {
            Check(sweep_hop1.count(off) == 1, "the one-hop sweep must cover every other 8-byte slot");
        }
    }
    Check(sweep_hop2.size() == MFCAL_STAGE4_COUNT - (MFCAL_SWEEP_COUNT - MFCAL_SWEEP_SKIP_HOP1),
          "the two-hop sweep count must match the declared geometry");
    Check(sweep_hop1.size() == MFCAL_SWEEP_COUNT - MFCAL_SWEEP_SKIP_HOP1,
          "the one-hop sweep count must match the declared skip");

    // 迭代器与 mfcal_run 必须走同一条序列。
    std::vector<mfcal_offsets> recorded;
    unsigned calls = 0;
    mfcal_run(ProbeRecord, &recorded, 0);
    (void)calls;
    Check(recorded.size() == MFCAL_MAX_PROBES, "the run must probe every candidate");
    mfcal_iter_reset(&it);
    bool same_order = true;
    for (unsigned i = 0; i < recorded.size(); ++i) {
        if (!mfcal_iter_next(&it, &o) || !mfcal_same(&o, &recorded[i])) {
            same_order = false;
            break;
        }
    }
    Check(same_order, "mfcal_run must follow the iterator order exactly");

    mfcal_offsets out;
    Check(mfcal_probe_at(limit, &out) == 0, "an out-of-range index must be rejected");
    mfcal_result null_run = mfcal_run(nullptr, nullptr, 0);
    Check(null_run.found == 0 && null_run.probed == 0, "a null probe must produce an empty result");
}

// 关键形状必须真的在列表里，否则"跨 15/16"是假的。
static void TestCoverage() {
    std::set<unsigned> hop2_first;
    std::set<unsigned> hop1_first;
    std::set<unsigned> task_maps;
    std::set<unsigned> map_pmaps;
    for (unsigned i = 0; i < mfcal_total_probes(); ++i) {
        mfcal_offsets o;
        mfcal_probe_at(i, &o);
        if (o.proc_hop == 2u) {
            hop2_first.insert(o.proc_task);
            Check(o.proc_task2 == 0x08u || o.proc_task2 == 0x00u || o.proc_task2 == 0x10u ||
                      o.proc_task2 == 0x18u || o.proc_task2 == 0x20u || o.proc_task2 == 0x28u,
                  "a two-hop entry must carry one of the declared second hops");
        } else {
            hop1_first.insert(o.proc_task);
            Check(o.proc_task2 == 0x00u, "a one-hop entry must not carry a second hop");
        }
        task_maps.insert(o.task_map);
        map_pmaps.insert(o.map_pmap);
    }

    Check(hop2_first.count(0x18u) == 1, "the iOS 16 p_ro offset 0x18 must be covered");
    Check(hop1_first.count(0x10u) == 1, "the iOS 15 inline task offset 0x10 must be covered");
    Check(task_maps.count(0x28u) == 1, "the documented task_map 0x28 must be covered");
    Check(task_maps.size() == 5, "every task_map alternative must be covered exactly once");
    Check(map_pmaps.count(0x40u) == 1, "the compiled-in map_pmap 0x40 must be covered");
    Check(map_pmaps.size() == 5, "every map_pmap alternative must be covered exactly once");
}

// 默认预算：只跑前三组。宽扫会把三千多个未验证指针当地址去读，
// 真机已经用一次内核 panic 证明过代价（copy_validate → 重启）。
static void TestSafeBudget() {
    Check(MFCAL_SAFE_BUDGET == 28u, "the default budget must be groups 1-3 only");
    Check(MFCAL_SAFE_BUDGET < MFCAL_MAX_PROBES, "the default budget must exclude the wide sweep");

    unsigned calls = 0;
    mfcal_result r = mfcal_run(ProbeNever, &calls, MFCAL_SAFE_BUDGET);
    Check(r.found == 0, "a bounded run cannot claim success");
    Check(r.probed == MFCAL_SAFE_BUDGET, "the bounded run must stop exactly at the budget");
    Check(calls == MFCAL_SAFE_BUDGET, "probe calls must match the budget");
    Check(r.budget_exhausted == 1, "stopping early because of the budget must be labelled");

    for (unsigned i = 0; i < MFCAL_SAFE_BUDGET; ++i) {
        mfcal_offsets o;
        Check(mfcal_probe_at(i, &o) == 1, "every budgeted index must resolve");
        Check(o.proc_task <= 0x40u, "the budgeted groups must stay near the documented offsets");
    }
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (std::strcmp(argv[1], "documented-ios16") == 0) TestDocumentedIos16();
    else if (std::strcmp(argv[1], "documented-ios15") == 0) TestDocumentedIos15();
    else if (std::strcmp(argv[1], "second-hop-variant") == 0) TestSecondHopVariant();
    else if (std::strcmp(argv[1], "task-map-moved") == 0) TestTaskMapMoved();
    else if (std::strcmp(argv[1], "pmap-moved") == 0) TestPmapMoved();
    else if (std::strcmp(argv[1], "sweep-two-hop") == 0) TestSweepTwoHop();
    else if (std::strcmp(argv[1], "sweep-one-hop") == 0) TestSweepOneHop();
    else if (std::strcmp(argv[1], "nothing-works") == 0) TestNothingWorks();
    else if (std::strcmp(argv[1], "budget") == 0) TestBudget();
    else if (std::strcmp(argv[1], "safe-budget") == 0) TestSafeBudget();
    else if (std::strcmp(argv[1], "enumeration") == 0) TestEnumeration();
    else if (std::strcmp(argv[1], "coverage") == 0) TestCoverage();
    else return 2;

    std::printf("%s: chain-calib %s (%d checks)\n", failures ? "FAIL" : "PASS", argv[1], checks);
    return failures ? 1 : 0;
}
