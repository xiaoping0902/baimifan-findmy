//
//  MFHUDAppDelegate.h — HUD 角色应用代理
//
//  由主进程 posix_spawn 自己、附 `-hud` 参数拉起（见 main.mm）。
//  职责：建两个窗口（菜单窗 + 透明绘制窗）并交给系统辅助窗口托管。
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// HUD 窗口：对齐分析已证的实现
///   DrawingWindow 的 _isSystemWindow / _isSecure /
///   _shouldCreateContextAsSecure / _ignoresHitTest 均返回 1
///   HUDImguiWindow 的前三项同样返回 1
@interface MFHUDWindow : UIWindow
@property (nonatomic, assign) BOOL ignoresHitTestOverride;
@end

@interface MFHUDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong, nullable) UIWindow *hudMenuWindow;
@property (nonatomic, strong, nullable) UIWindow *drawingWindow;
@property (nonatomic, strong, nullable) id menuController;   // 强引用，delegate 是 weak
+ (BOOL)isHUDProcess;
@end

NS_ASSUME_NONNULL_END
