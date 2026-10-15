//
//  MFHUDAppDelegate.h — HUD 角色应用代理
//
//  由主进程 posix_spawn 自己、附 `-hud` 参数拉起（见 main.mm）。
//  职责：建两个窗口（菜单窗 + 透明绘制窗）并交给系统辅助窗口托管。
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@class MFHUDWindowHost;

/// HUD 窗口：对齐分析已证的实现
///   DrawingWindow 的 _isSystemWindow / _isSecure /
///   _shouldCreateContextAsSecure / _ignoresHitTest 均返回 1
///   HUDImguiWindow 的前三项同样返回 1
@interface MFHUDWindow : UIWindow
@property (nonatomic, assign) BOOL ignoresHitTestOverride;
@property (nonatomic, weak, nullable) UIView *interactiveView;
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
@end

NS_ASSUME_NONNULL_END
