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
#import "HUD/MFHUDLog.h"
#include <string.h>
#include <unistd.h>

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
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (MFIsHUDLaunch(argc, argv)) {
            MFDumpArgv("HUD", argc, argv);
            NSLog(@"[MF] 以 HUD 角色启动");
            // ★ 这一步之后如果日志断了，说明卡在 UIApplicationMain 内部
            MFHUDLogLine(@"即将调用 UIApplicationMain（HUD 角色）…");
            int r = UIApplicationMain(argc, argv, nil, NSStringFromClass([MFHUDAppDelegate class]));
            MFHUDLogLine(@"⚠️ UIApplicationMain 返回了 r=%d（通常意味着进程要退出）", r);
            return r;
        }
        MFDumpArgv("控制台", argc, argv);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
