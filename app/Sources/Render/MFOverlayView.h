//
//  MFOverlayView.h — 透明 Metal 覆盖层
//
//  自建 CAMetalLayer（不用 MTKView），依据 docs/imgui-集成调研.md §1.3：
//    · 透明：isOpaque=NO + clearColor alpha=0
//    · 按需重绘（无交互时可停）
//    · 触摸只在菜单面板矩形内命中，其余区域透给底层
//
#import <UIKit/UIKit.h>
#import "MFImGuiContext.h"

NS_ASSUME_NONNULL_BEGIN

@class MFOverlayView;

@protocol MFOverlayViewDelegate <NSObject>
/// 每帧构建 UI。实现方在里面 ImGui::Begin/End，并把主面板矩形写回 overlay.captureRect
- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay;
@end

@interface MFOverlayView : UIView

@property (nonatomic, weak, nullable) id<MFOverlayViewDelegate> delegate;
@property (nonatomic, strong, readonly) MFImGuiContext *imgui;

/// YES = 接收触摸（菜单窗）；NO = 完全穿透（绘制窗）
@property (nonatomic, assign) BOOL interactive;

/// 触摸捕获区（视图坐标）。只有落在这个矩形里的触摸才会被本视图接住
@property (nonatomic, assign) CGRect captureRect;
@property (nonatomic, copy, nullable) void (^captureRectDidChange)(CGRect rect);
/// The HUD uses a BKS/AX input bridge, so UIKit must not enqueue duplicate touches.
@property (nonatomic, assign) BOOL usesExternalTouchInput;

/// 暂停渲染（省电）
@property (nonatomic, assign) BOOL paused;

/// 目标帧率（默认 60）
@property (nonatomic, assign) NSInteger preferredFPS;

/// HUD delays rendering until window hosting has been submitted.
@property (nonatomic, assign) BOOL automaticallyStartsRendering;
/// Main-thread callback after the first GPU completion, or an explicit error.
@property (nonatomic, copy, nullable) void (^firstFrameCompletion)(NSString *_Nullable error);
@property (nonatomic, assign, readonly) BOOL hasCompletedFrame;

- (instancetype)initWithFrame:(CGRect)frame interactive:(BOOL)interactive;

- (BOOL)startRenderingWithError:(NSString *_Nullable *_Nullable)err;
- (void)stopRendering;

@end

NS_ASSUME_NONNULL_END
