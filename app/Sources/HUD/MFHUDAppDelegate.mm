//
//  MFHUDAppDelegate.mm — HUD 角色（实现）
//
#import "MFHUDAppDelegate.h"
#import "MFHUDApplication.h"
#import "MFHUDWindowHost.h"
#import "MFHUDStartupStatus.h"
#import "MFHUDInputBridge.h"
#import "MFHUDIslandView.h"
#import "MFMenuPanel.h"
#include "MFHUDFloatingLayout.h"
#import "MFHUDCaptureShieldView.h"
#import "MFHUDControl.h"
#import "MFHUDTargetBinding.h"
#import "MFHUDPassiveState.h"
#import <mach/mach.h>
#include <signal.h>
#include <stdlib.h>
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
        /*
         * acquire —— [M5.207] 端口路已移除。
         *
         * 状态机的第一阶段本来要拿目标 task port。现在读取由 KFD 页表直读承担
         * （attachKFDPid 时一次性解析 pmap 根表），端口不再出现在任何读取路径上。
         * 这里如实返回失败与原因，而不是伪造一个 0 端口让状态机以为"拿到了"。
         *
         * KFD 就绪后 refreshTargetBinding 会提前返回，走不到这里；
         * 这条分支只在 KFD 还没打开时出现，用来把"为什么没数据"解释清楚。
         */
        [](const MFHUD::Target &target) {
            (void)target;
            return MFHUD::PortResult{0,
                "task_for_pid 已在 M5.207 停用：读取由 KFD 页表接管（端口路不再参与）"};
        },
        [](uint32_t port, const MFHUD::Target &target) -> std::string {
            (void)port; (void)target;
            return "端口校验不再适用：读取链上没有 task port";
        },
        [](uint32_t port, const MFHUD::Target &target) {
            (void)port;
            NSString *error = nil;
            MFModuleInfo *module = [MFModuleLocator mainModuleForPidViaKFD:target.pid error:&error];
            NSString *identity = MFTargetIdentity(target.pid, [MFOffsets shared].current.processName, NULL);
            if (![identity isEqual:[NSString stringWithUTF8String:target.identity.c_str()]])
                return MFHUD::ModuleResult{0, "", "Target instance changed during module lookup"};
            return MFHUD::ModuleResult{module.base, module.name.UTF8String ?: "", error.UTF8String ?: ""};
        },
        [](uint32_t port) {
            (void)port;
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
            (void)port;
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
@property (nonatomic, strong) NSTimer *liveReadTimer;   /* [M5.128] 持续读取 */
/* [M5.135] 当前绑定：游戏重启会换 pid + 换 pmap，root 不能只在 attach 时捕获一次 */
@property (nonatomic) uint64_t liveRoot;
@property (nonatomic) int livePid;
@property (nonatomic) int liveFailStreak;
- (void)bootstrapKernelInHUD;
- (void)writeHUDKernelLog:(NSString *)text;
- (void)startLiveReadTimerWithRoot:(uint64_t)root;
- (BOOL)rebindLiveTargetWithLog:(NSMutableString *)log;
@property (nonatomic, strong) MFOverlayView *menuOverlay;
@property (nonatomic, strong) MFOverlayView *drawingOverlay;
@property (nonatomic, strong) NSMutableDictionary *startupReport;
@property (nonatomic, copy) NSString *startupToken;
@property (nonatomic, strong) MFHUDInputBridge *inputBridge;
@property (nonatomic, strong) MFHUDCaptureShieldView *menuContent;
@property (nonatomic, strong) MFHUDCaptureShieldView *drawingContent;
@property (nonatomic, strong) MFHUDWindow *islandWindow;
@property (nonatomic, strong) MFHUDWindowHost *islandHost;
@property (nonatomic, strong) MFHUDCaptureShieldView *islandContent;
@property (nonatomic, strong) MFHUDIslandView *islandView;
@property (nonatomic) NSUInteger presentationGeneration;
@property (nonatomic) BOOL menuTransitioning;
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

    // The island owns only its small capsule surface, even while the panel is
    // expanded. A separate bounded window keeps the rest of the screen free.
    CGSize islandSize = [MFHUDIslandView preferredSize];
    MFHUDWindow *islandWin = [[MFHUDWindow alloc] initWithFrame:(CGRect){CGPointZero, islandSize}];
    islandWin.windowLevel = 10000011.0;
    islandWin.backgroundColor = UIColor.clearColor;
    islandWin.opaque = NO;
    UIViewController *islandVC = [[MFHUDFixedRootController alloc] init];
    islandVC.view.backgroundColor = UIColor.clearColor;
    islandWin.rootViewController = islandVC;
    islandVC.view.frame = islandWin.bounds;
    self.islandWindow = islandWin;
    self.islandContent = [[MFHUDCaptureShieldView alloc] initWithFrame:islandVC.view.bounds error:&captureError];
    if (!self.islandContent) { [self failStartup:captureError]; return YES; }
    [islandVC.view addSubview:self.islandContent];
    self.islandView = [[MFHUDIslandView alloc] initWithFrame:(CGRect){CGPointZero, islandSize}];
    [self.islandContent.contentView addSubview:self.islandView];
    islandWin.interactiveView = self.islandContent;
    islandWin.hidden = NO;
    [self.islandView setExpanded:![MFMenuUI collapsed] animated:NO];
    __weak MFHUDIslandView *weakStatsIsland = self.islandView;
    MFMenuPanelSetStatsChangeHandler(^(int real, int bot, int loot, BOOL cameraOK) {
        [weakStatsIsland updateRealCount:real botCount:bot cameraValid:cameraOK];
    });
    /*
     * ★ [M5.134] 启动时强制关掉防录屏，并清掉持久化的开关。
     *
     * 上一次卡死时开关可能已经被存成 YES，如果启动还照它执行，悬浮窗会每次
     * 启动就卡死 —— 用户只能重启设备。这里直接清零，保证进来一定是关闭状态。
     */
    if ([MFSettings shared].captureProtectionEnabled) {
        [MFSettings shared].captureProtectionEnabled = NO;
        [[MFSettings shared] save];
        MFHUDLogLine(@"[M5.134] 已清除上次持久化的防录屏开关（该功能暂停使用）");
    }
    [self applyCaptureProtectionEnabled:NO];
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
        // Touch presentation follows the hardware refresh capability. Drawing
        // retains its configured budget independently of the menu animation.
        menuView.preferredFPS = MAX(60, UIScreen.mainScreen.maximumFramesPerSecond);
        menuView.idleFPS = 12;
        drawView.preferredFPS = rate;
        __weak MFHUDAppDelegate *weakSelfForFPS = self;
        [MFMenuUI setFrameRateApplier:^(NSInteger fps) {
            MFHUDAppDelegate *owner = weakSelfForFPS;
            owner.menuOverlay.preferredFPS = MAX(60, UIScreen.mainScreen.maximumFramesPerSecond);
            owner.drawingOverlay.preferredFPS = fps;
            MFHUDLogLine(@"绘制刷新率 → %ld；菜单交互跟随屏幕", (long)fps);
        }];
        MFHUDLogLine(@"帧率：菜单 %ld/空闲 12，绘制 %ld", (long)menuView.preferredFPS, (long)rate);
    }

    self.inputBridge = [[MFHUDInputBridge alloc] initWithOverlay:menuView window:menuWin];
    self.islandView.usesExternalTouchInput = YES;
    self.inputBridge.auxiliaryView = self.islandView;
    __weak MFHUDAppDelegate *weakIslandOwner = self;
    self.inputBridge.auxiliaryPressHandler = ^(BOOL pressed) {
        [weakIslandOwner.islandView setPressed:pressed animated:YES];
    };
    void (^activateIsland)(void) = ^{
        MFHUDAppDelegate *owner = weakIslandOwner;
        if (!owner || [owner isStopping] || ![owner.startupReport[@"state"] isEqual:@"ready"]) return;
        [MFMenuUI setCollapsed:![MFMenuUI collapsed]];
    };
    self.inputBridge.auxiliaryActivationHandler = activateIsland;
    self.islandView.activationHandler = activateIsland;
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
        // Collapse owns its native animation and hides only on completion.
        // Keep the independent island active while the panel is paused.
        if (![MFMenuUI collapsed] && !owner.menuTransitioning) {
            owner.hudMenuWindow.hidden = empty;
            owner.inputBridge.menuInputEnabled = !empty;
            if (empty) [owner.inputBridge cancelAll];
        }
    };
    [MFMenuUI setCollapseChangeHandler:^(BOOL collapsed) {
        // Freeze the last complete Metal image before the next display tick;
        // UIKit can animate that surface without rebuilding a collapsed UI.
        MFHUDAppDelegate *currentOwner = weakSelfForInput;
        currentOwner.menuOverlay.paused = collapsed;
        currentOwner.inputBridge.menuInputEnabled = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            MFHUDAppDelegate *owner = weakSelfForInput;
            if (!owner || [owner isStopping]) return;
            [owner setMenuCollapsed:[MFMenuUI collapsed] animated:YES];
        });
    }];
    MFMenuPanelSetPresentationChangeHandler(^{
        dispatch_async(dispatch_get_main_queue(), ^{
            MFHUDAppDelegate *owner = weakSelfForInput;
            if (!owner || [owner isStopping]) return;
            [owner resizeMenuForOrientation:owner.hudOrientation initial:NO];
        });
    });
    [self startObservingOrientation];

    // Let UIKit finish initial window layout before reading its native context.
    // Keep rendering stopped until all three layer trees have been registered.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isStopping]) return;
        @try {
            [self.hudMenuWindow layoutIfNeeded];
            [self.drawingWindow layoutIfNeeded];
            [self.islandWindow layoutIfNeeded];
            [self layoutIslandForOrientation:self.hudOrientation];
            [CATransaction flush];
            MFHUDLogLine(@"---- 准备菜单、绘制与灵动岛窗口 context 与托管 ----");
            MFHUDLogLine(@"connectedScenes=%lu，menu bounds=%@，drawing bounds=%@",
                         (unsigned long)app.connectedScenes.count,
                         NSStringFromCGRect(menuView.bounds), NSStringFromCGRect(drawView.bounds));
            Class contextClass = NSClassFromString(@"CAContext");
            Class hostingClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
            uint32_t nativeMenu = [self nativeContextIDForWindow:self.hudMenuWindow];
            uint32_t nativeDrawing = [self nativeContextIDForWindow:self.drawingWindow];
            uint32_t nativeIsland = [self nativeContextIDForWindow:self.islandWindow];
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
            self.islandHost = [[MFHUDWindowHost alloc] initWithLayer:self.islandWindow.layer
                nativeContextID:nativeIsland level:self.islandWindow.windowLevel
                contextClass:contextClass hostingClass:hostingClass];
            NSString *error = nil;
            if (!nativeIsland || ![self.islandHost registerWithError:&error]) {
                [self failStartup:[@"灵动岛窗口：" stringByAppendingString:error ?: @"未取得原生 context"]];
                return;
            }
            self.startupReport[@"islandContextID"] = @(self.islandHost.contextID);
            self.startupReport[@"islandRegistered"] = @YES;
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
    self.presentationGeneration++;
    [self.menuOverlay.layer removeAllAnimations];
    self.menuOverlay.transform = CGAffineTransformIdentity;
    self.menuOverlay.alpha = 1;
    self.menuTransitioning = NO;
    self.hudOrientation = orientation;
    CGFloat angle = orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI :
        (orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 :
         (orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2 : 0));
    CGRect fixed = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGSize logicalScreen = landscape ? CGSizeMake(fixed.size.height, fixed.size.width) : fixed.size;
    [self resizeMenuForOrientation:orientation initial:initial];
    [self layoutIslandForOrientation:orientation];
    self.hudMenuWindow.hidden = [MFMenuUI collapsed];
    self.menuOverlay.paused = [MFMenuUI collapsed];
    self.inputBridge.menuInputEnabled = ![MFMenuUI collapsed];
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
        (self.drawingHost && [self nativeContextIDForWindow:self.drawingWindow] != self.drawingHost.contextID) ||
        (self.islandHost && [self nativeContextIDForWindow:self.islandWindow] != self.islandHost.contextID))
        [self failStartup:@"旋转后窗口 context 已变化，悬浮窗已退出，请重新启动悬浮窗。"];
}

- (void)applyCaptureProtectionEnabled:(BOOL)enabled {
    NSString *menuError = nil, *drawingError = nil, *islandError = nil;
    BOOL menuOK = [self.menuContent setCaptureProtectionEnabled:enabled error:&menuError];
    BOOL drawingOK = [self.drawingContent setCaptureProtectionEnabled:enabled error:&drawingError];
    BOOL islandOK = [self.islandContent setCaptureProtectionEnabled:enabled error:&islandError];
    if (!menuOK || !drawingOK || !islandOK) {
        // Optional capture protection must not stop the HUD or leave only one
        // surface hidden. Ordinary content remains available for screenshots.
        [self.menuContent setCaptureProtectionEnabled:NO error:NULL];
        [self.drawingContent setCaptureProtectionEnabled:NO error:NULL];
        [self.islandContent setCaptureProtectionEnabled:NO error:NULL];
        [MFSettings shared].captureProtectionEnabled = NO;
        [[MFSettings shared] save];
        self.startupReport[@"captureProtectionError"] = menuError ?: drawingError ?: islandError ?: @"防录屏切换失败";
        MFHUDLogLine(@"防录屏切换失败，已回退关闭：menu=%@ drawing=%@", menuError ?: @"无", drawingError ?: @"无");
    } else {
        [self.startupReport removeObjectForKey:@"captureProtectionError"];
    }
    BOOL menuProtected = self.menuContent.captureProtectionEnabled;
    BOOL drawingProtected = self.drawingContent.captureProtectionEnabled;
    BOOL islandProtected = self.islandContent.captureProtectionEnabled;
    BOOL active = menuProtected && drawingProtected && islandProtected;
    self.startupReport[@"captureProtectionEnabled"] = @(active);
    NSMutableArray *surfaces = [NSMutableArray array];
    if (menuProtected) [surfaces addObject:@"menu"];
    if (islandProtected) [surfaces addObject:@"island"];
    if (drawingProtected) [surfaces addObject:@"drawing"];
    self.startupReport[@"captureProtectedSurfaces"] = surfaces;
    MFHUDLogLine(@"防录屏=%@ menu=%d drawing=%d（请求=%d）", active ? @"开" : @"关", menuProtected, drawingProtected, enabled);
    NSError *reportError = nil;
    if (self.startupToken && ![MFHUDStartupStatus writeReport:self.startupReport token:self.startupToken error:&reportError])
        MFHUDLogLine(@"防录屏状态写入失败：%@", reportError);
    [self writePassiveStateSnapshot];
}

#pragma mark - [M5.124] HUD 进程内的内核引导

/*
 * [M5.128] 会话的"临终释放"。
 *
 * 用户的原话：「不应该是一直读取吗，然后进程退出了这个东西一起退出，这样才能持久」——
 * 完全正确。持久读取就必须一直开着会话；真正要防的是【进程被硬杀，来不及释放】，
 * 那样内核的 perfmon 会一直停在"被占用"，下一次 kopen 直接
 *     assertion failed: (kfd->perf.dev.fd > 0)
 * 所以这里挂三层兜底：atexit、SIGTERM/SIGINT/SIGHUP、以及退出菜单里的显式 kclose。
 */
static void MFHUDKernelAtExit(void)
{
    if (mf_is_open()) {
        mf_kclose();
    }
}

static void MFHUDKernelSignalCleanup(int sig)
{
    if (mf_is_open()) {
        mf_kclose();
    }
    _exit(128 + sig);
}

static void MFHUDInstallKernelCleanup(void)
{
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    atexit(MFHUDKernelAtExit);
    signal(SIGTERM, MFHUDKernelSignalCleanup);
    signal(SIGINT, MFHUDKernelSignalCleanup);
    signal(SIGHUP, MFHUDKernelSignalCleanup);
}

/*
 * [M5.135] 持续读取的"上一轮还没跑完"闸门。
 *
 * 3 秒一拍，但读 600 个 Actor 要上千次内核读；慢的时候一轮会超过 3 秒。
 * 不设闸门的话 global queue 会一拍一拍地堆上去，把内核锁的争用放大。
 * tryLock 失败就丢掉这一拍 —— 下一拍还有机会。
 */
static NSLock *MFHUDLiveReadLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

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
                /*
                 * [M5.128] 最常见的失败不是"参数不对"，而是上一次会话没死透：
                 *     assertion failed: (kfd->perf.dev.fd > 0) at perf.h:87
                 * 这种情况重试、换参数都无效，只能重启设备把 perfmon 清掉。
                 * 说清楚原因，别再让用户反复点。
                 */
                if (err && strstr(err, "perf.dev.fd") != NULL) {
                    [log appendString:
                        @"  → 内核被上一次会话占用（perfmon 独占）。\n"
                        @"    重试和换参数都没用，只能【重启设备】清掉。\n"
                        @"    以后请用悬浮窗菜单里的「退出」关闭，不要上滑硬杀。\n"];
                } else {
                    [log appendString:@"  → 不再重试。杀掉 HUD 与 App 后重开，或重启设备。\n"];
                }
                [self writeHUDKernelLog:log];
                return;
            }
            MFHUDInstallKernelCleanup();
        } else {
            [log appendString:@"[kopen] 会话已存在，复用\n"];
        }

        /*
         * ② 等游戏出现（[M5.131] 循环等待，不再一次落空就退出）。
         *
         * 用户的实际顺序经常是"先起悬浮窗、再开游戏"，之前那种写法会让整个
         * 引导直接结束，连持续读取都不会启动。现在内核开着，每 3 秒扫一次，
         * 最多等 3 分钟；游戏一出现就接上。
         */
        MFProcessInfo *game = nil;
        for (int attempt = 0; attempt < 60 && !game; attempt++) {
            NSString *err = nil;
            NSArray<MFProcessInfo *> *list = [[MFKernel shared]
                enumerateProcessesWithRoute:MFEnumRouteNone error:&err];
            for (MFProcessInfo *p in list) {
                if (MFHUDLooksLikeGame(p.name, p.path)) { game = p; break; }
            }
            if (game) {
                [log appendFormat:@"[find] %@ pid=%d（第 %d 次扫描）\n",
                 game.name, game.pid, attempt + 1];
                break;
            }
            if (attempt == 0) {
                [log appendFormat:@"[find] 还没看到游戏（%lu 个进程），每 3 秒重试，最多 3 分钟\n",
                 (unsigned long)list.count];
                [self writeHUDKernelLog:log];
            }
            usleep(3 * 1000 * 1000);
        }
        if (!game) {
            [log appendString:@"[find] 3 分钟内没等到游戏，引导结束（内核保持开启，重开悬浮窗即可）\n"];
            [self writeHUDKernelLog:log];
            return;
        }

        /* ③ 解析 pmap 并接管读取 */
        if (![[MFReadBackend shared] attachKFDPid:game.pid]) {
            [log appendString:@"[attach] attachKFDPid 失败\n"];
            [self writeHUDKernelLog:log];
            return;
        }
        uint64_t root = [MFReadBackend shared].kfdRoot;
        [log appendFormat:@"[attach] root=%#llx（读取后端已切到 KFD）\n",
         (unsigned long long)root];

        /*
         * ★ [M5.135] 就在这里停掉 task-port 那条老绑定。
         *
         * refreshTargetBinding 每秒跑一次，直到 kernelViaKFD 为真才返回；
         * 它的失败分支会执行 unbindReader：modeFlag = NO、libBase = 0。
         * 原来 kernelViaKFD 是在整个引导【最后】才置位的，于是 attach 成功
         * 之后到引导结束之前，只要定时器插进来一次，就会把刚设好的 libBase
         * 清零 —— 持续读取还活着（它捕获了 root），但绘制层的 gateOpen /
         * libBase 检查直接判死，表现是「有时画得出来，有时一片空白」。
         * 所以就绪即置位，不等日志和自检跑完。
         */
        self.kernelViaKFD = YES;
        self.livePid = game.pid;      /* [M5.135] 看门狗用它判断"pid 有没有变" */

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
        uint64_t gw = 0;
        {
            const uint64_t slot = base + 0x178B44E0ULL;
            int r = mfpt_read(root, slot, &gw, sizeof(gw));
            [log appendFormat:@"[gworld] read(%#llx) rc=%d val=%#llx\n",
             (unsigned long long)slot, r, (unsigned long long)gw];
            if (r != 0) {
                char trace[1024];
                int trc = mfpt_walk_trace(root, slot, trace, sizeof(trace));
                [log appendFormat:@"[gworld] 失败，walk trace rc=%d\n%s", trc, trace];
            }
        }

        /*
         * ⑥ [M5.133] 用验证过的链做一次自检：
         *   UWorld +0xF8 → ULevel +0x98 → Actors{data, num}
         *   AActor +0x180 → USceneComponent +0x168 → FEncVector
         */
        /*
         * 把链上每一步的结果提到块外：下面的 RESULT 行要按【实际读到了什么】
         * 来写，不能无条件写 OK（旧版无论 GWorld / Level / Actors 是否读通，
         * 都会写 RESULT OK 并启动持续读取，日志因此会骗人）。
         */
        BOOL actorChainOK = NO;
        uint64_t level = 0, actorsData = 0;
        int32_t num = 0, maxc = 0;
        int valid = 0;
        if (gw > 0x100000000ULL && gw < 0x8000000000ULL) {
            mfpt_read(root, gw + 0xF8, &level, sizeof(level));
            if (level) {
                mfpt_read(root, level + 0x98, &actorsData, sizeof(actorsData));
                mfpt_read(root, level + 0xA0, &num, sizeof(num));
                mfpt_read(root, level + 0xA4, &maxc, sizeof(maxc));
            }
            [log appendFormat:
                @"[chain] world=%#llx  level=%#llx  actors=%#llx  num=%d  max=%d\n",
             (unsigned long long)gw, (unsigned long long)level,
             (unsigned long long)actorsData, num, maxc];

            int shown = 0;
            for (int i = 0; i < num && i < 200 && actorsData; i++) {
                uint64_t a = 0, comp = 0;
                float v[3] = {0, 0, 0};
                uint32_t handler = 0;
                if (mfpt_read(root, actorsData + (uint64_t)i * 8, &a, sizeof(a)) != 0 || !a) continue;
                if (mfpt_read(root, a + 0x180, &comp, sizeof(comp)) != 0 || !comp) continue;
                if (mfpt_read(root, comp + 0x168, v, sizeof(v)) != 0) continue;
                mfpt_read(root, comp + 0x174, &handler, sizeof(handler));
                valid++;
                if (shown < 5 && v[0] != 0.0f) {
                    [log appendFormat:@"[actor %d] %#llx  pos=%.1f, %.1f, %.1f  handler=%u\n",
                     i, (unsigned long long)a, v[0], v[1], v[2], handler];
                    shown++;
                }
            }
            [log appendFormat:@"[actors] 有效=%d / %d（有效只表示三次读都成功，不代表坐标可信）\n",
             valid, num];
            actorChainOK = (level != 0 && actorsData != 0 && num > 0 && valid > 0);
        }

        if (actorChainOK) {
            [log appendFormat:@"\nRESULT OK —— 内核、读取、Actor 链都在常驻的 HUD 进程里"
                                @"（level=%#llx num=%d valid=%d）\n",
             (unsigned long long)level, num, valid];
        } else {
            [log appendString:
                @"\nRESULT PARTIAL —— 内核与 Mach-O 自检通过，但 Actor 链没有读到东西。\n"
                @"  这条日志不能当成「链已通」：往上翻 [chain] 行，看 level / actors / num 哪一步是 0。\n"];
        }
        [self writeHUDKernelLog:log];

        /* [M5.128] 会话不关，改成持续读取 */
        [self startLiveReadTimerWithRoot:root];
    });
}

/*
 * [M5.128] 持续读取：每 3 秒把 GWorld + 玩家链 + 坐标重新读一遍，写到
 * /mf-debug/mf-live.txt。这就是"一直读取"的形态 —— 会话开着，读循环跑着，
 * 只有进程被硬杀才会中断（那时靠 atexit/signal 兜底释放）。
 */
- (void)startLiveReadTimerWithRoot:(uint64_t)initialRoot {
    /*
     * ★ [M5.135] 这个方法是从 bootstrapKernelInHUD 的【后台队列】里调的。
     * NSRunLoop 不是线程安全的，从后台线程往 mainRunLoop 里塞 timer 属于
     * 未定义行为（可能不触发，也可能和 shutdown 里的 invalidate 撞车）。
     * 统一回主线程建。
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.liveReadTimer) return;
        self.liveRoot = initialRoot;
        __weak MFHUDAppDelegate *weakSelf = self;
        self.liveReadTimer = [NSTimer timerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (!mf_is_open()) { return; }
            MFHUDAppDelegate *me = weakSelf;
            if (!me) { return; }
            if (![MFHUDLiveReadLock() tryLock]) { return; }
            uint64_t root = me.liveRoot;
            if (root == 0) { [MFHUDLiveReadLock() unlock]; return; }

            NSMutableString *s = [NSMutableString string];
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.dateFormat = @"HH:mm:ss";
            NSString *stamp = [f stringFromDate:[NSDate date]];
            [s appendFormat:@"[%@] session=%@\n", stamp,
             mf_is_open() ? @"open" : @"closed"];

            uint64_t base = [MFUEReader shared].libBase;
            uint64_t gw = 0;
            int r = mfpt_read(root, base + 0x178B44E0ULL, &gw, sizeof(gw));
            [s appendFormat:@"  gworld rc=%d %#llx\n", r, (unsigned long long)gw];

            /*
             * ★ [M5.135] 目标失效看门狗。
             *
             * root 是 attach 那一刻从游戏 pmap 拿的。游戏一重启就换了 pid 和 pmap，
             * 旧 root 会稳定翻译失败 —— 以前这里只会每 3 秒打一行 rc=-11，永远不重连。
             * 现在连续两拍读不到就重新枚举进程；pid 变了才重挂，同一个 pid 只清计数，
             * 避免关卡加载时反复 attach。
             */
            if (r != 0 || gw == 0) {
                me.liveFailStreak = me.liveFailStreak + 1;
            } else {
                me.liveFailStreak = 0;
            }
            if (me.liveFailStreak >= 2) {
                [s appendFormat:@"  [rebind] 连续 %d 拍读不到 GWorld，检查目标\n",
                 me.liveFailStreak];
                if ([me rebindLiveTargetWithLog:s]) {
                    root = me.liveRoot;
                    base = [MFUEReader shared].libBase;
                    mfpt_read(root, base + 0x178B44E0ULL, &gw, sizeof(gw));
                    [s appendFormat:@"  [rebind] 新 gworld=%#llx base=%#llx\n",
                     (unsigned long long)gw, (unsigned long long)base];
                }
                me.liveFailStreak = 0;
            }

            /*
             * ★ [M5.133] 这里换成 SDK + 二进制双向验证过的链，不再用旧表的
             * 400/56/48/928（那组值在 +48 就断了）：
             *
             *   UWorld +0x0F8 → ULevel          （PersistentLevel）
             *   ULevel +0x098 → Actors.Data，+0x0A0 → Num，+0x0A4 → Max
             *   AActor +0x180 → RootComponent（USceneComponent）
             *   USceneComponent +0x168 → FEncVector{X,Y,Z,EncHandler@+0xC}
             *
             * 二进制侧证据：LDR[x,#0xF8] 15,270 处、与 [x,#0x98] 相邻 80 处、
             * [x,#0x98]+[x,#0xA0] 成对 2109 处。
             */
            uint64_t level = 0, actorsData = 0;
            int32_t num = 0, maxc = 0;
            if (gw) mfpt_read(root, gw + 0xF8, &level, sizeof(level));
            if (level) {
                mfpt_read(root, level + 0x98, &actorsData, sizeof(actorsData));
                mfpt_read(root, level + 0xA0, &num, sizeof(num));
                mfpt_read(root, level + 0xA4, &maxc, sizeof(maxc));
            }
            [s appendFormat:@"  world=%#llx  level=%#llx\n",
             (unsigned long long)gw, (unsigned long long)level];
            [s appendFormat:@"  actors=%#llx  num=%d  max=%d\n",
             (unsigned long long)actorsData, num, maxc];

            /* 遍历 Actors：每个取 RootComponent 的位置，并统计 EncHandler 是否非 0 */
            /*
             * ★ [M5.135] 三个指标全部重做，旧口径会骗人：
             *   ① handler 读失败时变量还是 0，被算进「未加密」；
             *   ② NaN 与 0.0f 比较不相等，能穿过 != 0 的过滤被当成有效坐标；
             *   ③ handler 是 FEncHandler{uint16 Index; int8 bEncrypted; ...}，
             *      「整体非 0」只说明 Index 有值 —— 它不是加密标志。
             * 另外：二进制侧已证坐标在内存里是明文（DecVector 只做原样拷贝），
             * encrypted 这个数只当参考，不要再拿它决定要不要解密。
             */
            int valid = 0, encrypted = 0, nonFinite = 0, shown = 0;
            for (int i = 0; i < num && i < 600 && actorsData; i++) {
                uint64_t a = 0;
                if (mfpt_read(root, actorsData + (uint64_t)i * 8, &a, sizeof(a)) != 0 || !a) {
                    continue;
                }
                uint64_t comp = 0;
                if (mfpt_read(root, a + 0x180, &comp, sizeof(comp)) != 0 || !comp) {
                    continue;
                }
                float v[3] = {0, 0, 0};
                /* [M5.143] 0x168 是 RelativeLocation（局部），改用 ComponentToWorld.Translation */
                if (mfpt_read(root, comp + 0x220, v, sizeof(v)) != 0) {
                    continue;
                }
                if (!isfinite(v[0]) || !isfinite(v[1]) || !isfinite(v[2])) {
                    nonFinite++;
                    continue;
                }

                uint32_t handler = 0;
                BOOL haveHandler =
                    (mfpt_read(root, comp + 0x174, &handler, sizeof(handler)) == 0);
                unsigned idx = haveHandler ? (handler & 0xFFFFu) : 0;        /* +0x00 Index     */
                unsigned enc = haveHandler ? ((handler >> 16) & 0xFFu) : 0;  /* +0x02 bEncrypted */

                valid++;
                if (enc) encrypted++;
                BOOL usable = (v[0] != 0.0f || v[1] != 0.0f || v[2] != 0.0f);

                /*
                 * [M5.143] 把「判断人机/队伍/骨骼」需要的数据全部落盘。
                 * 没有 Frida 也能拿到同样的东西：队伍(Pawn+0x10C0 → +0x108)、
                 * 人机标志(+0xE60)、Mesh(+0x3D0) 与骨数(Mesh+0xA18+8)。
                 */
                if (usable && shown < 40) {
                    uint64_t mesh = 0, bdata = 0, teamComp = 0;
                    uint32_t boneNum = 0, team = 0;
                    uint8_t ai = 0;
                    (void)mfpt_read(root, a + 0x3D0, &mesh, sizeof(mesh));
                    if (mesh) {
                        (void)mfpt_read(root, mesh + 0xA18, &bdata, sizeof(bdata));
                        (void)mfpt_read(root, mesh + 0xA18 + 8, &boneNum, sizeof(boneNum));
                        if (bdata == 0) boneNum = 0;
                    }
                    (void)mfpt_read(root, a + 0x10C0, &teamComp, sizeof(teamComp));
                    if (teamComp) {
                        (void)mfpt_read(root, teamComp + 0x108, &team, sizeof(team));
                    }
                    (void)mfpt_read(root, a + 0xE60, &ai, sizeof(ai));

                    /* [M5.154] 把装备槽的原始物品 ID 也写进日志 —— 不接 frida 也能核对头甲 */
                    char eq[96] = {0};
                    if (mesh) {
                        uint64_t ec = 0, slots = 0;
                        (void)mfpt_read(root, a + 0x24E0, &ec, sizeof(ec));
                        if (ec) (void)mfpt_read(root, ec + 0x1D8, &slots, sizeof(slots));
                        if (slots) {
                            uint8_t rawSlot[10 * 0x30];
                            size_t got = 0;
                            if (mfpt_read_partial(root, slots, rawSlot, sizeof(rawSlot), &got) == 0) {
                                size_t nSlot = got / 0x30;
                                int w = 0, cnt = 0;
                                for (size_t k = 0; k < nSlot && cnt < 3; k++) {
                                    uint64_t itemId = 0;
                                    memcpy(&itemId, rawSlot + k * 0x30, 8);
                                    if (itemId == 0) continue;
                                    w += snprintf(eq + w, sizeof(eq) - (size_t)w, "%s%llu",
                                                  cnt ? "/" : "", (unsigned long long)itemId);
                                    if (w < 0 || (size_t)w >= sizeof(eq)) break;
                                    cnt++;
                                }
                            }
                        }
                    }

                    [s appendFormat:
                     @"    A[%d] %#llx pos=%.1f,%.1f,%.1f idx=%u enc=%u team=%u ai=%u bone=%u eq=%s\n",
                     i, (unsigned long long)a, v[0], v[1], v[2], idx, enc,
                     team, (unsigned)ai, boneNum, eq];
                    shown++;
                }
            }
            [s appendFormat:@"  scan: valid=%d  encrypted=%d  nonFinite=%d  (num=%d)\n",
             valid, encrypted, nonFinite, num];

            /*
             * [M5.130] GWorld 结构 dump（只跑一次）。
             *
             * 玩家链 400/56/48/928 在这一版断在 +48（读到 0），说明偏移过期了。
             * 与其继续猜，不如把 GWorld 前 0x400 字节按 8 字节逐格读出来，
             * 并且标注每个指针"指向的对象首字段是否落在模块代码段里"
             * （是的话就是 UObject 的 vtable，那就是我们要找的成员）。
             */
            static BOOL dumped = NO;
            if (!dumped && gw > 0x100000000ULL && gw < 0x8000000000ULL) {
                dumped = YES;
                uint64_t modBase = base;
                uint64_t modEnd = base + 0x1296C000ULL;
                NSMutableString *d = [NSMutableString stringWithFormat:
                    @"GWorld = %#llx   module = %#llx..%#llx\n",
                    (unsigned long long)gw,
                    (unsigned long long)modBase, (unsigned long long)modEnd];
                for (uint64_t off = 0; off < 0x400; off += 8) {
                    uint64_t v = 0;
                    int rr = mfpt_read(root, gw + off, &v, sizeof(v));
                    if (rr != 0) {
                        [d appendFormat:@"  +%03llx  read-fail(rc=%d)\n",
                         (unsigned long long)off, rr];
                        continue;
                    }
                    BOOL isPtr = (v > 0x100000000ULL && v < 0x8000000000ULL && (v % 8) == 0);
                    if (!isPtr) {
                        [d appendFormat:@"  +%03llx  %#llx\n",
                         (unsigned long long)off, (unsigned long long)v];
                        continue;
                    }
                    uint64_t vt = 0;
                    int rv = mfpt_read(root, v, &vt, sizeof(vt));
                    BOOL obj = (rv == 0 && vt >= modBase && vt < modEnd);
                    [d appendFormat:@"  +%03llx  %#llx →[%#llx] %@\n",
                     (unsigned long long)off, (unsigned long long)v,
                     (unsigned long long)vt,
                     obj ? @"★UObject(vtable 在模块内)" : @""];
                }
                [d writeToFile:@"/var/mobile/Media/mf-debug/mf-gworld-dump.txt"
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];

                /*
                 * [M5.132] 再深一层：GWorld 里每个指针，读它的目标前 0x200 字节，
                 * 找真正的 TArray {ptr, num, cap}，且 num 在 [16, 20000]。
                 * Actors 数组通常有几百个元素，这一条就能把它筛出来。
                 */
                NSMutableString *deep = [NSMutableString stringWithFormat:
                    @"deep scan of GWorld %#llx  module %#llx..%#llx\n",
                    (unsigned long long)gw, (unsigned long long)modBase,
                    (unsigned long long)modEnd];
                for (uint64_t o1 = 0; o1 < 0x400; o1 += 8) {
                    uint64_t p1 = 0;
                    if (mfpt_read(root, gw + o1, &p1, sizeof(p1)) != 0) continue;
                    if (!(p1 > 0x100000000ULL && p1 < 0x8000000000ULL && p1 % 8 == 0)) continue;
                    for (uint64_t o2 = 0; o2 < 0x200; o2 += 8) {
                        uint64_t data = 0, tail = 0;
                        if (mfpt_read(root, p1 + o2, &data, sizeof(data)) != 0) continue;
                        if (mfpt_read(root, p1 + o2 + 8, &tail, sizeof(tail)) != 0) continue;
                        uint32_t num = (uint32_t)(tail & 0xffffffffu);
                        uint32_t cap = (uint32_t)((tail >> 32) & 0xffffffffu);
                        if (!(data > 0x100000000ULL && data < 0x8000000000ULL)) continue;
                        if (num < 16 || num > 20000 || cap < num || cap > 40000) continue;
                        uint64_t first = 0, vt = 0;
                        if (mfpt_read(root, data, &first, sizeof(first)) != 0) continue;
                        BOOL obj = (mfpt_read(root, first, &vt, sizeof(vt)) == 0 &&
                                    vt >= modBase && vt < modEnd);
                        [deep appendFormat:@"  world+%03llx → %#llx  +%03llx ARRAY data=%#llx num=%u cap=%u%@\n",
                         (unsigned long long)o1, (unsigned long long)p1,
                         (unsigned long long)o2, (unsigned long long)data, num, cap,
                         obj ? @"  ★元素是 UObject" : @""];
                    }
                }
                [deep writeToFile:@"/var/mobile/Media/mf-debug/mf-gworld-deep.txt"
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }

            NSString *dir = @"/var/mobile/Media/mf-debug";
            [s writeToFile:[dir stringByAppendingPathComponent:@"mf-live.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [MFHUDLiveReadLock() unlock];
        });
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.liveReadTimer forMode:NSRunLoopCommonModes];
        MFHUDLogLine(@"[M5.128] 持续读取已启动（3 秒一次）");
    });
}

/*
 * [M5.135] 目标失效后的重挂。
 *
 * 判据只看 pid：同一个 pid 说明游戏没重启，重挂没有意义（多半是世界还没加载完）。
 * 真的换了 pid 才走完整流程：枚举 → attach（重取 pmap 根表）→ 重新找模块基址 →
 * 校验 Mach-O 头 → 更新 livePid / liveRoot / MFUEReader.libBase。
 */
- (BOOL)rebindLiveTargetWithLog:(NSMutableString *)log {
    NSString *err = nil;
    NSArray<MFProcessInfo *> *list =
        [[MFKernel shared] enumerateProcessesWithRoute:MFEnumRouteNone error:&err];
    MFProcessInfo *game = nil;
    for (MFProcessInfo *p in list) {
        if (MFHUDLooksLikeGame(p.name, p.path)) { game = p; break; }
    }
    if (game == nil) {
        [log appendFormat:@"  [rebind] 没找到游戏进程（%@）\n", err ?: @"列表为空"];
        return NO;
    }
    if (game.pid == self.livePid) {
        [log appendFormat:@"  [rebind] pid=%d 没变，先不动（可能还在加载关卡）\n", game.pid];
        return NO;
    }
    /*
     * 先在"不动共享后端"的前提下把整条链验完，再提交。
     * 顺序反过来的话，attach 成功但后面校验失败，会留下
     * 「后端指向新进程、libBase 还是旧的」这种半吊子状态，绘制会读到垃圾。
     */
    uint64_t root = 0;
    char why[192] = {0};
    if (mf_pid_chain(game.pid, NULL, NULL, NULL, NULL, &root, why, sizeof(why)) != 0 || root == 0) {
        [log appendFormat:@"  [rebind] pid=%d 取 pmap 失败：%s\n", game.pid, why];
        return NO;
    }
    uint64_t base = 0;
    if (mfpt_lowest_mapped_page(root, 0x100000000ULL, &base) != 0 || base == 0) {
        [log appendString:@"  [rebind] 找不到模块基址\n"];
        return NO;
    }
    uint32_t magic = 0;
    if (mfpt_read(root, base, &magic, sizeof(magic)) != 0 || magic != 0xfeedfacf) {
        [log appendFormat:@"  [rebind] 基址 0x%llx 不是 Mach-O\n", (unsigned long long)base];
        return NO;
    }
    if (![[MFReadBackend shared] attachKFDPid:game.pid]) {
        [log appendFormat:@"  [rebind] attach pid=%d 失败\n", game.pid];
        return NO;
    }
    self.livePid = game.pid;
    self.liveRoot = root;
    [MFUEReader shared].libBase = base;
    [log appendFormat:@"  [rebind] 已重挂 pid=%d root=%#llx base=%#llx\n",
     game.pid, (unsigned long long)root, (unsigned long long)base];
    return YES;
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
        @"captureProtectionEnabled": @(self.menuContent.captureProtectionEnabled && self.drawingContent.captureProtectionEnabled && self.islandContent.captureProtectionEnabled),
        @"kernelState": @(kernel.state), @"kernelBase": @(kernel.kbase),
        @"startup": [self.startupReport copy] ?: @{},
        @"binding": @{
            /*
             * [M5.207] 端口路移除后，绑定状态由这两处共同表达：
             *   · KFD 就绪时：stage 写成 "ready-kfd"，kfdRoot/sessionIdentity 来自读取后端；
             *   · KFD 未就绪时：沿用状态机的 stage（通常是 "task-port"），
             *     其 error 会明确写出"task_for_pid 已停用"，而不是一个含糊的失败。
             * taskPort 字段保留但恒为 0 —— 旧判据（端口 > 0）已不再代表就绪，
             * 消费方必须改看 kfdRoot / sessionToken。
             */
            @"stage": self.kernelViaKFD && backend.gateOpen
                ? @"ready-kfd" : [NSString stringWithUTF8String:binding.stage.c_str()],
            @"error": self.kernelViaKFD && backend.gateOpen
                ? @"" : [NSString stringWithUTF8String:binding.error.c_str()],
            @"targetPID": @(binding.target.pid > 0 ? binding.target.pid : backend.kfdPid),
            @"identity": self.kernelViaKFD && backend.gateOpen
                ? (backend.sessionIdentity ?: @"")
                : [NSString stringWithUTF8String:binding.target.identity.c_str()],
            @"taskPort": @(binding.port), @"libBase": @(binding.base),
            @"kfdRoot": @(backend.kfdRoot), @"kfdPid": @(backend.kfdPid),
            /* [M5.209] 对局世代：换局时 +1。现场看它有没有跟上，就知道
             * "换局没被识别"这个 bug 是不是还活着。 */
            @"matchEpoch": @(backend.matchEpoch),
            @"sessionToken": @(backend.sessionToken),
            @"module": [NSString stringWithUTF8String:binding.module.c_str()],
            @"portAttempts": @(binding.portAttempts), @"moduleAttempts": @(binding.moduleAttempts),
            @"lastAttemptUptime": @(binding.lastAttemptUptime),
        },
        @"reader": @{ @"targetTaskPort": @(reader.targetTaskPort), @"ready": @(reader.ready),
            @"gateOpen": @(backend.gateOpen), @"modeFlag": @(backend.modeFlag),
            @"libBase": @([MFUEReader shared].libBase),
            @"kfdRoot": @(backend.kfdRoot), @"kfdPid": @(backend.kfdPid) },
        /*
         * [M5.207] 清痕自证：整场会话对内核的写入次数/字节数。
         * 读取只走页表，正确配置下这两个值恒为 0。现场拿到非 0 就说明
         * 有路径在写内核，必须查清楚是谁。
         */
        @"kernelWrites": @{ @"count": @(mf_kernel_write_count()),
            @"bytes": @(mf_kernel_write_bytes()) },
        /*
         * [M5.208] 触发与清痕：kopen 走完就意味着 libkfd 内部已执行 puaf_cleanup
         * （还原被改坏的页表项伪装）。cleanup=true + openMs>=0 合起来才是
         * "这一轮真的触发过、并且清过"的证据 —— 单看 UI 上的"已初始化"不够。
         */
        @"kernelInit": @{ @"cleanup": @(mf_kernel_cleanup_done() == 1),
            @"openMs": @(mf_kernel_open_ms()),
            @"puafPages": @(kernel.puafPages) },
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
    UIWindow *window = self.hudMenuWindow;
    CGRect fixed = window.screen.fixedCoordinateSpace.bounds;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGFloat angle = orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI :
        (orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 :
         (orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2 : 0));
    CGSize logical = landscape ? CGSizeMake(fixed.size.height, fixed.size.width) : fixed.size;
    CGSize panel = MFMenuPanelPreferredSize(logical);
    CGSize physical = landscape ? CGSizeMake(panel.height, panel.width) : panel;
    CGPoint center = window.center;
    if (initial) {
        center = CGPointMake(CGRectGetMidX(fixed), CGRectGetMidY(fixed));
    } else if (CGAffineTransformEqualToTransform(self.menuContent.transform,
                                                CGAffineTransformMakeRotation(angle))) {
        CGPoint anchor = [self.menuContent convertPoint:CGPointZero
                                      toCoordinateSpace:window.screen.fixedCoordinateSpace];
        center = CGPointMake(anchor.x + cos(angle)*panel.width/2 - sin(angle)*panel.height/2,
                             anchor.y + sin(angle)*panel.width/2 + cos(angle)*panel.height/2);
    }
    auto clamped = MFHUDFloating::ClampCenter({center.x, center.y},
        {physical.width, physical.height},
        {fixed.origin.x, fixed.origin.y, fixed.size.width, fixed.size.height});
    center = CGPointMake(clamped.x, clamped.y);
    window.bounds = (CGRect){CGPointZero, physical};
    window.center = center;
    window.rootViewController.view.frame = window.bounds;
    // Set bounds/center/transform separately; frame is undefined for a rotated view.
    self.menuContent.bounds = (CGRect){CGPointZero, panel};
    self.menuContent.center = CGPointMake(physical.width/2, physical.height/2);
    self.menuContent.transform = CGAffineTransformMakeRotation(angle);
    // UIKit may round the secure canvas to display pixels during rotation.
    // Finish its layout before sizing Metal; otherwise flexible autoresizing
    // can add a second pixel adjustment after the explicit panel assignment.
    [window layoutIfNeeded];
    [self.menuContent setNeedsLayout]; [self.menuContent layoutIfNeeded];
    const CGRect content = self.menuContent.contentView.bounds;
    self.menuOverlay.bounds = (CGRect){CGPointZero, content.size};
    self.menuOverlay.center = CGPointMake(CGRectGetMidX(content), CGRectGetMidY(content));
    [self.menuOverlay layoutIfNeeded];
    [self.menuOverlay requestRedraw];
    [CATransaction flush];
    if (self.menuHost && [self nativeContextIDForWindow:window] != self.menuHost.contextID)
        [self failStartup:@"调整菜单尺寸后 context 已变化，已停止悬浮窗，请重新启动。"];
}

- (void)layoutIslandForOrientation:(UIInterfaceOrientation)orientation {
    CGRect fixed = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    auto screen = MFHUDFloating::LogicalSize({fixed.size.width, fixed.size.height}, (int)orientation);
    CGSize size = [MFHUDIslandView preferredSize];
    CGFloat top = UIInterfaceOrientationIsLandscape(orientation) ? 12 :
        MAX(12, MIN(60, self.drawingWindow.safeAreaInsets.top + 6));
    auto logicalCenter = MFHUDFloating::IslandCenter(screen, {size.width, size.height}, top);
    auto center = MFHUDFloating::ToPhysical(logicalCenter,
        {fixed.origin.x, fixed.origin.y, fixed.size.width, fixed.size.height}, (int)orientation);
    auto physical = MFHUDFloating::PhysicalSize({size.width,size.height}, (int)orientation);
    UIWindow *window = self.islandWindow;
    window.bounds = CGRectMake(0,0,physical.width,physical.height);
    window.center = CGPointMake(center.x,center.y);
    window.rootViewController.view.frame = window.bounds;
    self.islandContent.bounds = (CGRect){CGPointZero,size};
    self.islandContent.center = CGPointMake(physical.width/2,physical.height/2);
    self.islandContent.transform = CGAffineTransformMakeRotation(MFHUDFloating::Angle((int)orientation));
    self.islandView.frame = (CGRect){CGPointZero,size};
    [window layoutIfNeeded];
    MFMenuPanelSetIslandCenter(CGPointMake(logicalCenter.x,logicalCenter.y));
}

- (void)setMenuCollapsed:(BOOL)collapsed animated:(BOOL)animated {
    if ([self isStopping]) return;
    [self.inputBridge cancelAll];
    self.inputBridge.menuInputEnabled = NO;
    [self.islandView setExpanded:!collapsed animated:animated];
    const NSUInteger generation = ++self.presentationGeneration;
    self.menuTransitioning = YES;
    self.menuOverlay.paused = collapsed;
    if (!collapsed) [self.menuOverlay requestRedraw];
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    CGAffineTransform compact = CGAffineTransformMakeTranslation(0, -12);
    compact = CGAffineTransformScale(compact, 0.94, 0.94);
    if (!collapsed && self.hudMenuWindow.hidden) {
        self.menuOverlay.alpha = 0;
        self.menuOverlay.transform = reduce ? CGAffineTransformIdentity : compact;
    }
    self.hudMenuWindow.hidden = NO;
    void (^changes)(void) = ^{
        self.menuOverlay.alpha = collapsed ? 0 : 1;
        self.menuOverlay.transform = collapsed && !reduce ? compact : CGAffineTransformIdentity;
    };
    void (^finished)(BOOL) = ^(BOOL completed) {
        if (generation != self.presentationGeneration || [self isStopping]) return;
        self.menuTransitioning = NO;
        self.hudMenuWindow.hidden = collapsed;
        self.menuOverlay.paused = collapsed;
        self.inputBridge.menuInputEnabled = !collapsed;
        if (!collapsed) [self.menuOverlay requestRedraw];
    };
    if (!animated || reduce) {
        [UIView animateWithDuration:animated ? 0.12 : 0 animations:changes completion:finished];
    } else {
        [UIView animateWithDuration:collapsed ? 0.22 : 0.38 delay:0
            usingSpringWithDamping:collapsed ? 1.0 : 0.88 initialSpringVelocity:0
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
            animations:changes completion:finished];
    }
}

- (void)dealloc {
    [self.orientationObserver invalidate];
    [self.targetTimer invalidate];
    _targetBinding.reset(MFMakeTargetBindingHooks());
    [MFMenuUI setCaptureProtectionApplier:nil];
    [MFMenuUI setCollapseChangeHandler:nil];
    [MFMenuUI setFrameRateApplier:nil];
    MFMenuPanelSetPresentationChangeHandler(nil);
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
    [MFMenuUI setCollapseChangeHandler:nil];
    [MFMenuUI setFrameRateApplier:nil];
    MFMenuPanelSetPresentationChangeHandler(nil);
    self.presentationGeneration++;
    _targetBinding.reset(MFMakeTargetBindingHooks());
    self.boundTargetPID = 0; self.boundTargetIdentity = nil;
    [self.inputBridge cancelAll];
    [self.menuOverlay stopRendering];
    [self.drawingOverlay stopRendering];
    self.hudMenuWindow.hidden = YES;
    self.drawingWindow.hidden = YES;
    self.islandWindow.hidden = YES;
    self.menuHost = nil;
    self.drawingHost = nil;
    self.islandHost = nil;
    [self publishStartupState:@"failed" error:error];
    /*
     * ★ [M5.135] 退出前必须显式释放内核。
     * _exit() 不跑 atexit，所以报告里那「三道兜底」在这条路径上一道都不生效；
     * 不关会话 = perfmon 被占住，下次 kopen 直接 perf.dev.fd > 0，只能重启设备。
     */
    if (mf_is_open()) {
        MFHUDLogLine(@"[M5.135] failStartup：先 kclose 再退出");
        mf_kclose();
    }
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

    /*
     * [M5.128] 退出前必须显式释放内核会话。
     * 这是"常驻 + 持久读取"能反复重开的唯一前提：只要走正常退出（菜单里的退出），
     * perfmon 就会被释放；只有硬杀（上滑 / jetsam）才需要重启设备。
     */
    if (self.liveReadTimer) {
        [self.liveReadTimer invalidate];
        self.liveReadTimer = nil;
    }
    if (mf_is_open()) {
        mf_kclose();
        MFHUDLogLine(@"[M5.128] 内核会话已释放（kclose）");
    }

    _targetBinding.reset(MFMakeTargetBindingHooks());
    self.boundTargetPID = 0; self.boundTargetIdentity = nil;

    MFHUDLogLine(@"HUD 退出：撤窗口 → 停渲染 → 结束进程（身份保留到确认死亡）（pid=%d）", getpid());
    [self publishStartupState:@"stopping" error:nil];
    [self.targetTimer invalidate];
    [MFMenuUI setCollapseChangeHandler:nil];
    [MFMenuUI setFrameRateApplier:nil];
    [MFMenuUI setCaptureProtectionApplier:nil];
    MFMenuPanelSetPresentationChangeHandler(nil);
    self.presentationGeneration++;
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
    self.islandWindow.hidden = YES;
    self.hudMenuWindow = nil;
    self.drawingWindow = nil;
    self.islandWindow = nil;
    self.menuHost = nil;
    self.drawingHost = nil;
    self.islandHost = nil;

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
