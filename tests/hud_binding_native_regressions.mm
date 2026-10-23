#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#import "MFModuleLocator.h"
#import "MFHUDPassiveState.h"

static void Check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

@interface BorrowedOnlyLocator : MFModuleLocator
@end
@implementation BorrowedOnlyLocator
+ (mach_port_t)taskPortForPid:(pid_t)pid {
    Check(NO, "borrowed task lookup must never acquire another task port");
    return MACH_PORT_NULL;
}
@end

static void TestBorrowedPortRemainsOwnedByCaller(void) {
    mach_port_t borrowed = mach_task_self();
    mach_port_urefs_t before = 0, after = 0;
    Check(mach_port_get_refs(mach_task_self(), borrowed, MACH_PORT_RIGHT_SEND, &before) == KERN_SUCCESS,
          "self send-right count must be readable");
    NSString *error = nil;
    MFModuleInfo *module = [BorrowedOnlyLocator mainModuleForPid:getpid() borrowedTask:borrowed error:&error];
    Check(module.base != 0, "borrowed self task must resolve a real loaded module");
    Check(mach_port_get_refs(mach_task_self(), borrowed, MACH_PORT_RIGHT_SEND, &after) == KERN_SUCCESS && before == after,
          "module lookup must not consume or leak the caller's borrowed send right");
    Check([BorrowedOnlyLocator mainModuleForPid:getpid() + 1 borrowedTask:borrowed error:&error] == nil && error.length,
          "borrowed port for a different PID must fail before any module reads");
    Check([BorrowedOnlyLocator mainModuleForPid:getpid() borrowedTask:MACH_PORT_NULL error:&error] == nil && error.length,
          "null borrowed task must fail without requesting a replacement");
}

static void TestPassiveSnapshotWritesCachedEvidence(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *token = NSUUID.UUID.UUIDString;
    NSDictionary *cached = @{
        @"binding": @{ @"stage": @"task-port", @"error": @"fixture-denied", @"taskPort": @0, @"libBase": @0 },
        @"feed": @{ @"running": @YES, @"packetCount": @0, @"lastPacketAge": NSNull.null },
        @"drawing": @{ @"cameraOK": @NO, @"entities": @0 },
        @"firstFrameCompletions": @{ @"menu": @1, @"drawing": @1 },
    };
    NSError *error = nil;
    @try {
        Check([MFHUDPassiveState writeSnapshot:cached token:token directory:directory error:&error],
              "cached failure and rendering evidence must export without live providers");
        NSString *path = [MFHUDPassiveState snapshotPathForToken:token directory:directory];
        NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:&error];
        Check([saved[@"pid"] intValue] == getpid() && [saved[@"token"] isEqual:token] && saved[@"exportedAt"],
              "snapshot must carry its writer PID, session token and collection time");
        for (NSString *key in cached)
            Check([saved[key] isEqual:cached[key]], "passive writer must preserve cached evidence exactly");
        struct stat info = {};
        Check(stat(path.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0644,
              "mobile console must be able to read root HUD snapshots");
        Check(![MFHUDPassiveState writeSnapshot:cached token:@"../other-session" directory:directory error:&error] && error,
              "invalid session token must not escape the snapshot directory");
        Check([MFHUDPassiveState writeSnapshot:@{ @"terminal": @YES } token:token directory:directory error:&error],
              "one session snapshot must be atomically replaceable");
        saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:&error];
        Check([saved[@"terminal"] boolValue] && !saved[@"binding"], "atomic update must replace stale evidence completely");
    } @finally {
        [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
    }
}

int main(void) {
    @autoreleasepool {
        TestBorrowedPortRemainsOwnedByCaller();
        TestPassiveSnapshotWritesCachedEvidence();
        puts("PASS: production borrowed module lookup and passive session snapshot export");
    }
}
