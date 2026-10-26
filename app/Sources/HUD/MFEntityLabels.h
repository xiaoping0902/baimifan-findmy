#pragma once
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>

namespace MFEntityLabels {
inline std::string Gear(const char *slot, int level, uint64_t rawID, bool known, float current) {
    if (level < 1 || level > 6) return std::string(slot) + (known && !rawID ? "空" : "?");
    char text[64];
    // The current value is useful even when the maximum is not replicated.
    // NaN marks a failed read; zero is a valid broken piece of equipment.
    if (std::isfinite(current) && current >= 0 && current <= 100000)
        std::snprintf(text, sizeof(text), "%d%s%.0f", level, slot, current);
    else
        std::snprintf(text, sizeof(text), "%d%s?", level, slot);
    return text;
}

inline std::string Bag(int level, uint64_t rawID, bool known) {
    return level >= 1 && level <= 6 ? std::to_string(level) + "包" :
        std::string("包") + (known && !rawID ? "空" : "?");
}

inline std::string PlayerRow(int team, const char *nickname, bool showTeam, bool showName) {
    std::string row;
    if (showTeam) row = team > 0 ? std::to_string(team) : "?";
    if (showName) {
        if (!row.empty()) row += " : ";
        row += nickname && *nickname ? nickname : "玩家未知";
    }
    return row;
}

inline const char *Weapon(const char *name) { return name && *name ? name : "武器未知"; }
inline const char *Hero(const char *name) { return name && *name ? name : "英雄未知"; }
}
