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

    /*
     * ★★ [M5.24] 严格校验 —— 采纳另一位分析者的意见 ★★
     *
     * 原话：「现在的逻辑有一个明显缺口：创建 context → 只要对象不是 nil 就继续
     *        → 即使 contextId 是 0，也只打印日志 → 继续绑定窗口。
     *        应该改成：创建适用于跨进程托管的 context → 检查对象存在，
     *        并且 contextId 非 0 → ...任一步失败，都向上返回具体错误。」
     *
     * 而且他点出关键：「对象存在」并不代表它具有可用于跨进程托管的显示 ID。
     * 同时设备的方法列表里已经有 initRemoteWithOptions:，
     * remote context 的创建路径应该作为对照验证。
     *
     * 所以这里改成：
     *   ① 先试 initRemoteWithOptions:（跨进程托管要的就是 remote context）
     *   ② 再试 initWithOptions:localContext:（本地 context，退而求其次）
     *   ③ 【必须】拿到 contextId != 0 才算成功；否则明确返回失败并说明是哪一步
     */

    id ctx = nil;
    NSString *howUsed = nil;

    // ① remote context —— 跨进程托管的正解
    SEL remoteSel = sel_registerName("initRemoteWithOptions:");
    if ([CAContextCls instancesRespondToSelector:remoteSel]) {
        @try {
            ctx = ((id (*)(id, SEL, id))objc_msgSend)([CAContextCls alloc], remoteSel, @{});
            howUsed = @"initRemoteWithOptions:";
        } @catch (NSException *e) {
            MFHUDLogLine(@"  [%@] initRemoteWithOptions: 抛异常 %@", tag, e.reason);
            ctx = nil;
        }
    }

    // ② 回退到 local context
    if (ctx == nil) {
        SEL localSel = sel_registerName("initWithOptions:localContext:");
        if ([CAContextCls instancesRespondToSelector:localSel]) {
            @try {
                ctx = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                          [CAContextCls alloc], localSel, @{}, YES);
                howUsed = @"initWithOptions:localContext:YES";
            } @catch (NSException *e) {
                MFHUDLogLine(@"  [%@] initWithOptions:localContext: 抛异常 %@", tag, e.reason);
                ctx = nil;
            }
        }
    }

    MFHUDLogLine(@"  [%@] context 创建方式 = %@，对象 = %@",
                 tag, howUsed ?: @"（两种都不可用）", ctx ? @"非 nil" : @"★ nil");
    if (ctx == nil) {
        MFHUDLogLine(@"  [%@] ★★ 造不出 CAContext —— 本路不通", tag);
        return nil;
    }

    // ②.5 挂 layer
    SEL setLayerSel = sel_registerName("setLayer:");
    if ([ctx respondsToSelector:setLayerSel]) {
        CALayer *l = window.layer;
        ((void (*)(id, SEL, id))objc_msgSend)(ctx, setLayerSel, l);
        MFHUDLogLine(@"  [%@] setLayer: %@", tag, l ? @"✓" : @"layer 为 nil");
    }

    SEL setSecureSel = sel_registerName("setSecure:");
    if ([ctx respondsToSelector:setSecureSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(ctx, setSecureSel, YES);
        MFHUDLogLine(@"  [%@] setSecure:YES ✓", tag);
    }

    // ③ ★ 硬性要求：contextId 必须非 0
    SEL ctxIdSel = sel_registerName("contextId");
    uint32_t ctxId = 0;
    if ([ctx respondsToSelector:ctxIdSel]) {
        ctxId = ((uint32_t (*)(id, SEL))objc_msgSend)(ctx, ctxIdSel);
    }
    MFHUDLogLine(@"  [%@] CAContext.contextId = 0x%x", tag, ctxId);
    if (ctxId == 0) {
        MFHUDLogLine(@"  [%@] ★★★ contextId 仍为 0 —— 创建方式不对，【不再往下走】", tag);
        MFHUDLogLine(@"      最可能的原因：缺 com.apple.QuartzCore.displayable-context");
        MFHUDLogLine(@"      entitlement（对照 TrollSpeed 的 entitlements.plist 补上）");
        return nil;   // ★ 明确失败，不返回半成品
    }

    // ④ 绑到窗口
    //
    // ★★★ [M5.25] 这一步必须用 FBSCAContextSceneLayer 包一层 ★★★
    //
    // 真机崩溃（FindMy-2026-10-16-001751.ips）：
    //     EXC_CRASH SIGABRT
    //       libc++abi  std::terminate()
    //       libobjc    _objc_terminate()
    //       libdispatch _dispatch_client_callout
    //       FindMy      MFLaunchHUDRole +0x11700
    // 就在上一行日志（CAContext.contextId = 0xf4adfeba）之后 ——
    // 说明 _setBoundContext: 收到裸 CAContext 时抛了异常。
    //
    // 勘探结果里有答案：
    //     [FBSCAContextSceneLayer] 共 12 个方法
    //         - initWithCAContext:                       ← 接受 CAContext
    //         - initWithCAContextID:level:               ← 或直接给 ID + level
    //         - _initWithCAContext:contextID:fallbackLevel:
    //         - CAContext / contextID / isCAContextLayer
    // _setBoundContext: 要的是「scene layer」而不是 context 本身。
    //
    // 另：整段包 @try/@catch —— 这个进程不能因为一个私有 API 不配合就 abort，
    //     它还得继续建窗口、托管、绘制。
    SEL bindSel = sel_registerName("_setBoundContext:");
    if ([window respondsToSelector:bindSel]) {
        id bindee = ctx;

        Class sceneLayerCls = NSClassFromString(@"FBSCAContextSceneLayer");
        if (sceneLayerCls) {
            SEL wrapSel = sel_registerName("initWithCAContextID:level:");
            if ([sceneLayerCls instancesRespondToSelector:wrapSel]) {
                @try {
                    id sl = ((id (*)(id, SEL, uint32_t, double))objc_msgSend)(
                                 [sceneLayerCls alloc], wrapSel, ctxId,
                                 (double)window.windowLevel);
                    if (sl) { bindee = sl; MFHUDLogLine(@"  [%@] 已用 FBSCAContextSceneLayer 包装 ✓", tag); }
                } @catch (NSException *e) {
                    MFHUDLogLine(@"  [%@] FBSCAContextSceneLayer(CAContextID) 异常：%@", tag, e.reason);
                }
            }
            if (bindee == ctx) {
                SEL wrapSel2 = sel_registerName("initWithCAContext:");
                if ([sceneLayerCls instancesRespondToSelector:wrapSel2]) {
                    @try {
                        id sl = ((id (*)(id, SEL, id))objc_msgSend)([sceneLayerCls alloc], wrapSel2, ctx);
                        if (sl) { bindee = sl; MFHUDLogLine(@"  [%@] 已用 FBSCAContextSceneLayer(CAContext) 包装 ✓", tag); }
                    } @catch (NSException *e) {
                        MFHUDLogLine(@"  [%@] FBSCAContextSceneLayer(CAContext) 异常：%@", tag, e.reason);
                    }
                }
            }
        } else {
            MFHUDLogLine(@"  [%@] 没有 FBSCAContextSceneLayer 类", tag);
        }

        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(window, bindSel, bindee);
            MFHUDLogLine(@"  [%@] window._setBoundContext: ✓", tag);
        } @catch (NSException *e) {
            MFHUDLogLine(@"  [%@] ★ _setBoundContext: 异常（已吞，不 abort）：%@", tag, e.reason);
        }
    } else {
        MFHUDLogLine(@"  [%@] ★ 窗口没有 _setBoundContext:", tag);
    }

    // ⑤ 后台保持
    SEL keepSel = sel_registerName("setKeepContextInBackground:");
    if ([window respondsToSelector:keepSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(window, keepSel, YES);
        MFHUDLogLine(@"  [%@] window.setKeepContextInBackground:YES ✓", tag);
    }

    // ⑥ 回头看窗口的 _contextId
    SEL winCtxSel = sel_registerName("_contextId");
    if ([window respondsToSelector:winCtxSel]) {
        uint32_t w = ((uint32_t (*)(id, SEL))objc_msgSend)(window, winCtxSel);
        MFHUDLogLine(@"  [%@] 绑后 window._contextId = 0x%x %@",
                     tag, w, (w == ctxId) ? @"✓ 与 context 一致" : @"⚠️ 不一致");
    }

    return ctx;
}

/// 给窗口装上 context（对外入口）。返回绑好的 context，失败返回 nil。
id MFAttachContextToWindow(UIWindow *window, NSString *tag) {
    if (window == nil) return nil;
    return MFCreateAndBindContext(window, tag);
}

/*
 * ★★★ [M5.25] 自造 context 的登记表 ★★★
 *
 * 为什么需要：
 *   MFHostWindow 里原来读的是 window._contextId —— 那个值在没有 scene 时恒为 0，
 *   所以托管永远拿 0 去登记，静默无效。
 *
 *   但我们【自己造出了有效的 context】：
 *       真机日志：CAContext.contextId = 0xf4adfeba
 *
 *   所以把「窗 → context 对象 + contextId」记下来，
 *   托管时直接用这个 ID，不再绕 window._contextId。
 *
 * 顺带解决另一位的提醒：context 对象必须有长期引用，
 * 否则函数一返回就被释放，登记的 context 可能一并失效。
 */
static NSMutableDictionary<NSString *, id>        *gMFContexts   = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gMFContextIds = nil;
static void MFContextRegistryInit(void) {
    if (gMFContexts == nil)   gMFContexts   = [NSMutableDictionary dictionary];
    if (gMFContextIds == nil) gMFContextIds = [NSMutableDictionary dictionary];
}

id MFContextForTag(NSString *tag) {
    MFContextRegistryInit();
    return gMFContexts[tag];
}

uint32_t MFContextIdForTag(NSString *tag) {
    MFContextRegistryInit();
    NSNumber *n = gMFContextIds[tag];
    return n ? (uint32_t)n.unsignedIntValue : 0;
}

/// 造 context、绑窗口、登记，返回 contextId（0 = 失败）
uint32_t MFPrepareContextForWindow(UIWindow *window, NSString *tag) {
    MFContextRegistryInit();
    if (tag == nil) tag = @"?";

    // 先清掉旧的
    [gMFContexts removeObjectForKey:tag];
    [gMFContextIds removeObjectForKey:tag];

    id ctx = MFAttachContextToWindow(window, tag);
    if (ctx == nil) {
        MFHUDLogLine(@"  [%@] 登记失败：context 为 nil", tag);
        return 0;
    }

    SEL ctxIdSel = sel_registerName("contextId");
    uint32_t cid = 0;
    if ([ctx respondsToSelector:ctxIdSel]) {
        cid = ((uint32_t (*)(id, SEL))objc_msgSend)(ctx, ctxIdSel);
    }

    gMFContexts[tag]   = ctx;               // ★ 强引用，保住生命周期
    gMFContextIds[tag] = @(cid);
    MFHUDLogLine(@"  [%@] 已登记：context=%p contextId=0x%x", tag, ctx, cid);
    return cid;
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
    typedef void *(*mf_hidreg_t)(void *);
    mf_hidreg_t p_BKSHIDReg = (mf_hidreg_t)dlsym(RTLD_DEFAULT,
                                                 "BKSHIDEventRegisterEventCallback");
    MFHUDLogLine(@"⑨ BKSHIDEventRegisterEventCallback = %p", (void *)p_BKSHIDReg);
    if (p_BKSHIDReg) {
        p_BKSHIDReg((void *)NULL);   // 先传 NULL，只要注册动作本身生效即可
        MFHUDLogLine(@"   已注册 ✓");
    }

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
