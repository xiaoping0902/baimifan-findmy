#include "../app/Sources/Game/MFUEHealth.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <vector>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main() {
    const uint64_t actor = 0x100001000, component = 0x100002000, set = 0x100003000;
    std::map<uint64_t, std::vector<unsigned char>> memory;
    auto put = [&](uint64_t address, auto value) {
        auto &bytes = memory[address]; bytes.resize(sizeof(value));
        std::memcpy(bytes.data(), &value, sizeof(value));
    };
    put(actor + 0x10B8, component);
    put(component + 0x280, set);
    // HealthMAX stays 100 even when a player has 25 current HP.
    put(component + 0x258, 100.0f);
    std::vector<unsigned char> attributes(40, 0);
    auto attribute = [&](size_t offset, float value) { std::memcpy(attributes.data() + offset, &value, 4); };
    attribute(12, 25.0f); attribute(36, 100.0f);
    memory[set + 0x30] = attributes;
    size_t reads = 0;
    auto read = [&](uint64_t address, void *out, size_t size) {
        ++reads;
        CHECK(address != component + 0x258, "HealthMAX must never be used as current HP");
        auto it = memory.find(address);
        if (it == memory.end() || it->second.size() < size) return false;
        std::memcpy(out, it->second.data(), size); return true;
    };
    auto hp = MFUEHealth::Read(actor, read);
    CHECK(hp.known() && hp.current == 25 && hp.maximum == 100 && hp.ratio() == 0.25f,
          "damaged actor must report 25/100 and a quarter bar");
    CHECK(reads == 3, "a health refresh should use two pointers and one attribute block");
    attribute(12, 50); attribute(36, 200); memory[set + 0x30] = attributes;
    CHECK(MFUEHealth::Read(actor, read).ratio() == 0.25f, "ratio must use actual maximum HP");
    attribute(12, 0); memory[set + 0x30] = attributes;
    CHECK(MFUEHealth::Read(actor, read).known() && MFUEHealth::Read(actor, read).ratio() == 0,
          "zero HP must remain a known empty bar");
    attribute(12, std::numeric_limits<float>::quiet_NaN()); memory[set + 0x30] = attributes;
    CHECK(!MFUEHealth::Read(actor, read).known(), "NaN health must be unknown");
    attribute(12, 250); memory[set + 0x30] = attributes;
    CHECK(!MFUEHealth::Read(actor, read).known(), "current HP above maximum must be rejected");
    memory.erase(set + 0x30);
    hp = MFUEHealth::Read(actor, read);
    CHECK(!hp.known() && hp.current < 0 && hp.ratio() == 0, "read failure must never appear full");
    reads = 0;
    CHECK(!MFUEHealth::Read(0, read).known() && reads == 0, "invalid actor must not be read");
    puts("PASS: SDK current-health chain, maximum ratio, invalid and unknown health");
}
