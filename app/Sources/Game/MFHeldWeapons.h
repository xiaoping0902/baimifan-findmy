#pragma once
#include <cstddef>
#include <cstdint>

namespace MFHeldWeapons {
// Verified 32-bit handheld IDs from the supplied weapon_dict.txt. They are
// distinct from the 64-bit inventory IDs in MFItemNames; do not remap by digits.
inline const char *NameForID(uint64_t id) {
    // The reference's int32 lookup truncates inventory IDs, e.g.
    // 18010000001 -> 830130817 (M4A1). Preserve the full ID during reads.
    if (id >= 10000000000ULL && id <= 19999999999ULL) id = (uint32_t)id;
    switch (id) {
        case 920130818: return u8"小刀";
        case 830130817: return "M4A1";
        case 830130833: return "SG552";
        case 830130853: return "AS Val";
        case 830130847: return "CAR-15";
        case 830130840: return "PTR-32";
        case 830130839: return "G3";
        case 830130837: return "SCAR-H";
        case 830130834: return "AK-12";
        case 830130832: return "M7";
        case 830130831: return "AUG";
        case 830130830: return "M16A4";
        case 830130829: return "M416";
        default: return nullptr;
    }
}

template <typename ReadBytes>
uint64_t ReadID(uint64_t address, ReadBytes read) {
    uint64_t id = 0;
    // AWeaponBase::WeaponID is uint64 at +0x838 in the supplied SDK.
    // A compact ID may be stored in that field, but its read width stays 8 bytes.
    return read(address, &id, sizeof(id)) ? id : 0;
}
}
