#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

struct MFOffscreenThreat {
    float bearingDeg, distanceM;
    int teamID;
    bool isBot, isBehind, isLoot, isBox;
    uint64_t address = 0;
    float labelWidth = 0, labelHeight = 0;
};

struct MFOffscreenIndicators {
    std::vector<MFOffscreenThreat> threats;
    int threatCount = 0;
};

struct MFOffscreenMarker {
    MFOffscreenThreat threat;
    float x, y, width, height;
    bool showLabel;
};

static inline bool MFOffscreenAdd(MFOffscreenIndicators &groups, MFOffscreenThreat threat,
                                  bool showBot, uint32_t localTeam, float maxDistance) {
    if (!threat.isBehind || threat.isLoot || threat.isBox || (threat.isBot && !showBot) ||
        (localTeam != 0 && threat.teamID == static_cast<int>(localTeam))) return false;
    if (!std::isfinite(threat.bearingDeg) || !std::isfinite(threat.distanceM) ||
        threat.distanceM <= 0 || (maxDistance > 0 && threat.distanceM > maxDistance)) return false;
    threat.bearingDeg = std::remainder(threat.bearingDeg, 360.0f);
    if (std::fabs(threat.bearingDeg) <= 90.0f) return false;
    groups.threats.push_back(threat);
    groups.threatCount = static_cast<int>(groups.threats.size());
    return true;
}

// Keep one independent marker per enemy. Order by true angle and identity,
// then select the nearest free cell to that angle's requested ring position.
// Arrow orientation retains the exact bearing even when a conflict moves it.
static inline std::vector<MFOffscreenMarker> MFOffscreenLayout(const MFOffscreenIndicators &groups,
                                                              float width, float height, float radius) {
    std::vector<MFOffscreenMarker> result;
    if (!std::isfinite(width) || !std::isfinite(height) || width < 32 || height < 32 || groups.threats.empty()) return result;
    auto ordered = groups.threats;
    auto angle = [](float value) { return value < 0 ? value + 360 : value; };
    std::sort(ordered.begin(), ordered.end(), [&](const auto &a, const auto &b) {
        if (angle(a.bearingDeg) != angle(b.bearingDeg)) return angle(a.bearingDeg) < angle(b.bearingDeg);
        if (a.address != b.address) return a.address < b.address;
        if (a.distanceM != b.distanceM) return a.distanceM < b.distanceM;
        return a.teamID < b.teamID;
    });
    float cardWidth = 52, cardHeight = 20;
    for (const auto &threat : ordered) {
        if (std::isfinite(threat.labelWidth)) cardWidth = std::max(cardWidth, threat.labelWidth + 24);
        if (std::isfinite(threat.labelHeight)) cardHeight = std::max(cardHeight, threat.labelHeight + 6);
    }
    constexpr float margin = 6, gap = 4;
    int columns = static_cast<int>((width - margin * 2 + gap) / (cardWidth + gap));
    int rows = static_cast<int>((height - margin * 2 + gap) / (cardHeight + gap));
    bool showLabel = columns > 0 && rows > 0 && size_t(columns) * rows >= ordered.size();
    if (!showLabel) {
        // In dense scenes keep every direction arrow; compact spacing has no
        // distance text to collide. Ordinary scenes keep individual distances.
        cardWidth = cardHeight = 18;
        columns = static_cast<int>((width - margin * 2 + gap) / (cardWidth + gap));
        rows = static_cast<int>((height - margin * 2 + gap) / (cardHeight + gap));
    }
    if (columns <= 0 || rows <= 0) return result;
    struct Cell { float x, y; bool used = false; };
    std::vector<Cell> cells;
    const float startX = (width - (columns * cardWidth + (columns - 1) * gap)) * 0.5f + cardWidth * 0.5f;
    const float startY = (height - (rows * cardHeight + (rows - 1) * gap)) * 0.5f + cardHeight * 0.5f;
    for (int row = 0; row < rows; ++row)
        for (int column = 0; column < columns; ++column)
            cells.push_back({startX + column * (cardWidth + gap), startY + row * (cardHeight + gap)});
    const float safeRadius = std::isfinite(radius) ? std::max(0.0f, std::min(radius, std::min(width, height) * 0.5f - 16)) : 60;
    result.reserve(std::min(ordered.size(), cells.size()));
    constexpr float degToRad = 0.01745329251994329577f;
    for (const auto &threat : ordered) {
        const float rad = (threat.bearingDeg - 90) * degToRad;
        const float preferredX = width * 0.5f + std::cos(rad) * safeRadius;
        const float preferredY = height * 0.5f + std::sin(rad) * safeRadius;
        size_t best = cells.size();
        float bestScore = std::numeric_limits<float>::infinity();
        for (size_t i = 0; i < cells.size(); ++i) {
            if (cells[i].used) continue;
            const float dx = cells[i].x - preferredX, dy = cells[i].y - preferredY;
            const float score = dx * dx + dy * dy;
            if (score < bestScore) { bestScore = score; best = i; }
        }
        if (best == cells.size()) break;
        Cell &cell = cells[best]; cell.used = true;
        result.push_back({threat, cell.x, cell.y, cardWidth, cardHeight, showLabel});
    }
    return result;
}
