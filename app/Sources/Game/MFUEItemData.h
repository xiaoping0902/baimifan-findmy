#pragma once
#include "MFUEPlayerData.h"

namespace MFUEItemData {
struct CommonRow {
    bool matched = false;
    int32_t quality = -1, price = -1;
    std::u16string name;
};

template <typename ReadBytes>
CommonRow ReadCommonRow(uint64_t address, uint32_t comparisonIndex, uint32_t number, ReadBytes read) {
    CommonRow row;
    if (!MFUEPlayerData::ValidPointer(address) || !comparisonIndex || comparisonIndex > 20000000) return row;
    uint32_t itemID[2]{};
    if (!read(address + 0x10, itemID, sizeof(itemID)) ||
        itemID[0] != comparisonIndex || itemID[1] != number) return row;
    row.matched = true;
    int32_t quality = -1;
    if (read(address + 0x68, &quality, sizeof(quality)) && quality >= 1 && quality <= 6) row.quality = quality;
    int32_t price = -1;
    // FDFMCommonItemRow.InitialGuidePrice is independent of Quality.
    if (read(address + 0xDC, &price, sizeof(price)) && price >= 0 && price <= 100000000) row.price = price;
    row.name = MFUEPlayerData::ReadFText(address + 0x18, read);
    return row;
}
}
