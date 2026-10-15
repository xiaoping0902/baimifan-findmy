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

/// 由 AppDelegate 持有（delegate 是 weak）
+ (void)setGlobalVisible:(BOOL)visible;
+ (BOOL)globalVisible;

/// 面板「收起成小圆球」状态。收起后只有球体那一小块参与命中，
/// 其余位置照常穿透；点球体恢复面板。
+ (BOOL)collapsed;
+ (void)setCollapseChangeHandler:(void (^_Nullable)(BOOL collapsed))handler;
+ (void)setCollapsed:(BOOL)collapsed;

/// 兼容旧调用：YES 收起实际窗口，NO 展开菜单。
+ (BOOL)fullPassthrough;
+ (void)setFullPassthrough:(BOOL)passthrough;

/// AppDelegate 注入：把刷新率同时应用到菜单层与绘制层。
+ (void)setFrameRateApplier:(void (^_Nullable)(NSInteger fps))applier;

@end

NS_ASSUME_NONNULL_END
