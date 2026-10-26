#pragma once
#include <unistd.h>

@interface MFDrawingLayer (SessionRegressionEntryPoint)
- (BOOL)acquireUE4FrameWithSize:(CGSize)size camera:(MFCamera *)camera
                     entities:(NSArray **)entities loot:(NSArray **)loot source:(NSInteger *)source;
- (void)synchronizeReadSessionWithResult:(MFUEResolveResult *)result;
@end

static BOOL SupplyDiscoveryCamera(id object, SEL selector, MFCamera *camera, MFUEResolveResult *result) {
    if (camera) { *camera = (MFCamera){0}; camera->fov = 90; }
    return YES;
}
static NSUInteger sDiscoveryReads;
static uint64_t sFirstDiscoveryAddress;
static NSArray<NSNumber *> *sDiscoveryAddresses;
static NSUInteger sAddressRefreshes;
static size_t SupplyDiscoveryAddresses(id object, SEL selector, uint64_t address, void *out, size_t size) {
    CHECK(size == sDiscoveryAddresses.count * sizeof(uint64_t), "address refresh must request the fixture's complete array");
    for (NSUInteger i = 0; i < sDiscoveryAddresses.count; ++i)
        ((uint64_t *)out)[i] = sDiscoveryAddresses[i].unsignedLongLongValue;
    ++sAddressRefreshes;
    return size;
}
static BOOL SlowInvalidActorRead(id object, SEL selector, uint64_t address, void *out, size_t size) {
    CHECK(size == 8, "discovery budget fixture only permits actor root reads");
    if (sDiscoveryReads++ == 0) sFirstDiscoveryAddress = address;
    usleep(7000); // A single failed actor read consumes this frame's discovery budget.
    return NO;
}

static void TestDrawingReadSessions(void) {
    MFReadBackend *backend = [MFReadBackend shared];
    MFUEReader *ue = [MFUEReader shared];
    const int savedPid = backend.kfdPid;
    const uint64_t savedRoot = backend.kfdRoot, savedBase = ue.libBase;
    const BOOL savedMode = backend.modeFlag;
    backend.kfdPid = getpid(); backend.kfdRoot = 0x12345000;
    backend.modeFlag = NO; ue.libBase = 0x100000000ULL;
    MFDrawingLayer *drawing = [MFDrawingLayer new];
    // A closed gate must still observe the identity before returning.
    CHECK(![drawing acquireUE4FrameWithSize:CGSizeMake(640,720) camera:NULL entities:NULL loot:NULL source:NULL],
          "a closed gate cannot acquire a local frame");
    auto seed = [&] {
        for (NSString *key in @[@"ueActors", @"personAttrs", @"personHealth", @"smoothCache", @"classNameByID", @"kindHistogram"])
            [(NSMutableDictionary *)[drawing valueForKey:key] setObject:@1 forKey:@1];
        [(NSMutableArray *)[drawing valueForKey:@"ueActorAddrs"] addObject:@(0x110000000ULL)];
        [drawing setValue:[MFUEResolveResult new] forKey:@"ueResolve"];
        [drawing setValue:[MFUEResolveResult new] forKey:@"ueResolveGood"];
        for (NSString *key in @[@"ueCursor", @"lastCameraAt", @"ueResolveGoodAt", @"classResolved", @"classFailed"])
            [drawing setValue:@12 forKey:key];
        [drawing setValue:@YES forKey:@"classifySticky"];
        [drawing setValue:@YES forKey:@"geometrySettingsKnown"];
        [drawing setValue:@YES forKey:@"lootStatsKnown"];
    };
    auto empty = [&] {
        for (NSString *key in @[@"ueActors", @"personAttrs", @"personHealth", @"smoothCache", @"classNameByID", @"kindHistogram", @"ueActorAddrs"])
            if ([[drawing valueForKey:key] count] != 0) return false;
        for (NSString *key in @[@"ueCursor", @"lastCameraAt", @"ueResolveGoodAt", @"classResolved", @"classFailed", @"classifySticky", @"geometrySettingsKnown", @"lootStatsKnown"])
            if ([[drawing valueForKey:key] doubleValue] != 0) return false;
        return [drawing valueForKey:@"ueResolve"] == nil && [drawing valueForKey:@"ueResolveGood"] == nil;
    };
    seed();
    [drawing acquireUE4FrameWithSize:CGSizeMake(640,720) camera:NULL entities:NULL loot:NULL source:NULL];
    CHECK([[drawing valueForKey:@"ueActors"] count] == 1,
          "an unchanged closed session retains short read-failure grace");
    backend.kfdRoot += 0x1000;
    [drawing acquireUE4FrameWithSize:CGSizeMake(640,720) camera:NULL entities:NULL loot:NULL source:NULL];
    CHECK(empty(), "a changed backend must clear every actor, camera and drawing cache before returning");
    seed(); ue.libBase += 0x1000;
    [drawing acquireUE4FrameWithSize:CGSizeMake(640,720) camera:NULL entities:NULL loot:NULL source:NULL];
    CHECK(empty(), "a changed module must clear old actor addresses even with a closed gate");

    MFUEResolveResult *first = [MFUEResolveResult new];
    first.gworld = 0x120000000ULL; first.level = 0x130000000ULL;
    [drawing synchronizeReadSessionWithResult:first]; seed();
    [drawing synchronizeReadSessionWithResult:first];
    CHECK([[drawing valueForKey:@"ueActors"] count] == 1, "an unchanged world retains its actor cache");
    MFUEResolveResult *loading = [MFUEResolveResult new];
    loading.gworld = 0x140000000ULL; loading.brokenAt = @"new world still loading";
    [drawing synchronizeReadSessionWithResult:loading];
    CHECK(empty(), "a confirmed new world must drop old camera grace even if its chain is incomplete");
    loading.level = 0x150000000ULL;
    [drawing synchronizeReadSessionWithResult:loading]; seed();
    loading.level += 0x1000;
    [drawing synchronizeReadSessionWithResult:loading];
    CHECK(empty(), "persistent level replacement within one world must drop old actor addresses");

    // Run the actual discovery loop against slow, failing root reads. It must
    // yield, and the next display frame must continue at the first unexamined actor.
    Method cameraMethod = class_getInstanceMethod(MFUEReader.class, @selector(readCamera:result:));
    Method readMethod = class_getInstanceMethod(MFReadBackend.class, @selector(readRemote:into:size:));
    IMP savedCamera = method_setImplementation(cameraMethod, (IMP)SupplyDiscoveryCamera);
    IMP savedRead = method_setImplementation(readMethod, (IMP)SlowInvalidActorRead);
    backend.modeFlag = YES;
    MFUEResolveResult *valid = [MFUEResolveResult new]; valid.gworld = loading.gworld; valid.level = loading.level;
    [drawing setValue:valid forKey:@"ueResolve"];
    const double now = CACurrentMediaTime();
    for (NSString *key in @[@"ueResolveAt", @"ueAddrsAt", @"histogramAt"]) [drawing setValue:@(now) forKey:key];
    NSMutableArray *addresses = [drawing valueForKey:@"ueActorAddrs"];
    for (NSUInteger i = 0; i < 192; ++i) [addresses addObject:@(0x160000000ULL + i * 0x1000)];
    sDiscoveryReads = 0;
    CHECK([drawing acquireUE4FrameWithSize:CGSizeMake(640,720) camera:NULL entities:NULL loot:NULL source:NULL],
          "an empty but valid scene remains a valid frame after discovery yields");
    const NSUInteger examined = sDiscoveryReads;
    CHECK(examined > 0 && examined <= 2, "slow invalid discovery must yield instead of reading all 192 actors");
    CHECK([[drawing valueForKey:@"ueCursor"] unsignedIntegerValue] == examined,
          "discovery cursor advances by examined actors including failed reads");
    sDiscoveryReads = 0;
    [drawing acquireUE4FrameWithSize:CGSizeMake(640,720) camera:NULL entities:NULL loot:NULL source:NULL];
    CHECK(sFirstDiscoveryAddress == [addresses[examined] unsignedLongLongValue] + ue.profile.actor_rootComponent,
          "the next frame must resume at the first unexamined actor without starvation");
    Method partialMethod = class_getInstanceMethod(MFReadBackend.class, @selector(readRemotePartial:into:size:));
    IMP savedPartial = method_setImplementation(partialMethod, (IMP)SupplyDiscoveryAddresses);
    sDiscoveryAddresses = [addresses copy]; sAddressRefreshes = 0;
    const NSUInteger next = [[drawing valueForKey:@"ueCursor"] unsignedIntegerValue];
    valid.actorsNum = (int)sDiscoveryAddresses.count; valid.actorsData = 0x170000000ULL;
    [drawing setValue:@0 forKey:@"ueAddrsAt"];
    sDiscoveryReads = 0;
    [drawing acquireUE4FrameWithSize:CGSizeMake(640,720) camera:NULL entities:NULL loot:NULL source:NULL];
    CHECK(sAddressRefreshes == 1 && sFirstDiscoveryAddress == [sDiscoveryAddresses[next] unsignedLongLongValue] + ue.profile.actor_rootComponent,
          "periodic address refresh must retain the pending actor instead of starving the array tail");
    method_setImplementation(partialMethod, savedPartial);
    sDiscoveryAddresses = nil;
    method_setImplementation(cameraMethod, savedCamera);
    method_setImplementation(readMethod, savedRead);
    backend.kfdPid = savedPid; backend.kfdRoot = savedRoot; backend.modeFlag = savedMode; ue.libBase = savedBase;
    puts("PASS: drawing caches isolate read sessions, worlds and levels; discovery yields and resumes");
}
