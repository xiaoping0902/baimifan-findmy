#pragma once
#import "../app/Sources/Game/MFUEReader.h"
#import "../app/Sources/Read/MFReadBackend.h"
#include <stdio.h>

// The caller replaces only readRemote: with a byte fixture. resolve, readU64,
// sessionToken and noteWorldPointer remain the real production implementations.
template <typename Put, typename Clear>
static void TestUEWorldEpochDuringBrokenResolve(Put put, Clear clear) {
    clear();
    MFReadBackend *backend = [MFReadBackend shared];
    MFUEReader *reader = [MFUEReader new];
    reader.libBase = 0x100000000ULL;
    reader.profile = [MFUEProfile new];
    reader.profile.gworldStaticOffset = 0x100;
    reader.profile.world_gameInstance = 0x10;
    const uint64_t worldSlot = reader.libBase + reader.profile.gworldStaticOffset;
    const uint64_t worldA = 0x130400000ULL;
    const uint64_t worldB = 0x130500000ULL;

    // Only the world slot is readable. The new UWorld's GameInstance has not
    // been initialized, which is a legitimate partial chain during map travel.
    put(worldSlot, &worldA, sizeof(worldA));
    MFUEResolveResult *first = [reader resolve];
    Check(first.gworld == worldA && first.gameInstance == 0 &&
          [first.brokenAt containsString:@"GameInstance"],
          "the byte fixture must reach a valid world and fail at its uninitialized GameInstance");
    const uint64_t firstEpoch = backend.matchEpoch;
    const uint64_t firstToken = backend.sessionToken;
    Check(firstToken != 0, "a KFD-bound reader must have a session token before map travel");

    put(worldSlot, &worldB, sizeof(worldB));
    MFUEResolveResult *second = [reader resolve];
    Check(second.gworld == worldB && [second.brokenAt containsString:@"GameInstance"],
          "the next world must be observed even while its object chain remains incomplete");
    Check(backend.matchEpoch == firstEpoch + 1 && backend.sessionToken != firstToken,
          "a valid replacement world must invalidate session caches before later chain failure returns");
    (void)[reader resolve];
    Check(backend.matchEpoch == firstEpoch + 1,
          "repeated broken resolves of the same world must not repeatedly invalidate session caches");

    const uint64_t nullWorld = 0;
    put(worldSlot, &nullWorld, sizeof(nullWorld));
    MFUEResolveResult *loading = [reader resolve];
    Check(loading.gworld == 0 && loading.brokenAt != nil && backend.matchEpoch == firstEpoch + 1,
          "an unreadable or null loading-screen world must not create a spurious match epoch");
    clear();
    puts("PASS: production UE resolve advances world epoch before an incomplete object chain returns");
}
