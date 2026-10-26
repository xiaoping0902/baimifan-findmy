#include "../app/Sources/HUD/MFOffscreenIndicators.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main() {
    MFOffscreenIndicators groups{};
    MFOffscreenThreat threat{180, 10, 8, false, true, false, false};
    CHECK(MFOffscreenAdd(groups, threat, true, 7, 80), "an eligible behind-camera human must be included");
    threat.bearingDeg = -179; threat.distanceM = 12; threat.isBot = true;
    CHECK(MFOffscreenAdd(groups, threat, true, 7, 80), "bearings across the -180/180 seam must remain eligible");
    CHECK(groups.threatCount == 2 && groups.buckets[6].count == 2 && groups.buckets[6].hasHuman &&
          groups.buckets[6].nearestM == 10 && groups.buckets[6].bearingDeg == 180,
          "neighbors across the rear seam must share their nearest distance and retain human priority");
    threat.bearingDeg = 120; threat.distanceM = 20;
    CHECK(MFOffscreenAdd(groups, threat, true, 7, 80) && groups.buckets[4].count == 1 &&
          !groups.buckets[4].hasHuman, "a separate all-bot bearing must keep its own marker and classification");
    CHECK(!MFOffscreenAdd(groups, threat, false, 7, 80), "hiding bots must suppress offscreen alerts");
    threat.isBot = false; threat.teamID = 7;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "known teammates must never trigger offscreen alerts");
    threat.teamID = 8; threat.isLoot = true;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "loot must not trigger offscreen alerts");
    threat.isLoot = false; threat.isBox = true;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "containers must not trigger offscreen alerts");
    threat.isBox = false; threat.distanceM = 81;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "the offscreen distance limit must be enforced");
    threat.distanceM = 0;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "unknown distances must not fabricate a zero-meter warning");
    threat.distanceM = NAN;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "nonfinite distances must be rejected");
    threat.distanceM = 10; threat.bearingDeg = NAN;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "nonfinite bearings must never create geometry");
    threat.bearingDeg = 90;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "front/side bearings must not become behind warnings");
    threat.bearingDeg = 180; threat.isBehind = false;
    CHECK(!MFOffscreenAdd(groups, threat, true, 7, 80), "only a confirmed behind target may enter the indicator");
    CHECK(groups.threatCount == 3, "filtered threats must not inflate the displayed threat count");
    MFOffscreenIndicators boundary{};
    threat.isBehind = true; threat.bearingDeg = 104.999f; threat.distanceM = 15;
    CHECK(MFOffscreenAdd(boundary, threat, true, 7, 80), "left edge of a rear sector must stay eligible");
    threat.bearingDeg = 105.001f; threat.distanceM = 10; threat.isBot = true;
    CHECK(MFOffscreenAdd(boundary, threat, true, 7, 80), "right edge of a rear sector must stay eligible");
    int visibleMarkers = 0;
    for (const auto &bucket : boundary.buckets) if (bucket.count) ++visibleMarkers;
    CHECK(visibleMarkers == 1,
          "nearly identical bearings across a sector boundary must share one marker");
    CHECK(boundary.threatCount == 2 && boundary.buckets[4].count == 2 &&
          boundary.buckets[4].nearestM == 10 && boundary.buckets[4].hasHuman,
          "cross-boundary merging must preserve total count, closest range and human priority");
    std::puts("PASS: offscreen aggregation, rear seam, nearest distance and threat filters");
}
