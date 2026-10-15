//
//  MFImGuiContext.h — ImGui 上下文的 Objective-C 封装
//
//  设计要点（依据 docs/imgui-集成调研.md）：
//    · ImGui 1.93 动态字体：AddFontFromFileTTF 不传 GlyphRanges、不 Build()
//    · 后端支持多 context → 菜单窗与绘制窗各持一个，互不干扰
//    · 每帧顺序必须：设 DisplaySize/FramebufferScale → ImGui_ImplMetal_NewFrame(rp) → ImGui::NewFrame()
//    · RenderDrawData 必须夹在 render encoder 的 begin/end 之间
//
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface MFImGuiContext : NSObject

@property (nonatomic, strong, readonly) id<MTLDevice> device;
@property (nonatomic, strong, readonly) id<MTLCommandQueue> queue;

/// 每个宿主视图一个上下文
- (instancetype)initWithDevice:(id<MTLDevice>)device;

/// 初始化（CreateContext + ImGui_ImplMetal_Init + 皮肤 + 字体）
- (BOOL)setupWithError:(NSString *_Nullable *_Nullable)err;

/// iOS 风格皮肤
- (void)applyIOSStyle;

/// 加载中文字体。name 为 bundle 内资源名（不含扩展名）
- (BOOL)loadFontNamed:(NSString *)name size:(float)size;

/// 每帧：开始
- (void)beginFrameWithSize:(CGSize)size
                     scale:(CGFloat)scale
                descriptor:(MTLRenderPassDescriptor *)descriptor;

/// 每帧：构建 UI（在 begin 与 end 之间调用）
- (void)buildUI:(void (^)(void))block;

/// 每帧：结束并提交绘制
- (void)endFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          encoder:(id<MTLRenderCommandEncoder>)encoder;

/// 输入事件转发
- (void)addTouchX:(float)x y:(float)y down:(BOOL)down;
- (void)cancelTouch;
- (void)addScrollY:(float)dy;
- (void)addFocus:(BOOL)focused;

/// 当前上下文的 io 是否想捕获触摸
- (BOOL)wantsTouch;

- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
