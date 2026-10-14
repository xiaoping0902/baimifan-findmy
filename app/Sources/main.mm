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
#include <string.h>

/// 参数检测：-hud / -hud1 / -hud2 / -hud3（对齐分析已证的自派生参数）
static BOOL MFIsHUDLaunch(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (!argv[i]) continue;
        if (strcmp(argv[i], "-hud") == 0 ||
            strncmp(argv[i], "-hud", 4) == 0) {
            return YES;
        }
    }
    return NO;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (MFIsHUDLaunch(argc, argv)) {
            NSLog(@"[MF] 以 HUD 角色启动");
            return UIApplicationMain(argc, argv, nil, NSStringFromClass([MFHUDAppDelegate class]));
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
