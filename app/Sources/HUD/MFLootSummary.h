#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace MFLootSummary {
struct Row {
    std::string name;
    int quality=0;
    uint64_t quantity=0;
    int64_t value=0;
    float nearest=INFINITY;
};
struct Summary {
    uint64_t quantity=0, boxes=0, byQuality[7]{};
    int64_t totalValue=0;
    std::map<std::pair<int,std::string>,Row> rows;
    void Add(const char *name,int quality,int count,int value,float distance,bool box) {
        if (box) { ++boxes; return; }
        quality=quality>=1&&quality<=6?quality:0;
        const uint64_t amount=count>0&&count<100000?count:1;
        quantity+=amount; byQuality[quality]+=amount;
        // Keep the acquired per-pickup value semantics; multiplying by the
        // stack here would double-count sources that already report a total.
        const int64_t knownValue=std::max(0,value);
        totalValue+=knownValue;
        const std::string label=name&&*name?name:"物资未知";
        Row &row=rows[{quality,label}];
        row.name=label;row.quality=quality;row.quantity+=amount;row.value+=knownValue;
        if(std::isfinite(distance)&&distance>=0)row.nearest=std::min(row.nearest,distance);
    }
    std::vector<Row> SortedRows() const {
        std::vector<Row> result;
        for(const auto &entry:rows)result.push_back(entry.second);
        std::sort(result.begin(),result.end(),[](const Row &a,const Row &b){
            if(a.quality!=b.quality)return a.quality>b.quality;
            if(a.value!=b.value)return a.value>b.value;
            if(a.nearest!=b.nearest)return a.nearest<b.nearest;
            return a.name<b.name;
        });
        return result;
    }
};
}
