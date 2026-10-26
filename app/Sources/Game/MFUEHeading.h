#pragma once
#include <cmath>
#include <cstdint>

namespace MFUEHeading {
inline bool ValidPointer(uint64_t pointer) { return pointer >= 0x100000001ULL && pointer < 0x2F00000000ULL; }
inline bool ValidRotation(const float rotation[3]) {
    for (int i = 0; i < 3; ++i)
        if (!std::isfinite(rotation[i]) || std::fabs(rotation[i]) > 720.0f) return false;
    return true;
}

template <typename ReadBytes>
float Read(uint64_t actor, const float world[3], ReadBytes read) {
    if (!ValidPointer(actor) || !world) return NAN;
    // SDK 1.201.37117: Engine_classes.hpp APawn.Controller+0x3A8,
    // AController.ControlRotation+0x3D8, CoreUObject FRotator={Pitch,Yaw,Roll}.
    uint64_t controller = 0;
    float rotation[3]{};
    if (read(actor + 0x3A8, &controller, sizeof(controller)) && ValidPointer(controller) &&
        read(controller + 0x3D8, rotation, sizeof(rotation)) && ValidRotation(rotation))
        return std::remainder(rotation[1], 360.0f);

    // Remote controllers often do not replicate. AActor.ReplicatedMovement is
    // Net/RepNotify at 0x9C; FRepMovement has FEncVector Location+0x18 and
    // FRotator Rotation+0x28 (Engine_structs.hpp). This is body facing.
    uint8_t flags[6]{}, role = 0;
    if (!read(actor + 0x90, flags, sizeof(flags)) || !(flags[0] & 0x80) ||
        !(flags[3] & 0x20) || (flags[1] & 0x04) || (flags[5] & 0x02) ||
        !read(actor + 0x130, &role, sizeof(role)) || role != 1) return NAN;
    // bReplicateMovement, bReplicates, !bTearOff, !bActorIsBeingDestroyed,
    // and ROLE_SimulatedProxy=1 are all SDK-declared fields of AActor.
    float movement[14]{};
    if (!read(actor + 0x9C, movement, sizeof(movement)) || !ValidRotation(movement + 10)) return NAN;
    float deltaSquared = 0;
    for (int i = 0; i < 3; ++i) {
        if (!std::isfinite(world[i]) || !std::isfinite(movement[6 + i]) ||
            std::fabs(movement[6 + i]) > 1.0e8f) return NAN;
        const float delta = world[i] - movement[6 + i];
        deltaSquared += delta * delta;
    }
    // Reject default/uninitialized records and movement stale by more than 5m.
    // Regular 15Hz resampling and the outer 0.20s cache limit still apply.
    if ((movement[6] == 0 && movement[7] == 0 && movement[8] == 0) ||
        !std::isfinite(deltaSquared) || deltaSquared > 500.0f * 500.0f) return NAN;
    return std::remainder(movement[11], 360.0f);
}
}
