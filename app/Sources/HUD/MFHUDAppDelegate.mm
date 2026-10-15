//
//  MFHUDAppDelegate.mm — HUD 角色（实现）
//
#import "MFHUDAppDelegate.h"
#import "MFHUDApplication.h"
#import "MFHUDWindowHost.h"
#import "MFHUDStartupStatus.h"
#include <unistd.h>
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

/*
 * ★★★ [M5.22] 这一组就是 TrollSpeed（Lessica，开源，ch.xxtou.hudapp）的做法 ★★★
 *
 * 来源：https://github.com/Lessica/TrollSpeed
 *       sources/HUDMainWindow.mm
 *
 *     @implementation HUDMainWindow
 *     + (BOOL)_isSystemWindow            { return YES; }
 *     - (BOOL)_isWindowServerHostingManaged { return NO; }
 *     - (BOOL)_ignoresHitTest            { return [HUDRootViewController passthroughMode]; }
 *     - (BOOL)_isSecure                  { return YES; }
 *     - (BOOL)_shouldCreateContextAsSecure { return YES; }
 *     @end
 *
 * ★ 三个关键修正（之前全搞错了）：
 *
 *   ① 这些是【重写 getter】，不是「调 setter」。
 *      我前面一直在试 set_isSystemWindow: / _setSystemWindow: 之类的名字，
 *      8 个里只有 1 个存在 —— 因为根本不该去 set，UIWindow 内部会问这些问题。
 *
 *   ② _isSystemWindow 是【类方法】(+) 不是实例方法。
 *
 *   ③ _isWindowServerHostingManaged 返回的是【NO】不是 YES。
 *      我前面把语义理解反了。
 */
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_ignoresHitTest { return self.ignoresHitTestOverride; }

/// 让窗口内容不参与命中（绘制层用）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.ignoresHitTestOverride) return nil;
    return [super hitTest:point withEvent:event];
}

@end

#pragma mark - HUD 应用代理

@interface MFHUDAppDelegate ()
@property (nonatomic, strong) MFOverlayView *menuOverlay;
@property (nonatomic, strong) MFOverlayView *drawingOverlay;
@property (nonatomic, strong) NSMutableDictionary *startupReport;
@property (nonatomic, copy) NSString *startupToken;
@end

@implementation MFHUDAppDelegate

static BOOL gIsHUD = NO;
+ (BOOL)isHUDProcess { return gIsHUD; }

- (BOOL)application:(UIApplication *)app
didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)opts {
    if (gIsHUD) return YES;
    gIsHUD = YES;
    self.startupToken = [MFHUDStartupStatus currentToken];
    self.startupReport = [@{ @"pid": @(getpid()), @"token": self.startupToken ?: @"",
                             @"state": @"starting" } mutableCopy];
    [self publishStartupState:@"starting" error:nil];
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
    // [M5.22] 层级对齐 TrollSpeed 的 10000010.0（原来 1020，差了四个数量级）
    MFHUDWindow *drawWin = [[MFHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    drawWin.ignoresHitTestOverride = YES;
    drawWin.windowLevel = 10000010.0;
    drawWin.backgroundColor = [UIColor clearColor];
    drawWin.opaque = NO;
    drawWin.userInteractionEnabled = NO;

    UIViewController *drawVC = [[UIViewController alloc] init];
    drawVC.view.backgroundColor = [UIColor clearColor];
    drawVC.view.userInteractionEnabled = NO;
    drawWin.rootViewController = drawVC;

    MFOverlayView *drawView = [[MFOverlayView alloc] initWithFrame:drawVC.view.bounds
                                                       interactive:NO];
    drawView.automaticallyStartsRendering = NO;
    self.drawingOverlay = drawView;
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
    // [M5.22] 对齐 TrollSpeed（绘制窗 10000010，菜单窗略低一点）
    MFHUDWindow *menuWin = [[MFHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    menuWin.windowLevel = 10000009.0;
    menuWin.backgroundColor = [UIColor clearColor];
    menuWin.opaque = NO;

    UIViewController *menuVC = [[UIViewController alloc] init];
    menuVC.view.backgroundColor = [UIColor clearColor];
    menuWin.rootViewController = menuVC;

    MFOverlayView *menuView = [[MFOverlayView alloc] initWithFrame:menuVC.view.bounds
                                                       interactive:YES];
    menuView.automaticallyStartsRendering = NO;
    self.menuOverlay = menuView;
    menuView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    MFMenuUI *menu = [[MFMenuUI alloc] init];
    menu.overlay = menuView;
    menuView.delegate = menu;
    self.menuController = menu;              // 强引用保活（delegate 是 weak）
    [menuVC.view addSubview:menuView];
    menuWin.hidden = NO;
    [menuWin makeKeyAndVisible];
    self.hudMenuWindow = menuWin;

    /*
     * ══════════════════════════════════════════════════════════════
     *  ★ [M5.24] 显示链路自检色块 —— 采纳另一位分析者的建议
     * ══════════════════════════════════════════════════════════════
     *
     * 原话：「验证这一层时，可以先显示一个固定位置、颜色明显的普通 UIView 色块。
     *        色块能跨应用显示，就说明基础窗口显示链路已经接通，
     *        再继续验证 ImGui 菜单，排查范围会清楚很多。」
     *
     * 这个思路很对 —— 把「窗口能不能显示」和「ImGui 能不能渲染」
     * 拆开验证。色块用的是最朴素的东西（UIView + backgroundColor），
     * 只要它不显示，问题就一定在窗口/托管层，与渲染无关。
     *
     * 放在屏幕右上角，不挡菜单；尺寸够大，一眼能看到。
     */
    {
        CGFloat w = 120, h = 120;
        CGRect f = CGRectMake(UIScreen.mainScreen.bounds.size.width - w - 24,
                              60, w, h);
        UIView *tv = [[UIView alloc] initWithFrame:f];
        tv.backgroundColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.45 alpha:0.92];
        tv.layer.cornerRadius = 16;
        tv.layer.borderWidth = 4;
        tv.layer.borderColor = [UIColor whiteColor].CGColor;
        tv.userInteractionEnabled = NO;

        UILabel *lbl = [[UILabel alloc] initWithFrame:tv.bounds];
        lbl.text = @"色块\n测试";
        lbl.numberOfLines = 0;
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.font = [UIFont boldSystemFontOfSize:26];
        lbl.textColor = [UIColor whiteColor];
        [tv addSubview:lbl];

        [menuVC.view addSubview:tv];
        self.testColorView = tv;
        MFHUDLogLine(@"已放入测试色块：frame=%@（右上角粉红色方块）",
                     NSStringFromCGRect(f));
    }

    // Let UIKit finish initial window layout before reading its native context.
    // Keep rendering stopped until both layer trees have been registered.
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self.hudMenuWindow layoutIfNeeded];
            [self.drawingWindow layoutIfNeeded];
            [CATransaction flush];
            MFHUDLogLine(@"---- 准备单一窗口 context 与托管 ----");
            MFHUDLogLine(@"connectedScenes=%lu，menu bounds=%@，drawing bounds=%@",
                         (unsigned long)app.connectedScenes.count,
                         NSStringFromCGRect(menuView.bounds), NSStringFromCGRect(drawView.bounds));
            Class contextClass = NSClassFromString(@"CAContext");
            Class hostingClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
            uint32_t nativeMenu = [self nativeContextIDForWindow:self.hudMenuWindow];
            uint32_t nativeDrawing = [self nativeContextIDForWindow:self.drawingWindow];
            self.menuHost = [[MFHUDWindowHost alloc] initWithLayer:self.hudMenuWindow.layer
                nativeContextID:nativeMenu level:self.hudMenuWindow.windowLevel
                contextClass:contextClass hostingClass:hostingClass];
            self.drawingHost = [[MFHUDWindowHost alloc] initWithLayer:self.drawingWindow.layer
                nativeContextID:nativeDrawing level:self.drawingWindow.windowLevel
                contextClass:contextClass hostingClass:hostingClass];
            NSString *error = nil;
            if (![self.menuHost registerWithError:&error]) {
                [self failStartup:[@"菜单窗口：" stringByAppendingString:error ?: @"托管失败"]];
                return;
            }
            self.startupReport[@"menuContextID"] = @(self.menuHost.contextID);
            self.startupReport[@"menuRegistered"] = @YES;
            MFHUDLogLine(@"菜单注册已调用：context=0x%x source=%@ controller=%p",
                         self.menuHost.contextID, nativeMenu ? @"UIKit" : @"remote layer",
                         self.menuHost.hostingController);
            if (![self.drawingHost registerWithError:&error]) {
                [self failStartup:[@"绘制窗口：" stringByAppendingString:error ?: @"托管失败"]];
                return;
            }
            self.startupReport[@"drawingContextID"] = @(self.drawingHost.contextID);
            self.startupReport[@"drawingRegistered"] = @YES;
            MFHUDLogLine(@"绘制注册已调用：context=0x%x source=%@ controller=%p",
                         self.drawingHost.contextID, nativeDrawing ? @"UIKit" : @"remote layer",
                         self.drawingHost.hostingController);
            [CATransaction flush];
            [self publishStartupState:@"waiting-for-frames" error:nil];

            __weak MFHUDAppDelegate *weakSelf = self;
            menuView.firstFrameCompletion = ^(NSString *frameError) {
                [weakSelf handleFirstFrame:@"menuFrame" error:frameError];
            };
            drawView.firstFrameCompletion = ^(NSString *frameError) {
                [weakSelf handleFirstFrame:@"drawingFrame" error:frameError];
            };
            if (![menuView startRenderingWithError:&error] ||
                ![drawView startRenderingWithError:&error]) {
                [self failStartup:error ?: @"Metal/ImGui 初始化失败"];
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if (![self.startupReport[@"state"] isEqual:@"ready"] &&
                    ![self.startupReport[@"state"] isEqual:@"failed"]) {
                    [self failStartup:[NSString stringWithFormat:
                        @"首帧等待超时：菜单=%@，绘制=%@。请查看 HUD 日志中的 drawable/Metal 记录。",
                        self.startupReport[@"menuFrame"] ?: @NO,
                        self.startupReport[@"drawingFrame"] ?: @NO]];
                }
            });
        } @catch (NSException *exception) {
            [self failStartup:[NSString stringWithFormat:@"HUD 建窗异常：%@ / %@",
                              exception.name, exception.reason ?: @""]];
        }
    });

    return YES;
}

- (uint32_t)nativeContextIDForWindow:(UIWindow *)window {
    SEL selector = NSSelectorFromString(@"_contextId");
    uint32_t contextID = 0;
    if ([window respondsToSelector:selector])
        contextID = ((uint32_t (*)(id, SEL))objc_msgSend)(window, selector);
    SEL keep = NSSelectorFromString(@"setKeepContextInBackground:");
    if ([window respondsToSelector:keep])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(window, keep, YES);
    return contextID;
}

- (void)publishStartupState:(NSString *)state error:(NSString *)error {
    if ([self.startupReport[@"state"] isEqual:@"failed"] && ![state isEqual:@"failed"]) return;
    self.startupReport[@"state"] = state;
    if (error) self.startupReport[@"error"] = error;
    MFHUDLogLine(@"HUD 状态=%@ %@", state, error ?: @"");
    NSError *writeError = nil;
    if (self.startupToken && ![MFHUDStartupStatus writeReport:self.startupReport
                            token:self.startupToken error:&writeError]) {
        MFHUDLogLine(@"启动状态写入失败：%@", writeError);
    }
}

- (void)failStartup:(NSString *)error {
    [self.menuOverlay stopRendering];
    [self.drawingOverlay stopRendering];
    [self publishStartupState:@"failed" error:error];
}

- (void)handleFirstFrame:(NSString *)key error:(NSString *)error {
    if ([self.startupReport[@"state"] isEqual:@"failed"]) return;
    if (error) { [self failStartup:[NSString stringWithFormat:@"%@：%@", key, error]]; return; }
    self.startupReport[key] = @YES;
    MFHUDLogLine(@"%@：GPU 首帧已完成", key);
    BOOL complete = [self.startupReport[@"menuFrame"] boolValue] &&
                    [self.startupReport[@"drawingFrame"] boolValue];
    [self publishStartupState:complete ? @"ready" : @"waiting-for-frames" error:nil];
    if (complete) {
        MFHUDLogLine(@"两窗注册调用和 GPU 首帧已完成；屏幕可见性仍需真机观察");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ [self.testColorView removeFromSuperview]; });
    }
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"[MF][HUD] 进入后台");
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    NSLog(@"[MF][HUD] 回到前台");
}

@end
