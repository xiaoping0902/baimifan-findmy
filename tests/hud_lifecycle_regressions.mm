#import <Foundation/Foundation.h>
#import "MFHUDControl.h"
#import "MFHUDLauncher.h"
#import "MFHUDStartupStatus.h"
#include <atomic>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

// Keep real spawn, notify, timers, files and waitpid. macOS cannot create the
// iOS persona, so replace only that unavailable identity-selection boundary.
extern "C" {
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t) { return 0; }
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t) { return 0; }
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, gid_t) { return 0; }
void MFHUDLogLine(NSString *format, ...) { }
}

// Reproduce mobile -> root EPERM for our fixtures without requiring a setuid
// helper on CI. Probes and test-only SIGKILL cleanup retain their real behavior.
static std::atomic<bool> denyTermination(false);
static int FixtureKill(pid_t pid, int sig) {
    if (denyTermination.load() && pid > 0 && sig == SIGTERM) {
        errno = EPERM;
        return -1;
    }
    typedef int (*KillFunction)(pid_t, int);
    static KillFunction realKill = (KillFunction)dlsym(RTLD_NEXT, "kill");
    if (!realKill) { errno = ENOSYS; return -1; }
    return realKill(pid, sig);
}
__attribute__((used)) static struct { const void *replacement; const void *original; }
    killInterposition __attribute__((section("__DATA,__interpose"))) = {
        (const void *)&FixtureKill, (const void *)&kill
    };

@interface SignalDeniedLauncher : MFHUDLauncher
@end
@implementation SignalDeniedLauncher
+ (BOOL)forceTerminateWithTaskPort:(pid_t)pid { return NO; }
@end

static pid_t children[16];
static size_t childCount;
static NSMutableArray<NSString *> *reportTokens;

static void RememberChild(pid_t pid) {
    if (pid <= 0) return;
    for (size_t i = 0; i < childCount; i++) if (children[i] == pid) return;
    if (childCount < sizeof(children) / sizeof(children[0])) children[childCount++] = pid;
}

static void Cleanup(void) {
    denyTermination.store(false);
    for (size_t i = 0; i < childCount; i++) {
        // All entries are children this test spawned, never a PID discovered
        // from an existing record. A failure must not leave a fixture behind.
        int status = 0;
        pid_t observed = waitpid(children[i], &status, WNOHANG);
        if (observed == 0) { kill(children[i], SIGKILL); waitpid(children[i], &status, 0); }
    }
    for (NSString *token in reportTokens) {
        NSString *path = [MFHUDStartupStatus reportPathForToken:token];
        if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    }
    if (childCount) [NSFileManager.defaultManager removeItemAtPath:MFHUDPIDFilePath error:NULL];
}

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static BOOL PumpUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (!condition() && NSProcessInfo.processInfo.systemUptime < deadline) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return condition();
}

static BOOL ProcessHasPath(pid_t pid) {
    char path[4096] = {0};
    return proc_pidpath(pid, path, sizeof(path)) > 0;
}

static NSDictionary *ReadyReport(NSString *token) {
    return @{ @"token": token, @"pid": @(getpid()), @"state": @"ready",
        @"menuContextID": @77, @"drawingContextID": @88,
        @"menuRegistered": @YES, @"drawingRegistered": @YES,
        @"menuFrame": @YES, @"drawingFrame": @YES };
}

static void RunChild(NSString *token) {
    NSString *mode = [NSString stringWithUTF8String:getenv("MF_HUD_LIFECYCLE_MODE") ?: "responsive"];
    if (![mode isEqual:@"unresponsive"]) {
        [MFHUDControl watchForExitRequest:^{ _exit(EXIT_SUCCESS); }];
    }
    NSMutableDictionary *report = [ReadyReport(token) mutableCopy];
    if ([mode isEqual:@"failed"]) {
        report[@"state"] = @"failed";
        report[@"error"] = @"fixture initialization failure";
    }
    Check([MFHUDStartupStatus writeReport:report token:token error:NULL], "child must publish its actual startup result");
    if ([mode isEqual:@"blocked"] || [mode isEqual:@"unresponsive"]) {
        // The real control implementation must enforce its exit deadline even
        // while UIKit's main thread never returns to the run loop.
        for (;;) pause();
    }
    CFRunLoopRun();
    _exit(EXIT_SUCCESS);
}

static pid_t RawChild(const char *mode, NSString *token) {
    setenv("MF_HUD_LIFECYCLE_MODE", mode, 1);
    NSString *exe = NSBundle.mainBundle.executablePath;
    const char *path = exe.fileSystemRepresentation;
    char *args[] = {(char *)path, (char *)"-hud", (char *)"-mf-session", (char *)token.UTF8String, NULL};
    pid_t pid = 0;
    Check(posix_spawn(&pid, path, NULL, NULL, args, environ) == 0, "spawn real independent session fixture");
    RememberChild(pid);
    [reportTokens addObject:token];
    Check(PumpUntil(^BOOL {
        return [[MFHUDStartupStatus readReportForToken:token][@"pid"] intValue] == pid;
    }, 3), "independent child must install control and publish its report");
    return pid;
}

static pid_t LaunchReady(const char *mode) {
    setenv("MF_HUD_LIFECYCLE_MODE", mode, 1);
    __block BOOL finished = NO, ready = NO;
    __block NSString *failure = nil;
    [MFHUDLauncher startHUDWithCompletion:^(BOOL result, NSString *error) {
        Check(NSThread.isMainThread, "startup completion must stay on the main thread");
        ready = result;
        failure = error;
        finished = YES;
    }];
    Check(PumpUntil(^BOOL {
        RememberChild([MFHUDLauncher hudPID]);
        return finished;
    }, 16), "real child startup must finish within its deadline");
    if (!ready) fprintf(stderr, "Unexpected launch error: %s\n", failure.UTF8String);
    Check(ready, "fixture must reach real launcher readiness before the lifecycle action");
    pid_t pid = [MFHUDLauncher hudPID];
    RememberChild(pid);
    Check(pid > 0 && ProcessHasPath(pid), "ready completion must identify a live child");
    return pid;
}

static BOOL StopOnWorker(Class launcher, NSString **error) {
    __block BOOL finished = NO, stopped = NO;
    __block NSString *failure = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *detail = nil;
        BOOL result = [launcher stopHUDWithError:&detail];
        dispatch_async(dispatch_get_main_queue(), ^{
            stopped = result;
            failure = detail;
            finished = YES;
        });
    });
    Check(PumpUntil(^BOOL { return finished; }, 7), "stop must have a bounded completion");
    if (error) *error = failure;
    return stopped;
}

static void TestRetainedIdentityAfterRequest(void) {
    pid_t pid = LaunchReady("unresponsive");
    [MFHUDControl requestExit];
    Check(ProcessHasPath(pid), "unresponsive child must still exist after receiving a request");
    Check([MFHUDLauncher hudPID] == pid,
          "requesting exit must retain the live HUD identity until death is confirmed");
}

static void TestFailedStopCanBeRetried(void) {
    pid_t pid = LaunchReady("unresponsive");
    denyTermination.store(true);
    NSString *error = nil;
    Check(!StopOnWorker(SignalDeniedLauncher.class, &error), "inaccessible unresponsive child must report stop failure");
    Check(error.length > 0 && ProcessHasPath(pid), "failed stop must describe the still-living child");
    Check([MFHUDLauncher hudPID] == pid, "failed stop must retain the same PID for retry and duplicate-start prevention");
    denyTermination.store(false);
    Check(StopOnWorker(MFHUDLauncher.class, &error), "a later permitted stop must still find and end that child");
}

static void TestBlockedMainQueueExit(void) {
    pid_t pid = LaunchReady("blocked");
    [MFHUDControl requestExit];
    Check(PumpUntil(^BOOL { return !ProcessHasPath(pid); }, 2.8),
          "control must enforce its own exit deadline while the HUD main queue is blocked");
}

static void TestSessionIsolation(void) {
    pid_t older = RawChild("responsive", NSUUID.UUID.UUIDString);
    pid_t current = LaunchReady("responsive");
    [MFHUDControl requestExit];
    Check(PumpUntil(^BOOL { return !ProcessHasPath(current); }, 2.8), "current session must honor the exit request");
    Check(ProcessHasPath(older), "a current-session exit request must not terminate a different session");
}

static void TestFailedStartupUsesCooperativeExit(void) {
    setenv("MF_HUD_LIFECYCLE_MODE", "failed", 1);
    denyTermination.store(true);
    __block BOOL finished = NO, ready = YES;
    [SignalDeniedLauncher startHUDWithCompletion:^(BOOL result, NSString *error) {
        ready = result;
        Check(error.length > 0, "failed initialization must preserve its error");
        finished = YES;
    }];
    Check(PumpUntil(^BOOL {
        RememberChild([MFHUDLauncher hudPID]);
        return finished;
    }, 16), "failed startup must complete");
    Check(!ready, "failed initialization cannot report ready");
    Check([MFHUDLauncher hudPID] == 0, "failed startup must use cooperative cleanup when SIGTERM is denied");
    for (size_t i = 0; i < childCount; i++)
        Check(!ProcessHasPath(children[i]), "failure completion must not hide a still-running child by deleting its record");
}

static void TestRejectUnrelatedLegacyPID(void) {
    pid_t pid = 0;
    char *args[] = {(char *)"/bin/sleep", (char *)"20", NULL};
    Check(posix_spawn(&pid, "/bin/sleep", NULL, NULL, args, environ) == 0, "spawn unrelated executable fixture");
    RememberChild(pid);
    Check([[NSString stringWithFormat:@"%d", pid] writeToFile:MFHUDPIDFilePath atomically:YES
        encoding:NSUTF8StringEncoding error:NULL], "write stale legacy PID fixture");
    Check([MFHUDLauncher hudPID] == 0, "legacy PID belonging to another executable must never be accepted as HUD");
    Check(ProcessHasPath(pid), "rejecting a stale PID must leave the unrelated executable untouched");
}

static void TestDuplicateAndRestart(void) {
    pid_t first = LaunchReady("responsive");
    __block BOOL finished = NO, ready = YES;
    [MFHUDLauncher startHUDWithCompletion:^(BOOL result, NSString *error) { ready = result; finished = YES; }];
    Check(PumpUntil(^BOOL { return finished; }, 3), "duplicate start must finish promptly");
    Check(!ready && [MFHUDLauncher hudPID] == first, "duplicate start must preserve the original session");
    Check(StopOnWorker(MFHUDLauncher.class, NULL), "cooperative stop must confirm process exit");
    Check(!ProcessHasPath(first), "successful stop must mean the old process has exited");
    pid_t second = LaunchReady("responsive");
    Check(second != first, "restart must create a fresh child after confirmed stop");
    Check(StopOnWorker(MFHUDLauncher.class, NULL), "restarted session must also stop successfully");
}

static void TestCooperativeExitReapsChild(void) {
    pid_t pid = LaunchReady("responsive");
    [MFHUDControl requestExit];
    Check(PumpUntil(^BOOL { return !ProcessHasPath(pid); }, 2.8), "cooperative child must actually exit");
    Check([MFHUDLauncher hudPID] == 0, "probe must publish exited state");
    int status = 0;
    errno = 0;
    Check(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD,
          "launcher must reap its exited child even after menu-style cooperative exit");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *token = [MFHUDStartupStatus currentToken];
        if (token) { RunChild(token); return 0; }
        Check(argc == 2, "supply one lifecycle case name");
        reportTokens = [NSMutableArray array];
        atexit(Cleanup);
        Check(![MFHUDLauncher isHUDRunning], "fixture host must not already contain a running HUD");
        const char *name = argv[1];
        if (!strcmp(name, "retain-request")) TestRetainedIdentityAfterRequest();
        else if (!strcmp(name, "failed-stop")) TestFailedStopCanBeRetried();
        else if (!strcmp(name, "blocked-main")) TestBlockedMainQueueExit();
        else if (!strcmp(name, "session-isolation")) TestSessionIsolation();
        else if (!strcmp(name, "startup-cleanup")) TestFailedStartupUsesCooperativeExit();
        else if (!strcmp(name, "foreign-pid")) TestRejectUnrelatedLegacyPID();
        else if (!strcmp(name, "restart")) TestDuplicateAndRestart();
        else if (!strcmp(name, "reap")) TestCooperativeExitReapsChild();
        else Check(NO, "unknown lifecycle case");
        printf("PASS: lifecycle %s\n", name);
    }
    return 0;
}
