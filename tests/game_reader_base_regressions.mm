#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import "MFGameReader.h"
#import "Offsets.h"
#import "../app/Sources/Read/MFReadBackend.h"
#include <cmath>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <stdio.h>
#include <stdlib.h>
#include "HUDRegressionOutput.h"

// Exercise the real reader and real process identity APIs. No game process or
// game memory is accessed; the target is this simulator regression process.
static NSString *const kSnapshotKey = @"mf.game.reader.absoluteBases.v1";
static id previousSnapshot, previousModuleBase;

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

#include "ue_resolve_epoch_regressions.h"

// Keep the reader, pointer-chain wrappers and projection real. Only the remote
// memory boundary is replaced: simulator fixtures never access a game/kernel.
static NSMutableDictionary<NSNumber *, NSData *> *remoteFixture;
static uint64_t failedReadAddress;

static BOOL ReadFixtureBytes(id object, SEL selector, uint64_t address, void *out, size_t size) {
    NSData *bytes = remoteFixture[@(address)];
    if (!out || !bytes || bytes.length != size) return NO;
    memcpy(out, bytes.bytes, size);
    // A failed read may have filled its destination. Validation of the bytes
    // alone must never turn that failure into a successful camera sample.
    return address != failedReadAddress;
}

template <typename T>
static void PutFixture(uint64_t address, const T &value) {
    remoteFixture[@(address)] = [NSData dataWithBytes:&value length:sizeof(value)];
}

class ScopedReaderMemory {
    Method method;
    IMP original;
    __strong MFGameProfile *previousProfile;
public:
    ScopedReaderMemory() {
        previousProfile = [MFOffsets shared].current;
        [MFOffsets shared].current = [MFGameProfile new];
        remoteFixture = [NSMutableDictionary dictionary];
        failedReadAddress = 0;
        method = class_getInstanceMethod(MFReadBackend.class, @selector(readRemote:into:size:));
        Check(method != NULL, "production remote-read boundary must exist");
        original = method_setImplementation(method, (IMP)ReadFixtureBytes);
    }
    ~ScopedReaderMemory() {
        method_setImplementation(method, original);
        [MFOffsets shared].current = previousProfile;
        remoteFixture = nil;
        failedReadAddress = 0;
    }
};

static const uint64_t kFixtureRoot = 0x100100000ULL;
static const uint64_t kFixtureCamera = 0x100900000ULL;

static void PutCameraFixture(MFCamera camera) {
    uint64_t object = kFixtureRoot;
    for (NSNumber *offset in [MFOffsets shared].current.rootChain) {
        const uint64_t next = object + 0x10000;
        PutFixture(object + offset.unsignedLongLongValue, next);
        object = next;
    }
    PutFixture(object + [MFOffsets shared].current.cameraPtrOffset, kFixtureCamera);
    PutFixture(kFixtureCamera + kMFCamera_X, camera.x);
    PutFixture(kFixtureCamera + kMFCamera_Y, camera.y);
    PutFixture(kFixtureCamera + kMFCamera_Z, camera.z);
    PutFixture(kFixtureCamera + kMFCamera_Pitch, camera.pitch);
    PutFixture(kFixtureCamera + kMFCamera_Yaw, camera.yaw);
    PutFixture(kFixtureCamera + kMFCamera_Roll, camera.roll);
    PutFixture(kFixtureCamera + kMFCamera_FOV, camera.fov);
}

static void CheckRejectedCamera(MFGameReader *reader, const char *message) {
    const MFCamera sentinel = {111, 222, 333, 44, 55, 66, 77};
    MFCamera result = sentinel;
    Check(![reader readCamera:&result], message);
    Check(memcmp(&result, &sentinel, sizeof(result)) == 0,
          "a rejected/partial camera must leave the caller's previous sample unchanged");
}

static void RestoreDefaults(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (previousSnapshot) [defaults setObject:previousSnapshot forKey:kSnapshotKey];
    else [defaults removeObjectForKey:kSnapshotKey];
    if (previousModuleBase) [defaults setObject:previousModuleBase forKey:@"mf.game.libbase"];
    else [defaults removeObjectForKey:@"mf.game.libbase"];
    [defaults synchronize];
}

static MFGameReader *NewReader(void) {
    MFGameReader *reader = [MFGameReader new];
    /*
     * [M5.207] 端口路已移除，夹具改为直接摆出「KFD 已绑定」的状态：
     * kfdPid 提供进程实例身份（pid|路径|启动时间），kfdRoot + modeFlag 让门打开。
     * 模拟器里不会真的去读内核 —— root 只是门判与令牌用的占位值。
     */
    MFReadBackend *backend = [MFReadBackend shared];
    backend.kfdPid = getpid();
    backend.kfdRoot = 0xFFFFFFE000100000ULL;
    backend.modeFlag = YES;
    reader.targetTaskPort = mach_task_self();
    return reader;
}

static void SetFixtureBases(MFGameReader *reader) {
    reader.rootObjectBase = 0x100001110ULL;
    reader.entityArrayBase = 0x100002220ULL;
    reader.lootArrayBase = 0x100003330ULL;
}

static void CheckEmpty(MFGameReader *reader, const char *message) {
    Check(reader.rootObjectBase == 0 && reader.entityArrayBase == 0 && reader.lootArrayBase == 0,
          message);
}

static void TestMissingIdentityCannotCrashHUDStartup(void) {
    MFGameReader *reader = [MFGameReader new];
    SetFixtureBases(reader);
    // This is the production message the HUD sends after it obtains a port.
    // Before the fix it throws NSInvalidArgumentException: missing selector.
    [reader loadBasesFromDefaults];
    CheckEmpty(reader, "loading without a target identity must clear all absolute bases");
    Check(reader.calibrationSummary.length > 0, "missing calibration must have a readable status");
    SetFixtureBases(reader);
    [reader saveBasesToDefaults];
    CheckEmpty(reader, "saving without a process identity must not retain unscoped absolute addresses");
    Check([NSUserDefaults.standardUserDefaults objectForKey:kSnapshotKey] == nil,
          "an unscoped snapshot must not be persisted");
}

static NSDictionary *TestSameProcessInstanceRoundTrip(void) {
    MFGameReader *saved = NewReader();
    SetFixtureBases(saved);
    [saved saveBasesToDefaults];
    NSDictionary *snapshot = [NSUserDefaults.standardUserDefaults dictionaryForKey:kSnapshotKey];
    Check(snapshot != nil, "a real current-process identity must permit a scoped snapshot");
    NSDictionary *identity = snapshot[@"identity"];
    Check([identity isKindOfClass:NSDictionary.class] &&
          [identity[@"pid"] intValue] == NSProcessInfo.processInfo.processIdentifier &&
          [identity[@"path"] isKindOfClass:NSString.class] && [identity[@"path"] isAbsolutePath] &&
          [identity[@"startTimeSec"] longLongValue] > 0 &&
          [identity[@"startTimeUSec"] isKindOfClass:NSNumber.class],
          "snapshot scope must include a real PID, exact executable path, and process start time");

    MFGameReader *loaded = NewReader();
    [loaded loadBasesFromDefaults];
    Check(loaded.rootObjectBase == 0x100001110ULL &&
          loaded.entityArrayBase == 0x100002220ULL &&
          loaded.lootArrayBase == 0x100003330ULL,
          "the same running process instance must restore the three distinct 64-bit addresses");
    NSString *summary = loaded.calibrationSummary;
    Check([summary containsString:@"100001110"] && [summary containsString:@"100002220"] &&
          [summary containsString:@"100003330"], "calibration status must identify each restored base");
    return snapshot;
}

static void TestRejectChangedProcessIdentity(NSDictionary *valid) {
    NSString *sameBasenameElsewhere = [@"/a/different/executable/location"
        stringByAppendingPathComponent:[valid[@"identity"][@"path"] lastPathComponent]];
    NSArray<NSDictionary *> *changes = @[
        @{ @"pid": @2147483647 },
        @{ @"path": sameBasenameElsewhere },
        @{ @"startTimeSec": @1 },
        @{ @"startTimeUSec": @1000001 },
    ];
    for (NSDictionary *change in changes) {
        NSMutableDictionary *snapshot = [valid mutableCopy];
        NSMutableDictionary *identity = [snapshot[@"identity"] mutableCopy];
        Check(identity != nil, "persisted process identity must be present for replay regression");
        [identity addEntriesFromDictionary:change];
        snapshot[@"identity"] = identity;
        [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kSnapshotKey];
        MFGameReader *reader = NewReader();
        SetFixtureBases(reader);
        [reader loadBasesFromDefaults];
        CheckEmpty(reader, "PID, exact path, or start-time mismatch must reject a saved process instance");
    }
}

static void TestRejectMalformedAndLegacyAddresses(NSDictionary *valid) {
    NSArray *invalid = @[
        @"not a snapshot", @{},
        @{ @"version": @1, @"rootObjectBase": @0x100001110ULL },
        @{ @"version": @2, @"identity": valid[@"identity"],
           @"rootObjectBase": @0x100001110ULL, @"entityArrayBase": @0x100002220ULL,
           @"lootArrayBase": @0x100003330ULL },
        @{ @"version": @1, @"identity": valid[@"identity"],
           @"rootObjectBase": @"0x100001110", @"entityArrayBase": @0x100002220ULL,
           @"lootArrayBase": @0x100003330ULL },
    ];
    for (id snapshot in invalid) {
        [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kSnapshotKey];
        MFGameReader *reader = NewReader();
        SetFixtureBases(reader);
        [reader loadBasesFromDefaults];
        CheckEmpty(reader, "malformed or unversioned addresses must fail closed without throwing");
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kSnapshotKey];
    [NSUserDefaults.standardUserDefaults setObject:@0x100009990ULL forKey:@"mf.game.libbase"];
    MFGameReader *reader = NewReader();
    SetFixtureBases(reader);
    [reader loadBasesFromDefaults];
    CheckEmpty(reader, "a UE module base must never be substituted for any reader object/array base");
}

static void TestChangingTargetCannotCarryAddresses(void) {
    MFGameReader *reader = NewReader();
    SetFixtureBases(reader);
    reader.targetTaskPort = MACH_PORT_NULL;
    CheckEmpty(reader, "unbinding or changing the target must discard addresses from the old instance");
}

static void TestCameraRejectsIncompleteAndCorruptSamples(MFGameReader *reader) {
    const MFCamera valid = {1000, 2000, 3000, 10, 20, 0, 90};
    const struct {
        uint32_t offset;
        float MFCamera::*member;
    } fields[] = {
        {kMFCamera_X, &MFCamera::x}, {kMFCamera_Y, &MFCamera::y},
        {kMFCamera_Z, &MFCamera::z}, {kMFCamera_Pitch, &MFCamera::pitch},
        {kMFCamera_Yaw, &MFCamera::yaw}, {kMFCamera_Roll, &MFCamera::roll},
        {kMFCamera_FOV, &MFCamera::fov},
    };
    PutCameraFixture(valid);
    MFCamera result = {};
    Check([reader readCamera:&result] && memcmp(&result, &valid, sizeof(valid)) == 0,
          "the production legacy camera chain must preserve a complete valid sample");
    Check([reader readCamera:nullptr], "a valid legacy camera may be probed without an output buffer");

    for (const auto &field : fields) {
        failedReadAddress = kFixtureCamera + field.offset;
        CheckRejectedCamera(reader, "failure of any camera field read must reject the complete sample");
    }
    failedReadAddress = 0;

    for (const auto &field : fields) {
        for (float bad : {std::numeric_limits<float>::quiet_NaN(),
                          std::numeric_limits<float>::infinity(),
                         -std::numeric_limits<float>::infinity()}) {
            MFCamera corrupt = valid;
            corrupt.*(field.member) = bad;
            PutCameraFixture(corrupt);
            CheckRejectedCamera(reader, "a nonfinite camera position, angle or FOV must be rejected");
        }
    }
    for (float badFov : {0.0f, 4.99f, 175.01f, 180.0f}) {
        MFCamera corrupt = valid;
        corrupt.fov = badFov;
        PutCameraFixture(corrupt);
        CheckRejectedCamera(reader, "an out-of-range legacy FOV must not suppress automatic-reader fallback");
    }
    MFCamera corrupt = valid;
    corrupt.pitch = 91.0f;
    PutCameraFixture(corrupt);
    CheckRejectedCamera(reader, "an impossible normalized pitch must reject a legacy camera sample");
    corrupt = valid;
    corrupt.x = 1000001.0f;
    PutCameraFixture(corrupt);
    CheckRejectedCamera(reader, "an implausible legacy camera position must reject a wrong-page sample");
    puts("PASS: production legacy camera rejects partial reads and corrupt samples without publishing them");
}

static void TestCameraPreservesValidBoundaries(MFGameReader *reader) {
    for (float fov : {5.0f, 90.0f, 175.0f}) {
        const MFCamera sample = {1000, 2000, 3000, 370, -725, 1080, fov};
        PutCameraFixture(sample);
        MFCamera result = {};
        Check([reader readCamera:&result] && result.x == 1000 && result.y == 2000 &&
              result.z == 3000 && result.pitch == 10 && result.yaw == -5 &&
              result.roll == 0 && result.fov == fov,
              "wrapped finite angles and inclusive production FOV boundaries must remain valid");
    }
    for (float pitch : {-90.5f, 90.5f}) {
        const MFCamera sample = {0, 0, 0, pitch, 180, -180, 90};
        PutCameraFixture(sample);
        MFCamera result = {};
        Check([reader readCamera:&result] && result.pitch == pitch &&
              result.yaw == 180 && result.roll == -180,
              "valid pitch and signed half-turn boundaries must preserve the camera convention");
    }
    const MFCamera huge = {1000, 2000, 3000, 0,
                          std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(), 90};
    PutCameraFixture(huge);
    MFCamera result = {};
    Check([reader readCamera:&result] && std::isfinite(result.yaw) && std::isfinite(result.roll) &&
          std::fabs(result.yaw) <= 180 && std::fabs(result.roll) <= 180,
          "finite extreme camera angles must normalize without a subtraction loop");
}

static NSArray<MFEntity *> *ReadEntitiesWithDeadline(MFGameReader *reader, MFCamera camera) {
    dispatch_source_t watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(watchdog, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(watchdog, ^{
        fputs("FAIL: production legacy bearing exceeded 3s for an untrusted camera yaw\n", stderr);
        exit(1);
    });
    dispatch_resume(watchdog);
    NSArray<MFEntity *> *entities = [reader readEntitiesWithCamera:camera
        screen:[MFProjection screenWithSize:CGSizeMake(800, 600) fov:camera.fov]];
    dispatch_source_cancel(watchdog);
    return entities;
}

static void TestLegacyBearingDoesNotLoop(MFGameReader *reader) {
    const uint64_t array = 0x102000000ULL, actor = 0x103000000ULL;
    const uint64_t mesh = 0x104000000ULL, bones = 0x105000000ULL;
    const int32_t count = 1, boneCount = 20;
    const float position[3] = {1000, 0, 0};
    reader.entityArrayBase = array;
    PutFixture(array + [MFOffsets shared].current.entityCountOffset, count);
    PutFixture(array, actor);
    PutFixture(actor + [MFOffsets shared].current.entityPositionOffset, position);
    PutFixture(actor + 0x3D0, mesh);
    PutFixture(mesh + 0x750, bones);
    PutFixture(mesh + 0x758, boneCount);

    const struct { float yaw, bearing; BOOL behind; } known[] = {
        {0, 0, NO}, {90, -90, NO}, {-90, 90, NO},
        {180, -180, YES}, {-180, 180, YES}, {-450, 90, NO},
    };
    for (const auto &sample : known) {
        const MFCamera camera = {0, 0, 0, 0, sample.yaw, 0, 90};
        NSArray<MFEntity *> *entities = ReadEntitiesWithDeadline(reader, camera);
        Check(entities.count == 1 && entities.firstObject.bearingDeg == sample.bearing &&
              entities.firstObject.isBehind == sample.behind,
              "the real legacy entity loop must preserve signed front/back bearing boundaries");
    }
    for (float yaw : {std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(),
                      std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity(),
                      std::numeric_limits<float>::quiet_NaN()}) {
        const MFCamera camera = {0, 0, 0, 0, yaw, 0, 90};
        NSArray<MFEntity *> *entities = ReadEntitiesWithDeadline(reader, camera);
        Check(entities.count == 1, "the production bearing fixture must traverse the real entity loop");
        MFEntity *entity = entities.firstObject;
        Check(std::isfinite(yaw) ? (std::isfinite(entity.bearingDeg) && std::fabs(entity.bearingDeg) <= 180)
                                : (std::isnan(entity.bearingDeg) && !entity.isBehind),
              "extreme finite bearings must normalize; nonfinite bearings must remain unknown without hanging");
    }
    puts("PASS: production legacy entity bearings terminate and preserve signed orientation");
}

static void TestProductionReaderMemoryPaths(void) {
    ScopedReaderMemory memory;
    MFGameReader *reader = NewReader();
    reader.rootObjectBase = kFixtureRoot;
    TestCameraRejectsIncompleteAndCorruptSamples(reader);
    TestCameraPreservesValidBoundaries(reader);
    TestLegacyBearingDoesNotLoop(reader);
    TestUEWorldEpochDuringBrokenResolve(
        [](uint64_t address, const void *bytes, size_t size) {
            remoteFixture[@(address)] = [NSData dataWithBytes:bytes length:size];
        }, [] { [remoteFixture removeAllObjects]; });
}

@interface GameReaderRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation GameReaderRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            previousSnapshot = [defaults objectForKey:kSnapshotKey];
            previousModuleBase = [defaults objectForKey:@"mf.game.libbase"];
            atexit(RestoreDefaults);
            [defaults removeObjectForKey:kSnapshotKey];
            TestMissingIdentityCannotCrashHUDStartup();
            NSDictionary *valid = TestSameProcessInstanceRoundTrip();
            TestRejectChangedProcessIdentity(valid);
            TestRejectMalformedAndLegacyAddresses(valid);
            TestChangingTargetCannotCarryAddresses();
            TestProductionReaderMemoryPaths();
            puts("PASS: production game reader scoped calibration and startup selectors");
            exit(0);
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: production game reader startup raised %s: %s\n",
                    exception.name.UTF8String, exception.reason.UTF8String);
            exit(1);
        }
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(GameReaderRegressionDelegate.class));
    }
}
