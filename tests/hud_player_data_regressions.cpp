#include "../app/Sources/Game/MFUEPlayerData.h"
#include "../app/Sources/Game/MFUEDataTable.h"
#include "../app/Sources/Game/MFHeldWeapons.h"
#include "../app/Sources/Game/MFHeroNames.h"
#include "../app/Sources/Game/MFNPCNames.h"
#include "../app/Sources/Kernel/MFDeviceCompatibility.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <vector>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main() {
    constexpr uint64_t gb = 1024ULL * 1024 * 1024;
    auto device = mf_device_configuration(16, 6, 1, 0x07d34b9f, 6 * gb);
    CHECK(device.status == MF_DEVICE_SUPPORTED && device.method == 2 && device.pages == 1024,
          "the connected A12Z tablet on 16.6.1 must select landa with the reduced page count");
    CHECK(!mf_device_method_allowed(device, 0) && !mf_device_method_allowed(device, 1),
          "patched old methods must be refused on 16.6.1 before an attempt");
    device = mf_device_configuration(16, 1, 0, 0xda33d83d, 8 * gb);
    CHECK(device.status == MF_DEVICE_SUPPORTED && device.method == 0 && device.pages == 1024,
          "the previously validated M2 16.1 bootstrap must retain physpuppet and 1024 pages");
    CHECK(!mf_device_method_allowed(device, 2), "the known unreliable landa-on-16.1 route must not run");
    for (auto v : {std::array<int,3>{16,3,1}, {16,4,0}, {16,5,0}, {16,5,1}, {16,6,0}, {16,6,1}}) {
        device = mf_device_configuration(v[0], v[1], v[2], 0x462504d2, 4 * gb);
        const int expected = v[1] <= 3 ? 0 : (v[1] < 5 || (v[1] == 5 && v[2] == 0) ? 1 : 2);
        CHECK(device.status == MF_DEVICE_SUPPORTED && device.method == expected && device.pages == 512 &&
              mf_device_method_allowed(device, expected), "method boundaries must honor patched OS releases on phones");
    }
    for (auto family : {0x07d34b9fu, 0x462504d2u, 0x1b588bb3u, 0xda33d83du, 0x8765edeau})
        CHECK(mf_device_configuration(16,6,1,family,6*gb).status == MF_DEVICE_SUPPORTED,
              "the existing arm64e offset family must accept A12 through A16 and M1/M2 chips");
    /* [M5.229] 15.x 现在放行：链形状由 MFChainCalib 覆盖，成不成由 kopen 的返回值裁决。
     * 但"放行"只等于 method 0（physpuppet），不许借用 16.4+ 的 smith/landa。 */
    for (auto v : {std::array<int,3>{15,0,0}, {15,6,1}, {15,8,0}}) {
        device = mf_device_configuration(v[0], v[1], v[2], 0x07d34b9f, 6 * gb);
        CHECK(device.status == MF_DEVICE_SUPPORTED && device.method == 0 && device.pages == 1024 &&
              mf_device_method_allowed(device, 0),
              "iOS 15 must be allowed to try physpuppet instead of being refused by the version table");
        CHECK(!mf_device_method_allowed(device, 1) && !mf_device_method_allowed(device, 2),
              "iOS 15 must not borrow the 16.4+ smith or landa routes");
    }
    for (auto v : {std::array<int,3>{14,8,0}, {16,6,2}, {16,7,0}, {17,0,0}, {16,-1,0}}) {
        device = mf_device_configuration(v[0], v[1], v[2], 0x07d34b9f, 6 * gb);
        CHECK(device.status == MF_DEVICE_UNSUPPORTED_OS && device.method == -1 && device.pages == 0 &&
              !mf_device_method_allowed(device, 0), "unsupported offset releases must not produce executable kernel settings");
    }
    CHECK(mf_device_configuration(16,6,1,0x37b32da7,2*gb).status == MF_DEVICE_UNSUPPORTED_CHIP &&
          mf_device_configuration(16,6,1,0,6*gb).status == MF_DEVICE_UNSUPPORTED_CHIP,
          "A8-A11 and unknown chips must not reuse arm64e offsets");
    CHECK(!MFHeroNames::UsesBotHUD(true, 10007) && !MFHeroNames::UsesBotHUD(true, 40011),
          "AI using a verified playable operator must use human HUD rules");
    CHECK(MFHeroNames::UsesBotHUD(true, 0) && MFHeroNames::UsesBotHUD(true, 99999) &&
          MFHeroNames::UsesBotHUD(true, 10010007),
          "ordinary AI and unknown IDs must not be promoted by an ID suffix or a guessed hero");
    CHECK(!MFHeroNames::UsesBotHUD(false, 0) && !MFHeroNames::UsesBotHUD(false, 20003),
          "human targets remain human with or without operator metadata");
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
    put(actor+0xE60,uint8_t(1));
    CHECK(MFUEPlayerData::ReadBotIdentity(actor,read),
          "the SDK player-AI flag must survive a valid PlayerState pointer");
    put(actor+0xE60,uint8_t(0));
    CHECK(!MFUEPlayerData::ReadBotIdentity(actor,read),"an unflagged player with valid PlayerState remains human");
    put(actor+0xE61,uint8_t(1));
    CHECK(MFUEPlayerData::ReadBotIdentity(actor,read),"the SDK SOL player-AI flag must identify AI with PlayerState");
    put(actor+0xE61,uint8_t(0));
    put(ps+0x39E,uint8_t(0x08));
    CHECK(MFUEPlayerData::ReadBotIdentity(actor,read),"APlayerState bIsABot identifies a replicated bot independently of actor AI flags");
    put(ps+0x39E,uint8_t(0x01));
    CHECK(!MFUEPlayerData::ReadBotIdentity(actor,read),"neighboring PlayerState bits must not identify a bot");
    put(actor+0xE61,uint8_t(2));
    CHECK(!MFUEPlayerData::ReadBotIdentity(actor,read),"out-of-range SDK bool bytes must not establish AI identity");
    put(actor+0xE61,uint8_t(0));
    put(actor+0x390,uint64_t(0));
    CHECK(MFUEPlayerData::ReadBotIdentity(actor,read),"a confirmed absent PlayerState identifies ordinary AI");
    memory.erase(actor+0x390);
    CHECK(!MFUEPlayerData::ReadBotIdentity(actor,read),"failed PlayerState reads must not change human identity to AI");
    put(actor+0x390,ps);
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
    const float unknownMax = 0, broken = 0, nan = std::numeric_limits<float>::quiet_NaN();
    std::memcpy(memory[armorData].data() + 0x1C, &unknownMax, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.health == 12 && std::isnan(gear.head.maximum),
          "valid current armor HP must survive an unavailable maximum");
    const float staleMaximum = 1;
    std::memcpy(memory[armorData].data() + 0x1C, &staleMaximum, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.health == 12, "a stale replicated maximum must not erase valid current armor HP");
    std::memcpy(memory[armorData].data() + 0x18, &broken, 4);
    std::memcpy(memory[armorData].data() + 0x1C, &maximum, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.health == 0, "broken armor must preserve zero current HP");
    std::memcpy(memory[armorData].data() + 0x18, &nan, 4);
    std::memcpy(memory[armorData].data() + 0x20, &current, 4);
    std::memcpy(memory[armorData].data() + 0x24, &maximum, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.health == 12, "SDK Durability is a fallback when ArmorHP is invalid");
    std::memcpy(memory[armorData].data() + 0x18, &current, 4);
    std::memcpy(memory[armorData].data() + 0x20, &broken, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.health == 12, "zero Durability must not replace valid ArmorHP");
    std::memcpy(memory[armorData].data() + 0x18, &nan, 4);
    std::memcpy(memory[armorData].data() + 0x20, &nan, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(std::isnan(gear.head.health), "unreadable current HP must remain unknown, not zero");
    std::memcpy(memory[infoData].data(), &helmet, 8);
    std::memcpy(memory[infoData].data() + 0x10, &current, 4);
    std::memcpy(memory[infoData].data() + 0x14, &maximum, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.health == 12, "matching SDK equipment Health fills unavailable armor HP");
    std::memcpy(memory[armorData].data() + 0x18, &broken, 4);
    gear = MFUEPlayerData::ReadEquipment(actor, read);
    CHECK(gear.head.health == 0, "equipment fallback must not refill broken armor");
    std::memcpy(memory[armorData].data() + 0x18, &current, 4);
    std::memcpy(memory[infoData].data(), &bag, 8);
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
    const uint64_t fashion = 0x100007000, textData = 0x100008000;
    put(actor + 0x26A8, fashion);
    put(fashion + 0x508, uint64_t(12345678901ULL));
    CHECK(MFUEPlayerData::ReadHeroID(actor, read) == 12345678901ULL,
          "hero identity must use the live replicated fashion component, not player UIN");
    memory.erase(fashion + 0x508);
    CHECK(MFUEPlayerData::ReadHeroID(actor, read) == 0, "missing hero state must stay unknown");
    const uint64_t battleClass = 0x100009000;
    put(actor + 0x3890, battleClass);
    put(battleClass + 0x100, int64_t(10007));
    put(fashion + 0x508, uint64_t(12345678901ULL));
    CHECK(MFUEPlayerData::ReadExpertID(actor, read) == 10007 &&
          MFUEPlayerData::ReadHeroID(actor, read) == 12345678901ULL,
          "the supplied operator dictionary uses BattleClass ExpertId, independently of fashion HeroID");
    put(ps + 0x9F8, int64_t(20003));
    put(ps + 0x9F0, int64_t(99887766));
    put(battleClass + 0x100, int64_t(0));
    put(fashion + 0x508, uint64_t(0));
    CHECK(MFUEPlayerData::ReadExpertID(actor, read) == 20003 &&
          MFUEPlayerData::ReadHeroID(actor, read) == 99887766,
          "replicated PlayerState ExpertId and HeroID are separate fallbacks while components initialize");
    memory.erase(battleClass + 0x100);
    memory.erase(fashion + 0x508);
    CHECK(MFUEPlayerData::ReadExpertID(actor, read) == 20003 &&
          MFUEPlayerData::ReadHeroID(actor, read) == 99887766,
          "unavailable components must not hide readable replicated player identities");
    put(battleClass + 0x100, int64_t(-1));
    put(ps + 0x9F8, int64_t(-1));
    put(ps + 0x9F0, int64_t(-1));
    CHECK(MFUEPlayerData::ReadExpertID(actor, read) == 0 &&
          MFUEPlayerData::ReadHeroID(actor, read) == 0,
          "negative identity sentinels must remain unknown instead of becoming unsigned lookup keys");
    memory.erase(ps + 0x9F8);
    memory.erase(ps + 0x9F0);
    memory.erase(battleClass + 0x100);
    CHECK(MFUEPlayerData::ReadExpertID(actor, read) == 0 &&
          MFUEPlayerData::ReadExpertID(0, read) == 0,
          "missing ExpertId must not be guessed from a player name, UIN, or HeroID suffix");
    const std::pair<uint64_t, const char *> heroes[] = {
        {10007, u8"红狼"}, {10010, u8"威龙"}, {10011, u8"无名"}, {10012, u8"张姐"},
        {20003, u8"疯医"}, {20004, u8"女医"}, {20005, u8"蝶"}, {20006, u8"养狗的"},
        {30008, u8"老黑"}, {30009, u8"比特"}, {30010, u8"盾狗"}, {30011, u8"乌鲁鲁"},
        {30012, u8"液氮"}, {40005, u8"露娜"}, {40010, u8"骇爪"}, {40011, u8"老头"}
    };
    for (const auto &hero : heroes)
        CHECK(MFHeroNames::Resolve(hero.first, nullptr) &&
              std::string(MFHeroNames::Resolve(hero.first, nullptr)) == hero.second,
              "each exact supplied hero ID must have its documented fallback name");
    CHECK(std::string(MFHeroNames::Resolve(20003, u8"蜂医")) == u8"蜂医",
          "the live localized hero name must take precedence over documented slang");
    CHECK(std::string(MFHeroNames::Resolve(10010, "")) == u8"威龙",
          "an empty live name must still use the local hero fallback");
    CHECK(!MFHeroNames::Resolve(99999, nullptr) && !MFHeroNames::Resolve(0, nullptr) &&
          !MFHeroNames::Resolve(10010007, nullptr),
          "unknown hero IDs must not be guessed or matched by decimal suffix");
    const char *specialNPCs[] = {u8"[卫队长官]赛伊德",u8"[地域黑鲨]雷斯",u8"[安全总监]德穆兰",
        u8"[堕落王子]渡鸦",u8"[效能部长]哈德森",u8"加速部队特勤组",u8"哈夫克支援战车",
        u8"阿萨拉死囚",u8"哈夫克自动战车"};
    for (const char *name : specialNPCs)
        CHECK(MFNPCNames::Resolve(true,{name}) == name,
              "each supplied special NPC name must survive ordinary bot normalization");
    CHECK(MFNPCNames::Resolve(true,{u8"赛伊德"}) == u8"[卫队长官]赛伊德" &&
          MFNPCNames::Resolve(true,{u8"普通士兵", "123456"}) == u8"人机" &&
          MFNPCNames::Resolve(true,{nullptr}) == u8"人机",
          "known special aliases must resolve while unnamed or ordinary AI simply displays bot");
    CHECK(MFNPCNames::Resolve(false,{u8"赛伊德"},1u<<4).empty(),
          "a human's player-authored name must never be rewritten as an NPC");
    CHECK(MFNPCNames::Resolve(true,{},1u<<4) == u8"盾兵" &&
          MFNPCNames::Resolve(true,{},1u<<18) == u8"盾兵" &&
          MFNPCNames::Resolve(true,{},1u<<4,u8"哈夫克盾兵") == u8"哈夫克盾兵",
          "both SDK shield roles must display a shield role, preferring validated localized template names");
    CHECK(MFNPCNames::Resolve(true,{u8"我是赛伊德的粉丝"}) == u8"人机",
          "substring resemblance must not fabricate a special NPC identity");
    const uint64_t npcClass = 0x100020000, aiClass = 0x100021000, npcChars = 0x100022000;
    put(actor+0x08,npcClass); put(npcClass+0x40,aiClass);
    auto className = [&](uint64_t cls) { return cls==aiClass ? std::string("DFMAICharacter") : std::string("NPCBlueprint"); };
    CHECK(MFUEPlayerData::IsAICharacterClass(actor,read,className),
          "AI subclass recognition must walk the SDK Class and SuperStruct fields");
    put(npcClass+0x40,npcClass);
    CHECK(!MFUEPlayerData::IsAICharacterClass(actor,read,className),
          "a corrupt class hierarchy cycle must not grant access to AI-only fields");
    put(actor+0x2E28,std::array<uint32_t,2>{1234,0});
    put(actor+0x2E88,std::array<uint32_t,2>{4321,0});
    const std::u16string npcTitle = u"赛伊德";
    put(actor+0x2E58,MFUEPlayerData::ArrayHeader{npcChars,4,4});
    memory[npcChars].resize(8); std::memcpy(memory[npcChars].data(),npcTitle.c_str(),8);
    put(actor+0x3CE8,uint64_t(0x100023000));
    put(actor+0x3DD0,MFUEPlayerData::ArrayHeader{npcChars+0x100,2,2});
    memory[npcChars+0x100] = {1,4};
    auto npc = MFUEPlayerData::ReadNPCIdentity(actor,true,true,read);
    CHECK(npc.chosenName==npcTitle && npc.npcIndex==1234 && npc.characterIndex==4321 &&
          npc.templateTable==0x100023000ULL && (npc.tagMask&(1u<<4)),
          "SDK replicated NPC name, template, and byte-sized character tags must be read from their verified fields");
    npc = MFUEPlayerData::ReadNPCIdentity(actor,true,false,read);
    CHECK(!npc.templateTable && !npc.tagMask && npc.chosenName==npcTitle,
          "an unverified subclass may only access the common DFMCharacter fields");
    int npcHumanReads = 0;
    npc = MFUEPlayerData::ReadNPCIdentity(actor,false,true,[&](uint64_t,void*,size_t){++npcHumanReads;return false;});
    CHECK(npcHumanReads==0 && npc.chosenName.empty(),"human identity must not attempt NPC-only reads");
    put(actor+0x3DD0,MFUEPlayerData::ArrayHeader{npcChars+0x100,99,99});
    CHECK(!MFUEPlayerData::ReadNPCIdentity(actor,true,true,read).tagMask,
          "invalid tag counts must not become a special role");
    put(actor + 0x18, textData);
    stringAt(0x470, u"威龙");
    put(textData + 0x48, MFUEPlayerData::ArrayHeader{nameData, 3, 3});
    CHECK(MFUEPlayerData::ReadFText(actor + 0x18, read) == u"威龙",
          "localized FText must follow SDK TextData.TextSource at 0x48");
    CHECK(MFUEDataTable::AlignedReadSize(0x1000, 24) == 4080,
          "data-table read chunks must not split a 24-byte element and shift all later rows");
    CHECK(MFUEDataTable::AlignedReadSize(100, 24) == 96, "last complete rows must fit the read buffer");
    CHECK(MFUEDataTable::ValidQuality(6) && !MFUEDataTable::ValidQuality(0) && !MFUEDataTable::ValidQuality(7),
          "only six explicit quality levels are drawable; zero must not suppress a known red grade");
    CHECK(MFUEDataTable::NumericID("11010006001") == 11010006001ULL &&
          MFUEDataTable::NumericID("11010006001_bad") == 0,
          "item FNames must decode only complete decimal IDs");
    CHECK(std::string(MFHeldWeapons::NameForID(920130818)) == u8"小刀",
          "verified held knife identity must display the knife name");
    CHECK(MFHeldWeapons::NameForID(830130830) &&
          std::string(MFHeldWeapons::NameForID(830130830)) == "M16A4" &&
          MFHeldWeapons::NameForID(830130829) &&
          std::string(MFHeldWeapons::NameForID(830130829)) == "M416",
          "all verified compact rifle IDs must retain their concrete names");
    put(actor + 0x838, uint64_t(0xABCDEF1200000000ULL | 920130818ULL));
    CHECK(MFHeldWeapons::ReadID(actor + 0x838, read) == (0xABCDEF1200000000ULL | 920130818ULL),
          "the SDK uint64 weapon field must preserve all bits without guessing a narrower ABI");
    put(actor + 0x838, uint64_t(18010000001ULL));
    CHECK(MFHeldWeapons::ReadID(actor + 0x838, read) == 18010000001ULL,
          "full inventory weapon IDs must stay intact");
    put(actor + 0x838, uint32_t(920130818));
    CHECK(MFHeldWeapons::ReadID(actor + 0x838, read) == 0,
          "a partial four-byte read must not masquerade as a valid SDK uint64 field");
    const uint64_t table = 0x100009000, rowStruct = 0x10000A000, tableData = 0x10000B000;
    put(table + 0x28, rowStruct);
    put(table + 0x30, MFUEPlayerData::ArrayHeader{tableData, 201, 201});
    std::vector<unsigned char> tableBytes(201 * 24);
    for (uint32_t i = 0; i < 201; ++i) {
        const uint32_t nameIndex = i + 100;
        const uint64_t row = 0x100100000 + i * 0x300;
        std::memcpy(tableBytes.data() + i * 24, &nameIndex, 4);
        std::memcpy(tableBytes.data() + i * 24 + 8, &row, 8);
    }
    auto readTable = [&](uint64_t address, void *out, size_t size) {
        if (address >= tableData && address - tableData <= tableBytes.size() && size <= tableBytes.size() - (address - tableData)) {
            std::memcpy(out, tableBytes.data() + (address - tableData), size); return true;
        }
        return read(address, out, size);
    };
    const auto rows = MFUEDataTable::ReadRows(table, rowStruct, readTable);
    CHECK(rows.size() == 201 && rows[170].comparisonIndex == 270 && rows.back().comparisonIndex == 300,
          "localized table rows after the first 4KB boundary must retain their exact item/hero keys");
    CHECK(MFUEDataTable::ReadRows(table, rowStruct + 8, readTable).empty(),
          "a different RowStruct must not be interpreted as a hero/item table");
    puts("PASS: SDK player names, UIN, equipment records, known empty and unreadable states");
}
