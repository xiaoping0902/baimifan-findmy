//
//  MFHUDAppDelegate.mm — HUD 角色（实现）
//
#import "MFHUDAppDelegate.h"
#import "MFHUDApplication.h"   // [M5.18] MFMarkWindowSystemSecure
#import "MFHUDLog.h"
#import "MFMenuUI.h"
#import "MFDrawingLayer.h"
#import "../Render/MFOverlayView.h"
#import "../Kernel/MFKernel.h"
#import "../Game/MFGameReader.h"
#import "../Read/MFReadBackend.h"
#import <objc/message.h>
#include <string.h>

#pragma mark - HUD 窗口

@implementation MFHUDWindow

/// 私有属性，对齐分析已证：三项返回 YES
- (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_ignoresHitTest { return self.ignoresHitTestOverride; }

/// 让窗口内容不参与命中（绘制层用）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.ignoresHitTestOverride) return nil;
    return [super hitTest:point withEvent:event];
}

@end

#pragma mark - 辅助窗口托管

/*
 * ★★ [M5.17] 跨进程窗口托管的两条路 ★★
 *
 * 原版白米饭用的私有成员（已从二进制差分确认）：
 *     HUDMainApplication / _drawingHostingController /
 *     _isWindowServerHostingManaged / ToggleDrawingWindow
 *
 * `_isWindowServerHostingManaged` 是 UIWindow 的私有属性 ——
 * 它告诉 UIKit「这个窗口由 WindowServer 托管」，正是跨进程显示需要的。
 * 我们之前完全没设它，只调了 SBSAccessibilityWindowHostingController。
 *
 * 这里两条都试：
 *   ① set_isWindowServerHostingManaged:YES  ← 原版的机制
 *   ② registerWindowWithContextID:atLevel:  ← SpringBoard 托管
 * 任何一条成功，窗口就能进合成器。
 */
static void MFMarkWindowServerHostingManaged(UIWindow *w) {
    if (w == nil) return;
    // 私有 setter 的名字在几个 iOS 版本间变过，逐个试
    NSArray<NSString *> *setters = @[
        @"set_isWindowServerHostingManaged:",
        @"_setWindowServerHostingManaged:",
    ];
    for (NSString *name in setters) {
        SEL s = sel_registerName(name.UTF8String);
        if ([w respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(w, s, YES);
            MFHUDLogLine(@"  ✓ 已设置 %@ = YES", name);
            return;
        }
    }
    MFHUDLogLine(@"  ⚠️ 没有可用的 _isWindowServerHostingManaged setter（试过 %lu 个名字）",
                 (unsigned long)setters.count);
}

/// 通过 SBSAccessibilityWindowHostingController 把窗口托管给 SpringBoard
/// （跨 App 悬浮的关键；对应 entitlement: com.apple.springboard.accessibility-window-hosting）
///
/// [M5.17] ★ 每一步都写 MFHUDLogLine，不再用 NSLog。
///   原因：原来失败时只 NSLog，而 NSLog 进 syslog 不进我们的日志文件 ——
///   结果「托管失败」时我在文件里什么都看不到，只能看到一句笼统的结论。
///   真机配过一次（pid 307 活着但窗口不出来），现场全空。
static BOOL MFHostWindow(UIWindow *window) {
    if (window == nil) {
        MFHUDLogLine(@"  MFHostWindow: 窗口为 nil，跳过");
        return NO;
    }

    // ① 先试原版那条路：标记成 WindowServer 托管
    MFMarkWindowServerHostingManaged(window);

    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    MFHUDLogLine(@"  MFHostWindow: SBSAccessibilityWindowHostingController = %@",
                 cls ? @"存在" : @"★ 不存在");
    if (!cls) return NO;

    id controller = ((id (*)(id, SEL))objc_msgSend)([cls alloc], sel_registerName("init"));
    MFHUDLogLine(@"  MFHostWindow: controller alloc/init = %@", controller ? @"成功" : @"★ 失败");
    if (!controller) return NO;

    SEL regSel = sel_registerName("registerWindowWithContextID:atLevel:");
    BOOL responds = [controller respondsToSelector:regSel];
    MFHUDLogLine(@"  MFHostWindow: respondsToSelector(registerWindowWithContextID:atLevel:) = %d", responds);
    if (!responds) return NO;

    SEL ctxSel = sel_registerName("_contextId");
    BOOL hasCtx = [window respondsToSelector:ctxSel];
    MFHUDLogLine(@"  MFHostWindow: UIWindow 有 _contextId = %d", hasCtx);
    if (!hasCtx) return NO;

    uint32_t ctxId = ((uint32_t (*)(id, SEL))objc_msgSend)(window, ctxSel);
    MFHUDLogLine(@"  MFHostWindow: _contextId = 0x%x  level = %.0f",
                 ctxId, (double)window.windowLevel);

    if (ctxId == 0) {
        MFHUDLogLine(@"  ★★ _contextId == 0 —— registerWindowWithContextID:0 会静默无效");
        MFHUDLogLine(@"     这是「窗口建了但没进合成器」的直接原因");
        MFHUDLogLine(@"     上游原因：本进程没有 UIWindowScene → 没拿到 CAContext");
        MFHUDLogLine(@"     （但 _isWindowServerHostingManaged 已设，可能已足够）");
        return NO;
    }

    ((void (*)(id, SEL, uint32_t, double))objc_msgSend)(
        controller, regSel, ctxId, (double)window.windowLevel);
    MFHUDLogLine(@"  ✓ 已托管 contextId=0x%x level=%.0f", ctxId, (double)window.windowLevel);
    return YES;
}

#pragma mark - HUD 应用代理

@implementation MFHUDAppDelegate

static BOOL gIsHUD = NO;
+ (BOOL)isHUDProcess { return gIsHUD; }

- (BOOL)application:(UIApplication *)app
didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)opts {
    gIsHUD = YES;
    NSLog(@"[MF][HUD] didFinish，开始建立双窗口");
    MFHUDLogLine(@"==== HUD didFinishLaunching 进来了 ====");

    /*
     * ★★ 审查修正（P0-2）★★
     *
     * 原来：控制台进程在「进程列表」里点一下，把 task port 写进【它自己】的
     *       MFGameReader；而绘制跑在【这个】posix_spawn 出来的 HUD 进程里。
     *       端口名字只在创建它的 IPC space 里有效 —— HUD 进程根本用不了那个号，
     *       于是门条件永远不成立，绘制永远是空的。
     *
     * 现在：控制台把「目标 pid」落盘（NSUserDefaults 跨进程同容器可见），
     *       HUD 进程启动时读回来，用 task_for_pid 为【自己】取一份端口。
     */
    {
        NSInteger targetPid = [[NSUserDefaults standardUserDefaults] integerForKey:@"mf.target.pid"];
        NSString *targetName = [[NSUserDefaults standardUserDefaults] stringForKey:@"mf.target.name"];
        MFHUDLogLine(@"目标进程：pid=%ld name=%@", (long)targetPid, targetName ?: @"(未绑定)");

        if (targetPid > 0) {
            NSString *perr = nil;
            uint32_t port = [MFKernel acquireTaskPortForPid:(int)targetPid error:&perr];
            if (port != MACH_PORT_NULL) {
                [MFGameReader shared].targetTaskPort = port;
                [MFReadBackend shared].modeFlag = YES;
                [[MFGameReader shared] loadBasesFromDefaults];   // 基址也一起读回来
                MFHUDLogLine(@"✅ HUD 侧已取得目标端口 0x%x，读取链门条件=%d",
                             port, [MFReadBackend shared].gateOpen);
            } else {
                MFHUDLogLine(@"❌ HUD 侧取端口失败：%@", perr ?: @"?");
            }
        } else {
            MFHUDLogLine(@"⚠️ 还没有绑定目标进程 —— 先回控制台在「进程列表」点一个进程");
        }
    }

    // ── ① 绘制窗（透明，完全穿透）──────────────────────
    // 分析已证：level = UIWindowLevelStatusBar + 20；opaque=NO；userInteractionEnabled=NO
    MFHUDWindow *drawWin = [[MFHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    drawWin.ignoresHitTestOverride = YES;
    drawWin.windowLevel = UIWindowLevelStatusBar + 20;
    drawWin.backgroundColor = [UIColor clearColor];
    drawWin.opaque = NO;
    drawWin.userInteractionEnabled = NO;

    UIViewController *drawVC = [[UIViewController alloc] init];
    drawVC.view.backgroundColor = [UIColor clearColor];
    drawVC.view.userInteractionEnabled = NO;
    drawWin.rootViewController = drawVC;

    MFOverlayView *drawView = [[MFOverlayView alloc] initWithFrame:drawVC.view.bounds
                                                       interactive:NO];
    drawView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    MFDrawingLayer *drawLayer = [[MFDrawingLayer alloc] init];
    drawLayer.overlay = drawView;
    drawView.delegate = drawLayer;
    self.drawingLayer = drawLayer;           // 强引用保活（delegate 是 weak）
    [drawVC.view addSubview:drawView];
    /*
     * [M5.18] 打系统窗口 / 安全窗口标记 —— 必须在 makeKeyAndVisible 之前。
     * 对照白米饭已证的窗口特性：
     *     _isSystemWindow / _isSecure / _shouldCreateContextAsSecure 均为 1
     */
    MFMarkWindowSystemSecure(drawWin);
    drawWin.hidden = NO;
    [drawWin makeKeyAndVisible];
    self.drawingWindow = drawWin;

    // ── ② 菜单窗（可交互）────────────────────────────
    // 分析已证：level = UIWindowLevelStatusBar - 20
    MFHUDWindow *menuWin = [[MFHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    menuWin.windowLevel = UIWindowLevelStatusBar - 20;
    menuWin.backgroundColor = [UIColor clearColor];
    menuWin.opaque = NO;

    UIViewController *menuVC = [[UIViewController alloc] init];
    menuVC.view.backgroundColor = [UIColor clearColor];
    menuWin.rootViewController = menuVC;

    MFOverlayView *menuView = [[MFOverlayView alloc] initWithFrame:menuVC.view.bounds
                                                       interactive:YES];
    menuView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    MFMenuUI *menu = [[MFMenuUI alloc] init];
    menu.overlay = menuView;
    menuView.delegate = menu;
    self.menuController = menu;              // 强引用保活（delegate 是 weak）
    [menuVC.view addSubview:menuView];
    MFMarkWindowSystemSecure(menuWin);       // [M5.18] 同上，必须在 visible 之前
    menuWin.hidden = NO;
    [menuWin makeKeyAndVisible];
    self.hudMenuWindow = menuWin;

    // ── ③ 启动渲染 ───────────────────────────────────
    NSString *err = nil;
    if (![drawView startRenderingWithError:&err]) {
        NSLog(@"[MF][HUD] 绘制窗渲染启动失败: %@", err);
    }
    err = nil;
    if (![menuView startRenderingWithError:&err]) {
        NSLog(@"[MF][HUD] 菜单窗渲染启动失败: %@", err);
    }

    // ── ④ 交给系统托管（跨 App 悬浮）─────────────────
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // ★ 托管前先把关键量落盘 —— 这是判断「窗口建了但没进合成器」的唯一证据
        MFHUDLogLine(@"---- 托管前诊断 ----");
        MFHUDLogLine(@"UIApplication.applicationState = %ld (0=Active 1=Inactive 2=Background)",
                     (long)UIApplication.sharedApplication.applicationState);
        MFHUDLogLine(@"UIScreen.bounds = %@", NSStringFromCGRect(UIScreen.mainScreen.bounds));

        /*
         * ★★ [M5.17] scene 诊断 —— 这是整个 HUD 问题的核心 ★★
         *
         * UIWindow 要进合成器，必须有一个 UIWindowScene，
         * 而 scene 由 FrontBoard 在「前台 App 启动」时创建。
         * posix_spawn 出来的子进程【不走 FrontBoard】，所以大概率一个 scene 都没有
         * → UIWindow 挂不上 CAContext → _contextId = 0
         * → registerWindowWithContextID:0 静默无效 → 窗口永远不显示。
         */
        {
            NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
            MFHUDLogLine(@"connectedScenes 数量 = %lu", (unsigned long)scenes.count);
            int idx = 0;
            for (UIScene *sc in scenes) {
                MFHUDLogLine(@"  scene[%d]: %@  activationState=%ld",
                             idx++, NSStringFromClass(sc.class), (long)sc.activationState);
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)sc;
                    MFHUDLogLine(@"    是 UIWindowScene，windows 数 = %lu",
                                 (unsigned long)ws.windows.count);
                    for (UIWindow *w in ws.windows) {
                        MFHUDLogLine(@"      - %@ level=%.0f hidden=%d",
                                     NSStringFromClass(w.class), w.windowLevel, w.isHidden);
                    }
                }
            }
            if (scenes.count == 0) {
                MFHUDLogLine(@"  ★★ 一个 scene 都没有 = 本进程不是 FrontBoard 启动的前台 App");
                MFHUDLogLine(@"     这就是 _contextId=0 的根因");
            }
        }

        MFHUDLogLine(@"UIApplication.windows 数量 = %lu（含未挂 scene 的）",
                     (unsigned long)UIApplication.sharedApplication.windows.count);
        MFHUDLogLine(@"keyWindow = %@", UIApplication.sharedApplication.keyWindow ? @"有" : @"nil");

        // ★ [M5.20] 把私有 API 的真实名字 dump 出来（不再靠猜）
        MFDumpWindowAPI();

        /*
         * ★★★ [M5.21] 核心修复：没有 scene 就自己造 CAContext ★★★
         *
         * 勘探已证设备上有：
         *     CAContext     - initWithOptions:localContext: / contextId / setLayer:
         *     UIWindow      - _setBoundContext: / setKeepContextInBackground:
         * 先自己建 context 并绑上，再去托管 —— 否则 _contextId=0，托管必然无效。
         */
        MFHUDLogLine(@"---- 自造 CAContext（核心修复）----");
        MFAttachContextToWindow(self.hudMenuWindow, @"菜单");
        MFAttachContextToWindow(self.drawingWindow, @"绘制");
        MFHUDLogLine(@"---- 自造结束，准备托管 ----");

        for (UIWindow *w in @[ self.hudMenuWindow ?: (id)[NSNull null],
                               self.drawingWindow ?: (id)[NSNull null] ]) {
            if (![w isKindOfClass:[UIWindow class]]) continue;
            id ctx = [w valueForKey:@"_contextId"];
            MFHUDLogLine(@"窗口 %@: level=%.0f hidden=%d windowScene=%@ _contextId=%@",
                         (w == self.hudMenuWindow) ? @"菜单" : @"绘制",
                         w.windowLevel, w.isHidden,
                         w.windowScene ? @"有" : @"nil",
                         ctx ? [NSString stringWithFormat:@"0x%x", [ctx unsignedIntValue]] : @"nil");
        }

        BOOL a = MFHostWindow(self.hudMenuWindow);
        BOOL b = MFHostWindow(self.drawingWindow);
        NSLog(@"[MF][HUD] 托管结果：菜单窗=%d 绘制窗=%d", a, b);
        MFHUDLogLine(@"托管结果：菜单窗=%d 绘制窗=%d", a, b);

        // 托管后再看一次 _contextId，能判断托管到底有没有生效
        id ctxMenu = [self.hudMenuWindow valueForKey:@"_contextId"];
        id ctxDraw = [self.drawingWindow valueForKey:@"_contextId"];
        MFHUDLogLine(@"托管后 _contextId：菜单=%@ 绘制=%@",
                     ctxMenu ? [NSString stringWithFormat:@"0x%x", [ctxMenu unsignedIntValue]] : @"nil",
                     ctxDraw ? [NSString stringWithFormat:@"0x%x", [ctxDraw unsignedIntValue]] : @"nil");

        if (!a && !b) {
            NSLog(@"[MF][HUD] ⚠️ 两个窗口都托管失败 —— 检查 accessibility-window-hosting 权限是否生效");
            MFHUDLogLine(@"⚠️ 两个窗口都托管失败");
            MFHUDLogLine(@"最可能的原因（HUD 审查报告 §1 结论 1，概率 ~70%）：");
            MFHUDLogLine(@"  子进程没有被 FrontBoard 承认为前台 App → 拿不到 UIWindowScene/CAContext");
            MFHUDLogLine(@"  → _contextId 为 0 → registerWindowWithContextID:0 静默无效");
            MFHUDLogLine(@"  原版靠 NSPrincipalClass=HUDMainApplication + 一整套 hosting 机制解决，");
            MFHUDLogLine(@"  复刻版没有这一层（已用二进制差分证实）。");
        }
    });

    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"[MF][HUD] 进入后台");
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    NSLog(@"[MF][HUD] 回到前台");
}

@end
