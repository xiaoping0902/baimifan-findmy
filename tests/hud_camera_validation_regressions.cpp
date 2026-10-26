// Compiled after the actual MFUEBuildCamera body by the portable runner.
// No Apple SDK or target-process access is needed to replay corrupt POV reads.
#include <array>
#include <cstdio>
#include <cstring>
#include <limits>

static int failures = 0;
static int checks = 0;

static void Check(bool condition, const char *message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

static std::array<float, 8> POV() {
    return {100, 200, 300, 0, 0, 0, 0, 90};
}

static void CheckRejected(const std::array<float, 8> &pov, const char *message) {
    MFCamera camera = {11, 12, 13, 14, 15, 16, 17};
    Check(!MFUEBuildCamera(pov.data(), &camera), message);
    Check(camera.x == 11 && camera.y == 12 && camera.z == 13 &&
          camera.pitch == 14 && camera.yaw == 15 && camera.roll == 16 && camera.fov == 17,
          "a rejected sample must leave the last usable camera untouched");
}

static void TestValidCamera() {
    struct Angles { float pitch, yaw, roll, wantPitch, wantYaw, wantRoll; };
    const Angles cases[] = {
        {0, 0, 0, 0, 0, 0},
        {30, 450, -450, 30, 90, -90},
        {-390, -720, 810, -30, 0, 90},
        {0, 180, -180, 0, 180, -180},
        {0, 540, -540, 0, 180, -180},
        {90.5f, -180, 180, 90.5f, -180, 180},
        {-90.5f, 720, -720, -90.5f, 0, 0},
        {360, 359, 270, 0, -1, -90},
    };
    for (const auto &angles : cases) {
        auto pov = POV();
        pov[4] = angles.pitch; pov[5] = angles.yaw; pov[6] = angles.roll;
        MFCamera camera = {};
        Check(MFUEBuildCamera(pov.data(), &camera), "a valid camera must remain accepted");
        Check(camera.pitch == angles.wantPitch && camera.yaw == angles.wantYaw &&
              camera.roll == angles.wantRoll, "signed angle wrapping must preserve camera orientation");
        Check(camera.x == 100 && camera.y == 200 && camera.z == 300 && camera.fov == 90,
              "angle wrapping must preserve camera position and field of view");
    }
    for (float fov : {5.0f, 175.0f}) {
        auto pov = POV(); pov[7] = fov;
        MFCamera camera = {};
        Check(MFUEBuildCamera(pov.data(), &camera) && camera.fov == fov,
              "the supported zoom and transition FOV boundaries must remain inclusive");
    }
    auto pov = POV();
    pov[3] = std::numeric_limits<float>::quiet_NaN();
    Check(MFUEBuildCamera(pov.data(), nullptr), "the EncHandler slot is not a float camera field");
}

static void TestInfiniteAngle(int component) {
    for (float value : {std::numeric_limits<float>::infinity(),
                        -std::numeric_limits<float>::infinity()}) {
        auto pov = POV(); pov[component] = value;
        CheckRejected(pov, "an infinite remote angle must fail promptly");
    }
}

static void TestHugeFiniteAngles() {
    const float largest = std::numeric_limits<float>::max();
    for (int component : {4, 5, 6}) {
        for (float value : {largest, -largest}) {
            auto pov = POV(); pov[component] = value;
            MFCamera camera = {};
            Check(MFUEBuildCamera(pov.data(), &camera),
                  "finite angles must complete even when subtracting 360 cannot change the float");
            Check(std::isfinite(camera.pitch) && std::isfinite(camera.yaw) && std::isfinite(camera.roll) &&
                  std::fabs(camera.pitch) <= 90.5f && std::fabs(camera.yaw) <= 180 && std::fabs(camera.roll) <= 180,
                  "huge finite angles must produce bounded finite angles");
        }
    }
}

static void TestInvalidCameraFields() {
    for (int component : {0, 1, 2, 4, 5, 6, 7}) {
        auto pov = POV(); pov[component] = std::numeric_limits<float>::quiet_NaN();
        CheckRejected(pov, "NaN in any camera field must be rejected");
    }
    for (int component : {0, 1, 2, 7}) {
        auto pov = POV(); pov[component] = std::numeric_limits<float>::infinity();
        CheckRejected(pov, "infinite position and FOV must be rejected");
    }
    for (float pitch : {90.6f, -90.6f, 180.0f}) {
        auto pov = POV(); pov[4] = pitch;
        CheckRejected(pov, "a pitch outside the supported physical range must be rejected");
    }
    for (float fov : {4.9f, 175.1f, 0.0f}) {
        auto pov = POV(); pov[7] = fov;
        CheckRejected(pov, "unsupported FOV must be rejected");
    }
    auto pov = POV(); pov[0] = 1000001;
    CheckRejected(pov, "an implausible camera position must be rejected");
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (std::strcmp(argv[1], "valid") == 0) TestValidCamera();
    else if (std::strcmp(argv[1], "yaw-infinity") == 0) TestInfiniteAngle(5);
    else if (std::strcmp(argv[1], "pitch-infinity") == 0) TestInfiniteAngle(4);
    else if (std::strcmp(argv[1], "roll-infinity") == 0) TestInfiniteAngle(6);
    else if (std::strcmp(argv[1], "huge-finite") == 0) TestHugeFiniteAngles();
    else if (std::strcmp(argv[1], "invalid-fields") == 0) TestInvalidCameraFields();
    else return 2;
    std::printf("%s: production camera %s (%d checks)\n", failures ? "FAIL" : "PASS", argv[1], checks);
    return failures ? 1 : 0;
}
