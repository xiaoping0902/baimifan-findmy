//
//  MFHUDAppDelegate.h — HUD 角色应用代理
//
//  由主进程 posix_spawn 自己、附 `-hud` 参数拉起（见 main.mm）。
//  职责：建两个窗口（菜单窗 + 透明绘制窗）并交给系统辅助窗口托管。
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@class MFHUDWindowHost;

/// Interactive HUD window. Its native surface is limited to the visible panel.
@interface MFHUDWindow : UIWindow
@property (nonatomic, weak, nullable) UIView *interactiveView;
@end

/// Display-only window: never participates in hit testing or key focus, including
/// while UIWindow's superclass initializer is creating its native context.
@interface MFHUDDrawingWindow : MFHUDWindow
@end

/// Menu input is observed by MFHUDInputBridge while the original system touch
/// goes to the lower app. This policy is fixed before native context creation.
@interface MFHUDSharedTouchWindow : MFHUDWindow
@end

@interface MFHUDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong, nullable) UIWindow *hudMenuWindow;
@property (nonatomic, strong, nullable) UIWindow *drawingWindow;
@property (nonatomic, strong, nullable) id menuController;   // 强引用，delegate 是 weak
@property (nonatomic, strong, nullable) id drawingLayer;     // 同上

/// Each owner retains one layer context and its hosting controller together.
@property (nonatomic, strong, nullable) MFHUDWindowHost *menuHost;
@property (nonatomic, strong, nullable) MFHUDWindowHost *drawingHost;

/// [M5.24] 测试色块：跨 App 能看见它就说明显示链路通了
@property (nonatomic, strong, nullable) UIView *testColorView;

+ (BOOL)isHUDProcess;

/// 收到退出请求（控制台通知 / 看门狗 / 菜单「退出」按钮）后：
/// 停渲染 → 撤窗口 → 删 PID 文件 → 结束**本进程**。
/// 之所以由 HUD 自己退：控制台是 mobile，给 root 子进程发信号会被内核拒绝。
- (void)shutdownForExitRequest;

@end

NS_ASSUME_NONNULL_END
