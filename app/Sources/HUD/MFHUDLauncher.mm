//
//  MFHUDLauncher.mm — 派生 HUD 进程（实现）
//
#import "MFHUDLauncher.h"
#import "MFHUDLog.h"
#import "MFHUDStartupStatus.h"
#import <spawn.h>
#import <signal.h>
#import <sys/stat.h>
#import <sys/types.h>     // uid_t / gid_t（persona 私有 API 的参数类型）
#import <sys/wait.h>
#import <unistd.h>
#import <mach-o/dyld.h>    // _NSGetExecutablePath（root 助手取自己的路径）
#include <errno.h>
#include <string.h>
#include <stdlib.h>      // calloc / free（root 助手拼 argv）

/*
 * libproc.h 在 iOS 公开 SDK 里不存在（构建 #12 踩过），自己声明。
 * PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096
 */
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
#endif

extern "C" {
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

/*
 * ★ [M5.22] persona 相关私有 API —— 必须放在【文件作用域】。
 *
 * 之前写在函数体内（extern "C" { ... } 在块作用域），
 * 构建 #50 报：
 *     error: use of undeclared identifier 'posix_spawnattr_set_persona_uid_np'
 *     error: use of undeclared identifier 'posix_spawnattr_set_persona_gid_np'
 *     did you mean 'posix_spawnattr_set_csm_np'?
 * 说明块作用域的 extern "C" 声明没生效到调用点。
 *
 * 这三个是 Apple 私有 API，iOS 公开 SDK 的 <spawn.h> 里没有，所以自己声明。
 * 用途见 spawnHUD 里的注释（以 root 身份派生 HUD 子进程）。
 */
#define MF_POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attr, uid_t persona, uint32_t flags);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attr, uid_t uid);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attr, uid_t gid);
}

extern char **environ;

/// 原版 PID 路径是 /var/mobile/Library/Caches/ch.xxtou.hudapp.pid；
/// 我们用自己的名字，避免与真白米饭冲突
static NSString *const kPIDFile = @"/var/mobile/Library/Caches/mf.findmy.hud.pid";

/*
 * ★★ 审查修正（HUD 报告 §1.7）：探活不能只用 kill(pid, 0) ★★
 *
 * 问题：全工程没有 waitpid、也没装 SIGCHLD 处理器。
 *   posix_spawn 出来的子进程一旦死掉而父进程没回收，就变成僵尸。
 *   而 kill(僵尸进程, 0) 【返回 0（成功）】—— 因为进程表里还有这个条目。
 *   后果两个，都很致命：
 *     ① 状态行永久显示「运行中 PID xxx」，你以为它在跑
 *     ② isHUDRunning 恒为真 → startHUD 直接拒绝 → 【再也拉不起第二个 HUD】
 *        你每测一次都得重装 App
 *
 * 修法：三重判定
 *   ① waitpid(WNOHANG) —— 顺手回收僵尸，能收掉就说明已经死了
 *   ② proc_pidpath 能读出路径 —— 真活着的进程才有（僵尸读不到）
 *   ③ kill(pid, 0) 兜底
 */
static BOOL MFPidAlive(pid_t p) {
    if (p <= 0) return NO;

    // ① 先试回收。能收到 → 它已经死了（我们之前没收）
    int status = 0;
    pid_t w = waitpid(p, &status, WNOHANG);
    if (w == p) {
        NSLog(@"[MF][HUDLaunch] pid=%d 是僵尸，已回收（status=0x%x）", p, status);
        return NO;
    }

    // ② proc_pidpath 对僵尸返回失败
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(p, path, sizeof(path)) <= 0) {
        return NO;
    }

    // ③ 兜底
    return (kill(p, 0) == 0 || errno == EPERM);
}

@implementation MFHUDLauncher

+ (NSString *)pidFilePath { return kPIDFile; }

+ (pid_t)hudPID {
    NSString *s = [NSString stringWithContentsOfFile:kPIDFile
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    if (!s) return 0;
    pid_t p = (pid_t)s.intValue;
    if (p <= 0) return 0;

    if (MFPidAlive(p)) return p;

    // ★ 死了就立刻清 PID 文件，否则永远拉不起第二个
    [[NSFileManager defaultManager] removeItemAtPath:kPIDFile error:NULL];
    MFHUDLogLine(@"hudPID: pid=%d 已不在，PID 文件已清理", p);
    return 0;
}

+ (BOOL)isHUDRunning {
    return [self hudPID] != 0;
}

+ (BOOL)spawnHUDWithToken:(NSString *)token pid:(pid_t *)spawnedPID error:(NSString **)err {
    // 先清一次可能的僵尸/陈旧 PID
    (void)[self hudPID];

    if ([self isHUDRunning]) {
        if (err) *err = @"HUD 已在运行";
        return NO;
    }

    NSString *exe = [NSBundle mainBundle].executablePath;
    if (!exe) {
        if (err) *err = @"取不到自身可执行路径";
        return NO;
    }

    MFHUDLogLine(@"==== 开始派生 HUD 进程 ====");
    MFHUDLogLine(@"exe = %@", exe);

    const char *path = exe.fileSystemRepresentation;
    char *argv[] = { (char *)path, (char *)"-hud", (char *)"-mf-session",
                     (char *)token.UTF8String, NULL };

    /*
     * ══════════════════════════════════════════════════════════════
     *  ★★★ [M5.22] 用 root 身份派生 —— 对齐 TrollSpeed ★★★
     *
     *  TrollSpeed（Lessica，开源，ch.xxtou.hudapp）的 SetHUDEnabled：
     *
     *      posix_spawnattr_t attr;
     *      posix_spawnattr_init(&attr);
     *      posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
     *      posix_spawnattr_set_persona_uid_np(&attr, 0);
     *      posix_spawnattr_set_persona_gid_np(&attr, 0);
     *      ...
     *      posix_spawnattr_setpgroup(&attr, 0);
     *      posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
     *      posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
     *
     *  为什么这很重要：
     *      HUD 子进程要调 GSInitialize() / BKSDisplayServicesStart() /
     *      UIApplicationInitialize() 这些图形栈底层初始化。
     *      以 mobile(501) 身份跑，这些大概率半途失败 →
     *      UIApplication 内部状态不完整 → 窗口拿不到 CAContext。
     *
     *  依赖 entitlement：persona-mgmt（我们已验证生效）。
     */
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    int pr1 = posix_spawnattr_set_persona_np(&attr, 99, MF_POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    int pr2 = posix_spawnattr_set_persona_uid_np(&attr, 0);
    int pr3 = posix_spawnattr_set_persona_gid_np(&attr, 0);
    MFHUDLogLine(@"persona 设定：np=%d uid=%d gid=%d（0 表示成功）", pr1, pr2, pr3);

    posix_spawnattr_setpgroup(&attr, 0);
    // GCD worker threads can block signals. Do not pass that mask into the
    // long-lived HUD child, otherwise SIGTERM cannot stop a failed startup.
    sigset_t emptyMask, defaultSignals;
    sigemptyset(&emptyMask);
    sigemptyset(&defaultSignals);
    sigaddset(&defaultSignals, SIGTERM);
    sigaddset(&defaultSignals, SIGINT);
    posix_spawnattr_setsigmask(&attr, &emptyMask);
    posix_spawnattr_setsigdefault(&attr, &defaultSignals);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        if (err) {
            *err = [NSString stringWithFormat:@"posix_spawn 失败: %s (rc=%d)", strerror(rc), rc];
        }
        MFHUDLogLine(@"posix_spawn 失败 rc=%d (%s)", rc, strerror(rc));
        return NO;
    }

    NSLog(@"[MF][HUDLaunch] 已拉起 HUD 进程 pid=%d", pid);
    MFHUDLogLine(@"posix_spawn 成功，子进程 pid=%d", pid);
    // Return the child's identity even if saving its PID file fails, so the
    // caller can still perform cleanup and report a root/mobile signal error.
    if (spawnedPID) *spawnedPID = pid;

    // 记 PID（目录不存在则忽略）
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [kPIDFile stringByDeletingLastPathComponent]
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:NULL];
    NSError *writeError = nil;
    if (![[NSString stringWithFormat:@"%d", pid] writeToFile:kPIDFile atomically:YES
                encoding:NSUTF8StringEncoding error:&writeError]) {
        if (err) *err = [NSString stringWithFormat:@"无法保存 HUD PID：%@", writeError.localizedDescription];
        return NO;
    }
    return YES;
}

+ (void)startHUDWithCompletion:(void (^)(BOOL, NSString *))completion {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.mf.hud.launch", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        @autoreleasepool {
            NSString *token = NSUUID.UUID.UUIDString;
            NSString *error = nil;
            NSError *writeError = nil;
            pid_t pid = 0;
            BOOL ready = NO;
            // The parent creates the directory as mobile before the root child
            // writes its reports. A UUID also prevents old PID/report reuse.
            BOOL prepared = [MFHUDStartupStatus writeReport:@{ @"token": token, @"pid": @0,
                                 @"state": @"starting" } token:token error:&writeError];
            if (!prepared) {
                error = [NSString stringWithFormat:@"无法创建 HUD 启动状态文件：%@",
                         writeError.localizedDescription ?: @"目录不可写"];
            } else if ([self spawnHUDWithToken:token pid:&pid error:&error]) {
                NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 12.0;
                while (NSProcessInfo.processInfo.systemUptime < deadline) {
                    NSDictionary *report = [MFHUDStartupStatus readReportForToken:token];
                    BOOL alive = MFPidAlive(pid);
                    MFHUDStartupState state = [MFHUDStartupStatus stateForReport:report
                                                 pid:pid token:token processAlive:alive];
                    if (state == MFHUDStartupReady) { ready = YES; break; }
                    if (state == MFHUDStartupFailed) {
                        error = [report[@"error"] isKindOfClass:NSString.class] ? report[@"error"] : @"HUD 初始化失败";
                        break;
                    }
                    if (state == MFHUDStartupExited) {
                        error = [NSString stringWithFormat:@"HUD 在窗口就绪前退出（PID %d），请查看 HUD 日志。", pid];
                        // Do not erase a replacement process's PID file.
                        NSString *stored = [NSString stringWithContentsOfFile:kPIDFile
                            encoding:NSUTF8StringEncoding error:NULL];
                        if (stored.intValue == pid)
                            [NSFileManager.defaultManager removeItemAtPath:kPIDFile error:NULL];
                        break;
                    }
                    usleep(100 * 1000); // Worker queue only; the console stays responsive.
                }
                if (!ready && !error)
                    error = @"HUD 启动超时：未收到两窗注册与首帧回报。请查看 HUD 日志后重试。";
            }
            if (!ready && pid > 0) {
                // Reap a failed child and remove only this launch's PID. The
                // HUD also exits itself on failure (root/mobile signal rules).
                int childStatus = 0;
                pid_t observed;
                do { observed = waitpid(pid, &childStatus, WNOHANG); }
                while (observed < 0 && errno == EINTR);
                int signalResult = 0, signalError = 0;
                if (observed == 0) {
                    signalResult = kill(pid, SIGTERM);
                    signalError = signalResult < 0 ? errno : 0;
                    for (int attempt = 0; attempt < 50 && observed == 0; attempt++) {
                        usleep(20 * 1000);
                        do { observed = waitpid(pid, &childStatus, WNOHANG); }
                        while (observed < 0 && errno == EINTR);
                    }
                }
                int waitError = observed < 0 ? errno : 0;
                BOOL confirmedExit = observed == pid ||
                    (observed < 0 && waitError == ECHILD && !MFPidAlive(pid));
                if (confirmedExit) {
                    NSString *stored = [NSString stringWithContentsOfFile:kPIDFile
                        encoding:NSUTF8StringEncoding error:NULL];
                    if (stored.intValue == pid)
                        [NSFileManager.defaultManager removeItemAtPath:kPIDFile error:NULL];
                } else {
                    error = [NSString stringWithFormat:@"%@\nHUD 尚未确认退出（PID %d，signal=%d errno=%d wait=%d），请先结束该进程。",
                             error ?: @"初始化失败", pid, signalResult, signalError, waitError];
                }
            }
            MFHUDLogLine(@"启动等待结果：pid=%d ready=%d %@", pid, ready, error ?: @"");
            NSString *reportPath = [MFHUDStartupStatus reportPathForToken:token];
            if (reportPath) [NSFileManager.defaultManager removeItemAtPath:reportPath error:NULL];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ready, error); });
        }
    });
}

+ (BOOL)stopHUDWithError:(NSString **)err {
    pid_t p = [self hudPID];
    if (p <= 0) {
        if (err) *err = @"HUD 未在运行";
        return NO;
    }
    if (kill(p, SIGTERM) != 0) {
        if (err) *err = [NSString stringWithFormat:@"kill 失败 errno=%d (%s)", errno, strerror(errno)];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:kPIDFile error:NULL];
    NSLog(@"[MF][HUDLaunch] 已结束 HUD pid=%d", p);
    MFHUDLogLine(@"已发 SIGTERM 结束 HUD pid=%d", p);
    return YES;
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
