#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import "MFGameReader.h"
#import "../app/Sources/Read/MFReadBackend.h"
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
