//
//  MFOverlayView.h — 透明 Metal 覆盖层
//
//  自建 CAMetalLayer（不用 MTKView），依据 docs/imgui-集成调研.md §1.3：
//    · 透明：isOpaque=NO + clearColor alpha=0
//    · 按需重绘（无交互时降频）
//    · 命中只在菜单面板内、且只在实际可交互控件上；空白区透给底层
//
#import <UIKit/UIKit.h>
#import "MFImGuiContext.h"

NS_ASSUME_NONNULL_BEGIN

@class MFOverlayView;

@protocol MFOverlayViewDelegate <NSObject>
/// 每帧构建 UI。实现方在里面 ImGui::Begin/End，并把主面板矩形写回 overlay.captureRect；
/// 菜单还要用 begin/add/endInteractiveRects 上报**真正可交互**的控件矩形。
- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay;
@end

@interface MFOverlayView : UIView

@property (nonatomic, weak, nullable) id<MFOverlayViewDelegate> delegate;
@property (nonatomic, strong, readonly) MFImGuiContext *imgui;

/// YES = 接收触摸（菜单窗）；NO = 完全穿透（绘制窗）
@property (nonatomic, assign) BOOL interactive;

/// 触摸捕获区（视图坐标）。只有落在这个矩形里的触摸才会被本视图接住
@property (nonatomic, assign) CGRect captureRect;
/// Published by the actual header layout; excludes buttons and the tab bar.
@property (nonatomic, assign) CGRect headerDragRect;
@property (nonatomic, copy, nullable) void (^captureRectDidChange)(CGRect rect);
/// The HUD uses a BKS/AX input bridge, so UIKit must not enqueue duplicate touches.
@property (nonatomic, assign) BOOL usesExternalTouchInput;

/// 整窗穿透。UIKit 和共享 HID 命中几何同时拒绝输入。
@property (nonatomic, assign) BOOL passthroughAll;

/// 共享输入几何：只查询有效、可见范围内的控件/标题矩形，无 UIKit 副作用。
/// passthroughAll 或非交互视图恒返回 NO；HID Began 与 UIKit 使用同一规则。
- (BOOL)acceptsInteractionAtPoint:(CGPoint)point;

/// ★ 可交互矩形集合（视图坐标）。
///   菜单每帧把每个真实控件的位置上报进来；落在集合外的点会
///   `hitTest` 返回 nil，事件因此穿透到下层 App。
///   矩形必须是有限的正尺寸，并裁剪到视图 bounds；调用者先按 child/popup
///   的可见视口裁剪。命中不再外扩，以免将已裁掉的区域重新变为可交互。
///   没上报过任何矩形时退化成「整个 captureRect 都可交互」（旧行为）。
- (void)beginInteractiveRects;
- (void)addInteractiveRect:(CGRect)rect;
- (void)endInteractiveRects;
@property (nonatomic, readonly) BOOL hasInteractiveRects;

/// 暂停渲染（省电）
@property (nonatomic, assign) BOOL paused;

/// 满帧率（默认 60）
@property (nonatomic, assign) NSInteger preferredFPS;
/// Screen capacity and the current (active/idle) bounded request. iOS may
/// choose a lower display cadence because of power, thermal or user policy.
@property (nonatomic, readonly) NSInteger maximumFPS;
@property (nonatomic, readonly) NSInteger effectiveFPS;
/// Successful GPU completions per second; not game FPS or physical scanout.
@property (nonatomic, readonly) double renderedFPS;
/// Actual overlay presentations measured from CAMetalDrawable.presentedTime.
/// Zero means no valid recent sample; this is not the underlying game's FPS.
/// The simulator does not expose drawable presentation timing and reports zero.
@property (nonatomic, readonly) double presentedFPS;
/// 空闲帧率（默认 0 = 不降频）。菜单设成 ~12：不交互时不占 GPU。
@property (nonatomic, assign) NSInteger idleFPS;
/// 一次交互之后保持满帧的秒数（默认 0.6）
@property (nonatomic, assign) NSTimeInterval activeWindow;
/// 主动要求继续满帧渲染（设置变更、外部状态变更时调用）
- (void)requestRedraw;

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
