#pragma once
#include <cmath>
#include <cstdint>
#include <mutex>

// One instance belongs to one rendering generation. Presentation callbacks can
// arrive on a Metal thread; sampling belongs to main. This small lock protects
// the timestamp/count pair without queuing one block per displayed frame.
class MFPresentedFrameRate {
public:
    void Record(double presentedAt) {
        if (!std::isfinite(presentedAt) || presentedAt <= 0) return;
        std::lock_guard<std::mutex> guard(mutex_);
        if (presentedAt <= last_) return;
        last_ = presentedAt;
        ++count_;
        if (count_ == 1) { sampleAt_ = presentedAt; sampleCount_ = count_; }
    }

    double Sample(double now) {
        if (!std::isfinite(now) || now <= 0) return 0;
        std::lock_guard<std::mutex> guard(mutex_);
        if (!count_) return 0;
        if (now - last_ > 0.75) {
            fps_ = 0;
            sampleAt_ = last_; sampleCount_ = count_;
            return 0;
        }
        // Use actual presentation times, not the rate at which the OS delivers
        // callbacks or the screen's maximum/requested refresh rate.
        const double elapsed = last_ - sampleAt_;
        if (elapsed >= 0.5 && now >= last_) {
            fps_ = (count_ - sampleCount_) / elapsed;
            sampleAt_ = last_; sampleCount_ = count_;
        }
        return fps_;
    }

private:
    std::mutex mutex_;
    uint64_t count_ = 0, sampleCount_ = 0;
    double last_ = 0, sampleAt_ = 0, fps_ = 0;
};
