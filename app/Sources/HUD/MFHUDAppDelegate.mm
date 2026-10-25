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
#import "MFHUDTargetBinding.h"
#import "MFHUDPassiveState.h"
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
#import "../Read/MFExternalFeed.h"
#import "../Kernel/MFKernelBridge.h"
#import "../Kernel/MFPageTable.h"
#import "../Kernel/MFCrossProc.h"
#import <objc/message.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>
#include <errno.h>

// Validate the process instance before using a persisted PID or absolute base.
static NSString *MFTargetIdentity(pid_t pid, NSString *expectedName, NSString **error) {
    if (pid <= 0 || !expectedName.length) {
        if (error) *error = expectedName.length ? @"未找到目标进程" : @"当前档案未配置目标进程名";
        return nil;
    }
    char path[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) {
        if (error) *error = [NSString stringWithFormat:@"目标路径不可读：pid=%d errno=%d", pid, errno];
        return nil;
    }
    NSString *executable = [NSString stringWithUTF8String:path].stringByResolvingSymlinksInPath;
    if (![executable.lastPathComponent isEqual:expectedName]) {
        if (error) *error = [NSString stringWithFormat:@"目标进程名不匹配：%@ / %@", executable.lastPathComponent, expectedName];
        return nil;
    }
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info = {}; size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length < sizeof(info) ||
        info.kp_proc.p_pid != pid || info.kp_proc.p_starttime.tv_sec <= 0) {
        if (error) *error = [NSString stringWithFormat:@"目标启动时间无法确认：pid=%d errno=%d", pid, errno];
        return nil;
    }
    return [NSString stringWithFormat:@"%d|%@|%lld|%d", pid, executable,
        (long long)info.kp_proc.p_starttime.tv_sec, (int)info.kp_proc.p_starttime.tv_usec];
}

static MFHUD::BindingHooks MFMakeTargetBindingHooks(void) {
    return {
        [](const MFHUD::Target &target) {
            NSString *error = nil;
            uint32_t port = [MFKernel acquireTaskPortForPid:target.pid error:&error];
            return MFHUD::PortResult{port, error.UTF8String ?: ""};
        },
        [](uint32_t port, const MFHUD::Target &target) -> std::string {
            int portPID = 0;
            NSString *error = nil;
            NSString *identity = MFTargetIdentity(target.pid, [MFOffsets shared].current.processName, &error);
            NSString *expectedIdentity = [NSString stringWithUTF8String:target.identity.c_str()];
            if (pid_for_task(port, &portPID) != KERN_SUCCESS || portPID != target.pid)
                return "Acquired task port does not identify the selected PID";
            if (![identity isEqual:expectedIdentity]) return error.UTF8String ?: "Target instance changed while acquiring its port";
            return "";
        },
        [](uint32_t port, const MFHUD::Target &target) {
            NSString *error = nil;
            MFModuleInfo *module = [MFModuleLocator mainModuleForPid:target.pid borrowedTask:port error:&error];
            NSString *identity = MFTargetIdentity(target.pid, [MFOffsets shared].current.processName, NULL);
            if (![identity isEqual:[NSString stringWithUTF8String:target.identity.c_str()]])
                return MFHUD::ModuleResult{0, "", "Target instance changed during module lookup"};
            return MFHUD::ModuleResult{module.base, module.name.UTF8String ?: "", error.UTF8String ?: ""};
        },
        [](uint32_t port) {
            MFGameReader *reader = [MFGameReader shared];
            reader.targetTaskPort = port;
            [reader loadBasesFromDefaults];
        },
        [](uint64_t base) { [MFUEReader shared].libBase = base; },
        [] {
            MFGameReader *reader = [MFGameReader shared];
            reader.targetTaskPort = MACH_PORT_NULL;
            reader.rootObjectBase = reader.entityArrayBase = reader.lootArrayBase = 0;
            [MFReadBackend shared].modeFlag = NO;
            [MFUEReader shared].libBase = 0;
            for (NSString *key in @[@"mf.game.libbase", @"mf.game.module", @"mf.game.pid"])
                [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        },
        [](uint32_t port) {
            if (port != MACH_PORT_NULL && port != mach_task_self()) mach_port_deallocate(mach_task_self(), port);
        },
    };
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
/* [M5.124] 内核在 HUD 进程里常驻 */
@property (nonatomic) BOOL kernelViaKFD;   /* KFD 就绪后停用 task port 老路 */
- (void)bootstrapKernelInHUD;
- (void)writeHUDKernelLog:(NSString *)text;
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
@property (nonatomic, copy) NSString *lastBindingLog;
@property (nonatomic, copy) NSString *lastPassiveStateError;
@property (nonatomic) NSUInteger menuFirstFrameCompletions;
@property (nonatomic) NSUInteger drawingFirstFrameCompletions;
@end

@implementation MFHUDAppDelegate {
    MFHUD::TargetBinding _targetBinding;
}

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

    /*
     * ★ [M5.124] 内核搬到 HUD 进程。
     *
     * 为什么必须搬：
     *   主 App 在用户切到游戏时会被 jetsam 回收（游戏要吃 3~4 GB），进程一死，
     *   它持有的 KFD 会话就留下悬空 PPL 页，内核随即
     *     pmap_mark_page_as_ppl_page_internal: page still has mappings
     *   整机 panic（15:59:39 那次就是这个）。
     *   HUD 进程有窗口托管在 SpringBoard 上，不会被挂起 —— 所以内核应该活在
     *   这里：开一次、常驻、读数据、绘制，全在同一个进程里。
     */
    [self bootstrapKernelInHUD];

    __weak MFHUDAppDelegate *weakTargetOwner = self;
    self.targetTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakTargetOwner refreshTargetBinding];
        [weakTargetOwner writePassiveStateSnapshot];
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
    [self applyCaptureProtectionEnabled:[MFSettings shared].captureProtectionEnabled];
    __weak MFHUDAppDelegate *weakSelfForCapture = self;
    [MFMenuUI setCaptureProtectionApplier:^(BOOL enabled) {
        // Reparent content after the current ImGui build has ended.
        dispatch_async(dispatch_get_main_queue(), ^{
            MFHUDAppDelegate *owner = weakSelfForCapture;
            if (!owner || [owner isStopping]) return;
            [owner applyCaptureProtectionEnabled:enabled];
        });
    }];

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

- (void)applyCaptureProtectionEnabled:(BOOL)enabled {
    NSString *menuError = nil, *drawingError = nil;
    BOOL menuOK = [self.menuContent setCaptureProtectionEnabled:enabled error:&menuError];
    BOOL drawingOK = [self.drawingContent setCaptureProtectionEnabled:enabled error:&drawingError];
    if (!menuOK || !drawingOK) {
        // Optional capture protection must not stop the HUD or leave only one
        // surface hidden. Ordinary content remains available for screenshots.
        [self.menuContent setCaptureProtectionEnabled:NO error:NULL];
        [self.drawingContent setCaptureProtectionEnabled:NO error:NULL];
        [MFSettings shared].captureProtectionEnabled = NO;
        [[MFSettings shared] save];
        self.startupReport[@"captureProtectionError"] = menuError ?: drawingError ?: @"防录屏切换失败";
        MFHUDLogLine(@"防录屏切换失败，已回退关闭：menu=%@ drawing=%@", menuError ?: @"无", drawingError ?: @"无");
    } else {
        [self.startupReport removeObjectForKey:@"captureProtectionError"];
    }
    BOOL menuProtected = self.menuContent.captureProtectionEnabled;
    BOOL drawingProtected = self.drawingContent.captureProtectionEnabled;
    BOOL active = menuProtected && drawingProtected;
    self.startupReport[@"captureProtectionEnabled"] = @(active);
    NSMutableArray *surfaces = [NSMutableArray array];
    if (menuProtected) [surfaces addObjectsFromArray:@[@"menu", @"ball"]];
    if (drawingProtected) [surfaces addObject:@"drawing"];
    self.startupReport[@"captureProtectedSurfaces"] = surfaces;
    MFHUDLogLine(@"防录屏=%@ menu=%d drawing=%d（请求=%d）", active ? @"开" : @"关", menuProtected, drawingProtected, enabled);
    NSError *reportError = nil;
    if (self.startupToken && ![MFHUDStartupStatus writeReport:self.startupReport token:self.startupToken error:&reportError])
        MFHUDLogLine(@"防录屏状态写入失败：%@", reportError);
    [self writePassiveStateSnapshot];
}

#pragma mark - [M5.124] HUD 进程内的内核引导

static BOOL MFHUDLooksLikeGame(NSString *name, NSString *path) {
    NSString *hay = [NSString stringWithFormat:@"%@ %@",
                     name.lowercaseString ?: @"", path.lowercaseString ?: @""];
    for (NSString *k in @[@"dfm", @"tmgp", @"delta", @"三角洲"]) {
        if ([hay containsString:k]) return YES;
    }
    return NO;
}

- (void)writeHUDKernelLog:(NSString *)text {
    NSString *dir = @"/var/mobile/Media/mf-debug";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [(text ?: @"(nil)") writeToFile:[dir stringByAppendingPathComponent:@"mf-hud-kfd.txt"]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:NULL];
    MFHUDLogLine(@"内核引导报告已写入 /mf-debug/mf-hud-kfd.txt");
}

- (void)bootstrapKernelInHUD {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *log = [NSMutableString stringWithFormat:
            @"[M5.124] HUD 进程接管内核  pid=%d\n", getpid()];

        /* ① 开内核（只开一次；失败不重试，重试只会养脏 PUAF 页） */
        if (!mf_is_open()) {
            int rc = mf_kopen(1024, MF_PUAF_PHYSPUPPET,
                              MF_KREAD_SEM_OPEN, MF_KWRITE_SEM_OPEN);
            const char *err = mf_last_error();
            [log appendFormat:@"[kopen] rc=%d %@\n", rc,
             rc == 0 ? @"OK"
                     : [NSString stringWithFormat:@"失败：%s", err ? err : "(no detail)"]];
            if (rc != 0) {
                [log appendString:@"  → 不再重试。杀掉 HUD 与 App 后重开，或重启设备。\n"];
                [self writeHUDKernelLog:log];
                return;
            }
        } else {
            [log appendString:@"[kopen] 会话已存在，复用\n"];
        }

        /* ② 找游戏进程 */
        NSError *err = nil;
        NSArray<MFProcessInfo *> *list = [[MFKernel shared]
            enumerateProcessesWithRoute:MFEnumRouteNone error:&err];
        MFProcessInfo *game = nil;
        for (MFProcessInfo *p in list) {
            if (MFHUDLooksLikeGame(p.name, p.path)) { game = p; break; }
        }
        if (!game) {
            [log appendFormat:@"[find] 没找到游戏（枚举 %lu 个进程）\n",
             (unsigned long)list.count];
            [self writeHUDKernelLog:log];
            return;
        }
        [log appendFormat:@"[find] %@ pid=%d\n", game.name, game.pid];

        /* ③ 解析 pmap 并接管读取 */
        if (![[MFReadBackend shared] attachKFDPid:game.pid]) {
            [log appendString:@"[attach] attachKFDPid 失败\n"];
            [self writeHUDKernelLog:log];
            return;
        }
        uint64_t root = [MFReadBackend shared].kfdRoot;
        [log appendFormat:@"[attach] root=%#llx（读取后端已切到 KFD）\n",
         (unsigned long long)root];

        /* ④ 自证：读游戏 Mach-O 头 */
        uint64_t base = 0;
        if (mfpt_lowest_mapped_page(root, 0x100000000ULL, &base) != 0 || base == 0) {
            [log appendString:@"[base] 找不到最低映射页\n"];
            [self writeHUDKernelLog:log];
            return;
        }
        uint32_t magic = 0;
        int mrc = mfpt_read(root, base, &magic, sizeof(magic));
        [log appendFormat:@"[base] %#llx → magic=%#x (rc=%d)\n",
         (unsigned long long)base, magic, mrc];
        if (mrc != 0 || magic != 0xfeedfacf) {
            [log appendString:@"[base] 不是 Mach-O，放弃\n"];
            [self writeHUDKernelLog:log];
            return;
        }
        [MFUEReader shared].libBase = base;

        /* ⑤ GWorld 那一跳：成功就说明整条读取链在 HUD 进程里成立 */
        {
            const uint64_t slot = base + 0x178B44E0ULL;
            uint64_t gw = 0;
            int r = mfpt_read(root, slot, &gw, sizeof(gw));
            [log appendFormat:@"[gworld] read(%#llx) rc=%d val=%#llx\n",
             (unsigned long long)slot, r, (unsigned long long)gw];
            if (r != 0) {
                char trace[1024];
                int trc = mfpt_walk_trace(root, slot, trace, sizeof(trace));
                [log appendFormat:@"[gworld] 失败，walk trace rc=%d\n%s", trc, trace];
            }
        }

        [log appendString:@"\nRESULT OK —— 内核与读取都在常驻的 HUD 进程里\n"];
        [self writeHUDKernelLog:log];
        self.kernelViaKFD = YES;      /* [M5.125] 从此刻起不再碰 task port */
    });
}

- (void)refreshTargetBinding {
    if ([self isStopping]) return;

    /*
     * ★ [M5.125] KFD 接管之后，彻底停掉 task port 那条老路。
     *
     * 用户的问题很直接：「不是说不用 task port 吗，为什么还有这个？」
     * 对 —— 读内存只用 KFD 页表直读。这里的老绑定会做三件我们不要的事：
     *   ① 每秒尝试 task_for_pid（对正版游戏必然失败，白刷日志）
     *   ② 失败后调 unbindReader，把 MFUEReader.libBase 清成 0
     *   ③ 把 MFReadBackend.modeFlag 置 NO，干扰 KFD 读取状态
     * 所以 KFD 一旦就绪，这条定时绑定直接返回，什么都不碰。
     */
    if (self.kernelViaKFD) {
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults synchronize];
    NSString *expected = [MFOffsets shared].current.processName;
    pid_t pid = (pid_t)[defaults integerForKey:@"mf.target.pid"];
    NSString *identityError = nil;
    NSString *identity = MFTargetIdentity(pid, expected, &identityError);
    if (!identity) {
        pid = [MFModuleLocator pidForProcessName:expected];
        identity = MFTargetIdentity(pid, expected, &identityError);
    }
    MFHUD::Target target{pid, identity.UTF8String ?: "", identityError.UTF8String ?: ""};
    _targetBinding.tick(CACurrentMediaTime(), target, MFMakeTargetBindingHooks());
    const MFHUD::BindingState &state = _targetBinding.state();
    self.boundTargetPID = state.port ? state.target.pid : 0;
    self.boundTargetIdentity = state.port ? [NSString stringWithUTF8String:state.target.identity.c_str()] : nil;
    if (state.port) {
        [defaults setInteger:state.target.pid forKey:@"mf.target.pid"];
        [defaults setObject:expected forKey:@"mf.target.name"];
    }
    // A stable denial is recorded once; every retry still updates the passive
    // snapshot's attempt counters and uptime without flooding the HUD log.
    NSString *line = [NSString stringWithFormat:@"stage=%s pid=%d port=0x%x libBase=0x%llx error=%s",
        state.stage.c_str(), state.target.pid, state.port, (unsigned long long)state.base, state.error.c_str()];
    if (![line isEqual:self.lastBindingLog]) {
        self.lastBindingLog = line;
        MFHUDLogLine(@"[Binding] %@", line);
    }
}

- (void)writePassiveStateSnapshot {
    // Read cached getters only. Do not acquire a frame, resolve a chain, locate
    // a module, refresh the binding, or start a receiver on this path.
    const MFHUD::BindingState &binding = _targetBinding.state();
    MFExternalFeed *feed = [MFExternalFeed shared];
    MFGameReader *reader = [MFGameReader shared];
    MFReadBackend *backend = [MFReadBackend shared];
    MFDrawingLayer *drawing = self.drawingLayer;
    MFSettings *settings = [MFSettings shared];
    MFKernel *kernel = [MFKernel shared];
    MFCamera camera = {};
    BOOL hasCamera = [feed snapshotCamera:&camera];
    NSUInteger packets = feed.packetCount;
    NSTimeInterval age = feed.lastPacketAge;
    double fps = self.drawingOverlay.renderedFPS;
    NSDictionary *snapshot = @{
        @"role": @"hud",
        @"captureProtectionEnabled": @(self.menuContent.captureProtectionEnabled && self.drawingContent.captureProtectionEnabled),
        @"kernelState": @(kernel.state), @"kernelBase": @(kernel.kbase),
        @"startup": [self.startupReport copy] ?: @{},
        @"binding": @{
            @"stage": [NSString stringWithUTF8String:binding.stage.c_str()],
            @"error": [NSString stringWithUTF8String:binding.error.c_str()],
            @"targetPID": @(binding.target.pid),
            @"identity": [NSString stringWithUTF8String:binding.target.identity.c_str()],
            @"taskPort": @(binding.port), @"libBase": @(binding.base),
            @"module": [NSString stringWithUTF8String:binding.module.c_str()],
            @"portAttempts": @(binding.portAttempts), @"moduleAttempts": @(binding.moduleAttempts),
            @"lastAttemptUptime": @(binding.lastAttemptUptime),
        },
        @"reader": @{ @"targetTaskPort": @(reader.targetTaskPort), @"ready": @(reader.ready),
            @"gateOpen": @(backend.gateOpen), @"modeFlag": @(backend.modeFlag),
            @"libBase": @([MFUEReader shared].libBase) },
        @"feed": @{ @"running": @(feed.running), @"packetCount": @(packets),
            @"errorCount": @(feed.errorCount), @"fresh": @(feed.fresh),
            @"lastPacketAge": packets && isfinite(age) ? @(age) : NSNull.null,
            @"lastSequence": @(feed.lastSequence), @"hasCamera": @(hasCamera),
            @"cameraFOV": hasCamera && isfinite(camera.fov) ? @(camera.fov) : NSNull.null,
            @"entities": @([feed snapshotEntities].count) },
        @"drawing": @{ @"cameraOK": @(drawing.lastCameraOK),
            @"entities": @(drawing.lastEntityCount), @"loot": @(drawing.lastLootCount),
            @"hasCompletedFrame": @(self.drawingOverlay.hasCompletedFrame),
            @"renderedFPS": isfinite(fps) ? @(fps) : NSNull.null,
            @"masterEnabled": @(settings.masterEnabled), @"drawEnabled": @(settings.drawEnabled),
            @"renderSelfTest": @(settings.renderSelfTest) },
        @"firstFrameCompletions": @{ @"menu": @(self.menuFirstFrameCompletions),
            @"drawing": @(self.drawingFirstFrameCompletions) },
    };
    NSError *error = nil;
    if (![MFHUDPassiveState writeSnapshot:snapshot token:self.startupToken ?: @""
        directory:@"/var/mobile/Media/mf-debug" error:&error]) {
        if (![error.localizedDescription isEqual:self.lastPassiveStateError])
            MFHUDLogLine(@"HUD 被动状态写入失败：%@", error);
        self.lastPassiveStateError = error.localizedDescription;
    } else {
        self.lastPassiveStateError = nil;
    }
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

- (void)dealloc {
    [self.orientationObserver invalidate];
    [self.targetTimer invalidate];
    _targetBinding.reset(MFMakeTargetBindingHooks());
    [MFMenuUI setCaptureProtectionApplier:nil];
}

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
    [self writePassiveStateSnapshot];
}

- (void)failStartup:(NSString *)error {
    if ([self isStopping]) return;
    [self.targetTimer invalidate];
    [MFMenuUI setCaptureProtectionApplier:nil];
    _targetBinding.reset(MFMakeTargetBindingHooks());
    self.boundTargetPID = 0; self.boundTargetIdentity = nil;
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
    _targetBinding.reset(MFMakeTargetBindingHooks());
    self.boundTargetPID = 0; self.boundTargetIdentity = nil;

    MFHUDLogLine(@"HUD 退出：撤窗口 → 停渲染 → 结束进程（身份保留到确认死亡）（pid=%d）", getpid());
    [self publishStartupState:@"stopping" error:nil];
    [self.targetTimer invalidate];
    [MFMenuUI setCollapseChangeHandler:nil];
    [MFMenuUI setFrameRateApplier:nil];
    [MFMenuUI setCaptureProtectionApplier:nil];
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
    if ([key isEqual:@"menuFrame"]) self.menuFirstFrameCompletions++;
    if ([key isEqual:@"drawingFrame"]) self.drawingFirstFrameCompletions++;
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
