#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

// Dumper-7 SDK: UGPHealthDataComponent::HealthSet + UGPAttributeSetHealth.
// Component + 0x258 is HealthMAX, not a live current-health value.
namespace MFUEHealth {
constexpr uint32_t ComponentOffset = 0x10B8;
constexpr uint32_t AttributeSetOffset = 0x280;
constexpr uint32_t AttributesOffset = 0x30;
constexpr float SanityMaximum = 2000.0f;

struct Snapshot {
    float current = -1.0f;
    float maximum = 0.0f;
    bool known() const {
        return std::isfinite(current) && std::isfinite(maximum) &&
            current >= 0 && maximum > 0 && maximum <= SanityMaximum && current <= maximum;
    }
    float ratio() const { return known() ? current / maximum : 0.0f; }
};

inline bool ValidPointer(uint64_t value) {
    return value >= 0x100000001ULL && value < 0x2F00000000ULL;
}

template <typename ReadBytes>
Snapshot Read(uint64_t actor, ReadBytes read) {
    uint64_t component = 0, attributes = 0;
    if (!ValidPointer(actor) ||
        !read(actor + ComponentOffset, &component, sizeof(component)) || !ValidPointer(component) ||
        !read(component + AttributeSetOffset, &attributes, sizeof(attributes)) || !ValidPointer(attributes))
        return {};
    // Health is a 24-byte attribute; MaxHealth follows as a 16-byte attribute.
    // Their CurrentValue fields are at +0x0C and +0x24 in this block.
    unsigned char values[40] = {};
    if (!read(attributes + AttributesOffset, values, sizeof(values))) return {};
    Snapshot result;
    std::memcpy(&result.current, values + 12, sizeof(float));
    std::memcpy(&result.maximum, values + 36, sizeof(float));
    return result.known() ? result : Snapshot{};
}
} // namespace MFUEHealth
