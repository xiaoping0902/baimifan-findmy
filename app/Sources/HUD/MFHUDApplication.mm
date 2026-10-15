#import "MFHUDApplication.h"
#import "MFHUDAppDelegate.h"
#import "MFHUDLog.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <objc/objc.h>

/*
 * ══════════════════════════════════════════════════════════════════
 *  白米饭的 HUD 启动机制（分析报告已证）
 * ══════════════════════════════════════════════════════════════════
 *
 *  《白米饭补充分析-启动窗口与功能》§2 原文：
 *      「HUD 初始化局部读取 `HUDMainApplication` 和 `HUDMainApplicationDelegate` 类，
 *        并调用 `UIApplicationInstantiateSingleton`。」
 *
 *  而普通启动那条路，`UIApplicationMain` 在样本里是【被改写的 stub】——
 *  也就是说：两条路白米饭都没有用系统原版的 UIApplicationMain。
 *
 *  为什么必须这样：
 *      iOS 13+ 的 UIApplicationMain 会做 scene 协商。
 *      posix_spawn 出来的子进程不走 FrontBoard → 没有 UIWindowScene
 *      → 协商永远等不到结果 → 卡在 UIApplicationMain 内部。
 *
 *  真机证据（M5.17 日志，pid 402）：
 *      22:40:30.393 即将调用 UIApplicationMain（HUD 角色）…
 *      ← 之后再无任何输出，连 didFinishLaunching 的第一行都没有
 *      22:40:30.767 子进程 400ms 后仍存活（父进程看的）
 *      而且【没有新的崩溃报告】—— 不是崩，是卡。
 *
 *  所以本文件照搬白米饭的做法：UIApplicationInstantiateSingleton + 手动引导。
 */

@implementation MFHUDApplication

/*
 * 让这个子类在没有 main scene 时也能正常跑。
 *
 * 系统 UIApplication 在 scene 模式下会等 _UISceneLifecycleMonitor 之类的设施；
 * 这里把与 scene 相关的入口做成「没有就走旧路径」。
 */
- (BOOL)supportsMultipleScenes { return NO; }

@end

#pragma mark - 窗口标记

void MFMarkWindowSystemSecure(UIWindow *w) {
    if (w == nil) return;

    /*
     * 逐个试私有 setter（名字在 iOS 版本间变过）。
     * 对照白米饭已证的窗口特性：
     *     _isSystemWindow      = 1
     *     _isSecure            = 1
     *     _shouldCreateContextAsSecure = 1
     *     _ignoresHitTest      = 1（只绘制窗）
     */
    struct { const char *sel; BOOL val; } marks[] = {
        { "set_isSystemWindow:",               YES },
        { "_setSystemWindow:",                 YES },
        { "set_isSecure:",                     YES },
        { "_setSecure:",                       YES },
        { "set_shouldCreateContextAsSecure:",  YES },
        { "_setShouldCreateContextAsSecure:",  YES },
        { "set_isWindowServerHostingManaged:", YES },
        { "_setWindowServerHostingManaged:",   YES },
    };
    int applied = 0;
    for (size_t i = 0; i < sizeof(marks)/sizeof(marks[0]); i++) {
        SEL s = sel_registerName(marks[i].sel);
        if ([w respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(w, s, marks[i].val);
            applied++;
        }
    }
    MFHUDLogLine(@"  窗口标记：应用了 %d 个私有标记（共试 %lu 个）",
                 applied, (unsigned long)(sizeof(marks)/sizeof(marks[0])));
}

#pragma mark - HUD 引导

int MFLaunchHUDRole(int argc, char *argv[]) {
    MFHUDLogLine(@"---- HUD 引导开始（绕开 UIApplicationMain）----");

    /*
     * ① 拿私有函数 UIApplicationInstantiateSingleton
     *    它在 UIKit 里，符号可见（白米饭直接调用过）。
     */
    typedef void (*mf_instantiate_t)(Class);
    mf_instantiate_t instantiate = NULL;

    // RTLD_DEFAULT 在已加载的镜像里找
    instantiate = (mf_instantiate_t)dlsym(RTLD_DEFAULT,
                                          "UIApplicationInstantiateSingleton");
    if (instantiate == NULL) {
        void *h = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
        if (h) instantiate = (mf_instantiate_t)dlsym(h, "UIApplicationInstantiateSingleton");
    }
    MFHUDLogLine(@"① UIApplicationInstantiateSingleton = %p", (void *)instantiate);

    if (instantiate == NULL) {
        MFHUDLogLine(@"✗ 拿不到该符号 → 回退标准 UIApplicationMain（大概率还是卡）");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MFHUDAppDelegate class]));
    }

    @autoreleasepool {
        // ② 实例化 App 单例（不走 scene 协商）
        instantiate([MFHUDApplication class]);
        UIApplication *app = [UIApplication sharedApplication];
        MFHUDLogLine(@"② MFHUDApplication 已实例化：%@", app ? NSStringFromClass(app.class) : @"★ nil");
        if (app == nil) {
            MFHUDLogLine(@"✗ sharedApplication 仍是 nil，放弃");
            return 1;
        }

        // ③ 设 delegate
        MFHUDAppDelegate *del = [[MFHUDAppDelegate alloc] init];
        [app setDelegate:del];
        MFHUDLogLine(@"③ delegate 已设置：%@ → %@",
                     NSStringFromClass(del.class), app.delegate ? @"✓" : @"★ 没设上");
    }

    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        id del = app.delegate;

        /*
         * ④ 手动触发 didFinishLaunchingWithOptions
         *
         * 标准流程里这一步由 UIApplicationMain 在 scene 就绪后调用。
         * 我们绕开了那一步，所以自己调。
         */
        MFHUDLogLine(@"④ 手动调用 didFinishLaunchingWithOptions…");
        BOOL ok = NO;
        SEL s = sel_registerName("application:didFinishLaunchingWithOptions:");
        if (del && [del respondsToSelector:s]) {
            ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(del, s, app, @{});
        }
        MFHUDLogLine(@"④ didFinishLaunching 返回 %d", ok);

        // 顺便把 main() 的 argv 交过去（有些实现会读它）
        SEL s2 = sel_registerName("application:willFinishLaunchingWithOptions:");
        if (del && [del respondsToSelector:s2]) {
            ((BOOL (*)(id, SEL, id, id))objc_msgSend)(del, s2, app, @{});
            MFHUDLogLine(@"   已调 willFinishLaunching");
        }
    }

    /*
     * ⑤ 跑 runloop
     *
     * 不用 [app run] —— 那个在 scene 模式下也有依赖。
     * 直接 CFRunLoopRun()，UIWindow 建好后主线程事件照常处理。
     */
    MFHUDLogLine(@"⑤ 进入 CFRunLoopRun()（HUD 常驻）");
    CFRunLoopRun();

    MFHUDLogLine(@"⚠️ CFRunLoopRun 返回了（异常）");
    return 0;
}
