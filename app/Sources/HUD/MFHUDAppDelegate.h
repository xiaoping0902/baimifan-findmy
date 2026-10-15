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
@property (nonatomic, strong, nullable) id drawingLayer;     // 同上

/*
 * ★ [M5.24] context 与托管控制器必须长期持有 —— 采纳另一位分析者的建议
 *
 * 原话：「建议给菜单窗、绘制窗分别保存 menuContext / drawingContext /
 *        menuHostingController / drawingHostingController，目的是让这些
 *        对象的生命周期覆盖整个悬浮窗显示期间。当前 hosting controller
 *        只放在函数的局部变量里，没有由项目中的对象明确持有，存在生命周期隐患。」
 *
 * 确实如此：原来 MFHostWindow 里的 controller 是局部变量，
 * 函数一返回就被释放 —— 而登记是登记到 controller 上的，
 * controller 没了，登记可能一并失效。
 */
@property (nonatomic, strong, nullable) id menuContext;
@property (nonatomic, strong, nullable) id drawingContext;
@property (nonatomic, strong, nullable) id menuHostingController;
@property (nonatomic, strong, nullable) id drawingHostingController;

/// [M5.24] 测试色块：跨 App 能看见它就说明显示链路通了
@property (nonatomic, strong, nullable) UIView *testColorView;

+ (BOOL)isHUDProcess;
@end

NS_ASSUME_NONNULL_END
