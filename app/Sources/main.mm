//
//  main.mm — 程序入口
//  双角色分流（对齐白米饭）：普通（主界面控制台） / HUD（悬浮窗进程）
//
//  M0：只跑普通角色；HUD 角色在 M2 接入（见 docs/复刻总方案.md §5.2）
//
#import <UIKit/UIKit.h>
#import "App/AppDelegate.h"
#include <string.h>

/// 是否以 HUD 角色启动（由主进程 posix_spawn 自己、附 -hud 参数拉起）
static BOOL MFIsHUDLaunch(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (argv[i] && strcmp(argv[i], "-hud") == 0) return YES;
    }
    return NO;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (MFIsHUDLaunch(argc, argv)) {
            // ---- M2：此处转入 HUD 角色 ----
            //  1) 不创建主界面窗口
            //  2) 建 HUDImguiWindow（菜单，状态栏层级 −20） + DrawingWindow（透明绘制，+20）
            //  3) 交给 SBSAccessibilityWindowHostingController 托管
            //  当前 M0 阶段尚未接入，先按普通角色启动以便观察。
            NSLog(@"[MF] -hud 参数已识别，但 HUD 角色将在 M2 接入，本次按普通角色启动");
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
