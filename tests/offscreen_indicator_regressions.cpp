#include "../app/Sources/HUD/MFOffscreenIndicators.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

static void CheckLayout(const std::vector<MFOffscreenMarker> &markers, float width, float height) {
    for (size_t i = 0; i < markers.size(); ++i) {
        const auto &a = markers[i];
        CHECK(std::isfinite(a.x) && std::isfinite(a.y), "offscreen positions must stay finite");
        CHECK(a.x - a.width / 2 >= 0 && a.x + a.width / 2 <= width &&
              a.y - a.height / 2 >= 0 && a.y + a.height / 2 <= height,
              "every individual offscreen arrow and label must remain inside the viewport");
        for (size_t j = i + 1; j < markers.size(); ++j) {
            const auto &b = markers[j];
            CHECK(std::fabs(a.x - b.x) >= (a.width + b.width) / 2 + 1 ||
                  std::fabs(a.y - b.y) >= (a.height + b.height) / 2 + 1,
                  "individual arrows and distance labels must never overlap");
        }
    }
}

int main() {
    MFOffscreenIndicators groups{};
    MFOffscreenThreat threat{180, 10, 8, false, true, false, false};
    threat.address = 1; threat.labelWidth = 24; threat.labelHeight = 12;
    CHECK(MFOffscreenAdd(groups, threat, true, 7, 80), "an eligible behind-camera human must be included");
    threat.bearingDeg = -179; threat.distanceM = 12; threat.isBot = true; threat.address = 2;
    CHECK(MFOffscreenAdd(groups, threat, true, 7, 80), "rear bearings must remain independently eligible");
    auto markers = MFOffscreenLayout(groups, 640, 720, 60);
    CHECK(markers.size() == 2 && markers[0].threat.address != markers[1].threat.address,
          "two nearby enemies must produce two separate arrows without aggregation");
    CheckLayout(markers, 640, 720);
    CHECK(groups.threatCount == 2, "each accepted enemy must retain its own count");
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
    CHECK(groups.threatCount == 2, "filtered threats must not inflate the displayed threat count");

    MFOffscreenIndicators crowded{}, reversed{};
    threat.isBehind = true;
    for (int i = 1; i <= 24; ++i) {
        threat.address = i; threat.bearingDeg = 180;
        MFOffscreenAdd(crowded, threat, true, 7, 80);
    }
    markers = MFOffscreenLayout(crowded, 844, 390, 60);
    CHECK(markers.size() == 24, "identical bearings must still render one arrow per enemy");
    CheckLayout(markers, 844, 390);
    std::map<uint64_t, std::pair<float, float>> locations;
    for (const auto &marker : markers) locations[marker.threat.address] = {marker.x, marker.y};
    for (int i = 24; i >= 1; --i) { threat.address = i; MFOffscreenAdd(reversed, threat, true, 7, 80); }
    for (const auto &marker : MFOffscreenLayout(reversed, 844, 390, 60))
        CHECK(locations[marker.threat.address] == std::make_pair(marker.x, marker.y),
              "stable entity identities must keep collision placement independent of input order");
    for (int i = 25; i <= 192; ++i) { threat.address = i; MFOffscreenAdd(crowded, threat, true, 7, 80); }
    markers = MFOffscreenLayout(crowded, 320, 480, 500);
    CHECK(markers.size() == 192, "dense supported scenes must keep every arrow, using compact markers if needed");
    CheckLayout(markers, 320, 480);
    CHECK(MFOffscreenLayout(crowded, NAN, 480, 60).empty(), "invalid viewport must not produce markers");
    std::puts("PASS: individual offscreen arrows, stable conflict layout, viewport bounds and threat filters");
}
