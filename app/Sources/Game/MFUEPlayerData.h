#pragma once
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace MFUEPlayerData {
struct ArrayHeader { uint64_t data; int32_t num; int32_t maximum; };
struct EquipmentSlot { uint64_t rawID = 0; int level = 0; float health = NAN, maximum = NAN; };
struct Equipment { bool known = false; EquipmentSlot head, armor, bag; };
static_assert(sizeof(ArrayHeader) == 16, "SDK TArray/FString layout");
constexpr uint32_t UINOffset = 0x490;
constexpr uint32_t PrivateNameOffset = 0x470;
constexpr uint32_t PublicNameOffset = 0x378;
constexpr int32_t MaxNameCodeUnits = 32;

inline bool ValidPointer(uint64_t value) {
    return value >= 0x100000001ULL && value < 0x2F00000000ULL;
}

template <typename ReadBytes>
std::u16string ReadFString(uint64_t address, ReadBytes read) {
    ArrayHeader header{};
    if (!read(address, &header, sizeof(header)) || !ValidPointer(header.data) ||
        header.num < 2 || header.num > MaxNameCodeUnits + 1 || header.maximum < header.num) return {};
    char16_t text[MaxNameCodeUnits + 1] = {};
    if (!read(header.data, text, (size_t)header.num * sizeof(char16_t)) || text[header.num - 1] != 0) return {};
    // SDK FString::ToString uses NumElements - 1: the last code unit is the NUL.
    const size_t length = (size_t)header.num - 1;
    for (size_t i = 0; i < length; ++i) {
        const uint16_t c = text[i];
        if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) return {};
        if (c >= 0xD800 && c <= 0xDBFF) {
            if (++i >= length || text[i] < 0xDC00 || text[i] > 0xDFFF) return {};
        } else if (c >= 0xDC00 && c <= 0xDFFF) return {};
    }
    return std::u16string(text, length);
}

template <typename ReadBytes>
std::u16string ReadName(uint64_t playerState, ReadBytes read) {
    if (!ValidPointer(playerState)) return {};
    auto name = ReadFString(playerState + PrivateNameOffset, read);
    return name.empty() ? ReadFString(playerState + PublicNameOffset, read) : name;
}

template <typename ReadBytes>
uint64_t ReadUIN(uint64_t playerState, ReadBytes read) {
    uint64_t uin = 0;
    return ValidPointer(playerState) && read(playerState + UINOffset, &uin, sizeof(uin)) ? uin : 0;
}

template <typename ReadBytes>
uint64_t ReadHeroID(uint64_t actor, ReadBytes read) {
    uint64_t fashion = 0, id = 0;
    // SDK ADFMCharacter.CharacterFashionComponent / currentCharacterHeroID.
    if (!ValidPointer(actor) || !read(actor + 0x26A8, &fashion, 8) || !ValidPointer(fashion) ||
        !read(fashion + 0x508, &id, 8)) return 0;
    return id;
}

template <typename ReadBytes>
std::u16string ReadFText(uint64_t address, ReadBytes read) {
    uint64_t textData = 0;
    // SDK Basic.hpp: FText.TextData -> FTextData.TextSource FString (+0x48).
    return read(address, &textData, 8) && ValidPointer(textData) ? ReadFString(textData + 0x48, read) : std::u16string{};
}

// GPPlayerState.CurrentCharacterLiveStatus is a replicated int32; its enum
// distinguishes rescuable ImpendingDeath from Death. Health==0 is not death.
template <typename ReadBytes>
bool IsFullyDead(uint64_t actor, ReadBytes read) {
    if (!ValidPointer(actor)) return false;
    uint64_t playerState = 0;
    int32_t status = 0;
    if (read(actor + 0x390, &playerState, sizeof(playerState)) && ValidPointer(playerState) &&
        read(playerState + 0x944, &status, sizeof(status))) {
        if (status == 1 || status == 3) return false;
        if (status == 2) return true;
    }
    uint8_t dead = 0;
    return read(actor + 0xDC8, &dead, sizeof(dead)) && dead == 1;
}

inline EquipmentSlot *SlotForID(Equipment &result, uint64_t itemID) {
    if (itemID < 10000000000ULL || itemID > 19999999999ULL) return nullptr;
    const unsigned type = (unsigned)((itemID / 10000000ULL) % 1000ULL);
    return type == 101 ? &result.head : type == 105 ? &result.armor : type == 108 ? &result.bag : nullptr;
}

inline void ReadCurrentDurability(const unsigned char *record, size_t healthOffset,
                                  size_t durabilityOffset, EquipmentSlot &slot) {
    if (std::isfinite(slot.health)) return;
    for (const size_t offset : {healthOffset, durabilityOffset}) {
        float health = NAN, maximum = NAN;
        std::memcpy(&health, record + offset, sizeof(float));
        std::memcpy(&maximum, record + offset + 4, sizeof(float));
        const bool validMaximum = std::isfinite(maximum) && maximum > 0 && maximum <= 10000;
        // Replication can provide current HP before its maximum. A zero value
        // is broken equipment; NAN alone means the read could not establish HP.
        if (!std::isfinite(health) || health < 0 || health > 10000) continue;
        slot.health = health;
        slot.maximum = validMaximum ? maximum : NAN;
        return;
    }
}

template <typename ReadBytes>
bool ReadEquipmentArray(uint64_t component, uint32_t offset, size_t stride,
                        size_t itemOffset, bool durability, Equipment &result, ReadBytes read) {
    ArrayHeader header{};
    if (!read(component + offset, &header, sizeof(header)) || header.num < 0 || header.num > 32 ||
        header.maximum < header.num) return false;
    if (header.num == 0) return true;
    if (!ValidPointer(header.data)) return false;
    // Read each complete record; a failed record must not establish empty slots.
    bool complete = true;
    for (int32_t i = 0; i < header.num; ++i) {
        unsigned char record[0x40] = {};
        const size_t readSize = durability ? sizeof(record) : stride;
        if (!read(header.data + (uint64_t)i * stride, record, readSize)) { complete = false; continue; }
        uint64_t id = 0;
        std::memcpy(&id, record + itemOffset, sizeof(id));
        if (!id) continue;
        EquipmentSlot *encodedSlot = SlotForID(result, id);
        EquipmentSlot *slot = encodedSlot;
        // SDK GPGameplay::EEquipmentType is authoritative for armor records:
        // Helmet=1, BreastPlate=5, Bag=8. Preserve unknown nonzero IDs so a
        // failed level decode cannot turn an equipped slot into "empty".
        if (durability) {
            const uint8_t type = record[0];
            slot = type == 1 ? &result.head : type == 5 ? &result.armor : type == 8 ? &result.bag : encodedSlot;
        }
        if (!slot) continue;
        const int encodedLevel = (int)((id / 1000ULL) % 10ULL);
        const int level = encodedSlot == slot && encodedLevel >= 1 && encodedLevel <= 6 ? encodedLevel : 0;
        if (!slot->rawID) { slot->rawID = id; slot->level = level; }
        if (slot != &result.bag && slot->rawID == id) {
            // FArmorInfo: ArmorHP/MaxArmorHP at 0x18, Durability at 0x20.
            // FEquipmentInfo: Health/MaxHealth at 0x10, Durability at 0x18.
            ReadCurrentDurability(record, durability ? 0x18 : 0x10,
                                  durability ? 0x20 : 0x18, *slot);
        }
    }
    return complete;
}

template <typename ReadBytes>
Equipment ReadEquipment(uint64_t actor, ReadBytes read) {
    Equipment result;
    uint64_t component = 0;
    if (!ValidPointer(actor) || !read(actor + 0x24E0, &component, sizeof(component)) || !ValidPointer(component)) return result;
    // DFMGameplay_structs.hpp: FArmorInfo is 0x88 bytes; only its leading
    // fields through durability are required here. FEquipmentInfo is 0x30.
    const bool armorComplete = ReadEquipmentArray(component, 0x1E8, 0x88, 8, true, result, read);
    const bool equipmentComplete = ReadEquipmentArray(component, 0x1D8, 0x30, 0, false, result, read);
    result.known = armorComplete && equipmentComplete;
    return result;
}
}
