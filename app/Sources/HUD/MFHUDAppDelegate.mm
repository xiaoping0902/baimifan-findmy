//
//  MFHUDAppDelegate.mm — HUD 角色（实现）
//
#import "MFHUDAppDelegate.h"
#import "MFMenuUI.h"
#import "MFDrawingLayer.h"
#import "../Render/MFOverlayView.h"
#import "../Kernel/MFKernel.h"
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

/// 通过 SBSAccessibilityWindowHostingController 把窗口托管给 SpringBoard
/// （跨 App 悬浮的关键；对应 entitlement: com.apple.springboard.accessibility-window-hosting）
static BOOL MFHostWindow(UIWindow *window) {
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        NSLog(@"[MF][HUD] 找不到 SBSAccessibilityWindowHostingController");
        return NO;
    }
    id controller = ((id (*)(id, SEL))objc_msgSend)([cls alloc], sel_registerName("init"));
    if (!controller) return NO;

    SEL regSel = sel_registerName("registerWindowWithContextID:atLevel:");
    if (![controller respondsToSelector:regSel]) {
        NSLog(@"[MF][HUD] 托管控制器不支持 registerWindowWithContextID:atLevel:");
        return NO;
    }

    SEL ctxSel = sel_registerName("_contextId");
    if (![window respondsToSelector:ctxSel]) {
        NSLog(@"[MF][HUD] UIWindow 没有 _contextId");
        return NO;
    }
    uint32_t ctxId = ((uint32_t (*)(id, SEL))objc_msgSend)(window, ctxSel);
    ((void (*)(id, SEL, uint32_t, double))objc_msgSend)(
        controller, regSel, ctxId, (double)window.windowLevel);

    NSLog(@"[MF][HUD] 已托管窗口 contextId=0x%x level=%.0f", ctxId, (double)window.windowLevel);
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
        BOOL a = MFHostWindow(self.hudMenuWindow);
        BOOL b = MFHostWindow(self.drawingWindow);
        NSLog(@"[MF][HUD] 托管结果：菜单窗=%d 绘制窗=%d", a, b);
        if (!a && !b) {
            NSLog(@"[MF][HUD] ⚠️ 两个窗口都托管失败 —— 检查 accessibility-window-hosting 权限是否生效");
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
