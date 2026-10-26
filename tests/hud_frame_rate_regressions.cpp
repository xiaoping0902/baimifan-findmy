#include "../app/Sources/Render/MFPresentedFrameRate.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <memory>
#include <thread>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

static void Feed(MFPresentedFrameRate &rate, double start, unsigned count, double fps) {
    for (unsigned i = 0; i < count; ++i) rate.Record(start + i / fps);
}

int main() {
    MFPresentedFrameRate rate;
    CHECK(rate.Sample(10) == 0, "a frame request without a presentation must stay unknown");
    rate.Record(0); rate.Record(-1); rate.Record(std::numeric_limits<double>::infinity());
    rate.Record(std::numeric_limits<double>::quiet_NaN());
    CHECK(rate.Sample(10) == 0, "invalid presentation timestamps must not become fake frames");
    Feed(rate, 10, 61, 120);
    CHECK(std::fabs(rate.Sample(10.5) - 120) < 0.001,
          "a 120Hz presentation timeline must report 120FPS independently of callback delivery");
    rate.Record(10.5); rate.Record(10.4);
    CHECK(std::fabs(rate.Sample(10.6) - 120) < 0.001,
          "duplicate and out-of-order presentation callbacks must not inflate FPS");
    CHECK(rate.Sample(11.3) == 0, "a stalled surface must age its previous FPS back to zero");

    MFPresentedFrameRate sixty, thirty;
    Feed(sixty, 20, 31, 60); Feed(thirty, 20, 16, 30);
    CHECK(std::fabs(sixty.Sample(20.5) - 60) < 0.001 &&
          std::fabs(thirty.Sample(20.5) - 30) < 0.001,
          "actual 60 and 30Hz output must not inherit a requested 120FPS value");

    auto retired = std::make_shared<MFPresentedFrameRate>();
    auto active = std::make_shared<MFPresentedFrameRate>();
    std::thread late([retired] { Feed(*retired, 30, 121, 120); });
    Feed(*active, 30, 31, 60);
    late.join();
    CHECK(std::fabs(active->Sample(30.5) - 60) < 0.001 &&
          std::fabs(retired->Sample(31) - 120) < 0.001,
          "late callbacks captured by a retired generation must not contaminate the active surface");

    MFPresentedFrameRate concurrent;
    std::thread producer([&concurrent] { Feed(concurrent, 40, 1201, 120); });
    for (unsigned i = 0; i < 1000; ++i) {
        const double sample = concurrent.Sample(40 + i / 100.0);
        CHECK(std::isfinite(sample) && sample >= 0, "sampling while presentations arrive must remain finite");
    }
    producer.join();
    CHECK(std::fabs(concurrent.Sample(50) - 120) < 0.001,
          "simultaneous sample and presentation calls must preserve the actual frame timeline");
    std::puts("PASS: actual presentation FPS, invalid timestamps, stalls and generation isolation");
}
