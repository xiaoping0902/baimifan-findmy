#pragma once
#include <cstdint>

namespace MFHeroNames {
// Exact ExpertId values and labels from the user's supplied 干员名字表.md.
// HeroID is a distinct replicated field; do not use it as this table's key.
// Some labels are community nicknames; a live localized HeroData name takes priority.
inline const char *NameForID(uint64_t id) {
    switch (id) {
        case 10007: return u8"红狼";
        case 10010: return u8"威龙";
        case 10011: return u8"无名";
        case 10012: return u8"张姐";
        case 20003: return u8"疯医";
        case 20004: return u8"女医";
        case 20005: return u8"蝶";
        case 20006: return u8"养狗的";
        case 30008: return u8"老黑";
        case 30009: return u8"比特";
        case 30010: return u8"盾狗";
        case 30011: return u8"乌鲁鲁";
        case 30012: return u8"液氮";
        case 40005: return u8"露娜";
        case 40010: return u8"骇爪";
        case 40011: return u8"老头";
        default: return nullptr;
    }
}

inline const char *Resolve(uint64_t id, const char *localized) {
    return localized && *localized ? localized : NameForID(id);
}
}
