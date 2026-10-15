#import "MFHUDApplication.h"
#import "MFHUDAppDelegate.h"
#import "MFHUDLog.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <objc/objc.h>
#import <string.h>       // strstr（勘探那块用）
#import <stdlib.h>       // malloc / free
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

#pragma mark - 自制 CAContext（核心修复）

/*
 * ★★★ [M5.21] 没有 scene，就自己造一个 CAContext ★★★
 *
 * ── 问题 ──
 * M5.20 的运行时勘探给出了铁证（真机日志）：
 *     connectedScenes 数量 = 0
 *     窗口 菜单: level=980  hidden=0  windowScene=nil  _contextId=0x0
 *     窗口 绘制: level=1020 hidden=0  windowScene=nil  _contextId=0x0
 * 窗口建了、level 对、hidden=0 —— 但 _contextId 是 0，
 * registerWindowWithContextID:0 静默无效，所以永远不显示。
 *
 * ── 勘探给出的真实 API ──
 *   CAContext（53 个方法，全部 dump 自设备）：
 *       - initWithOptions:localContext:     ← 可以自己造 context
 *       - contextId                         ← 拿到 ID
 *       - setLayer:                         ← 把 window.layer 挂上去
 *       - setSecure: / setLevel: / setColorSpace:
 *   UIWindow：
 *       - _setBoundContext:                 ← 把 context 绑到窗口
 *       - _setContextBinder:
 *       - _setWindowHostingScene:
 *       - setKeepContextInBackground:       ← 后台也不回收
 *   SBSAccessibilityWindowHostingController：
 *       - registerWindowWithContextID:atLevel:   ← 用它登记
 *
 * ── 做法 ──
 * 既然 UIKit 不会给我们 context（没有 scene），就手动建一个：
 *   ① [[CAContext alloc] initWithOptions:@{} localContext:YES]
 *   ② setLayer:(window.layer)
 *   ③ setSecure:YES
 *   ④ window 上 _setBoundContext:(ctx)
 *   ⑤ window 上 setKeepContextInBackground:YES
 *   ⑥ 拿 ctx.contextId 去 registerWindowWithContextID:atLevel:
 *
 * 每一步都留日志，任何一步不支持都会明确写出来。
 */
static id MFCreateAndBindContext(UIWindow *window, NSString *tag) {
    if (window == nil) return nil;

    Class CAContextCls = NSClassFromString(@"CAContext");
    if (CAContextCls == nil) {
        MFHUDLogLine(@"  [%@] ★ CAContext 类不存在", tag);
        return nil;
    }

    id ctx = nil;
    SEL initSel = sel_registerName("initWithOptions:localContext:");

    if ([CAContextCls instancesRespondToSelector:initSel]) {
        ctx = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                  [CAContextCls alloc], initSel, @{}, YES);
        MFHUDLogLine(@"  [%@] initWithOptions:localContext: → %@",
                     tag, ctx ? @"成功" : @"nil");
    } else {
        MFHUDLogLine(@"  [%@] ★ 没有 initWithOptions:localContext:", tag);
    }

    // 回退：有些版本用 initOptions: 或 initRemoteWithOptions:
    if (ctx == nil) {
        SEL s2 = sel_registerName("initRemoteWithOptions:");
        if ([CAContextCls instancesRespondToSelector:s2]) {
            ctx = ((id (*)(id, SEL, id))objc_msgSend)([CAContextCls alloc], s2, @{});
            MFHUDLogLine(@"  [%@] 回退 initRemoteWithOptions: → %@",
                         tag, ctx ? @"成功" : @"nil");
        }
    }

    if (ctx == nil) {
        MFHUDLogLine(@"  [%@] ★★ 造不出 CAContext，本路不通", tag);
        return nil;
    }

    // ② 挂 layer
    SEL setLayerSel = sel_registerName("setLayer:");
    if ([ctx respondsToSelector:setLayerSel]) {
        CALayer *l = window.layer;
        ((void (*)(id, SEL, id))objc_msgSend)(ctx, setLayerSel, l);
        MFHUDLogLine(@"  [%@] setLayer: %@", tag, l ? @"✓" : @"layer 为 nil");
    }

    // ③ setSecure
    SEL setSecureSel = sel_registerName("setSecure:");
    if ([ctx respondsToSelector:setSecureSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(ctx, setSecureSel, YES);
        MFHUDLogLine(@"  [%@] setSecure:YES ✓", tag);
    }

    // 拿到 contextId
    SEL ctxIdSel = sel_registerName("contextId");
    uint32_t ctxId = 0;
    if ([ctx respondsToSelector:ctxIdSel]) {
        ctxId = ((uint32_t (*)(id, SEL))objc_msgSend)(ctx, ctxIdSel);
    }
    MFHUDLogLine(@"  [%@] CAContext.contextId = 0x%x", tag, ctxId);
    if (ctxId == 0) {
        MFHUDLogLine(@"  [%@] ★★ 自造 context 的 id 也是 0 —— 这条路也堵", tag);
    }

    // ④ 绑到窗口
    SEL bindSel = sel_registerName("_setBoundContext:");
    if ([window respondsToSelector:bindSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(window, bindSel, ctx);
        MFHUDLogLine(@"  [%@] window._setBoundContext: ✓", tag);
    } else {
        MFHUDLogLine(@"  [%@] ★ 窗口没有 _setBoundContext:", tag);
    }

    // ⑤ 后台保持
    SEL keepSel = sel_registerName("setKeepContextInBackground:");
    if ([window respondsToSelector:keepSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(window, keepSel, YES);
        MFHUDLogLine(@"  [%@] window.setKeepContextInBackground:YES ✓", tag);
    }

    // ⑥ 回头看窗口的 _contextId 变了没
    SEL winCtxSel = sel_registerName("_contextId");
    if ([window respondsToSelector:winCtxSel]) {
        uint32_t w = ((uint32_t (*)(id, SEL))objc_msgSend)(window, winCtxSel);
        MFHUDLogLine(@"  [%@] 绑后 window._contextId = 0x%x", tag, w);
    }

    return ctx;
}

/// 给窗口装上 context（对外入口，供 delegate 调用）
void MFAttachContextToWindow(UIWindow *window, NSString *tag) {
    if (window == nil) return;
    MFCreateAndBindContext(window, tag);
}

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
    MFHUDLogLine(@"---- HUD 引导开始（绕开 UIApplicationMain）----");

    /*
     * ① 拿私有函数 UIApplicationInstantiateSingleton
     *    它在 UIKit 里，符号可见（白米饭直接调用过）。
     */
    typedef void (*mf_instantiate_t)(Class);
    mf_instantiate_t instantiate = NULL;

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

    /*
     * ★★★ [M5.19] delegate 必须用【静态强引用】保住 ★★★
     *
     * 真机日志（M5.18，pid 365 / 373，两次完全一致）：
     *     ① UIApplicationInstantiateSingleton = 0x1aafad2e8
     *     ② MFHUDApplication 已实例化
     *     ③ delegate 已设置：MFHUDAppDelegate → ✓
     *     ← 然后进程在 400ms 内消失，④ 那行【从没出现过】
     *
     * 原因：原来写成
     *         @autoreleasepool {
     *             MFHUDAppDelegate *del = [[MFHUDAppDelegate alloc] init];
     *             [app setDelegate:del];     // UIApplication.delegate 是 weak/assign
     *         }                              // ← del 在这里被释放
     *         @autoreleasepool {
     *             id del = app.delegate;     // ← 悬垂指针 → 崩
     *         }
     *
     * UIApplication 不持有 delegate（和 NSURLSession 那些不一样），
     * 所以 delegate 必须由我们自己保活 —— 这是 UIApplicationMain 内部做的事，
     * 我们绕开它就得自己补上。
     */
    static MFHUDAppDelegate *sDelegate = nil;   // ★ 进程生命周期强引用

    @autoreleasepool {
        // ② 实例化 App 单例（不走 scene 协商）
        instantiate([MFHUDApplication class]);
        UIApplication *app = [UIApplication sharedApplication];
        MFHUDLogLine(@"② MFHUDApplication 已实例化：%@",
                     app ? NSStringFromClass(app.class) : @"★ nil");
        if (app == nil) {
            MFHUDLogLine(@"✗ sharedApplication 仍是 nil，放弃");
            return 1;
        }

        // ③ 设 delegate（强引用存进 static）
        sDelegate = [[MFHUDAppDelegate alloc] init];
        [app setDelegate:sDelegate];
        MFHUDLogLine(@"③ delegate 已设置并强引用保住：%@ → %@",
                     NSStringFromClass(sDelegate.class),
                     (app.delegate == sDelegate) ? @"✓ 一致" : @"⚠️ 不一致");

        // ④ 手动触发 didFinishLaunchingWithOptions
        //    标准流程里这一步由 UIApplicationMain 在 scene 就绪后调用；
        //    我们绕开了它，所以自己调。
        MFHUDLogLine(@"④ 手动调用 didFinishLaunchingWithOptions…");
        BOOL ok = NO;
        SEL s = sel_registerName("application:didFinishLaunchingWithOptions:");
        if ([sDelegate respondsToSelector:s]) {
            ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(sDelegate, s, app, @{});
        }
        MFHUDLogLine(@"④ didFinishLaunching 返回 %d", ok);

        SEL s2 = sel_registerName("application:willFinishLaunchingWithOptions:");
        if ([sDelegate respondsToSelector:s2]) {
            ((BOOL (*)(id, SEL, id, id))objc_msgSend)(sDelegate, s2, app, @{});
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
