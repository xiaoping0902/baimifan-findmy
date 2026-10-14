//
//  MFHUDLauncher.mm — 派生 HUD 进程（实现）
//
#import "MFHUDLauncher.h"
#import <spawn.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>
#include <errno.h>
#include <string.h>

extern char **environ;

/// 原版 PID 路径是 /var/mobile/Library/Caches/ch.xxtou.hudapp.pid；
/// 我们用自己的名字，避免与真白米饭冲突
static NSString *const kPIDFile = @"/var/mobile/Library/Caches/mf.findmy.hud.pid";

@implementation MFHUDLauncher

+ (NSString *)pidFilePath { return kPIDFile; }

+ (pid_t)hudPID {
    NSString *s = [NSString stringWithContentsOfFile:kPIDFile
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    if (!s) return 0;
    pid_t p = (pid_t)s.intValue;
    if (p <= 0) return 0;
    // 探活：信号 0 不发信号，只做存在性检查
    if (kill(p, 0) == 0 || errno == EPERM) return p;
    return 0;
}

+ (BOOL)isHUDRunning {
    return [self hudPID] != 0;
}

+ (BOOL)startHUDWithError:(NSString **)err {
    if ([self isHUDRunning]) {
        if (err) *err = @"HUD 已在运行";
        return NO;
    }

    NSString *exe = [NSBundle mainBundle].executablePath;
    if (!exe) {
        if (err) *err = @"取不到自身可执行路径";
        return NO;
    }

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
        return NO;
    }

    NSLog(@"[MF][HUDLaunch] 已拉起 HUD 进程 pid=%d", pid);

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
    if (kill(pid, 0) != 0 && errno != EPERM) {
        if (err) *err = [NSString stringWithFormat:@"HUD 进程启动后立即退出 (pid=%d)", pid];
        return NO;
    }
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
    return YES;
}

@end
