//
//  MFHUDLauncher.mm — 派生 HUD 进程（实现）
//
#import "MFHUDLauncher.h"
#import "MFHUDLog.h"
#import <spawn.h>
#import <signal.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#include <errno.h>
#include <string.h>

/*
 * libproc.h 在 iOS 公开 SDK 里不存在（构建 #12 踩过），自己声明。
 * PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096
 */
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
#endif

extern "C" {
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
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

+ (BOOL)startHUDWithError:(NSString **)err {
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
    char *argv[3];
    argv[0] = (char *)path;
    argv[1] = (char *)"-hud";
    argv[2] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) {
        if (err) {
            *err = [NSString stringWithFormat:@"posix_spawn 失败: %s (rc=%d)", strerror(rc), rc];
        }
        MFHUDLogLine(@"posix_spawn 失败 rc=%d (%s)", rc, strerror(rc));
        return NO;
    }

    NSLog(@"[MF][HUDLaunch] 已拉起 HUD 进程 pid=%d", pid);
    MFHUDLogLine(@"posix_spawn 成功，子进程 pid=%d", pid);

    // 记 PID（目录不存在则忽略）
    [[NSFileManager defaultManager] createDirectoryAtPath:
        [kPIDFile stringByDeletingLastPathComponent]
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:NULL];
    [[NSString stringWithFormat:@"%d", pid] writeToFile:kPIDFile
                                            atomically:YES
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];

    // 给子进程一点启动时间，回头确认存活
    usleep(400 * 1000);
    if (!MFPidAlive(pid)) {
        if (err) {
            *err = [NSString stringWithFormat:
                    @"HUD 进程启动后立即退出 (pid=%d)\n\n"
                    @"内存诊断：去看「其他 → HUD 日志」页。", pid];
        }
        MFHUDLogLine(@"⚠️ 子进程启动后 400ms 内就没了（posix_spawn 成功但进程立刻退出）");
        [[NSFileManager defaultManager] removeItemAtPath:kPIDFile error:NULL];
        return NO;
    }
    MFHUDLogLine(@"子进程 400ms 后仍存活");
    return YES;
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

@end
