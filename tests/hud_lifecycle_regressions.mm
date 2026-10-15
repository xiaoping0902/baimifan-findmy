#import <Foundation/Foundation.h>
#import "MFHUDControl.h"
#import "MFHUDLauncher.h"
#import "MFHUDStartupStatus.h"
#import <notify.h>
#include <atomic>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
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
static std::atomic<unsigned> deniedSignalCalls(0);
extern "C" int kill(pid_t pid, int sig) {
    if (denyTermination.load() && pid > 0 && sig == SIGTERM) {
        deniedSignalCalls.fetch_add(1);
        errno = EPERM;
        return -1;
    }
    typedef int (*KillFunction)(pid_t, int);
    static KillFunction realKill = (KillFunction)dlsym(RTLD_NEXT, "kill");
    if (!realKill) { errno = ENOSYS; return -1; }
    return realKill(pid, sig);
}

@interface SignalDeniedLauncher : MFHUDLauncher
@end
@implementation SignalDeniedLauncher
+ (BOOL)forceTerminateWithTaskPortForRecord:(NSDictionary *)record { return NO; }
@end

static pid_t children[16];
static size_t childCount;
static NSMutableArray<NSString *> *reportTokens;
static NSString *childIdentityPath;

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
    if (childIdentityPath) [NSFileManager.defaultManager removeItemAtPath:childIdentityPath error:NULL];
    if (childCount) [NSFileManager.defaultManager removeItemAtPath:MFHUDPIDFilePath error:NULL];
}

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static BOOL PumpUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    for (;;) {
        // A condition may consume waitpid's one exit result. Preserve the
        // first success instead of evaluating it again after leaving the loop.
        if (condition()) return YES;
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return NO;
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
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
    if ([mode isEqual:@"legacy"]) {
        // Characterize the old binary's unscoped listener without substituting
        // the new control implementation in any of the other cases.
        int legacyToken = NOTIFY_TOKEN_INVALID;
        Check(notify_register_dispatch(MFHUDExitNotificationName.UTF8String, &legacyToken,
              dispatch_get_main_queue(), ^(int t) { _exit(EXIT_SUCCESS); }) == NOTIFY_STATUS_OK,
              "legacy fixture must install its old notification protocol");
    } else if (![mode isEqual:@"unresponsive"]) {
        [MFHUDControl watchForExitRequest:^{ _exit(EXIT_SUCCESS); }];
    }
    const char *identityPath = getenv("MF_HUD_LIFECYCLE_CHILD_ID_PATH");
    if (identityPath) {
        Check([[NSString stringWithFormat:@"%d", getpid()] writeToFile:[NSString stringWithUTF8String:identityPath]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL], "publish independent test child identity");
    }
    NSMutableDictionary *report = [ReadyReport(token) mutableCopy];
    if ([mode isEqual:@"failed"]) {
        report[@"state"] = @"failed";
        report[@"error"] = @"fixture initialization failure";
    }
    if (![mode isEqual:@"silent"])
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
        RememberChild([[NSString stringWithContentsOfFile:childIdentityPath encoding:NSUTF8StringEncoding error:NULL] intValue]);
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
    BOOL stopped = StopOnWorker(SignalDeniedLauncher.class, &error);
    Check(deniedSignalCalls.load() > 0, "permission fixture must intercept production SIGTERM calls");
    Check(!stopped, "inaccessible unresponsive child must report stop failure");
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

static void TestFailedStartupUsesCooperativeExit(const char *mode) {
    setenv("MF_HUD_LIFECYCLE_MODE", mode, 1);
    denyTermination.store(true);
    __block BOOL finished = NO, ready = YES;
    [SignalDeniedLauncher startHUDWithCompletion:^(BOOL result, NSString *error) {
        ready = result;
        Check(error.length > 0, "failed initialization must preserve its error");
        finished = YES;
    }];
    Check(PumpUntil(^BOOL {
        RememberChild([[NSString stringWithContentsOfFile:childIdentityPath encoding:NSUTF8StringEncoding error:NULL] intValue]);
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

static void TestRejectReusedSameExecutablePID(void) {
    NSDictionary *stale = @{ @"pid": @(getpid()), @"token": NSUUID.UUID.UUIDString,
        @"executable": NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath,
        @"birth": @"1:000001" };
    Check([MFHUDControl writePIDRecord:stale error:NULL], "write stale same-executable identity");
    Check([MFHUDLauncher hudPID] == 0,
          "a reused PID in the same executable must be rejected when process birth differs");
    Check([MFHUDControl writePIDRecord:stale error:NULL], "restore stale identity for direct stop");
    denyTermination.store(true);
    Check(StopOnWorker(SignalDeniedLauncher.class, NULL), "a stale process instance must already count as stopped");
    Check(deniedSignalCalls.load() == 0, "stop must not signal a different birth of the same executable");
    Check(ProcessHasPath(getpid()), "rejecting reused HUD identity must leave the console alive");
}

static void TestMissingBirthCannotAuthorizeSignal(void) {
    pid_t pid = LaunchReady("unresponsive");
    NSDictionary *original = [MFHUDControl readPIDRecord];
    Check([original[@"birth"] isKindOfClass:NSString.class], "new child record must persist actual process birth");
    NSMutableDictionary *unverified = [original mutableCopy];
    [unverified removeObjectForKey:@"birth"];
    Check([MFHUDControl writePIDRecord:unverified error:NULL], "write identity without process birth");
    denyTermination.store(true);
    Check(!StopOnWorker(SignalDeniedLauncher.class, NULL), "an unverified unresponsive process cannot confirm exit");
    Check(deniedSignalCalls.load() == 0, "missing birth must permit cooperative requests without authorizing signals");
    Check(ProcessHasPath(pid) && [MFHUDLauncher hudPID] == pid,
          "failed cooperative-only stop must retain the live identity for retry");
    Check([MFHUDControl writePIDRecord:original error:NULL], "restore positively verified child identity");
    denyTermination.store(false);
    Check(StopOnWorker(MFHUDLauncher.class, NULL), "verified child can still use the normal termination fallback");
}

static void TestReadOnlyLockCanSerialize(void) {
    Check([MFHUDControl withPIDRecordLock:^{}], "initialize shared lock fixture");
    NSString *path = [MFHUDPIDFilePath stringByAppendingString:@".lock"];
    Check(chmod(path.fileSystemRepresentation, 0444) == 0, "make existing lock readable without write access");
    __block BOOL ran = NO;
    BOOL locked = [MFHUDControl withPIDRecordLock:^{ ran = YES; }];
    chmod(path.fileSystemRepresentation, 0644);
    Check(locked && ran, "read-only lock descriptor must still serialize root/mobile lifecycle operations");
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

static void TestLegacyRecordCanStillStop(void) {
    pid_t pid = LaunchReady("legacy");
    Check([[NSString stringWithFormat:@"%d", pid] writeToFile:MFHUDPIDFilePath atomically:YES
        encoding:NSUTF8StringEncoding error:NULL], "replace metadata with a legacy decimal PID record");
    Check([MFHUDLauncher hudPID] == pid, "a live legacy HUD executable must remain discoverable");
    denyTermination.store(true);
    Check(StopOnWorker(SignalDeniedLauncher.class, NULL), "old PID records must retain their cooperative notification exit");
    Check(!ProcessHasPath(pid), "legacy stop success must mean the old child is gone");
}

static void TestConsoleReopenUsesPersistedSession(void) {
    pid_t hud = LaunchReady("responsive");
    NSString *exe = NSBundle.mainBundle.executablePath;
    char *args[] = {(char *)exe.fileSystemRepresentation, (char *)"stop-existing-console", NULL};
    pid_t console = 0;
    Check(posix_spawn(&console, exe.fileSystemRepresentation, NULL, NULL, args, environ) == 0,
          "spawn a fresh console with no in-memory session state");
    RememberChild(console);
    __block pid_t observed = 0;
    __block int status = 0;
    Check(PumpUntil(^BOOL { observed = waitpid(console, &status, WNOHANG); return observed != 0; }, 7),
          "reopened console stop must complete");
    Check(observed == console && WIFEXITED(status) && WEXITSTATUS(status) == 0,
          "fresh console must find and cooperatively stop the persisted session");
    Check(!ProcessHasPath(hud) && ![MFHUDLauncher isHUDRunning], "fresh console cannot hide a still-running HUD");
}

static void TestStartupCancellation(void) {
    setenv("MF_HUD_LIFECYCLE_MODE", "silent", 1);
    __block BOOL finished = NO, ready = YES;
    [MFHUDLauncher startHUDWithCompletion:^(BOOL result, NSString *error) { ready = result; finished = YES; }];
    __block pid_t pid = 0;
    Check(PumpUntil(^BOOL {
        pid = [[NSString stringWithContentsOfFile:childIdentityPath encoding:NSUTF8StringEncoding error:NULL] intValue];
        return pid > 0;
    }, 3), "silent child must exist before cancelling startup");
    RememberChild(pid);
    Check(StopOnWorker(MFHUDLauncher.class, NULL), "stop during startup must cancel its readiness wait");
    Check(finished && !ready && !ProcessHasPath(pid), "cancelled startup must finish without leaving its child running");
    LaunchReady("responsive");
    Check(StopOnWorker(MFHUDLauncher.class, NULL), "a cancelled launch must allow a later clean restart");
}

static void TestTerminalStartupReports(void) {
    NSString *token = NSUUID.UUID.UUIDString;
    [reportTokens addObject:token];
    NSMutableDictionary *report = [ReadyReport(token) mutableCopy];
    report[@"state"] = @"stopped";
    Check([MFHUDStartupStatus writeReport:report token:token error:NULL], "publish terminal stopped report");
    Check([MFHUDStartupStatus stateForReport:report pid:getpid() token:token processAlive:YES] != MFHUDStartupExited,
          "a stopped acknowledgement cannot claim a living process has exited");
    report[@"state"] = @"ready";
    Check([MFHUDStartupStatus writeReport:report token:token error:NULL], "late frame report must be handled without transport error");
    Check([[[MFHUDStartupStatus readReportForToken:token] objectForKey:@"state"] isEqual:@"stopped"],
          "late ready must not overwrite a terminal stopped report");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *token = [MFHUDStartupStatus currentToken];
        if (token) { RunChild(token); return 0; }
        Check(argc == 2, "supply one lifecycle case name");
        if (!strcmp(argv[1], "stop-existing-console")) {
            NSString *error = nil;
            BOOL stopped = [MFHUDLauncher stopHUDWithError:&error];
            if (!stopped) fprintf(stderr, "Fresh console stop error: %s\n", error.UTF8String);
            return stopped ? 0 : 1;
        }
        reportTokens = [NSMutableArray array];
        childIdentityPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"mf-hud-lifecycle-%@.pid", NSUUID.UUID.UUIDString]];
        setenv("MF_HUD_LIFECYCLE_CHILD_ID_PATH", childIdentityPath.fileSystemRepresentation, 1);
        atexit(Cleanup);
        denyTermination.store(true);
        errno = 0;
        Check(kill(getpid(), SIGTERM) == -1 && errno == EPERM && deniedSignalCalls.load() == 1,
              "permission fixture must demonstrably deny SIGTERM before exercising production");
        denyTermination.store(false);
        deniedSignalCalls.store(0);
        Check(![MFHUDLauncher isHUDRunning], "fixture host must not already contain a running HUD");
        const char *name = argv[1];
        if (!strcmp(name, "retain-request")) TestRetainedIdentityAfterRequest();
        else if (!strcmp(name, "failed-stop")) TestFailedStopCanBeRetried();
        else if (!strcmp(name, "blocked-main")) TestBlockedMainQueueExit();
        else if (!strcmp(name, "session-isolation")) TestSessionIsolation();
        else if (!strcmp(name, "startup-cleanup")) TestFailedStartupUsesCooperativeExit("failed");
        else if (!strcmp(name, "startup-timeout")) TestFailedStartupUsesCooperativeExit("silent");
        else if (!strcmp(name, "foreign-pid")) TestRejectUnrelatedLegacyPID();
        else if (!strcmp(name, "same-executable-pid")) TestRejectReusedSameExecutablePID();
        else if (!strcmp(name, "missing-birth")) TestMissingBirthCannotAuthorizeSignal();
        else if (!strcmp(name, "readonly-lock")) TestReadOnlyLockCanSerialize();
        else if (!strcmp(name, "restart")) TestDuplicateAndRestart();
        else if (!strcmp(name, "reap")) TestCooperativeExitReapsChild();
        else if (!strcmp(name, "legacy-record")) TestLegacyRecordCanStillStop();
        else if (!strcmp(name, "console-reopen")) TestConsoleReopenUsesPersistedSession();
        else if (!strcmp(name, "cancel-start")) TestStartupCancellation();
        else if (!strcmp(name, "terminal-report")) TestTerminalStartupReports();
        else Check(NO, "unknown lifecycle case");
        printf("PASS: lifecycle %s\n", name);
    }
    return 0;
}
