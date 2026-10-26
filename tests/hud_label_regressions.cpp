#include "../app/Sources/HUD/MFEntityLabels.h"
#include "../app/Sources/HUD/MFLootSummary.h"
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
    CHECK(std::string(ActorName(false,"玩家小玉","盾兵"))=="玩家小玉" &&
          std::string(ActorName(true,"随机编号",nullptr))=="人机" &&
          std::string(ActorName(true,nullptr,"[卫队长官]赛伊德"))=="[卫队长官]赛伊德",
          "human nicknames, ordinary bots and verified special NPC names must stay distinct");
    MFLootSummary::Summary summary;
    summary.Add("红色物资",6,3,100,20,false);
    summary.Add("红色物资",6,2,50,10,false);
    summary.Add("白色物资",1,0,20,30,false);
    summary.Add("未知物资",0,1,-100,40,false);
    summary.Add("武器箱",6,99,99999,1,true);
    const auto rows=summary.SortedRows();
    CHECK(summary.quantity==7 && summary.byQuality[6]==5 && summary.byQuality[1]==1 &&
          summary.byQuality[0]==1 && summary.boxes==1 && summary.totalValue==170,
          "loot statistics must count stacks, include all six qualities and exclude containers from item totals");
    CHECK(rows.size()==3 && rows[0].name=="红色物资" && rows[0].quantity==5 &&
          rows[0].nearest==10 && rows[1].quality==1 && rows[2].quality==0,
          "equal item names and qualities must merge, ordered by quality then value with unknown last");
    CHECK(summary.valueByQuality[6]==150 && summary.valueByQuality[1]==20 &&
          summary.valueByQuality[0]==0 && summary.valueByQuality[5]==0,
          "quality summaries must sum acquired pickup values, excluding boxes and negative unknown values");
    std::puts("PASS: weapon, current durability, team nickname and separate hero labels");
}
