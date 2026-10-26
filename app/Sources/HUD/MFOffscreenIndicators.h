#pragma once
#include <cmath>
#include <cstdint>

struct MFOffscreenThreat {
    float bearingDeg, distanceM;
    int teamID;
    bool isBot, isBehind, isLoot, isBox;
};

struct MFOffscreenBucket {
    int count = 0;
    float nearestM = 0, bearingDeg = 0;
    bool hasHuman = false;
};

struct MFOffscreenIndicators {
    static constexpr int kBucketCount = 12;
    MFOffscreenBucket buckets[kBucketCount];
    int threatCount = 0;
};

static inline void MFOffscreenMerge(MFOffscreenBucket &target, MFOffscreenBucket &source) {
    if (!target.count || source.nearestM < target.nearestM) {
        target.nearestM = source.nearestM;
        target.bearingDeg = source.bearingDeg;
    }
    target.count += source.count;
    target.hasHuman = target.hasHuman || source.hasHuman;
    source = {};
}

static inline bool MFOffscreenAdd(MFOffscreenIndicators &groups, const MFOffscreenThreat &threat,
                                  bool showBot, uint32_t localTeam, float maxDistance) {
    if (!threat.isBehind || threat.isLoot || threat.isBox || (threat.isBot && !showBot) ||
        (localTeam != 0 && threat.teamID == static_cast<int>(localTeam))) return false;
    if (!std::isfinite(threat.bearingDeg) || !std::isfinite(threat.distanceM) ||
        threat.distanceM <= 0 || (maxDistance > 0 && threat.distanceM > maxDistance)) return false;
    const float bearing = std::remainder(threat.bearingDeg, 360.0f);
    if (std::fabs(bearing) <= 90.0f) return false;
    // Round around the circular seam so -179 and +179 share the rear marker.
    int sector = static_cast<int>(std::floor(bearing / 30.0f + 0.5f));
    sector = (sector + MFOffscreenIndicators::kBucketCount) % MFOffscreenIndicators::kBucketCount;
    MFOffscreenBucket &bucket = groups.buckets[sector];
    if (bucket.count == 0 || threat.distanceM < bucket.nearestM) {
        bucket.nearestM = threat.distanceM;
        bucket.bearingDeg = bearing;
    }
    ++bucket.count;
    bucket.hasHuman = bucket.hasHuman || !threat.isBot;
    ++groups.threatCount;
    // A sector boundary must not split practically identical directions into
    // overlapping markers. Merge close neighbors, including the circular seam.
    for (int pass = 0; pass < MFOffscreenIndicators::kBucketCount; ++pass) {
        bool merged = false;
        for (int i = 0; i < MFOffscreenIndicators::kBucketCount; ++i) {
            auto &left = groups.buckets[i];
            auto &right = groups.buckets[(i + 1) % MFOffscreenIndicators::kBucketCount];
            if (!left.count || !right.count ||
                std::fabs(std::remainder(left.bearingDeg - right.bearingDeg, 360.0f)) > 15.0f) continue;
            // Keep the representative in the bucket containing the nearer
            // target, so later additions use the same sector consistently.
            if (right.nearestM < left.nearestM) MFOffscreenMerge(right, left);
            else MFOffscreenMerge(left, right);
            merged = true;
        }
        if (!merged) break;
    }
    return true;
}
