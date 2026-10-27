// Portable regression for the adaptive KFD chain search (MFChainScan.h).
//
// 背景：proc → proc_ro → task → vm_map → pmap 这条链在 iPadOS 16.6.1 上
// 第 5 跳读到野指针才炸（rc=-7 读 vm_map+0x40 失败），前四跳因为"指针看起来
// 像内核地址"全部放行。这里的用例锁住三件事：
//   1. 默认组合永远第一个试 —— 老设备上不多读一次；
//   2. 默认组合不成立时，能按距离升序找到真正可用的那一组；
//   3. 全部不成立时如实报"全失败"，不假装成功、也不死循环。
//
// 不需要 Apple SDK、不需要设备、不需要内核：判据由假 try_fn 提供。
#include <cstdio>
#include <cstring>
#include <vector>

#include "../app/Sources/Kernel/MFChainScan.h"

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

// 只在 target 这一组偏移上返回"可用"，模拟真机上只有一组偏移能读出 Mach-O 头。
struct OnlyOneWorks {
    mfchain_offsets target;
    unsigned calls = 0;
    std::vector<int> distances;
};

int TryOnlyTarget(void *ctx, const mfchain_offsets *offsets) {
    auto *state = static_cast<OnlyOneWorks *>(ctx);
    ++state->calls;
    return mfchain_same(offsets, &state->target) ? 1 : 0;
}

int TryNever(void *ctx, const mfchain_offsets *offsets) {
    (void)offsets;
    ++static_cast<unsigned *>(ctx)[0];
    return 0;
}

int TryAlways(void *ctx, const mfchain_offsets *offsets) {
    (void)offsets;
    ++static_cast<unsigned *>(ctx)[0];
    return 1;
}

int DistanceOf(const mfchain_offsets &o) {
    int a = 0, b = 0, c = 0, e = 0;
    for (unsigned i = 0; i < MFCHAIN_PROC_RO_COUNT; ++i) {
        if (mfchain_proc_ro_candidates[i] == o.proc_ro) { a = static_cast<int>(i); break; }
    }
    for (unsigned i = 0; i < MFCHAIN_PR_TASK_COUNT; ++i) {
        if (mfchain_pr_task_candidates[i] == o.pr_task) { b = static_cast<int>(i); break; }
    }
    for (unsigned i = 0; i < MFCHAIN_TASK_MAP_COUNT; ++i) {
        if (mfchain_task_map_candidates[i] == o.task_map) { c = static_cast<int>(i); break; }
    }
    for (unsigned i = 0; i < MFCHAIN_MAP_PMAP_COUNT; ++i) {
        if (mfchain_map_pmap_candidates[i] == o.map_pmap) { e = static_cast<int>(i); break; }
    }
    return a + b + c + e;
}

}  // namespace

// 默认组合可用 → 第一次尝试就命中，offsets 就是历史默认值。
static void TestDefaultFirst() {
    OnlyOneWorks state;
    state.target = mfchain_default_offsets();
    mfchain_result result = mfchain_search(TryOnlyTarget, &state, 0);

    Check(result.found == 1, "the default combination must be usable here");
    Check(result.attempts == 1, "the default combination must be the very first attempt");
    Check(state.calls == 1, "a first-attempt hit must not keep probing");

    mfchain_offsets expected = mfchain_default_offsets();
    Check(result.offsets.proc_ro == expected.proc_ro, "proc_ro must stay at the historical default");
    Check(result.offsets.pr_task == expected.pr_task, "pr_task must stay at the historical default");
    Check(result.offsets.task_map == expected.task_map, "task_map must stay at the historical default");
    Check(result.offsets.map_pmap == expected.map_pmap, "map_pmap must stay at the historical default");
    Check(expected.proc_ro == 0x18u && expected.pr_task == 0x08u && expected.task_map == 0x28u &&
              expected.map_pmap == 0x40u,
          "the historical default must remain 0x18/0x08/0x28/0x40 for iPadOS 16.1");
    Check(result.budget_exhausted == 0, "a hit is not a budget stop");
}

// 默认组合不成立（16.6.1 的情形）→ 必须继续找，并且命中的就是唯一可用那组。
static void TestShiftedOffsets() {
    OnlyOneWorks state;
    state.target.proc_ro = 0x20u;
    state.target.pr_task = 0x00u;
    state.target.task_map = 0x30u;
    state.target.map_pmap = 0x48u;
    mfchain_result result = mfchain_search(TryOnlyTarget, &state, 0);

    Check(result.found == 1, "a non-default but valid combination must still be found");
    Check(mfchain_same(&result.offsets, &state.target), "the search must return the combination that actually worked");
    Check(result.attempts > 1, "finding a shifted combination must cost more than one attempt");
    Check(state.calls == static_cast<unsigned>(result.attempts), "attempt accounting must match the probe calls");
    Check(result.budget_exhausted == 0, "an exhaustive search that succeeds is not a budget stop");
}

// 全部不成立 → 如实报失败，尝试次数正好等于组合总数，不再多探一次。
static void TestExhaustiveFailure() {
    unsigned calls = 0;
    mfchain_result result = mfchain_search(TryNever, &calls, 0);

    Check(result.found == 0, "no combination works, so the search must report failure");
    Check(result.attempts == MFCHAIN_COMBINATIONS, "failure must be reported only after every combination was tried");
    Check(calls == MFCHAIN_COMBINATIONS, "probe calls must equal the combination count");
    Check(result.budget_exhausted == 0, "an unlimited search is never a budget stop");

    mfchain_offsets fallback = mfchain_default_offsets();
    Check(mfchain_same(&result.offsets, &fallback), "a failed search must still report the default offsets for diagnostics");
}

// 预算截断 → 到点就停，标记 budget_exhausted，不能悄悄当成"全试过了"。
static void TestBudget() {
    unsigned calls = 0;
    mfchain_result result = mfchain_search(TryNever, &calls, 5);

    Check(result.found == 0, "a truncated search cannot claim success");
    Check(result.attempts == 5, "the budget must stop the search exactly at the limit");
    Check(calls == 5, "the budget must also bound the probe calls");
    Check(result.budget_exhausted == 1, "a truncated search must be labelled as budget-exhausted");

    unsigned one_call = 0;
    mfchain_result single = mfchain_search(TryAlways, &one_call, 1);
    Check(single.found == 1, "a budget of one must still allow the first probe to win");
    Check(single.budget_exhausted == 0, "hitting the budget after a success is not an exhausted search");
}

// 顺序契约：第一个是默认组合，索引距离单调不减，且 192 组互不重复。
static void TestOrderAndUniqueness() {
    mfchain_offsets previous = mfchain_default_offsets();
    int previous_distance = -1;
    unsigned distinct = 0;

    for (unsigned i = 0; i < MFCHAIN_COMBINATIONS; ++i) {
        mfchain_offsets current;
        Check(mfchain_candidate_at(i, &current) == 1, "every index below the count must resolve");

        if (i == 0) {
            Check(mfchain_same(&current, &previous), "candidate 0 must be the historical default");
        } else {
            Check(!mfchain_same(&current, &previous), "consecutive candidates must not repeat");
        }

        int distance = DistanceOf(current);
        Check(distance >= previous_distance, "candidate distance must never decrease (enumerate by proximity)");
        previous_distance = distance;
        previous = current;

        bool seen_before = false;
        for (unsigned j = 0; j < i; ++j) {
            mfchain_offsets other;
            mfchain_candidate_at(j, &other);
            if (mfchain_same(&other, &current)) { seen_before = true; break; }
        }
        Check(!seen_before, "the candidate list must not contain duplicates");
        ++distinct;
    }

    Check(distinct == MFCHAIN_COMBINATIONS, "the full candidate list must be enumerated");
    Check(MFCHAIN_COMBINATIONS == 192u, "4x3x4x4 candidates are expected once the pools change");
    Check(MFCHAIN_MAX_DISTANCE == 11, "the maximum index distance is the sum of the pool offsets");

    mfchain_offsets out;
    Check(mfchain_candidate_at(MFCHAIN_COMBINATIONS, &out) == 0, "an out-of-range index must be rejected");
}

// 候选池本身：默认值必须排在首位，否则"老设备零成本"这个前提就没了。
static void TestCandidatePools() {
    Check(mfchain_proc_ro_candidates[0] == 0x18u, "proc_ro default must be 0x18");
    Check(mfchain_pr_task_candidates[0] == 0x08u, "pr_task default must be 0x08");
    Check(mfchain_task_map_candidates[0] == 0x28u, "task_map default must be 0x28");
    Check(mfchain_map_pmap_candidates[0] == 0x40u, "map_pmap default must be 0x40");

    Check(mfchain_pr_task_candidates[1] == 0x00u,
          "struct proc_ro may carry pr_task at offset 0 on some kernels, so 0x00 must be tried second");
    Check(mfchain_map_pmap_candidates[1] == 0x38u,
          "the view of struct _vm_map before pmap is the nearest alternative, so 0x38 must be tried second");

    mfchain_offsets a = mfchain_default_offsets();
    mfchain_offsets b;
    b.proc_ro = a.proc_ro;
    b.pr_task = a.pr_task;
    b.task_map = a.task_map;
    b.map_pmap = a.map_pmap;
    Check(mfchain_same(&a, &b) == 1, "identical offsets must compare equal");
    b.map_pmap = 0x48u;
    Check(mfchain_same(&a, &b) == 0, "a single differing hop must compare unequal");
    Check(mfchain_same(&a, nullptr) == 0, "a null operand must compare unequal instead of crashing");

    mfchain_result null_search = mfchain_search(nullptr, nullptr, 0);
    Check(null_search.found == 0 && null_search.attempts == 0, "a null probe must produce an empty result");
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (std::strcmp(argv[1], "default-first") == 0) TestDefaultFirst();
    else if (std::strcmp(argv[1], "shifted-offsets") == 0) TestShiftedOffsets();
    else if (std::strcmp(argv[1], "exhaustive-failure") == 0) TestExhaustiveFailure();
    else if (std::strcmp(argv[1], "budget") == 0) TestBudget();
    else if (std::strcmp(argv[1], "order-and-uniqueness") == 0) TestOrderAndUniqueness();
    else if (std::strcmp(argv[1], "candidate-pools") == 0) TestCandidatePools();
    else return 2;

    std::printf("%s: chain-scan %s (%d checks)\n", failures ? "FAIL" : "PASS", argv[1], checks);
    return failures ? 1 : 0;
}
