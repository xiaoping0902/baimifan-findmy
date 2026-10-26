#include "../app/Sources/Game/MFUEPlayerData.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <vector>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main() {
    const uint64_t ps = 0x100001000, nameData = 0x100002000;
    const uint64_t actor = 0x100003000, equipment = 0x100004000;
    const uint64_t armorData = 0x100005000, infoData = 0x100006000;
    std::map<uint64_t, std::vector<unsigned char>> memory;
    auto put = [&](uint64_t address, auto value) {
        auto &bytes = memory[address]; bytes.resize(sizeof(value));
        std::memcpy(bytes.data(), &value, sizeof(value));
    };
    auto read = [&](uint64_t address, void *out, size_t size) {
        const auto it = memory.find(address);
        if (it == memory.end() || it->second.size() < size) return false;
        std::memcpy(out, it->second.data(), size); return true;
    };
    auto stringAt = [&](uint64_t offset, std::u16string name) {
        name.push_back(0); // FString::Num includes this terminator in the SDK.
        const MFUEPlayerData::ArrayHeader header{nameData, (int32_t)name.size(), (int32_t)name.size()};
        put(ps + offset, header);
        memory[nameData].resize(name.size() * 2);
        std::memcpy(memory[nameData].data(), name.data(), name.size() * 2);
    };
    stringAt(0x470, u"白米饭玩家");
    CHECK(MFUEPlayerData::ReadName(ps, read) == u"白米饭玩家", "valid terminated Chinese name must not fall back to UIN");
    stringAt(0x470, u"Player\U0001F642");
    CHECK(MFUEPlayerData::ReadName(ps, read) == u"Player\U0001F642", "valid UTF-16 surrogate pairs must survive decoding");
    stringAt(0x470, u"123456");
    CHECK(MFUEPlayerData::ReadName(ps, read) == u"123456", "numeric player-authored names are still valid names");
    stringAt(0x470, std::u16string(32, u'A'));
    CHECK(MFUEPlayerData::ReadName(ps, read).size() == 32, "32 content code units plus terminator must fit");
    stringAt(0x470, u"Bad\nName");
    CHECK(MFUEPlayerData::ReadName(ps, read).empty(), "embedded controls must be rejected");
    stringAt(0x470, std::u16string({u'A', 0, u'B'}));
    CHECK(MFUEPlayerData::ReadName(ps, read).empty(), "embedded NUL must not truncate into a plausible name");
    stringAt(0x470, std::u16string({u'A', char16_t(0xD800)}));
    CHECK(MFUEPlayerData::ReadName(ps, read).empty(), "unpaired surrogate must be rejected");
    stringAt(0x378, u"ReplicatedName");
    memory.erase(ps + 0x470);
    CHECK(MFUEPlayerData::ReadName(ps, read) == u"ReplicatedName", "SDK public PlayerName is a fallback when private name is unavailable");
    memory.erase(ps + 0x378);
    CHECK(MFUEPlayerData::ReadName(ps, read).empty(), "unreadable name must stay unknown");
    put(ps + 0x490, uint64_t(99887766)); put(ps + 0x320, uint64_t(123));
    CHECK(MFUEPlayerData::ReadUIN(ps, read) == 99887766, "UIN must come from ABasePlayerState::Uin at 0x490");

    put(actor + 0x390, ps); put(actor + 0xDC8, uint8_t(1));
    put(ps + 0x944, int32_t(3));
    CHECK(!MFUEPlayerData::IsFullyDead(actor, read), "ImpendingDeath must remain drawable even when the dead-info flag is set");
    put(ps + 0x944, int32_t(2));
    CHECK(MFUEPlayerData::IsFullyDead(actor, read), "Death status must be excluded");
    put(ps + 0x944, int32_t(1));
    CHECK(!MFUEPlayerData::IsFullyDead(actor, read), "Alive status must override a stale dead-info flag");
    memory.erase(ps + 0x944);
    CHECK(MFUEPlayerData::IsFullyDead(actor, read), "missing status retains the SDK dead-info fallback");
    memory.erase(actor + 0xDC8);
    CHECK(!MFUEPlayerData::IsFullyDead(actor, read), "unreadable death state must not hide a target");

    put(actor + 0x24E0, equipment);
    put(equipment + 0x1D8, MFUEPlayerData::ArrayHeader{0, 0, 0});
    put(equipment + 0x1E8, MFUEPlayerData::ArrayHeader{0, 0, 0});
    auto gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.known && gear.head.level == 0 && gear.armor.level == 0 && gear.bag.level == 0,
          "fully read empty equipment arrays must be known empty");
    put(equipment + 0x1E8, MFUEPlayerData::ArrayHeader{armorData, 1, 1});
    memory[armorData].resize(0x40);
    const uint64_t helmet = 11010005002ULL;
    memory[armorData][0] = 1;
    std::memcpy(memory[armorData].data() + 8, &helmet, 8);
    const float current = 12, maximum = 45;
    std::memcpy(memory[armorData].data() + 0x18, &current, 4);
    std::memcpy(memory[armorData].data() + 0x1C, &maximum, 4);
    put(equipment + 0x1D8, MFUEPlayerData::ArrayHeader{infoData, 1, 1});
    memory[infoData].resize(0x30);
    const uint64_t bag = 11080003001ULL;
    std::memcpy(memory[infoData].data(), &bag, 8);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.known && gear.head.level == 5 && gear.head.rawID == helmet &&
          gear.head.health == 12 && gear.head.maximum == 45 && gear.bag.level == 3 && gear.bag.rawID == bag && gear.armor.level == 0,
          "SDK armor and equipment arrays must yield IDs, levels, durability, and absent armor");
    put(equipment + 0x1E8, MFUEPlayerData::ArrayHeader{armorData, 2, 2});
    const uint64_t bodyArmor = 11050006001ULL;
    memory[armorData + 0x88].resize(0x40);
    memory[armorData + 0x88][0] = 5;
    std::memcpy(memory[armorData + 0x88].data() + 8, &bodyArmor, 8);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.known && gear.armor.level == 6 && gear.armor.rawID == bodyArmor,
          "second FArmorInfo must be read at the SDK 0x88 stride, not legacy 0x40");
    memory[infoData].resize(8); // partial record cannot establish absence in remaining slots.
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(!gear.known && gear.head.level == 5, "partial arrays must preserve valid slots while keeping absent slots unknown");
    put(equipment + 0x1D8, MFUEPlayerData::ArrayHeader{infoData, 33, 33});
    CHECK(!MFUEPlayerData::ReadEquipment(actor, read).known, "oversized array must fail closed");
    put(equipment + 0x1D8, MFUEPlayerData::ArrayHeader{0, 0, 0});
    put(equipment + 0x1E8, MFUEPlayerData::ArrayHeader{armorData, 1, 1});
    const uint64_t futureItem = 987654321ULL;
    std::memcpy(memory[armorData].data() + 8, &futureItem, 8);
    for (uint8_t type : {uint8_t(1), uint8_t(5), uint8_t(8)}) {
        memory[armorData][0] = type;
        gear = MFUEPlayerData::ReadEquipment(actor, read);
        const auto &slot = type == 1 ? gear.head : type == 5 ? gear.armor : gear.bag;
        CHECK(gear.known && slot.rawID == futureItem && slot.level == 0,
              "SDK equipment enum must preserve a nonzero unknown ID so it displays unknown, not empty");
    }
    memory[armorData][0] = 99;
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.rawID == 0 && gear.armor.rawID == 0 && gear.bag.rawID == 0,
          "unknown enum and unknown ID must not invent a head/armor/bag slot");
    put(equipment + 0x1E8, MFUEPlayerData::ArrayHeader{0, 0, 0});
    put(equipment + 0x1D8, MFUEPlayerData::ArrayHeader{infoData, 1, 1});
    memory[infoData].resize(0x30);
    const uint64_t unknownLevelBag = 11080000001ULL;
    std::memcpy(memory[infoData].data(), &unknownLevelBag, 8);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.known && gear.bag.rawID == unknownLevelBag && gear.bag.level == 0,
          "known encoded equipment type with unknown level must preserve ID for '?' rendering");
    puts("PASS: SDK player names, UIN, equipment records, known empty and unreadable states");
}
