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
    MFLootSummary::Summary concrete;
    concrete.Add("电脑",4,1,9000000,1,false);
    concrete.Add("金条",5,1,200000,2,false);
    concrete.Add("怀表",6,1,100000,30,false);
    concrete.Add("怀表",6,2,500000,10,false);
    concrete.Add("金币",5,1,10000,5,false);
    concrete.Add("金杯",5,1,300000,50,false);
    concrete.Add("非洲之心",6,1,2000000,60,false);
    concrete.Add("怀表",5,1,5000,4,false);
    concrete.Add(nullptr,6,3,99999999,1,false);
    concrete.Add("",6,2,99999999,1,false);
    concrete.Add(" \t\n",6,1,99999999,1,false);
    concrete.Add("物资未知",6,1,99999999,1,false);
    concrete.Add("未知物资",6,1,99999999,1,false);
    concrete.Add("未知",6,1,99999999,1,false);
    concrete.Add("Unknown",6,1,99999999,1,false);
    concrete.Add("物资",6,1,99999999,1,false);
    concrete.Add("容器",6,1,99999999,1,false);
    concrete.Add("武器箱",6,1,99999999,1,true);
    const auto top=concrete.TopItems();
    CHECK(top.size()==5 && top[0].name=="非洲之心" && top[1].name=="怀表" &&
          top[2].name=="金杯" && top[3].name=="金条" && top[4].name=="金币",
          "top loot must show at most five concrete item names by quality then acquired price, not quality bands");
    CHECK(top[1].quantity==3 && top[1].value==600000 && top[1].nearest==10,
          "same-name same-quality pickups must merge quantities and acquired values without multiplying stack totals");
    CHECK(concrete.TopItems(0).empty() && concrete.TopItems(2).size()==2 && concrete.TopItems(99).size()==5,
          "the top-item view must obey smaller limits and never exceed five concrete lines");
    MFLootSummary::Summary differentQualities;
    differentQualities.Add("怀表",5,1,900000,5,false);
    differentQualities.Add("怀表",6,1,100000,10,false);
    const auto separate=differentQualities.TopItems();
    CHECK(separate.size()==2 && separate[0].quality==6 && separate[1].quality==5 &&
          separate[0].quantity==1 && separate[1].quantity==1,
          "same labels at different qualities must remain separately ranked items");
    MFLootSummary::Summary unknownOnly;
    unknownOnly.Add(nullptr,6,2,100,2,false);
    CHECK(unknownOnly.TopItems().empty() && unknownOnly.quantity==2 && unknownOnly.totalValue==100,
          "unknown names must not invent a concrete item or disappear from aggregate accounting");
    MFLootSummary::Summary ties;
    ties.Add("远处金杯",5,1,1000,20,false);
    ties.Add("近处金杯",5,1,1000,10,false);
    const auto tied=ties.TopItems();
    CHECK(tied.size()==2 && tied[0].name=="近处金杯" && tied[1].name=="远处金杯",
          "equal quality and price must keep a deterministic nearest-first tie break");
    MFLootSummary::Summary unknownQuality;
    unknownQuality.Add("无等级但有名字的纪念币",0,1,90000000,1,false);
    unknownQuality.Add("已知等级的金杯",5,1,10,100,false);
    const auto qualityOrder=unknownQuality.TopItems();
    CHECK(qualityOrder.size()==2 && qualityOrder[0].name=="已知等级的金杯" &&
          qualityOrder[1].name=="无等级但有名字的纪念币" && qualityOrder[1].quality==0,
          "a known item with unknown quality remains eligible after ranked qualities without inventing a grade");
    std::puts("PASS: labels and at most five concrete loot items ranked by quality and acquired price");
}
