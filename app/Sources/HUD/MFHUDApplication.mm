#import "MFHUDApplication.h"
#import "MFHUDAppDelegate.h"
#import "MFHUDControl.h"
#import "MFHUDLog.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <objc/objc.h>
#import <string.h>       // strstr（勘探那块用）
#import <stdlib.h>       // malloc / free
#import <unistd.h>       // getpid / _exit（退出通道）
#import <dlfcn.h>        // dlsym

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

#pragma mark - 运行时 API 勘探

/*
 * ★★★ [M5.20] 直接从设备 dump UIWindow / CAContext 的真实私有 API ★★★
 *
 * 为什么需要这个：
 *   M5.19 的日志显示——
 *       窗口标记：应用了 1 个私有标记（共试 8 个）
 *       ⚠️ 没有可用的 _isWindowServerHostingManaged setter（试过 2 个名字）
 *   也就是说：我猜的 setter 名字 8 个里只有 1 个存在。
 *   继续猜下去没意义 —— 让运行时把真实名字报出来。
 *
 * 这里把三类东西的完整方法列表写进日志：
 *   ① UIWindow 上所有含 context / system / secure / hosting / scene 的方法
 *   ② 所有类名含 CAContext 的类，以及它的全部方法
 *   ③ 所有含 accessibility window hosting 的类（找托管接口）
 *
 * 拿到清单后就能精确调用，不用再猜。
 */
static void MFDumpMethodsOfClass(Class cls, NSString *label, NSArray<NSString *> *mustContainAny) {
    if (cls == nil) {
        MFHUDLogLine(@"  [%@] 类不存在", label);
        return;
    }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);   // 含私有
    NSMutableArray<NSString *> *hit = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = NSStringFromSelector(method_getName(ms[i]));
        if (mustContainAny.count == 0) { [hit addObject:name]; continue; }
        for (NSString *kw in mustContainAny) {
            if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hit addObject:name];
                break;
            }
        }
    }
    if (ms) free(ms);

    MFHUDLogLine(@"  [%@] 共 %u 个方法，命中 %lu 个：",
                 label, n, (unsigned long)hit.count);
    for (NSString *s in [hit sortedArrayUsingSelector:@selector(compare:)]) {
        MFHUDLogLine(@"      - %@", s);
    }
}

void MFDumpWindowAPI(void) {
    MFHUDLogLine(@"======== 运行时 API 勘探 ========");

    // ① UIWindow 的关键方法
    MFDumpMethodsOfClass([UIWindow class], @"UIWindow",
        @[@"context", @"system", @"secure", @"hosting", @"scene", @"sceneSession",
          @"display", @"server", @"portal"]);

    // ② UIApplication 的 scene 相关
    MFDumpMethodsOfClass([UIApplication class], @"UIApplication",
        @[@"scene", @"window", @"context", @"idle", @"run"]);

    // ③ 找 CAContext 及其方法
    int ncls = objc_getClassList(NULL, 0);
    if (ncls > 0) {
        Class *all = (Class *)malloc(sizeof(Class) * ncls);
        if (all) {
            objc_getClassList(all, ncls);
            for (int i = 0; i < ncls; i++) {
                const char *nm = class_getName(all[i]);
                if (nm == NULL) continue;
                if (strstr(nm, "CAContext") != NULL) {
                    MFDumpMethodsOfClass(all[i],
                        [NSString stringWithFormat:@"%s", nm], @[]);
                }
            }
            free(all);
        }
    }

    // ④ 找托管相关类（accessibility window hosting）
    ncls = objc_getClassList(NULL, 0);
    if (ncls > 0) {
        Class *all = (Class *)malloc(sizeof(Class) * ncls);
        if (all) {
            objc_getClassList(all, ncls);
            for (int i = 0; i < ncls; i++) {
                const char *nm = class_getName(all[i]);
                if (nm == NULL) continue;
                if (strstr(nm, "AccessibilityWindowHosting") != NULL ||
                    strstr(nm, "WindowHosting") != NULL) {
                    MFDumpMethodsOfClass(all[i],
                        [NSString stringWithFormat:@"%s", nm],
                        @[@"register", @"host", @"window", @"context", @"enable"]);
                }
            }
            free(all);
        }
    }

    MFHUDLogLine(@"======== 勘探结束 ========");
}

#pragma mark - HUD 引导

int MFLaunchHUDRole(int argc, char *argv[]) {
    MFHUDLogLine(@"---- HUD 引导开始（对齐 TrollSpeed / ch.xxtou.hudapp）----");

    /*
     * ══════════════════════════════════════════════════════════════
     *  [M5.22] ★★★ 完整对齐 TrollSpeed 的启动序列 ★★★
     *
     *  来源：https://github.com/Lessica/TrollSpeed（开源）
     *        sources/HUDApp.mm 的 -hud 分支
     *
     *  TrollSpeed 的原文：
     *      [UIScreen initialize];
     *      CFRunLoopGetCurrent();
     *      GSInitialize();
     *      BKSDisplayServicesStart();
     *      UIApplicationInitialize();
     *      UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));
     *      [UIApplication.sharedApplication setDelegate:appDelegate];
     *      [UIApplication.sharedApplication _accessibilityInit];
     *      [NSRunLoop currentRunLoop];
     *      BKSHIDEventRegisterEventCallback(_HUDEventCallback);
     *      GSEventInitialize(0);
     *      GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
     *      [UIApplication.sharedApplication __completeAndRunAsPlugin];
     *      CFRunLoopRun();
     *
     *  ★ 我们之前缺了整整一层：GSInitialize / BKSDisplayServicesStart /
     *    UIApplicationInitialize / _accessibilityInit / GSEventInitialize /
     *    __completeAndRunAsPlugin —— 一个都没做。
     *
     *  ★ 而且 TrollSpeed 【不手动调 didFinishLaunching】——
     *    是 __completeAndRunAsPlugin 触发的。
     *    我们手动调了，但 UIApplication 内部状态没就绪，
     *    所以窗口拿不到 CAContext（_contextId 恒为 0）。
     *
     *  全部用 dlsym 取，符号缺失时明确记录并降级。
     * ══════════════════════════════════════════════════════════════
     */

    typedef void (*mf_void_fn)(void);
    typedef void (*mf_int_fn)(int);
    typedef void (*mf_cfstr_fn)(CFStringRef);

    mf_void_fn   p_UIScreenInitialize   = (mf_void_fn)  dlsym(RTLD_DEFAULT, "UIScreenInitialize");
    // UIScreen 的 +initialize 是 ObjC 类方法，用 objc_msgSend 调更稳
    ((void (*)(id, SEL))objc_msgSend)((id)[UIScreen class], sel_registerName("initialize"));
    MFHUDLogLine(@"① [UIScreen initialize] ✓");

    CFRunLoopGetCurrent();
    MFHUDLogLine(@"② CFRunLoopGetCurrent() ✓");

    mf_void_fn p_GSInitialize = (mf_void_fn)dlsym(RTLD_DEFAULT, "GSInitialize");
    MFHUDLogLine(@"③ GSInitialize = %p", (void *)p_GSInitialize);
    if (p_GSInitialize) { p_GSInitialize(); MFHUDLogLine(@"   GSInitialize() ✓"); }

    mf_void_fn p_BKSDisplayServicesStart = (mf_void_fn)dlsym(RTLD_DEFAULT, "BKSDisplayServicesStart");
    MFHUDLogLine(@"④ BKSDisplayServicesStart = %p", (void *)p_BKSDisplayServicesStart);
    if (p_BKSDisplayServicesStart) { p_BKSDisplayServicesStart(); MFHUDLogLine(@"   已调用 ✓"); }
    else {
        // 有些版本在 BackBoardServices 框架里，手动 dlopen 再试
        void *h = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
        if (h) {
            p_BKSDisplayServicesStart = (mf_void_fn)dlsym(h, "BKSDisplayServicesStart");
            MFHUDLogLine(@"   从框架里再取 = %p", (void *)p_BKSDisplayServicesStart);
            if (p_BKSDisplayServicesStart) { p_BKSDisplayServicesStart(); MFHUDLogLine(@"   已调用 ✓"); }
        }
    }

    mf_void_fn p_UIApplicationInitialize = (mf_void_fn)dlsym(RTLD_DEFAULT, "UIApplicationInitialize");
    MFHUDLogLine(@"⑤ UIApplicationInitialize = %p", (void *)p_UIApplicationInitialize);
    if (p_UIApplicationInitialize) { p_UIApplicationInitialize(); MFHUDLogLine(@"   已调用 ✓"); }

    /*
     * ⑥ 实例化 App 单例
     */
    typedef void (*mf_instantiate_t)(Class);
    mf_instantiate_t instantiate = (mf_instantiate_t)dlsym(RTLD_DEFAULT,
                                                           "UIApplicationInstantiateSingleton");
    MFHUDLogLine(@"⑥ UIApplicationInstantiateSingleton = %p", (void *)instantiate);
    if (instantiate == NULL) {
        MFHUDLogLine(@"✗ 拿不到该符号 → 回退标准 UIApplicationMain（大概率还是卡）");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MFHUDAppDelegate class]));
    }

    static MFHUDAppDelegate *sDelegate = nil;   // ★ 进程级强引用，见 [M5.19]

    instantiate([MFHUDApplication class]);
    UIApplication *app = [UIApplication sharedApplication];
    MFHUDLogLine(@"   已实例化：%@", app ? NSStringFromClass(app.class) : @"★ nil");
    if (app == nil) { MFHUDLogLine(@"✗ sharedApplication 仍为 nil"); return 1; }

    sDelegate = [[MFHUDAppDelegate alloc] init];
    [app setDelegate:sDelegate];
    MFHUDLogLine(@"   delegate 已设并强引用保住：%@", (app.delegate == sDelegate) ? @"✓ 一致" : @"⚠️ 不一致");

    /*
     * ★ 退出通道必须在这里就装好 ★
     *
     * 控制台（mobile）杀不动这个 root 子进程，所以退出只能由 HUD 自己执行。
     * 越早装越好：窗口还没建起来的时候用户也可能想取消，
     * 那时候如果没有监听，就只能干等启动超时。
     */
    [MFHUDControl watchForExitRequest:^{
        MFHUDAppDelegate *delegate = sDelegate;
        if (delegate) {
            [delegate shutdownForExitRequest];
        } else {
            MFHUDLogLine(@"退出请求到达时窗口尚未建立，直接结束进程（pid=%d）", getpid());
            _exit(EXIT_SUCCESS);
        }
    }];

    /*
     * ⑦ _accessibilityInit —— TrollSpeed 有这一步
     */
    SEL accSel = sel_registerName("_accessibilityInit");
    if ([app respondsToSelector:accSel]) {
        ((void (*)(id, SEL))objc_msgSend)(app, accSel);
        MFHUDLogLine(@"⑦ [app _accessibilityInit] ✓");
    } else {
        MFHUDLogLine(@"⑦ ⚠️ app 没有 _accessibilityInit");
    }

    /*
     * ⑧ [NSRunLoop currentRunLoop] —— 提前把 runloop 建起来
     */
    [NSRunLoop currentRunLoop];
    MFHUDLogLine(@"⑧ [NSRunLoop currentRunLoop] ✓");

    /*
     * ⑨ BKSHIDEventRegisterEventCallback —— 注册 HID 事件回调
     *    （没有它窗口收不到触摸；TrollSpeed 传的是自己的 _HUDEventCallback）
     */
    // Register a real callback after the menu overlay exists in the delegate.
    // Registering NULL here left a visible window with no touch receiver.
    MFHUDLogLine(@"⑨ HID 输入将在菜单视图建立后由 MFHUDInputBridge 注册");

    /*
     * ⑩ GSEvent 初始化（iOS 15+）
     */
    if (@available(iOS 15.0, *)) {
        mf_int_fn p_GSEventInitialize = (mf_int_fn)dlsym(RTLD_DEFAULT, "GSEventInitialize");
        MFHUDLogLine(@"⑩ GSEventInitialize = %p", (void *)p_GSEventInitialize);
        if (p_GSEventInitialize) { p_GSEventInitialize(0); MFHUDLogLine(@"   已调用 ✓"); }

        mf_cfstr_fn p_GSEventPushRunLoopMode = (mf_cfstr_fn)dlsym(RTLD_DEFAULT,
                                                                  "GSEventPushRunLoopMode");
        MFHUDLogLine(@"   GSEventPushRunLoopMode = %p", (void *)p_GSEventPushRunLoopMode);
        if (p_GSEventPushRunLoopMode) {
            p_GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
            MFHUDLogLine(@"   已推 runloop mode ✓");
        }
    }

    /*
     * ⑪ ★★★ 最关键的一步：__completeAndRunAsPlugin
     *
     *  TrollSpeed 用它取代了手动调 didFinishLaunchingWithOptions。
     *  它会把 UIApplication 内部状态补全（eventDispatcher / eventFetcher /
     *  accessibility / 无 scene 的插件模式），然后触发 didFinishLaunching。
     */
    SEL completeSel = sel_registerName("__completeAndRunAsPlugin");
    MFHUDLogLine(@"⑪ app 有 __completeAndRunAsPlugin = %d",
                 [app respondsToSelector:completeSel]);
    if ([app respondsToSelector:completeSel]) {
        ((void (*)(id, SEL))objc_msgSend)(app, completeSel);
        MFHUDLogLine(@"   ★ 已调用 __completeAndRunAsPlugin");
    } else {
        MFHUDLogLine(@"   ★ 没有这个方法，退回手动触发 didFinishLaunching");
        SEL s = sel_registerName("application:didFinishLaunchingWithOptions:");
        if ([sDelegate respondsToSelector:s]) {
            ((BOOL (*)(id, SEL, id, id))objc_msgSend)(sDelegate, s, app, @{});
            MFHUDLogLine(@"   手动 didFinishLaunching ✓");
        }
    }

    /*
     * ⑫ 跑 runloop
     */
    MFHUDLogLine(@"⑫ 进入 CFRunLoopRun()（HUD 常驻）");
    CFRunLoopRun();

    MFHUDLogLine(@"⚠️ CFRunLoopRun 返回了（异常）");
    return 0;
}
