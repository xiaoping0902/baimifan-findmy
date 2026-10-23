#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

static void Check(bool value, const char *message) {
    if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

#if __has_include("MFHUDTargetBinding.h")
#include "MFHUDTargetBinding.h"
using namespace MFHUD;

struct Fixture {
    Target target{42, "42|/fixture|100|1", ""};
    int acquired = 0, located = 0, bound = 0, cleared = 0;
    std::vector<uint32_t> released;
    bool denyPort = false, rejectIdentity = false, denyModule = true;
    BindingHooks hooks() {
        return {
            [&](const Target &) { ++acquired; return PortResult{denyPort ? 0u : 73u, "port-denied"}; },
            [&](uint32_t, const Target &) { return rejectIdentity ? "target-changed" : ""; },
            [&](uint32_t port, const Target &) {
                Check(port == 73, "module lookup must receive the already verified port");
                ++located; return ModuleResult{denyModule ? 0ull : 0x100000000ull, "fixture", "module-unavailable"};
            },
            [&](uint32_t port) { Check(port == 73, "reader must bind the acquired port"); ++bound; },
            [&](uint64_t) {},
            [&] { ++cleared; },
            [&](uint32_t port) { released.push_back(port); },
        };
    }
};

static void TestZeroBaseRetriesWithBorrowedPort() {
    Fixture f; TargetBinding binding; auto hooks = f.hooks();
    binding.tick(10, f.target, hooks);
    Check(binding.state().stage == "module" && binding.state().port == 73 && binding.state().base == 0,
          "failed module lookup must retain a verified binding and its failure stage");
    Check(binding.state().error == "module-unavailable", "module error must remain observable");
    binding.tick(11, f.target, hooks);
    Check(f.located == 1 && f.acquired == 1, "module retries must be limited to the retry interval");
    f.denyModule = false;
    binding.tick(15, f.target, hooks);
    Check(binding.state().stage == "ready" && binding.state().base == 0x100000000ull,
          "same target with base zero must recover when module lookup becomes available");
    Check(f.acquired == 1 && f.bound == 1 && f.located == 2 && f.released.empty(),
          "recovering a module must reuse the verified port without acquiring, binding or releasing it again");
    binding.tick(20, f.target, hooks);
    Check(f.located == 2 && f.acquired == 1, "ready target must not repeat acquisition or module lookup");
}

static void TestIdentityChangeClearsBeforeRebinding() {
    Fixture f; f.denyModule = false; TargetBinding binding; auto hooks = f.hooks();
    binding.tick(10, f.target, hooks);
    f.target.identity = "42|/fixture|101|1";
    f.denyModule = true;
    binding.tick(11, f.target, hooks);
    Check(f.cleared == 1 && f.released == std::vector<uint32_t>{73},
          "a restarted instance with the same PID must clear addresses and release the old port once");
    Check(binding.state().base == 0 && binding.state().stage == "module" && f.acquired == 2,
          "the new instance must not inherit the previous module base");
    binding.tick(12, Target{42, "", "identity-unavailable"}, hooks);
    Check(binding.state().port == 0 && binding.state().base == 0 && binding.state().stage == "identity",
          "losing target identity must clear the binding instead of reusing absolute addresses");
    Check(binding.state().error == "identity-unavailable" && f.released.size() == 2,
          "identity failure must be visible and release only the active port");
}

static void TestDeniedAndReusedPortStages() {
    Fixture f; f.denyPort = true; TargetBinding binding; auto hooks = f.hooks();
    binding.tick(10, f.target, hooks);
    Check(binding.state().stage == "task-port" && binding.state().error == "port-denied",
          "failed acquisition must expose its exact stage and provider error");
    binding.tick(11, f.target, hooks);
    Check(f.acquired == 1 && f.located == 0, "denied port retries must be limited and cannot locate modules");
    f.denyPort = false; f.rejectIdentity = true;
    binding.tick(15, f.target, hooks);
    Check(binding.state().stage == "port-identity" && binding.state().port == 0,
          "a PID reuse race must not publish the acquired port");
    Check(f.released == std::vector<uint32_t>{73} && f.bound == 0 && f.located == 0,
          "unverified port must be released without entering the reader or module locator");
}

static void TestPassiveObservationAndReset() {
    Fixture f; f.denyModule = false; TargetBinding binding; auto hooks = f.hooks();
    binding.tick(10, f.target, hooks);
    const auto before = binding.state();
    for (int i = 0; i < 20; ++i) {
        const auto snapshot = binding.state();
        Check(snapshot.port == before.port && snapshot.base == before.base, "passive state must retain cached values");
    }
    Check(f.acquired == 1 && f.located == 1, "reading binding state must not acquire ports or read target memory");
    binding.reset(hooks);
    binding.reset(hooks);
    Check(f.released == std::vector<uint32_t>{73} && f.cleared == 1,
          "shutdown must release the owned port once, including repeated cleanup");
    Check(binding.state().stage == "stopped" && binding.state().base == 0 && binding.state().port == 0,
          "shutdown state must not retain live addresses");
}
#endif

int main() {
#if __has_include("MFHUDTargetBinding.h")
    TestZeroBaseRetriesWithBorrowedPort();
    TestIdentityChangeClearsBeforeRebinding();
    TestDeniedAndReusedPortStages();
    TestPassiveObservationAndReset();
    std::cout << "PASS: production HUD binding recovery, port ownership, failure stages and passive observation\n";
#else
    Check(false, "production HUD binding coordinator is missing; zero-base recovery has no testable policy");
#endif
}
