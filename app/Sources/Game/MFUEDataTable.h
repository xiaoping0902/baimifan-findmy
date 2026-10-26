#pragma once
#include "MFUEPlayerData.h"
#include <algorithm>
#include <limits>
#include <vector>

namespace MFUEDataTable {
struct Row { uint32_t comparisonIndex, number; uint64_t address; };
inline bool ValidQuality(int value) { return value >= 1 && value <= 6; }
inline constexpr size_t AlignedReadSize(size_t limit, size_t stride) { return stride ? limit - limit % stride : 0; }
inline uint64_t NumericID(const char *name) {
    if (!name || !*name) return 0;
    uint64_t value = 0;
    for (; *name; ++name) {
        if (*name < '0' || *name > '9' || value > (UINT64_MAX - (*name - '0')) / 10) return 0;
        value = value * 10 + (*name - '0');
    }
    return value;
}

template <typename ReadBytes>
uint64_t ObjectAtIndex(uint64_t libBase, int32_t index, ReadBytes read) {
    if (!libBase || index < 0) return 0;
    const uint64_t objects = libBase + 0x177A17B8ULL;
    int32_t count = 0;
    uint64_t chunks = 0, chunk = 0, object = 0;
    if (!read(objects + 0x14, &count, 4) || count <= index || count > 5000000 ||
        !read(objects + 0x20, &chunks, 8) || !MFUEPlayerData::ValidPointer(chunks) ||
        !read(chunks + (uint64_t)(index / 0x10000) * 8, &chunk, 8) || !MFUEPlayerData::ValidPointer(chunk) ||
        !read(chunk + (uint64_t)(index % 0x10000) * 0x18, &object, 8)) return 0;
    return MFUEPlayerData::ValidPointer(object) ? object : 0;
}

template <typename ReadBytes>
std::vector<Row> ReadRows(uint64_t table, uint64_t expectedStruct, ReadBytes read) {
    uint64_t rowStruct = 0;
    MFUEPlayerData::ArrayHeader header{};
    if (!MFUEPlayerData::ValidPointer(table) || !MFUEPlayerData::ValidPointer(expectedStruct) ||
        !read(table + 0x28, &rowStruct, 8) || rowStruct != expectedStruct ||
        !read(table + 0x30, &header, sizeof(header)) || !MFUEPlayerData::ValidPointer(header.data) ||
        header.num <= 0 || header.num > 200000 || header.maximum < header.num) return {};
    constexpr size_t stride = 24;
    unsigned char sample[stride * 8]{};
    const size_t probe = std::min<size_t>(header.num, 8);
    if (!read(header.data, sample, stride * probe)) return {};
    size_t score[2]{};
    for (size_t i = 0; i < probe; ++i) {
        for (size_t layout = 0; layout < 2; ++layout) {
            uint32_t name = 0; uint64_t row = 0;
            std::memcpy(&name, sample + i * stride + layout * 8, 4);
            std::memcpy(&row, sample + i * stride + layout * 8 + 8, 8);
            if (name > 0 && name <= 20000000 && MFUEPlayerData::ValidPointer(row)) ++score[layout];
        }
    }
    if (score[0] == score[1] || std::max(score[0], score[1]) * 4 < probe * 3) return {};
    const size_t nameOffset = score[0] > score[1] ? 0 : 8;
    std::vector<Row> rows;
    unsigned char buffer[4080]{}; // 170 complete elements; next read stays aligned.
    const size_t total = (size_t)header.num * stride;
    for (size_t done = 0; done < total;) {
        const size_t ask = std::min(sizeof(buffer), total - done);
        if (read(header.data + done, buffer, ask)) {
            for (size_t i = 0; i < ask; i += stride) {
                Row row{};
                std::memcpy(&row.comparisonIndex, buffer + i + nameOffset, 4);
                std::memcpy(&row.number, buffer + i + nameOffset + 4, 4);
                std::memcpy(&row.address, buffer + i + nameOffset + 8, 8);
                if (row.comparisonIndex > 0 && row.comparisonIndex <= 20000000 &&
                    MFUEPlayerData::ValidPointer(row.address)) rows.push_back(row);
            }
        }
        done += ask;
    }
    return rows;
}
}
