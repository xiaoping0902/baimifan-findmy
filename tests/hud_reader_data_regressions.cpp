#include "../app/Sources/Game/MFUEActorState.h"
#include "../app/Sources/Game/MFUEItemData.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main() {
    std::map<uint64_t, std::vector<unsigned char>> memory;
    auto put = [&](uint64_t address, auto value) {
        auto &bytes = memory[address]; bytes.resize(sizeof(value));
        std::memcpy(bytes.data(), &value, sizeof(value));
    };
    auto read = [&](uint64_t address, void *out, size_t size) {
        const auto found = memory.find(address);
        if (found == memory.end() || found->second.size() < size) return false;
        std::memcpy(out, found->second.data(), size); return true;
    };
    const uint64_t ps = 0x100001000, rowAddress = 0x100002000;
    put(ps + 0x4C0, uint8_t(1)); // bFinishGame is independent of inactive/spectator flags.
    put(ps + 0x39E, uint8_t(0x09)); // Ping flag + bIsABot.
    CHECK(!MFUEActorState::IsSpectatorOrInactive(ps, read),
          "a valid bot must not disappear because bFinishGame or bIsABot is set");
    for (const uint8_t flag : {uint8_t(0x02), uint8_t(0x04), uint8_t(0x20)}) {
        put(ps + 0x39E, flag);
        CHECK(MFUEActorState::IsSpectatorOrInactive(ps, read),
              "SDK spectator, only-spectator and inactive flags must be excluded");
    }
    memory.erase(ps + 0x39E);
    CHECK(!MFUEActorState::IsSpectatorOrInactive(ps, read), "unreadable status must not hide an active character");

    const uint32_t itemID[2] = {54321, 7};
    memory[rowAddress + 0x10].resize(sizeof(itemID));
    std::memcpy(memory[rowAddress + 0x10].data(), itemID, sizeof(itemID));
    put(rowAddress + 0x68, int32_t(6));
    put(rowAddress + 0xDC, int32_t(123456));
    const uint64_t textData = 0x100003000, textChars = 0x100004000;
    put(rowAddress + 0x18, textData);
    const char16_t name[] = u"六级物资";
    put(textData + 0x48, MFUEPlayerData::ArrayHeader{textChars, int32_t(sizeof(name) / 2), int32_t(sizeof(name) / 2)});
    memory[textChars].resize(sizeof(name));
    std::memcpy(memory[textChars].data(), name, sizeof(name));
    auto row = MFUEItemData::ReadCommonRow(rowAddress, 54321, 7, read);
    CHECK(row.matched && row.quality == 6 && row.price == 123456 && row.name == u"六级物资",
          "a matched cached row must retain its actual name and guide price alongside quality");
    CHECK(!MFUEItemData::ReadCommonRow(rowAddress, 54321, 0, read).matched,
          "a row for another FName number must not be used");
    CHECK(!MFUEItemData::ReadCommonRow(rowAddress, 54322, 7, read).matched,
          "a row for another item ID must not be used");
    put(rowAddress + 0x68, int32_t(0));
    row = MFUEItemData::ReadCommonRow(rowAddress, 54321, 7, read);
    CHECK(row.matched && row.quality == -1 && row.price == 123456 && !row.name.empty(),
          "an unavailable quality must not suppress independent valid name and price fields");
    put(rowAddress + 0xDC, int32_t(-2));
    CHECK(MFUEItemData::ReadCommonRow(rowAddress, 54321, 7, read).price == -1, "negative guide prices remain unknown");
    put(rowAddress + 0xDC, int32_t(100000001));
    CHECK(MFUEItemData::ReadCommonRow(rowAddress, 54321, 7, read).price == -1, "out-of-range guide prices remain unknown");
    put(rowAddress + 0xDC, int32_t(0));
    CHECK(MFUEItemData::ReadCommonRow(rowAddress, 54321, 7, read).price == 0, "a verified zero guide price stays zero");
    memory.erase(rowAddress + 0xDC);
    row = MFUEItemData::ReadCommonRow(rowAddress, 54321, 7, read);
    CHECK(row.price == -1 && !row.name.empty(), "a failed price read must not discard a valid localized name");
    std::puts("HUD reader data regressions passed");
}
