#pragma once
#import <QuartzCore/QuartzCore.h>
#import "../app/Sources/Game/MFGearReader.h"
#import "../app/Sources/Game/MFItemTable.h"

// Exercise the actual Objective-C caches while the surrounding drawing fixture
// rejects every remote read. Session changes must invalidate before returning
// a cached value or considering an old item table ready.
static void TestLootSessionCaches(void) {
    MFReadBackend *backend = [MFReadBackend shared];
    MFUEReader *ue = [MFUEReader shared];
    const uint32_t savedTask = backend.targetTaskPort;
    const uint64_t savedBase = ue.libBase;
    const BOOL savedMode = backend.modeFlag;
    backend.targetTaskPort = 0x1234;
    backend.modeFlag = NO; // The port setter normally enables its read gate.
    ue.libBase = 0x100000000ULL;

    MFItemTable *table = [MFItemTable new];
    (void)table.ready;
    auto seedTable = [&] {
        [table setValue:@YES forKey:@"ready"];
        [table setValue:@5 forKey:@"rowCount"];
        [table setValue:@(0x110000000ULL) forKey:@"gameItem"];
        [table setValue:@(0x120000000ULL) forKey:@"rowStructExpected"];
        [(NSMutableDictionary *)[table valueForKey:@"rowIndex"] setObject:@(0x130000000ULL) forKey:@123];
        [(NSMutableDictionary *)[table valueForKey:@"rowCache"] setObject:[MFItemRow new] forKey:@123];
    };
    auto tableEmpty = [&] {
        return [(NSDictionary *)[table valueForKey:@"rowIndex"] count] == 0 &&
               [(NSDictionary *)[table valueForKey:@"rowCache"] count] == 0 && table.rowCount == 0 &&
               [[table valueForKey:@"gameItem"] unsignedLongLongValue] == 0 &&
               [[table valueForKey:@"rowStructExpected"] unsignedLongLongValue] == 0;
    };
    seedTable();
    CHECK(table.ready, "an unchanged session must retain its loaded item table");
    ue.libBase += 0x1000;
    CHECK(!table.ready && tableEmpty(), "ready must invalidate all item-table addresses when the module changes");
    seedTable();
    backend.targetTaskPort++;
    backend.modeFlag = NO;
    CHECK(![table loadIfNeeded] && tableEmpty(), "a new task must not let old readiness bypass table loading");
    seedTable();
    backend.targetTaskPort++;
    backend.modeFlag = NO;
    MFItemRow *oldRow = nil;
    CHECK(![table lookupComparisonIndex:123 number:0 row:&oldRow] && oldRow == nil && tableEmpty(),
          "direct lookup must invalidate a previous task even without reading ready first");

    MFGearReader *gear = [MFGearReader new];
    const uint64_t actor = 0x140000000ULL;
    CHECK([gear readGearForVerifiedPickup:actor] == nil, "a closed read gate cannot create gear data");
    auto seedGear = [&] {
        MFGearInfo *info = [MFGearInfo new]; info.displayName = @"old session item";
        [(NSMutableDictionary *)[gear valueForKey:@"cache"] setObject:info forKey:@(actor)];
        [(NSMutableDictionary *)[gear valueForKey:@"cacheAt"] setObject:@(CACurrentMediaTime()) forKey:@(actor)];
        [(NSMutableDictionary *)[gear valueForKey:@"itemsCache"] setObject:@[info] forKey:@(actor)];
        [(NSMutableDictionary *)[gear valueForKey:@"itemsCacheAt"] setObject:@(CACurrentMediaTime()) forKey:@(actor)];
        [gear setValue:@(CACurrentMediaTime()) forKey:@"tableRetryAt"];
    };
    auto gearEmpty = [&] {
        return [(NSDictionary *)[gear valueForKey:@"cache"] count] == 0 && [(NSDictionary *)[gear valueForKey:@"cacheAt"] count] == 0 &&
               [(NSDictionary *)[gear valueForKey:@"itemsCache"] count] == 0 && [(NSDictionary *)[gear valueForKey:@"itemsCacheAt"] count] == 0 &&
               [[gear valueForKey:@"tableRetryAt"] doubleValue] == 0;
    };
    seedGear();
    CHECK([[gear readGearForVerifiedPickup:actor].displayName isEqualToString:@"old session item"],
          "an unchanged session may return a fresh gear cache entry");
    backend.targetTaskPort++;
    backend.modeFlag = NO;
    CHECK([gear readGearForVerifiedPickup:actor] == nil && gearEmpty(),
          "new-task gear reads must discard actor, container, timestamps and failed-table cooldown caches");
    seedGear();
    ue.libBase += 0x1000;
    CHECK([gear containedItemsForActor:actor].count == 0 && gearEmpty(),
          "container reads must invalidate module changes before returning cached contents");

    backend.targetTaskPort = savedTask;
    backend.modeFlag = savedMode;
    ue.libBase = savedBase;
    puts("PASS: real loot caches isolate task ports and module bases");
}
