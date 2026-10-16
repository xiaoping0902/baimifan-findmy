//
//  MFHUDAppDelegate.mm — HUD 角色（实现）
//
#import "MFHUDAppDelegate.h"
#import "MFHUDApplication.h"
#import "MFHUDWindowHost.h"
#import "MFHUDStartupStatus.h"
#import "MFHUDInputBridge.h"
#import "MFHUDCaptureShieldView.h"
#import "MFHUDControl.h"
#import <mach/mach.h>
#include <unistd.h>
#include <stdlib.h>
#import "MFHUDLog.h"
#import "MFMenuUI.h"
#import "MFDrawingLayer.h"
#import "../Render/MFOverlayView.h"
#import "../Kernel/MFKernel.h"
#import "../Game/MFGameReader.h"
#import "../Game/MFSettings.h"
#import "../Game/Offsets.h"
#import "../Kernel/MFModuleLocator.h"
#import "../Game/MFUEReader.h"
#include <sys/sysctl.h>
#include <sys/proc.h>
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#import "../Read/MFReadBackend.h"
#import <objc/message.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>

// Validate the process instance before using a persisted PID or absolute base.
static NSString *MFTargetIdentity(pid_t pid, NSString *expectedName) {
    if (pid <= 0 || !expectedName.length) return nil;
    char path[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    NSString *executable = [NSString stringWithUTF8String:path].stringByResolvingSymlinksInPath;
    if (![executable.lastPathComponent isEqual:expectedName]) return nil;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info = {}; size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length < sizeof(info) ||
        info.kp_proc.p_pid != pid || info.kp_proc.p_starttime.tv_sec <= 0) return nil;
    return [NSString stringWithFormat:@"%d|%@|%lld|%d", pid, executable,
        (long long)info.kp_proc.p_starttime.tv_sec, (int)info.kp_proc.p_starttime.tv_usec];
}

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
@property (nonatomic, strong) MFHUDCaptureShieldView *menuContent;
@property (nonatomic, strong) MFHUDCaptureShieldView *drawingContent;
@property (nonatomic, strong) id<MFHUDOrientationObserver> orientationObserver;
@property (nonatomic) UIInterfaceOrientation hudOrientation;
@property (nonatomic) BOOL exitRequested;
@property (nonatomic, strong) NSTimer *targetTimer;
@property (nonatomic) pid_t boundTargetPID;
@property (nonatomic, copy) NSString *boundTargetIdentity;
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

    // The session listener is installed before UIKit. Cancellation can arrive
    // before this delegate, so never start building a window after a stop.
    if ([MFHUDControl exitRequested]) { [self shutdownForExitRequest]; return YES; }
    MFHUDLogLine(@"退出通道：独立控制队列 + 会话退出请求，已由引导阶段安装");
    [self refreshTargetBinding];
    __weak MFHUDAppDelegate *weakTargetOwner = self;
    self.targetTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakTargetOwner refreshTargetBinding];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.targetTimer forMode:NSRunLoopCommonModes];

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
    NSString *captureError = nil;
    self.drawingContent = [[MFHUDCaptureShieldView alloc] initWithFrame:drawVC.view.bounds error:&captureError];
    if (!self.drawingContent) { [self failStartup:captureError]; return YES; }
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
    [self.drawingContent.contentView addSubview:drawView];
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
    self.menuContent = [[MFHUDCaptureShieldView alloc] initWithFrame:menuVC.view.bounds error:&captureError];
    if (!self.menuContent) { [self failStartup:captureError]; return YES; }
    [menuVC.view addSubview:self.menuContent];

    MFOverlayView *menuView = [[MFOverlayView alloc] initWithFrame:self.menuContent.bounds
                                                       interactive:YES];
    menuView.automaticallyStartsRendering = NO;
    self.menuOverlay = menuView;
    menuView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    MFMenuUI *menu = [[MFMenuUI alloc] init];
    menu.overlay = menuView;
    menu.drawingOverlay = drawView;
    menuView.delegate = menu;
    self.menuController = menu;              // 强引用保活（delegate 是 weak）
    [self.menuContent.contentView addSubview:menuView];
    menuWin.interactiveView = self.menuContent;
    menuWin.hidden = NO;
    [menuWin makeKeyAndVisible];
    self.hudMenuWindow = menuWin;
    self.startupReport[@"captureProtectedSurfaces"] = @[@"menu", @"ball", @"drawing"];
    MFHUDLogLine(@"菜单、悬浮球、绘制层已挂入固定安全画布；截图和录屏效果待真机验收");

    /*
     * ★ 帧率策略（M5.66）★
     *
     * 之前两个 overlay 都是固定 60 帧：
     *   · 菜单层 40 来个控件、内容不变，照样每帧问 GPU 要 drawable
     *   · 真正吃性能的全屏绘制层却不受「刷新率」设置影响（那个选项只改了菜单层）
     * 于是「菜单发烫 / 拖动发涩 / nextDrawable 卡 500ms」同时出现。
     *
     * 现在：菜单交互时满帧、空闲降到 12；绘制层跟设置走。
     */
    {
        NSInteger rate = [MFSettings shared].refreshRate;
        if (rate < 15) rate = 60;
        menuView.preferredFPS = rate;
        menuView.idleFPS = 12;
        drawView.preferredFPS = rate;
        __weak MFHUDAppDelegate *weakSelfForFPS = self;
        [MFMenuUI setFrameRateApplier:^(NSInteger fps) {
            MFHUDAppDelegate *owner = weakSelfForFPS;
            owner.menuOverlay.preferredFPS = fps;
            owner.drawingOverlay.preferredFPS = fps;
            MFHUDLogLine(@"刷新率 → %ld 帧（菜单层 + 绘制层同时应用）", (long)fps);
        }];
        MFHUDLogLine(@"帧率：菜单 %ld/空闲 12，绘制 %ld", (long)rate, (long)rate);
    }

    self.inputBridge = [[MFHUDInputBridge alloc] initWithOverlay:menuView window:menuWin];
    NSString *inputError = nil;
    if (![self.inputBridge installWithError:&inputError]) {
        [self failStartup:inputError];
        return YES;
    }
    __weak MFHUDAppDelegate *weakSelfForInput = self;
    menuView.captureRectDidChange = ^(CGRect rect) {
        MFHUDAppDelegate *owner = weakSelfForInput;
        if (!owner || [owner isStopping]) return;
        BOOL empty = CGRectIsNull(rect) || CGRectIsEmpty(rect);
        owner.hudMenuWindow.hidden = empty;
        if (empty) [owner.inputBridge cancelAll];
    };
    [MFMenuUI setCollapseChangeHandler:^(BOOL collapsed) {
        // Resize only after the current ImGui frame has ended.
        dispatch_async(dispatch_get_main_queue(), ^{
            MFHUDAppDelegate *owner = weakSelfForInput;
            if (!owner || [owner isStopping]) return;
            [owner resizeMenuForOrientation:owner.hudOrientation initial:NO];
        });
    }];
    [self startObservingOrientation];

    // Let UIKit finish initial window layout before reading its native context.
    // Keep rendering stopped until both layer trees have been registered.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isStopping]) return;
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
                if (![self isStopping] && ![self.startupReport[@"state"] isEqual:@"ready"] &&
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
    if ([self isStopping] || self.hudOrientation == orientation) return;
    BOOL initial = self.hudOrientation == UIInterfaceOrientationUnknown;
    [self.inputBridge cancelAll];
    self.hudOrientation = orientation;
    CGFloat angle = orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI :
        (orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 :
         (orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2 : 0));
    CGRect fixed = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGSize logicalScreen = landscape ? CGSizeMake(fixed.size.height, fixed.size.width) : fixed.size;
    [self resizeMenuForOrientation:orientation initial:initial];
    self.drawingContent.bounds = (CGRect){CGPointZero, logicalScreen};
    self.drawingContent.center = CGPointMake(fixed.size.width / 2, fixed.size.height / 2);
    self.drawingContent.transform = CGAffineTransformMakeRotation(angle);
    self.drawingOverlay.frame = self.drawingContent.bounds;
    [self.hudMenuWindow layoutIfNeeded];
    [self.menuOverlay layoutIfNeeded];
    [self.drawingOverlay layoutIfNeeded];
    [CATransaction flush];
    MFHUDLogLine(@"HUD 方向=%ld menu frame=%@ content=%@ drawing=%@",
        (long)orientation, NSStringFromCGRect(self.hudMenuWindow.frame),
        NSStringFromCGRect(self.menuOverlay.bounds), NSStringFromCGRect(self.drawingOverlay.bounds));
    // Never leave a stale registered context silently owning an invisible input surface.
    if ((self.menuHost && [self nativeContextIDForWindow:self.hudMenuWindow] != self.menuHost.contextID) ||
        (self.drawingHost && [self nativeContextIDForWindow:self.drawingWindow] != self.drawingHost.contextID))
        [self failStartup:@"旋转后窗口 context 已变化，悬浮窗已退出，请重新启动悬浮窗。"];
}

- (void)refreshTargetBinding {
    if ([self isStopping]) return;
    MFGameReader *reader = [MFGameReader shared];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *expected = [MFOffsets shared].current.processName;
    pid_t pid = (pid_t)[defaults integerForKey:@"mf.target.pid"];
    NSString *identity = MFTargetIdentity(pid, expected);
    if (!identity) {
        pid = [MFModuleLocator pidForProcessName:expected];
        identity = MFTargetIdentity(pid, expected);
    }
    if (identity && [identity isEqual:self.boundTargetIdentity] && reader.targetTaskPort != MACH_PORT_NULL) return;
    if (self.boundTargetIdentity || reader.targetTaskPort != MACH_PORT_NULL) {
        mach_port_t oldPort = reader.targetTaskPort;
        reader.targetTaskPort = MACH_PORT_NULL;
        reader.rootObjectBase = reader.entityArrayBase = reader.lootArrayBase = 0;
        [MFReadBackend shared].modeFlag = NO;
        if (oldPort != MACH_PORT_NULL && oldPort != mach_task_self()) mach_port_deallocate(mach_task_self(), oldPort);
        [MFUEReader shared].libBase = 0;
        for (NSString *key in @[@"mf.game.libbase", @"mf.game.module", @"mf.game.pid"])
            [defaults removeObjectForKey:key];
        self.boundTargetIdentity = nil; self.boundTargetPID = 0;
        MFHUDLogLine(@"目标实例变化/退出：已释放旧端口并清除绝对基址");
    }
    if (!identity) return;
    NSString *error = nil;
    mach_port_t port = [MFKernel acquireTaskPortForPid:pid error:&error];
    if (port == MACH_PORT_NULL) return;
    // Close the PID-reuse race between the name check and port acquisition.
    int portPID = 0;
    if (pid_for_task(port, &portPID) != KERN_SUCCESS || portPID != pid ||
        ![identity isEqual:MFTargetIdentity(pid, expected)]) {
        mach_port_deallocate(mach_task_self(), port); return;
    }
    reader.targetTaskPort = port;
    [reader loadBasesFromDefaults];
    self.boundTargetPID = pid; self.boundTargetIdentity = identity;
    [defaults setInteger:pid forKey:@"mf.target.pid"];
    [defaults setObject:expected forKey:@"mf.target.name"];
    MFHUDLogLine(@"HUD 绑定已核验：pid=%d %@", pid, reader.calibrationSummary);
}

- (BOOL)isStopping {
    NSString *state = self.startupReport[@"state"];
    return self.exitRequested || [MFHUDControl exitRequested] ||
        [state isEqual:@"failed"] || [state isEqual:@"stopping"] || [state isEqual:@"stopped"];
}

- (void)resizeMenuForOrientation:(UIInterfaceOrientation)orientation initial:(BOOL)initial {
    if ([self isStopping]) return;
    [self.inputBridge cancelAll];
    UIWindow *window = self.hudMenuWindow;
    CGRect fixed = window.screen.fixedCoordinateSpace.bounds;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGFloat angle = orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI :
        (orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 :
         (orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2 : 0));
    CGSize panel = [MFMenuUI collapsed] ? CGSizeMake(56, 56) : CGSizeMake(348, 520);
    CGSize physical = landscape ? CGSizeMake(panel.height, panel.width) : panel;
    CGPoint center = window.center;
    if (initial) {
        CGSize logical = landscape ? CGSizeMake(fixed.size.height, fixed.size.width) : fixed.size;
        CGFloat dx = 24 + panel.width / 2 - logical.width / 2;
        CGFloat dy = 90 + panel.height / 2 - logical.height / 2;
        center = CGPointMake(CGRectGetMidX(fixed) + cos(angle)*dx - sin(angle)*dy,
                             CGRectGetMidY(fixed) + sin(angle)*dx + cos(angle)*dy);
    } else if (CGAffineTransformEqualToTransform(self.menuContent.transform,
                                                CGAffineTransformMakeRotation(angle))) {
        CGPoint anchor = [self.menuContent convertPoint:CGPointZero
                                      toCoordinateSpace:window.screen.fixedCoordinateSpace];
        center = CGPointMake(anchor.x + cos(angle)*panel.width/2 - sin(angle)*panel.height/2,
                             anchor.y + sin(angle)*panel.width/2 + cos(angle)*panel.height/2);
    }
    center.x = MIN(CGRectGetMaxX(fixed)-physical.width/2, MAX(physical.width/2, center.x));
    center.y = MIN(CGRectGetMaxY(fixed)-physical.height/2, MAX(physical.height/2, center.y));
    window.bounds = (CGRect){CGPointZero, physical};
    window.center = center;
    window.rootViewController.view.frame = window.bounds;
    // Set bounds/center/transform separately; frame is undefined for a rotated view.
    self.menuContent.bounds = (CGRect){CGPointZero, panel};
    self.menuContent.center = CGPointMake(physical.width/2, physical.height/2);
    self.menuContent.transform = CGAffineTransformMakeRotation(angle);
    self.menuOverlay.frame = self.menuContent.bounds;
    [window layoutIfNeeded]; [self.menuOverlay layoutIfNeeded];
    [self.menuOverlay requestRedraw];
    [CATransaction flush];
    MFHUDLogLine(@"菜单原生窗口尺寸=%@ collapsed=%d", NSStringFromCGSize(window.bounds.size), [MFMenuUI collapsed]);
    if (self.menuHost && [self nativeContextIDForWindow:window] != self.menuHost.contextID)
        [self failStartup:@"调整菜单尺寸后 context 已变化，已停止悬浮窗，请重新启动。"];
}

- (void)dealloc { [self.orientationObserver invalidate]; [self.targetTimer invalidate]; }

- (void)publishStartupState:(NSString *)state error:(NSString *)error {
    NSString *previous = self.startupReport[@"state"];
    BOOL terminal = [previous isEqual:@"failed"] || [previous isEqual:@"stopped"];
    if (terminal && ![state isEqual:previous]) return;
    if ((self.exitRequested || [MFHUDControl exitRequested] || [previous isEqual:@"stopping"]) &&
        ![state isEqual:@"stopping"] && ![state isEqual:@"stopped"]) return;
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
    if ([self isStopping]) return;
    [self.targetTimer invalidate];
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

#pragma mark - 退出

/*
 * 收到退出请求后的完整收尾。
 *
 * 关键点：退出动作由 HUD **自己**执行。
 * 控制台（mobile）无论用 kill(SIGTERM) 还是别的信号，都越不过 uid 权限；
 * 而进程结束自己不需要任何权限。
 */
- (void)shutdownForExitRequest {
    if (self.exitRequested) return;
    self.exitRequested = YES;

    MFHUDLogLine(@"HUD 退出：撤窗口 → 停渲染 → 结束进程（身份保留到确认死亡）（pid=%d）", getpid());
    [self publishStartupState:@"stopping" error:nil];
    [self.targetTimer invalidate];
    [MFMenuUI setCollapseChangeHandler:nil];
    [MFMenuUI setFrameRateApplier:nil];
    self.menuOverlay.firstFrameCompletion = nil;
    self.drawingOverlay.firstFrameCompletion = nil;

    [self.inputBridge cancelAll];
    self.menuOverlay.delegate = nil;
    self.drawingOverlay.delegate = nil;
    [self.menuOverlay stopRendering];
    [self.drawingOverlay stopRendering];
    [self.orientationObserver invalidate];
    self.orientationObserver = nil;

    self.hudMenuWindow.hidden = YES;
    self.drawingWindow.hidden = YES;
    self.hudMenuWindow = nil;
    self.drawingWindow = nil;
    self.menuHost = nil;
    self.drawingHost = nil;

    [MFHUDControl stopWatching];

    // 给窗口服务器一点时间把两个 context 撤下来（否则可能留下残影），
    // 然后再硬退出。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self publishStartupState:@"stopped" error:nil];
        MFHUDLogLine(@"HUD 进程结束（退出码 0）");
        _exit(EXIT_SUCCESS);
    });
    // 兜底：主队列万一被渲染卡住，1.2 秒后从后台线程强制退出。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ _exit(EXIT_SUCCESS); });
}

- (void)handleFirstFrame:(NSString *)key error:(NSString *)error {
    if ([self isStopping]) return;
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
