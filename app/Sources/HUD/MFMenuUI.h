//
//  MFMenuUI.h — 悬浮菜单（三页：主功能 / 外观 / 其他）
//
//  页签与控件对照《白米饭补充分析-启动窗口与功能.md》§4：
//    主功能  createFunctionSwitchesInView + createDistanceSlidersInView
//    外观    createFontSlidersInView + createAllColorSelectorsInView
//    其他    createMaterialStatSlidersInView + createDistanceFontSizeSliderInView
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../Render/MFOverlayView.h"

@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN

@interface MFMenuUI : NSObject <MFOverlayViewDelegate>

@property (nonatomic, weak, nullable) MFOverlayView *overlay;
@property (nonatomic, weak, nullable) MFOverlayView *drawingOverlay;

/// 由 AppDelegate 持有（delegate 是 weak）
+ (void)setGlobalVisible:(BOOL)visible;
+ (BOOL)globalVisible;

/// 收起面板窗口。独立的顶部灵动岛保持可见，轻点可恢复面板。
+ (BOOL)collapsed;
+ (void)setCollapseChangeHandler:(void (^_Nullable)(BOOL collapsed))handler;
+ (void)setCollapsed:(BOOL)collapsed;

/// 兼容旧调用：YES 收起实际窗口，NO 展开菜单。
+ (BOOL)fullPassthrough;
+ (void)setFullPassthrough:(BOOL)passthrough;

/// AppDelegate 注入：把刷新率同时应用到菜单层与绘制层。
+ (void)setFrameRateApplier:(void (^_Nullable)(NSInteger fps))applier;
/// 同时更新菜单、悬浮球和绘制层的截屏保护。
+ (void)setCaptureProtectionApplier:(void (^_Nullable)(BOOL enabled))applier;

@end

NS_ASSUME_NONNULL_END
