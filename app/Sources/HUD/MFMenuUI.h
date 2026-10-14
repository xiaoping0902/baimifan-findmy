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

@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN

@interface MFMenuUI : NSObject

@property (nonatomic, weak, nullable) MFOverlayView *overlay;

/// 由 AppDelegate 持有（delegate 是 weak）
+ (void)setGlobalVisible:(BOOL)visible;
+ (BOOL)globalVisible;

@end

NS_ASSUME_NONNULL_END
