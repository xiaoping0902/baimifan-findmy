#pragma once
#include <cmath>

// A prone or knocked-down person can have a small vertical extent. Validate
// the complete spatial extent and link lengths instead of standing height.
inline bool MFBoneGeometryValid(const float (*points)[3], int count,
                                const int *links, int linkCount) {
    float lo[3] = {1.e9f, 1.e9f, 1.e9f}, hi[3] = {-1.e9f, -1.e9f, -1.e9f};
    for (int i = 0; i < count; ++i)
        for (int axis = 0; axis < 3; ++axis) {
            const float value = points[i][axis];
            if (!std::isfinite(value) || std::fabs(value) >= 1.e7f) return false;
            lo[axis] = std::fmin(lo[axis], value); hi[axis] = std::fmax(hi[axis], value);
        }
    const float x = hi[0] - lo[0], y = hi[1] - lo[1], z = hi[2] - lo[2];
    const float span = std::sqrt(x*x + y*y + z*z);
    if (span < 35.f || span > 320.f) return false;
    for (int i = 0; i < linkCount; ++i) {
        const int a = links[2*i], b = links[2*i+1];
        if (a < 0 || b < 0 || a >= count || b >= count) return false;
        const float dx = points[a][0]-points[b][0], dy = points[a][1]-points[b][1], dz = points[a][2]-points[b][2];
        if (dx*dx + dy*dy + dz*dz > 150.f*150.f) return false;
    }
    return true;
}
