#import <Foundation/Foundation.h>
#import "MFHUDLauncher.h"
#import "MFHUDStartupStatus.h"
#import "MFHUDLog.h"
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

// macOS does not expose the iOS persona service. Preserve real posix_spawn,
// files, liveness checks, deadlines and main-queue completion; only identity
// selection and the child UIKit work are substituted.
extern "C" {
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t) { return 0; }
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t) { return 0; }
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t) { return 0; }
void MFHUDLogLine(NSString *format, ...) { }
}

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static void LaunchFixture(const char *mode, BOOL wantReady) {
    setenv("MF_HUD_FIXTURE", mode, 1);
    __block BOOL finished = NO, gotReady = NO, wasRunning = NO;
    __block NSString *failure = nil;
    [MFHUDLauncher startHUDWithCompletion:^(BOOL ready, NSString *error) {
        Check(NSThread.isMainThread, "launcher completion must run on the main thread");
        gotReady = ready;
        failure = error;
        wasRunning = [MFHUDLauncher isHUDRunning];
        // Always clean a leaked fixture, including when running against the bug.
        if (wasRunning) {
            pid_t leftover = [MFHUDLauncher hudPID];
            [MFHUDLauncher stopHUDWithError:NULL];
            // This cleanup is test-only, so a regression cannot leave a fixture
            // process running on the CI host with inherited blocked signals.
            if (leftover > 0) { kill(leftover, SIGKILL); waitpid(leftover, NULL, 0); }
        }
        finished = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:16];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (!finished) [MFHUDLauncher stopHUDWithError:NULL];
    Check(finished, "startup must complete within its bounded deadline");
    Check(gotReady == wantReady, "reported readiness must match the child startup result");
    if (wantReady) Check(wasRunning, "a ready child's lifetime must cover its completion");
    else {
        if (wasRunning) fprintf(stderr, "Startup error before cleanup: %s\n", failure.UTF8String);
        Check(failure.length > 0, "failed startup must return an error");
        Check(!wasRunning, "failed or timed-out startup must end its child and allow retry");
    }
}

int main(void) {
    @autoreleasepool {
        NSString *token = [MFHUDStartupStatus currentToken];
        if (token) {
            NSString *mode = [NSString stringWithUTF8String:getenv("MF_HUD_FIXTURE") ?: ""];
            if (![mode isEqual:@"silent"]) {
                NSMutableDictionary *report = [@{ @"token": token, @"pid": @(getpid()),
                    @"state": [mode isEqual:@"ready"] ? @"ready" : @"failed",
                    @"error": @"fixture initialization failure", @"menuContextID": @77,
                    @"drawingContextID": @88, @"menuRegistered": @YES,
                    @"drawingRegistered": @YES, @"menuFrame": @YES, @"drawingFrame": @YES } mutableCopy];
                Check([MFHUDStartupStatus writeReport:report token:token error:NULL], "child report write");
            }
            for (;;) pause();
        }
        LaunchFixture("failed", NO);
        LaunchFixture("silent", NO);
        LaunchFixture("ready", YES);
        puts("PASS: real child failure/timeout cleanup, retry and main-thread completion");
    }
    return 0;
}
