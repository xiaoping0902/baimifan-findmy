//
//  main.mm — 程序入口
//  双角色分流（对齐白米饭）：
//    · 普通角色 → AppDelegate（主界面控制台）
//    · HUD 角色 → MFHUDAppDelegate（双窗口悬浮菜单 + 透明绘制层）
//  由主进程 posix_spawn 自己、附 `-hud` 参数拉起 HUD 角色。
//
#import <UIKit/UIKit.h>
#import "App/AppDelegate.h"
#import "HUD/MFHUDAppDelegate.h"
#import "HUD/MFHUDApplication.h"
#import "HUD/MFHUDLog.h"
#include <string.h>
#include <unistd.h>
#include <stdio.h>      // printf（root 助手回报身份用）
#include <stdlib.h>

/*
 * 参数检测：-hud / -hud1 / -hud2 / -hud3（对齐分析已证的自派生参数）
 *
 * ★ 审查修正：原来写的是 strncmp(argv[i], "-hud", 4) == 0，
 *   那是纯前缀匹配 —— "-hudxyz"、"-hudon" 之类也会被当成 HUD 角色。
 *   收紧成：完全等于 "-hud"，或 "-hud" + 单个数字。
 */
static BOOL MFIsHUDLaunch(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!a) continue;
        if (strcmp(a, "-hud") == 0) return YES;
        if (strncmp(a, "-hud", 4) == 0 &&
            a[4] >= '0' && a[4] <= '9' && a[5] == '\0') {
            return YES;
        }
    }
    return NO;
}

static void MFDumpArgv(const char *who, int argc, char *argv[]) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < argc; i++) {
        [s appendFormat:@"%s ", argv[i] ? argv[i] : "(null)"];
    }
    MFHUDLogLine(@"==== main() 进入，角色判定并启动 %s ====", who);
    MFHUDLogLine(@"argc=%d argv=[ %@]", argc, s);
    MFHUDLogLine(@"pid=%d ppid=%d", getpid(), getppid());

    /*
     * ★ [M5.24] 把跑起来的到底是哪一版写进日志 ★
     *
     * 起因：用户和另一位分析者的建议 ——
     *   「当前安装信息一直写着 1.0.0 / 1，建议给每次构建加上独立的版本号
     *     或 Git 提交号，并在启动日志里打印，方便确认实际运行的是哪一版。」
     *
     * 这个问题真发生过：M5.21 明明加了「自造 CAContext（核心修复）」那一步，
     * 但拉到的日志里没有 —— 分不清是没装、装错包，还是代码没跑到。
     * 版本号进日志之后，一眼就能对上。
     */
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    MFHUDLogLine(@"版本：%@ (%@)  build=%@",
                 info[@"CFBundleShortVersionString"] ?: @"?",
                 info[@"CFBundleVersion"] ?: @"?",
                 info[@"MFBuildStamp"] ?: @"未注入");
    MFHUDLogLine(@"bundleID=%@  exe=%@",
                 info[@"CFBundleIdentifier"] ?: @"?",
                 info[@"CFBundleExecutable"] ?: @"?");
    MFHUDLogLine(@"日志文件=%@", @"/var/mobile/Media/mf-debug/hud.log");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        /*
         * ★ [M5.26] root 助手分支
         *
         * 由 [MFHUDLauncher runAsRootWithArgs:] 以
         *     persona 99 + uid 0 + gid 0
         * 派生出来。走到这里说明已经是 root 了，跑特权活然后退出。
         *
         * 第一行就打印真实身份 —— 这是「到底有没有拿到 root」的唯一可信证据，
         * 父进程会从 stdout 里把它读出来。
         */
        if (argc > 1 && strcmp(argv[1], "-root") == 0) {
            printf("UID=%d EUID=%d GID=%d PID=%d\n",
                   getuid(), geteuid(), getgid(), getpid());
            fflush(stdout);

            // 第二段参数是子命令；没有就只回报身份
            const char *cmd = (argc > 2) ? argv[2] : "whoami";
            NSLog(@"[MF][Root] cmd=%s uid=%d euid=%d", cmd, getuid(), geteuid());

            if (strcmp(cmd, "whoami") == 0) {
                printf("根目录可写：%s\n", (access("/", W_OK) == 0) ? "是" : "否");
                printf("可读 /var/mobile：%s\n", (access("/var/mobile", R_OK) == 0) ? "是" : "否");
                fflush(stdout);
                return 0;
            }

            /*
             * 其它特权子命令在这里扩展。
             * 目前只做身份回报，具体业务（清理系统残留 / Keychain / 防封）
             * 仍然走各自原来的路径 —— 先把 root 通道打通、验证有效，
             * 再逐个搬迁，避免一次改太多不好定位。
             */
            printf("（子命令 %s 尚未实现，本轮只验证 root 通道）\n", cmd);
            fflush(stdout);
            return 0;
        }

        if (MFIsHUDLaunch(argc, argv)) {
            MFDumpArgv("HUD", argc, argv);
            NSLog(@"[MF] 以 HUD 角色启动");
            /*
             * ★★★ [M5.18] 不再走标准 UIApplicationMain ★★★
             *
             * 真机症状：日志停在上一条 MFHUDLogLine，之后【再无任何输出】——
             * 连 MFHUDAppDelegate 的 didFinishLaunching 第一行都没有，
             * 而且没有新的崩溃报告。是卡住，不是崩。
             *
             * 原因：iOS 13+ 的 UIApplicationMain 会做 scene 协商，
             * 而 posix_spawn 的子进程不走 FrontBoard → 没有 UIWindowScene
             * → 协商永远等不到 → 卡死。
             *
             * 白米饭的做法（《白米饭补充分析-启动窗口与功能》§2 已证）：
             *     「HUD 初始化局部读取 HUDMainApplication 和
             *       HUDMainApplicationDelegate 类，并调用
             *       UIApplicationInstantiateSingleton。」
             * 它【完全不用】系统的 UIApplicationMain。
             *
             * 所以改成 MFLaunchHUDRole()：实例化单例 → 设 delegate →
             * 手动触发 didFinishLaunching → CFRunLoopRun。
             */
            MFHUDLogLine(@"即将调用 MFLaunchHUDRole（绕开 UIApplicationMain）…");
            int r = MFLaunchHUDRole(argc, argv);
            MFHUDLogLine(@"⚠️ MFLaunchHUDRole 返回了 r=%d（通常意味着进程要退出）", r);
            return r;
        }
        MFDumpArgv("控制台", argc, argv);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
