#pragma once

#include <cstdint>
#include <functional>
#include <string>

// Platform-independent binding policy. System calls live in the HUD adapter;
// observing state() never calls a provider or reads target memory.
namespace MFHUD {
struct Target {
    int pid = 0;
    std::string identity;
    std::string error;
};
struct PortResult { uint32_t port = 0; std::string error; };
struct ModuleResult { uint64_t base = 0; std::string name; std::string error; };
struct BindingHooks {
    std::function<PortResult(const Target &)> acquire;
    std::function<std::string(uint32_t, const Target &)> verify;
    std::function<ModuleResult(uint32_t, const Target &)> locate;
    std::function<void(uint32_t)> bind;
    std::function<void(uint64_t)> setBase;
    std::function<void()> clear;
    std::function<void(uint32_t)> release;
};
struct BindingState {
    Target target;
    uint32_t port = 0;
    uint64_t base = 0;
    std::string module;
    std::string stage = "idle";
    std::string error;
    uint64_t portAttempts = 0;
    uint64_t moduleAttempts = 0;
    double lastAttemptUptime = 0;
};

class TargetBinding {
public:
    TargetBinding() = default;
    TargetBinding(const TargetBinding &) = delete;
    TargetBinding &operator=(const TargetBinding &) = delete;
    const BindingState &state() const { return state_; }

    void tick(double now, const Target &target, const BindingHooks &hooks) {
        if (target.pid <= 0 || target.identity.empty()) {
            clear(hooks);
            state_.target = target;
            state_.stage = "identity";
            state_.error = target.error.empty() ? "Target instance could not be verified" : target.error;
            return;
        }
        if (state_.target.pid != target.pid || state_.target.identity != target.identity) {
            clear(hooks);
            state_.target = target;
        }
        if (!state_.port) {
            if (now < nextAttempt_) return;
            ++state_.portAttempts;
            state_.lastAttemptUptime = now;
            const PortResult acquired = hooks.acquire(target);
            nextAttempt_ = now + retryInterval_;
            if (!acquired.port) {
                state_.stage = "task-port";
                state_.error = acquired.error.empty() ? "Task port acquisition failed" : acquired.error;
                return;
            }
            const std::string identityError = hooks.verify(acquired.port, target);
            if (!identityError.empty()) {
                hooks.release(acquired.port);
                state_.stage = "port-identity";
                state_.error = identityError;
                return;
            }
            state_.port = acquired.port;
            hooks.bind(state_.port);
            nextAttempt_ = now; // A newly verified port can locate its module immediately.
        }
        if (state_.base || now < nextAttempt_) return;
        ++state_.moduleAttempts;
        state_.lastAttemptUptime = now;
        const ModuleResult module = hooks.locate(state_.port, target);
        nextAttempt_ = now + retryInterval_;
        if (!module.base) {
            state_.stage = "module";
            state_.error = module.error.empty() ? "Module lookup returned no base" : module.error;
            return;
        }
        state_.base = module.base;
        state_.module = module.name;
        state_.stage = "ready";
        state_.error.clear();
        hooks.setBase(state_.base);
    }

    void reset(const BindingHooks &hooks) {
        clear(hooks);
        state_.target = {};
        state_.stage = "stopped";
        state_.error.clear();
    }

private:
    void clear(const BindingHooks &hooks) {
        if (state_.port) {
            hooks.clear(); // Stop readers using the name before surrendering our send right.
            hooks.release(state_.port);
        }
        state_.port = 0;
        state_.base = 0;
        state_.module.clear();
        nextAttempt_ = 0;
    }
    // [M5.173] 5.0 → 2.0：这里每失败一次，读取门就关一次、整屏空一次。
    // 目标身份偶发读不到（进程枚举/内核瞬时繁忙）时，5 秒的间隔等于"黑屏 5 秒"。
    static constexpr double retryInterval_ = 2.0;
    BindingState state_;
    double nextAttempt_ = 0;
};
} // namespace MFHUD
