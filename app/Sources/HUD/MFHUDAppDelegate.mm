//
//  MFHUDAppDelegate.mm — HUD 角色（实现）
//
#import "MFHUDAppDelegate.h"
#import "MFHUDApplication.h"
#import "MFHUDWindowHost.h"
#import "MFHUDStartupStatus.h"
#import "MFHUDInputBridge.h"
#include <unistd.h>
#include <stdlib.h>
#import "MFHUDLog.h"
#import "MFMenuUI.h"
#import "MFDrawingLayer.h"
#import "../Render/MFOverlayView.h"
#import "../Kernel/MFKernel.h"
#import "../Game/MFGameReader.h"
#import "../Read/MFReadBackend.h"
#import <objc/message.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>

#pragma mark - HUD 应用代理

@interface MFHUDFixedRootController : UIViewController
@end
@implementation MFHUDFixedRootController
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
@end

@protocol MFHUDOrientationUpdate <NSObject>
- (NSInteger)orientation;
@end
@protocol MFHUDOrientationObserver <NSObject>
- (NSInteger)activeInterfaceOrientation;
- (void)setHandler:(void (^)(id<MFHUDOrientationUpdate>))handler;
- (void)invalidate;
@end

@interface MFHUDAppDelegate ()
@property (nonatomic, strong) MFOverlayView *menuOverlay;
@property (nonatomic, strong) MFOverlayView *drawingOverlay;
@property (nonatomic, strong) NSMutableDictionary *startupReport;
@property (nonatomic, copy) NSString *startupToken;
@property (nonatomic, strong) MFHUDInputBridge *inputBridge;
@property (nonatomic, strong) UIView *menuContent;
@property (nonatomic, strong) UIView *drawingContent;
@property (nonatomic, strong) id<MFHUDOrientationObserver> orientationObserver;
@property (nonatomic) UIInterfaceOrientation hudOrientation;
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
    CGRect fixedScreen = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    // UIKit consults _ignoresHitTest while creating its native context. A
    // mutable property assigned after init is too late for that first query.
    MFHUDDrawingWindow *drawWin = [[MFHUDDrawingWindow alloc] initWithFrame:fixedScreen];
    drawWin.windowLevel = 10000010.0;
    drawWin.backgroundColor = [UIColor clearColor];
    drawWin.opaque = NO;
    drawWin.userInteractionEnabled = NO;

    UIViewController *drawVC = [[MFHUDFixedRootController alloc] init];
    drawVC.view.backgroundColor = [UIColor clearColor];
    drawVC.view.userInteractionEnabled = NO;
    drawWin.rootViewController = drawVC;
    drawVC.view.frame = drawWin.bounds;
    self.drawingContent = [[UIView alloc] initWithFrame:drawVC.view.bounds];
    self.drawingContent.userInteractionEnabled = NO;
    [drawVC.view addSubview:self.drawingContent];

    MFOverlayView *drawView = [[MFOverlayView alloc] initWithFrame:self.drawingContent.bounds
                                                       interactive:NO];
    drawView.automaticallyStartsRendering = NO;
    self.drawingOverlay = drawView;
    drawView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    MFDrawingLayer *drawLayer = [[MFDrawingLayer alloc] init];
    drawLayer.overlay = drawView;
    drawView.delegate = drawLayer;
    self.drawingLayer = drawLayer;           // 强引用保活（delegate 是 weak）
    [self.drawingContent addSubview:drawView];
    drawWin.hidden = NO;
    self.drawingWindow = drawWin;

    // ── ② 菜单窗（可交互）────────────────────────────
    // [M5.22] 对齐 TrollSpeed（绘制窗 10000010，菜单窗略低一点）
    // A full-screen interactive UIWindow blocks the desktop even when its
    // Metal view rejects points. Keep the actual native surface panel-sized.
    MFHUDWindow *menuWin = [[MFHUDWindow alloc] initWithFrame:CGRectMake(24, 90, 348, 520)];
    menuWin.windowLevel = 10000009.0;
    menuWin.backgroundColor = [UIColor clearColor];
    menuWin.opaque = NO;

    UIViewController *menuVC = [[MFHUDFixedRootController alloc] init];
    menuVC.view.backgroundColor = [UIColor clearColor];
    menuWin.rootViewController = menuVC;
    menuVC.view.frame = menuWin.bounds;
    self.menuContent = [[UIView alloc] initWithFrame:menuVC.view.bounds];
    [menuVC.view addSubview:self.menuContent];

    MFOverlayView *menuView = [[MFOverlayView alloc] initWithFrame:self.menuContent.bounds
                                                       interactive:YES];
    menuView.automaticallyStartsRendering = NO;
    self.menuOverlay = menuView;
    menuView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    MFMenuUI *menu = [[MFMenuUI alloc] init];
    menu.overlay = menuView;
    menuView.delegate = menu;
    self.menuController = menu;              // 强引用保活（delegate 是 weak）
    [self.menuContent addSubview:menuView];
    menuWin.interactiveView = menuView;
    menuWin.hidden = NO;
    [menuWin makeKeyAndVisible];
    self.hudMenuWindow = menuWin;
    self.inputBridge = [[MFHUDInputBridge alloc] initWithOverlay:menuView window:menuWin];
    NSString *inputError = nil;
    if (![self.inputBridge installWithError:&inputError]) {
        [self failStartup:inputError];
        return YES;
    }
    __weak MFHUDAppDelegate *weakSelfForInput = self;
    menuView.captureRectDidChange = ^(CGRect rect) {
        MFHUDAppDelegate *owner = weakSelfForInput;
        BOOL empty = CGRectIsNull(rect) || CGRectIsEmpty(rect);
        owner.hudMenuWindow.hidden = empty;
        if (empty) [owner.inputBridge cancelAll];
    };
    [self startObservingOrientation];

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
            MFHUDLogLine(@"绘制窗口=%@ nativeContext=0x%x（创建时固定忽略命中）",
                         NSStringFromClass(self.drawingWindow.class), nativeDrawing);
            if (nativeDrawing == 0) {
                // A generic remote CAContext does not inherit the window's
                // input policy. Do not silently create a full-screen blocker.
                [self failStartup:@"绘制窗口未取得原生 context，已停止悬浮窗以免遮挡触摸。"];
                return;
            }
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

- (void)startObservingOrientation {
    Class cls = NSClassFromString(@"FBSOrientationObserver");
    if (!cls) {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        cls = NSClassFromString(@"FBSOrientationObserver");
    }
    id<MFHUDOrientationObserver> observer = [[cls alloc] init];
    if ([observer respondsToSelector:@selector(setHandler:)] &&
        [observer respondsToSelector:@selector(activeInterfaceOrientation)]) {
        self.orientationObserver = observer;
        __weak MFHUDAppDelegate *weakSelf = self;
        [observer setHandler:^(id<MFHUDOrientationUpdate> update) {
            UIInterfaceOrientation orientation = (UIInterfaceOrientation)update.orientation;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applyHUDOrientation:orientation]; });
        }];
        [self applyHUDOrientation:(UIInterfaceOrientation)observer.activeInterfaceOrientation];
    } else {
        MFHUDLogLine(@"方向观察器不可用，菜单先使用竖屏坐标");
        [self applyHUDOrientation:UIInterfaceOrientationPortrait];
    }
}

- (void)applyHUDOrientation:(UIInterfaceOrientation)orientation {
    // LandscapeLeft is 4, LandscapeRight is 3; their names are not a range.
    switch (orientation) {
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationPortraitUpsideDown:
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            break;
        default:
            orientation = UIInterfaceOrientationPortrait;
            break;
    }
    if (self.hudOrientation == orientation) return;
    [self.inputBridge cancelAll];
    self.hudOrientation = orientation;
    CGFloat angle = orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI :
        (orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 :
         (orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2 : 0));
    CGRect fixed = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGSize logicalScreen = landscape ? CGSizeMake(fixed.size.height, fixed.size.width) : fixed.size;
    CGSize panel = CGSizeMake(348, 520);
    CGSize physicalPanel = landscape ? CGSizeMake(panel.height, panel.width) : panel;
    // Position (24,90) in the displayed orientation, then rotate into fixed space.
    CGFloat dx = 24 + panel.width / 2 - logicalScreen.width / 2;
    CGFloat dy = 90 + panel.height / 2 - logicalScreen.height / 2;
    CGPoint center = CGPointMake(CGRectGetMidX(fixed) + cos(angle)*dx - sin(angle)*dy,
                                 CGRectGetMidY(fixed) + sin(angle)*dx + cos(angle)*dy);
    UIWindow *menuWindow = self.hudMenuWindow;
    menuWindow.bounds = (CGRect){CGPointZero, physicalPanel};
    menuWindow.center = center;
    menuWindow.rootViewController.view.frame = menuWindow.bounds;
    // Only the content rotates. Setting a transformed UIView's frame is undefined.
    self.menuContent.bounds = (CGRect){CGPointZero, panel};
    self.menuContent.center = CGPointMake(physicalPanel.width / 2, physicalPanel.height / 2);
    self.menuContent.transform = CGAffineTransformMakeRotation(angle);
    self.menuOverlay.frame = self.menuContent.bounds;
    self.drawingContent.bounds = (CGRect){CGPointZero, logicalScreen};
    self.drawingContent.center = CGPointMake(fixed.size.width / 2, fixed.size.height / 2);
    self.drawingContent.transform = CGAffineTransformMakeRotation(angle);
    self.drawingOverlay.frame = self.drawingContent.bounds;
    [menuWindow layoutIfNeeded];
    [self.menuOverlay layoutIfNeeded];
    [self.drawingOverlay layoutIfNeeded];
    [CATransaction flush];
    MFHUDLogLine(@"HUD 方向=%ld menu frame=%@ content=%@ drawing=%@",
        (long)orientation, NSStringFromCGRect(menuWindow.frame),
        NSStringFromCGRect(self.menuOverlay.bounds), NSStringFromCGRect(self.drawingOverlay.bounds));
    // Never leave a stale registered context silently owning an invisible input surface.
    if ((self.menuHost && [self nativeContextIDForWindow:menuWindow] != self.menuHost.contextID) ||
        (self.drawingHost && [self nativeContextIDForWindow:self.drawingWindow] != self.drawingHost.contextID))
        [self failStartup:@"旋转后窗口 context 已变化，悬浮窗已退出，请重新启动悬浮窗。"];
}

- (void)dealloc { [self.orientationObserver invalidate]; }

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
    [self.inputBridge cancelAll];
    [self.menuOverlay stopRendering];
    [self.drawingOverlay stopRendering];
    self.hudMenuWindow.hidden = YES;
    self.drawingWindow.hidden = YES;
    self.menuHost = nil;
    self.drawingHost = nil;
    [self publishStartupState:@"failed" error:error];
    // The HUD is root while the console may be mobile. Exit here rather than
    // relying on the console being allowed to signal a root process.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ _exit(EXIT_FAILURE); });
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
