#pragma once
#include <cmath>
#include <limits>

namespace MFUECameraValidation {

// A remote float may be infinite, or so large that subtracting 360 does not
// change it. A subtraction loop can therefore hold the HUD main thread forever.
// Preserve the signed +/-180 boundary used by the previous camera convention.
inline float NormalizeDegrees(float degrees) {
    if (!std::isfinite(degrees)) return std::numeric_limits<float>::quiet_NaN();
    float result = std::fmod(degrees, 360.0f);
    if (result > 180.0f) result -= 360.0f;
    if (result < -180.0f) result += 360.0f;
    return result;
}

// Kept independent of Apple headers so corrupt POV samples can exercise the
// production reader in native regressions. Publish only a complete valid sample.
template <typename Camera>
inline bool NormalizeAndValidate(Camera &camera, float minFov, float maxFov) {
    if (!std::isfinite(camera.x) || !std::isfinite(camera.y) || !std::isfinite(camera.z) ||
        std::fabs(camera.x) > 1.e6f || std::fabs(camera.y) > 1.e6f || std::fabs(camera.z) > 1.e6f ||
        !std::isfinite(camera.pitch) || !std::isfinite(camera.yaw) || !std::isfinite(camera.roll) ||
        !std::isfinite(camera.fov) || !(camera.fov >= minFov && camera.fov <= maxFov)) return false;

    Camera normalized = camera;
    normalized.pitch = NormalizeDegrees(camera.pitch);
    normalized.yaw = NormalizeDegrees(camera.yaw);
    normalized.roll = NormalizeDegrees(camera.roll);
    if (!(normalized.pitch >= -90.5f && normalized.pitch <= 90.5f)) return false;
    camera = normalized;
    return true;
}

} // namespace MFUECameraValidation
