#include "../app/Sources/HUD/MFEntityLabels.h"
#include <cstdio>
#include <cstdlib>
#include <limits>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main() {
    using namespace MFEntityLabels;
    CHECK(Gear("头", 4, 11010004001ULL, true, 35) == "4头35",
          "current helmet durability must be visible without a maximum");
    CHECK(Gear("甲", 5, 11050005001ULL, true, 105) == "5甲105",
          "armor must show its own current durability");
    CHECK(Gear("甲", 6, 11050006001ULL, true, 0) == "6甲0",
          "broken armor has valid zero durability");
    CHECK(Gear("头", 4, 11010004001ULL, true, std::numeric_limits<float>::quiet_NaN()) == "4头?",
          "unreadable durability must remain unknown");
    CHECK(Gear("头", 0, 0, true, 0) == "头空" && Gear("甲", 0, 0, false, 0) == "甲?",
          "known absent and unreadable slots must remain distinct");
    CHECK(Gear("甲", 0, 999, true, 0) == "甲?",
          "unrecognized nonzero equipment must not become empty");
    CHECK(Bag(6, 11080006001ULL, true) == "6包", "backpack row has no fabricated durability");
    CHECK(PlayerRow(7, "玩家小玉", true, true) == "7 : 玩家小玉",
          "team identity row must contain the authored nickname rather than UIN");
    CHECK(PlayerRow(7, "123456", true, true) == "7 : 123456", "numeric nicknames remain valid");
    CHECK(PlayerRow(7, "玩家小玉", false, true) == "玩家小玉" &&
          PlayerRow(7, "玩家小玉", true, false) == "7" &&
          PlayerRow(7, "玩家小玉", false, false).empty(),
          "team and name switches independently control their actual contents");
    CHECK(PlayerRow(0, nullptr, true, true) == "? : 玩家未知", "unknown identity must not invent a name");
    CHECK(std::string(Weapon("M4A1突击步枪")) == "M4A1突击步枪" && std::string(Weapon("海盗弯刀")) == "海盗弯刀",
          "weapon row must contain only the concrete weapon name");
    CHECK(std::string(Hero("蜂医")) == "蜂医" && std::string(Hero(nullptr)) == "英雄未知", "hero name is distinct from player identity");
    std::puts("PASS: weapon, current durability, team nickname and separate hero labels");
}
