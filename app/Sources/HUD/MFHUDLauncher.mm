#import "MFHUDLauncher.h"
#import "MFHUDLog.h"
#import "MFHUDStartupStatus.h"
#import "MFHUDControl.h"
#import <mach/mach.h>
#import <spawn.h>
#import <signal.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#include <atomic>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
#endif
extern "C" {
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define MF_POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attr, uid_t persona, uint32_t flags);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attr, uid_t uid);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attr, uid_t gid);
}
extern char **environ;
#define kPIDFile MFHUDPIDFilePath

static const void *kMFLifecycleQueueKey = &kMFLifecycleQueueKey;
static std::atomic<uint64_t> sStopGeneration(0);
static NSDictionary *sOwnedChildRecord;
static dispatch_queue_t MFLifecycleQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.mf.hud.lifecycle", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, kMFLifecycleQueueKey, (void *)kMFLifecycleQueueKey, NULL);
    });
    return queue;
}
static NSString *MFExecutablePath(void) {
    return NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
}
static NSString *MFProcessBirth(pid_t pid) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info = {};
    size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length < sizeof(info) ||
        info.kp_proc.p_pid != pid || info.kp_proc.p_starttime.tv_sec <= 0) return nil;
    return [NSString stringWithFormat:@"%lld:%06d", (long long)info.kp_proc.p_starttime.tv_sec,
        (int)info.kp_proc.p_starttime.tv_usec];
}
static NSDictionary *MFCurrentRecord(void) {
    NSDictionary *saved = [MFHUDControl readPIDRecord];
    if (saved) return saved;
    @synchronized (MFHUDControl.class) { return sOwnedChildRecord; }
}
static void MFForgetRecord(NSDictionary *record) {
    [MFHUDControl removePIDRecordIfMatching:record];
    @synchronized (MFHUDControl.class) {
        if ([sOwnedChildRecord isEqual:record]) sOwnedChildRecord = nil;
    }
}
typedef NS_ENUM(NSInteger, MFProcessIdentity) {
    MFProcessExited, MFProcessMatches, MFProcessCooperativeOnly, MFProcessUnrelated, MFProcessUnknown
};
static MFProcessIdentity MFInspectRecord(NSDictionary *record) {
    pid_t pid = [record[@"pid"] intValue];
    if (pid <= 0) return MFProcessExited;
    int status = 0;
    pid_t observed;
    do { observed = waitpid(pid, &status, WNOHANG); } while (observed < 0 && errno == EINTR);
    if (observed == pid) return MFProcessExited;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) > 0) {
        NSString *actual = [NSString stringWithUTF8String:path].stringByResolvingSymlinksInPath;
        NSString *expected = MFExecutablePath();
        id stored = record[@"executable"];
        if (![actual isEqual:expected] || (stored && (![stored isKindOfClass:NSString.class] ||
            ![[stored stringByResolvingSymlinksInPath] isEqual:expected]))) return MFProcessUnrelated;
        id birth = record[@"birth"];
        // Old decimal records can still use their cooperative notification.
        // An executable path alone cannot authorize signals after PID reuse.
        if (!birth) return MFProcessCooperativeOnly;
        if (![birth isKindOfClass:NSString.class] || ![birth length]) return MFProcessUnrelated;
        NSString *actualBirth = MFProcessBirth(pid);
        if (!actualBirth) return MFProcessUnknown;
        if (![actualBirth isEqual:birth]) return MFProcessUnrelated;
        return MFProcessMatches;
    }
    // A denied path query is not proof of death. Keep identity for retry and
    // never use a signal/task port unless both path and birth were matched.
    if (kill(pid, 0) < 0 && errno == ESRCH) return MFProcessExited;
    return MFProcessUnknown;
}
static BOOL MFWaitForExit(NSDictionary *record, NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    do {
        MFProcessIdentity identity = MFInspectRecord(record);
        if (identity == MFProcessExited || identity == MFProcessUnrelated) {
            MFForgetRecord(record);
            return YES;
        }
        usleep(50 * 1000);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return NO;
}
static void MFObserveChild(NSDictionary *record) {
    pid_t pid = [record[@"pid"] intValue];
    __block dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,
        (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!source) return; // Explicit probes still reap on platforms denying a proc source.
    dispatch_source_set_event_handler(source, ^{
        int status = 0;
        pid_t observed;
        do { observed = waitpid(pid, &status, WNOHANG); } while (observed < 0 && errno == EINTR);
        if (observed == pid || (observed < 0 && errno == ECHILD)) MFForgetRecord(record);
        dispatch_source_cancel(source);
    });
    dispatch_source_set_cancel_handler(source, ^{ source = nil; });
    dispatch_resume(source);
}

@interface MFHUDLauncher (LifecyclePrivate)
+ (BOOL)spawnHUDWithToken:(NSString *)token pid:(pid_t *)pid record:(NSDictionary **)record error:(NSString **)error;
+ (BOOL)stopRecord:(NSDictionary *)record error:(NSString **)error;
+ (BOOL)forceTerminateWithTaskPortForRecord:(NSDictionary *)record;
+ (BOOL)stopCurrentWithError:(NSString **)error;
@end

@implementation MFHUDLauncher
+ (NSString *)pidFilePath { return kPIDFile; }
+ (pid_t)hudPID {
    NSDictionary *record = MFCurrentRecord();
    if (!record) return 0;
    MFProcessIdentity identity = MFInspectRecord(record);
    if (identity != MFProcessExited && identity != MFProcessUnrelated) return [record[@"pid"] intValue];
    MFForgetRecord(record);
    return 0;
}
+ (BOOL)isHUDRunning { return [self hudPID] > 0; }

+ (BOOL)spawnHUDWithToken:(NSString *)token pid:(pid_t *)spawnedPID record:(NSDictionary **)spawnedRecord error:(NSString **)err {
    __block BOOL spawned = NO;
    __block NSString *failure = nil;
    __block NSDictionary *identityRecord = nil;
    BOOL locked = [MFHUDControl withPIDRecordLock:^{
        if ([self isHUDRunning]) { failure = @"HUD 已在运行"; return; }
        NSString *exe = MFExecutablePath();
        if (!exe) { failure = @"取不到自身可执行路径"; return; }
        posix_spawnattr_t attr;
        int rc = posix_spawnattr_init(&attr);
        if (rc != 0) { failure = [NSString stringWithFormat:@"初始化派生属性失败：%s", strerror(rc)]; return; }
        int p1 = posix_spawnattr_set_persona_np(&attr, 99, MF_POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        int p2 = posix_spawnattr_set_persona_uid_np(&attr, 0);
        int p3 = posix_spawnattr_set_persona_gid_np(&attr, 0);
        sigset_t emptyMask, defaultSignals;
        sigemptyset(&emptyMask);
        sigemptyset(&defaultSignals);
        sigaddset(&defaultSignals, SIGTERM);
        sigaddset(&defaultSignals, SIGINT);
        int group = posix_spawnattr_setpgroup(&attr, 0);
        int mask = posix_spawnattr_setsigmask(&attr, &emptyMask);
        int defaults = posix_spawnattr_setsigdefault(&attr, &defaultSignals);
        int flags = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
        if (p1 || p2 || p3 || group || mask || defaults || flags) {
            posix_spawnattr_destroy(&attr);
            failure = [NSString stringWithFormat:@"HUD 派生权限/信号属性失败：persona=%d/%d/%d group=%d mask=%d defaults=%d flags=%d",
                p1, p2, p3, group, mask, defaults, flags];
            return;
        }
        const char *path = exe.fileSystemRepresentation;
        char *args[] = {(char *)path, (char *)"-hud", (char *)"-mf-session", (char *)token.UTF8String, NULL};
        pid_t pid = 0;
        rc = posix_spawn(&pid, path, NULL, &attr, args, environ);
        posix_spawnattr_destroy(&attr);
        if (rc != 0) { failure = [NSString stringWithFormat:@"posix_spawn 失败：%s (%d)", strerror(rc), rc]; return; }
        if (spawnedPID) *spawnedPID = pid;
        NSMutableDictionary *identity = [@{ @"pid": @(pid), @"token": token, @"executable": exe } mutableCopy];
        NSString *birth = MFProcessBirth(pid);
        if (birth) identity[@"birth"] = birth;
        NSDictionary *record = [identity copy];
        identityRecord = record;
        @synchronized (MFHUDControl.class) { sOwnedChildRecord = record; }
        MFObserveChild(record);
        NSError *writeError = nil;
        spawned = [MFHUDControl writePIDRecord:record error:&writeError];
        if (!spawned) failure = [NSString stringWithFormat:@"无法保存 HUD 身份：%@", writeError.localizedDescription ?: @"目录不可写"];
        MFHUDLogLine(@"派生 HUD：pid=%d token=%@ saved=%d", pid, token, spawned);
    }];
    if (spawnedRecord) *spawnedRecord = identityRecord;
    if (!locked) failure = @"无法锁定 HUD 身份文件，请检查缓存目录权限。";
    if (!spawned && err) *err = failure;
    return spawned;
}

+ (BOOL)stopRecord:(NSDictionary *)record error:(NSString **)err {
    MFProcessIdentity identity = MFInspectRecord(record);
    if (identity == MFProcessExited || identity == MFProcessUnrelated) { MFForgetRecord(record); return YES; }
    pid_t pid = [record[@"pid"] intValue];
    NSString *token = record[@"token"];
    NSError *requestError = nil;
    if (identity == MFProcessMatches || identity == MFProcessCooperativeOnly || token)
        [MFHUDControl requestExitForPID:pid token:token error:&requestError];
    if (MFWaitForExit(record, 2.0)) return YES;
    int signalError = 0;
    if (MFInspectRecord(record) == MFProcessMatches) {
        if (kill(pid, SIGTERM) < 0) signalError = errno;
        if (MFWaitForExit(record, 1.0)) return YES;
        // Revalidate immediately before the privileged fallback too.
        if (MFInspectRecord(record) == MFProcessMatches && [self forceTerminateWithTaskPortForRecord:record] &&
            MFWaitForExit(record, 1.0)) return YES;
    }
    if (err) *err = [NSString stringWithFormat:
        @"HUD 尚未确认退出（PID %d）。已保留进程身份，可再次点结束；signal errno=%d，控制通道=%@。",
        pid, signalError, requestError.localizedDescription ?: @"请求已送出"];
    return NO;
}

+ (void)startHUDWithCompletion:(void (^)(BOOL, NSString *))completion {
    uint64_t generation = sStopGeneration.load();
    dispatch_async(MFLifecycleQueue(), ^{
        @autoreleasepool {
            NSString *token = NSUUID.UUID.UUIDString;
            NSString *error = nil;
            NSError *writeError = nil;
            pid_t pid = 0;
            NSDictionary *record = nil;
            BOOL ready = NO;
            BOOL cancelled = generation != sStopGeneration.load();
            BOOL prepared = !cancelled && [MFHUDStartupStatus writeReport:
                @{ @"token": token, @"pid": @0, @"state": @"starting" } token:token error:&writeError];
            if (cancelled) {
                error = @"HUD 启动已取消。";
            } else if (!prepared) {
                error = [NSString stringWithFormat:@"无法创建 HUD 启动状态文件：%@", writeError.localizedDescription ?: @"目录不可写"];
            } else if ([self spawnHUDWithToken:token pid:&pid record:&record error:&error]) {
                NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 12.0;
                while (NSProcessInfo.processInfo.systemUptime < deadline) {
                    NSDictionary *report = [MFHUDStartupStatus readReportForToken:token];
                    if (generation != sStopGeneration.load() || [report[@"state"] isEqual:@"stopped"] ||
                        [report[@"state"] isEqual:@"stopping"]) { error = @"HUD 启动已取消。"; break; }
                    MFProcessIdentity identity = MFInspectRecord(record);
                    BOOL alive = identity != MFProcessExited && identity != MFProcessUnrelated;
                    MFHUDStartupState state = [MFHUDStartupStatus stateForReport:report pid:pid token:token processAlive:alive];
                    if (state == MFHUDStartupReady) { ready = YES; break; }
                    if (state == MFHUDStartupFailed || state == MFHUDStartupExited) {
                        error = [report[@"error"] isKindOfClass:NSString.class] ? report[@"error"] :
                            (alive ? @"HUD 初始化失败。" : @"HUD 在窗口就绪前退出，请查看 HUD 日志。");
                        break;
                    }
                    usleep(100 * 1000);
                }
                if (!ready && !error) error = @"HUD 启动超时：未收到两窗注册与首帧回报。";
            }
            if (!ready && record) {
                NSString *cleanupError = nil;
                if (![self stopRecord:record error:&cleanupError])
                    error = [NSString stringWithFormat:@"%@\n%@", error ?: @"初始化失败", cleanupError];
            }
            // Preserve terminal diagnostics. UUID-scoped files cannot become a
            // later launch's readiness report.
            MFHUDLogLine(@"启动结果：pid=%d ready=%d %@", pid, ready, error ?: @"");
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL accepted = ready && generation == sStopGeneration.load() && [self hudPID] == pid;
                if (completion) completion(accepted, ready && !accepted ? @"HUD 已停止或启动已取消。" : error);
            });
        }
    });
}

+ (BOOL)forceTerminateWithTaskPortForRecord:(NSDictionary *)record {
    if (MFInspectRecord(record) != MFProcessMatches) return NO;
    pid_t pid = [record[@"pid"] intValue];
    typedef kern_return_t (*TaskForPID)(mach_port_name_t, int, mach_port_name_t *);
    TaskForPID acquire = (TaskForPID)dlsym(RTLD_DEFAULT, "task_for_pid");
    if (!acquire) return NO;
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t result = acquire(mach_task_self(), pid, &task);
    if (result != KERN_SUCCESS || task == MACH_PORT_NULL) return NO;
    // The port is tied to a task instance. Recheck after acquisition before
    // terminating so PID reuse during task_for_pid cannot target a new task.
    result = MFInspectRecord(record) == MFProcessMatches ? task_terminate(task) : KERN_FAILURE;
    mach_port_deallocate(mach_task_self(), task);
    return result == KERN_SUCCESS;
}
+ (BOOL)stopCurrentWithError:(NSString **)err {
    NSDictionary *record = MFCurrentRecord();
    return !record || [self stopRecord:record error:err];
}
+ (BOOL)stopHUDWithError:(NSString **)err {
    sStopGeneration.fetch_add(1);
    if (dispatch_get_specific(kMFLifecycleQueueKey)) return [self stopCurrentWithError:err];
    __block BOOL stopped = NO;
    __block NSString *failure = nil;
    dispatch_sync(MFLifecycleQueue(), ^{ stopped = [self stopCurrentWithError:&failure]; });
    if (!stopped && err) *err = failure;
    return stopped;
}
+ (void)stopHUDWithCompletion:(void (^)(BOOL, NSString *))completion {
    // Cancel an in-flight start immediately; the serialized stop then confirms
    // that launch's cleanup before another start can be admitted.
    sStopGeneration.fetch_add(1);
    dispatch_async(MFLifecycleQueue(), ^{
        NSString *error = nil;
        BOOL stopped = [self stopCurrentWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(stopped, error); });
    });
}

#pragma mark - [M5.26] root 助手

/*
 * 以 root 身份派生自己，跑完等退出，回收 stdout。
 *
 * 为什么这样做：
 *   TrollStore 装的 App 本体在 mobile(501)，entitlements 只对【本进程】生效，
 *   改不了自己的 uid。特权操作（清理系统残留 / Keychain / 防封 / 巨魔装卸）
 *   要真 root，必须在 posix_spawn 时就指定 persona + uid/gid。
 *
 * 这是 TrollSpeed（Lessica，开源，ch.xxtou.hudapp）的做法，原样照搬。
 */
static BOOL gLastRootChildWasRoot = NO;

+ (BOOL)lastRootChildWasRoot {
    return gLastRootChildWasRoot;
}

+ (int)runAsRootWithArgs:(NSArray<NSString *> *)args
                  output:(NSString *_Nullable *_Nullable)out {
    gLastRootChildWasRoot = NO;

    uint32_t sz = 0;
    _NSGetExecutablePath(NULL, &sz);
    char *exePath = (char *)calloc(1, sz + 1);
    if (exePath == NULL) return -1;
    _NSGetExecutablePath(exePath, &sz);

    NSMutableArray<NSString *> *full = [NSMutableArray arrayWithObject:[NSString stringWithUTF8String:exePath]];
    [full addObjectsFromArray:(args ?: @[])];

    char **argv = (char **)calloc(full.count + 1, sizeof(char *));
    if (argv == NULL) { free(exePath); return -1; }
    for (NSUInteger i = 0; i < full.count; i++) argv[i] = strdup(full[i].UTF8String);
    argv[full.count] = NULL;

    int pipefd[2] = {-1, -1};
    BOOL capture = (out != NULL);
    if (capture && pipe(pipefd) != 0) capture = NO;

    posix_spawn_file_actions_t fa;
    if (capture) {
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&fa, pipefd[0]);
        posix_spawn_file_actions_addclose(&fa, pipefd[1]);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    int pr1 = posix_spawnattr_set_persona_np(&attr, 99, MF_POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    int pr2 = posix_spawnattr_set_persona_uid_np(&attr, 0);
    int pr3 = posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    MFHUDLogLine(@"[root 助手] 派生：args=%@ persona=%d uid=%d gid=%d（0=成功）",
                 [full subarrayWithRange:NSMakeRange(1, full.count - 1)], pr1, pr2, pr3);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, exePath, capture ? &fa : NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (capture) posix_spawn_file_actions_destroy(&fa);

    for (NSUInteger i = 0; i < full.count; i++) free(argv[i]);
    free(argv);
    free(exePath);

    if (rc != 0) {
        MFHUDLogLine(@"[root 助手] posix_spawn 失败 rc=%d (%s)", rc, strerror(rc));
        if (capture) { close(pipefd[0]); close(pipefd[1]); }
        return -1;
    }

    MFHUDLogLine(@"[root 助手] 子进程 pid=%d", pid);

    NSMutableData *buf = capture ? [NSMutableData data] : nil;
    if (capture) close(pipefd[1]);

    while (YES) {
        if (capture) {
            char tmp[4096];
            ssize_t n = read(pipefd[0], tmp, sizeof(tmp));
            if (n > 0) [buf appendBytes:tmp length:(NSUInteger)n];
        }
        int status = 0;
        pid_t w = waitpid(pid, &status, capture ? WNOHANG : 0);
        if (w == pid) {
            if (capture) {
                char tmp[4096];
                ssize_t n;
                while ((n = read(pipefd[0], tmp, sizeof(tmp))) > 0)
                    [buf appendBytes:tmp length:(NSUInteger)n];
                close(pipefd[0]);
                NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
                if (out) *out = s;
                if ([s containsString:@"uid=0"] || [s containsString:@"UID=0"]) {
                    gLastRootChildWasRoot = YES;
                }
                MFHUDLogLine(@"[root 助手] 输出：%@", (s.length < 1500 ? s : [s substringToIndex:1500]));
            }
            int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            MFHUDLogLine(@"[root 助手] 退出码=%d  真拿到 root=%d", code, gLastRootChildWasRoot);
            return code;
        }
        if (!capture) usleep(50 * 1000);
    }
}

@end
