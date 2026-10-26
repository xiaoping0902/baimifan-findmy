#include "../app/Sources/Game/MFUEHeading.h"
#include <array>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

int main() {
    constexpr uint64_t actor = 0x110000000ULL, controller = 0x130000000ULL;
    std::map<uint64_t, std::vector<unsigned char>> memory;
    auto put = [&](uint64_t address, const auto &value) {
        const auto *bytes = reinterpret_cast<const unsigned char *>(&value);
        memory[address] = std::vector<unsigned char>(bytes, bytes + sizeof(value));
    };
    auto read = [&](uint64_t address, void *out, size_t size) {
        auto found = memory.find(address);
        if (found == memory.end() || found->second.size() < size) return false;
        memcpy(out, found->second.data(), size); return true;
    };
    const float world[3] = {1000, 2000, 30};
    put(actor + 0x3A8, controller);
    put(controller + 0x3D8, std::array<float, 3>{0, 450, 0});
    CHECK(MFUEHeading::Read(actor, world, read) == 90,
          "valid controller yaw must be preferred and normalized in degrees");
    std::array<unsigned char, 6> flags{}; flags[0] = 0x80; flags[3] = 0x20;
    put(actor + 0x90, flags); put(actor + 0x130, uint8_t(1));
    std::array<float, 14> movement{};
    movement[6] = 1000; movement[7] = 2000; movement[8] = 30;
    movement[10] = 0; movement[11] = -90; movement[12] = 0;
    put(actor + 0x9C, movement);
    CHECK(MFUEHeading::Read(actor, world, read) == 90, "controller yaw must take precedence over body yaw");
    put(controller + 0x3D8, std::array<float, 3>{0, NAN, 0});
    CHECK(MFUEHeading::Read(actor, world, read) == -90,
          "an invalid controller rotation must fall back to a valid replicated body rotation");
    memory.erase(actor + 0x3A8);
    CHECK(MFUEHeading::Read(actor, world, read) == -90,
          "replicated body rotation must provide a heading when remote controller is absent");
    movement[11] = 0; put(actor + 0x9C, movement);
    CHECK(MFUEHeading::Read(actor, world, read) == 0,
          "zero degrees is a valid replicated facing when the replication record is initialized");
    movement[11] = NAN; put(actor + 0x9C, movement);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "invalid body rotation must stay unknown");
    movement[11] = 40; movement[6] = 0; movement[7] = 0; movement[8] = 0; put(actor + 0x9C, movement);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "an uninitialized replicated location must not fabricate a heading");
    movement[6] = 4000; movement[7] = 2000; movement[8] = 30; put(actor + 0x9C, movement);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "a stale movement record far from the current actor must stay unknown");
    movement[6] = 1000; put(actor + 0x9C, movement);
    flags[0] = 0; put(actor + 0x90, flags);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "disabled movement replication must reject a leftover body rotation");
    flags[0] = 0x80; flags[3] = 0; put(actor + 0x90, flags);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "a nonreplicated actor must not use body fallback");
    flags[3] = 0x20; flags[1] = 0x04; put(actor + 0x90, flags);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "a torn-off actor must not reuse stale replicated facing");
    flags[1] = 0; flags[5] = 0x02; put(actor + 0x90, flags);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "a destroying actor must not provide body fallback");
    flags[5] = 0; put(actor + 0x90, flags); put(actor + 0x130, uint8_t(3));
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "only simulated remote proxies may use body fallback");
    put(actor + 0x130, uint8_t(1)); memory[actor + 0x9C].resize(12);
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "partial replicated movement reads must fail closed");
    // A locally updated root component remains meaningful when controllers and
    // movement replication are absent. Relative rotation is world rotation
    // only with no parent, or when the absolute-rotation flag is enabled.
    constexpr uint64_t root = 0x140000000ULL;
    put(actor + 0x180, root); put(root + 0x108, uint64_t(0));
    put(root + 0x178, std::array<float, 3>{0, 135, 0});
    CHECK(MFUEHeading::Read(actor, world, read) == 135,
          "an unattached actor root must provide actual body yaw when controller/network facing is missing");
    put(root + 0x108, uint64_t(0x150000000ULL));
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)),
          "a parent-relative root rotation must not be mislabeled as world facing");
    put(root + 0x19C, uint8_t(0x08));
    CHECK(MFUEHeading::Read(actor, world, read) == 135,
          "an explicitly absolute root rotation may provide world facing despite attachment");
    put(root + 0x178, std::array<float, 3>{0, NAN, 0});
    CHECK(std::isnan(MFUEHeading::Read(actor, world, read)), "invalid root facing must stay unknown");
    std::puts("PASS: SDK controller, replicated body and unattached/absolute root facing paths");
}
