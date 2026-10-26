//
//  MFOverlayView.mm — 透明 Metal 覆盖层（实现）
//
#import "MFOverlayView.h"
#import "../HUD/MFHUDLog.h"
#import <QuartzCore/CAMetalLayer.h>
#import <TargetConditionals.h>
#include "MFPresentedFrameRate.h"
#include <cmath>
#include <atomic>
#include <memory>

struct MFOverlayFrameStats {
    std::atomic<uint64_t> completed{0};
    MFPresentedFrameRate presented;
};

/// 每帧上报的可交互矩形上限。菜单控件约 40 个，256 足够且不占内存。
static const NSUInteger kMFOverlayMaxInteractiveRects = 256;
// Reserve a credit before acquisition, then return it only on GPU completion
// (or discard). With three layer drawables this leaves one for the compositor.
static const long kMFOverlayFrameCredits = 2;

static BOOL MFValidInteractiveRect(CGRect rect) {
    return std::isfinite(rect.origin.x) && std::isfinite(rect.origin.y) &&
        std::isfinite(rect.size.width) && std::isfinite(rect.size.height) &&
        rect.size.width > 0 && rect.size.height > 0 &&
        std::isfinite(CGRectGetMaxX(rect)) && std::isfinite(CGRectGetMaxY(rect));
}

@interface MFOverlayView ()
/// 按「是否刚交互过」切换满帧率与空闲帧率
- (void)applyAdaptiveFrameRate;
- (NSInteger)screenMaximumFPS;
- (void)sampleCompletedFrames;
- (void)invalidateRenderingGeneration;
- (void)renderDrawable:(id<CAMetalDrawable>)drawable generation:(uint64_t)generation
                 size:(CGSize)size scale:(CGFloat)scale credits:(dispatch_semaphore_t)credits;
- (CGPoint)centerOfTouches:(NSSet<UITouch *> *)touches;
- (void)sendPos:(UITouch *)t down:(BOOL)down;
- (void)maybeRelease:(NSSet<UITouch *> *)touches;
@end

@implementation MFOverlayView {
    CADisplayLink *_link;
    UITouch *_primaryTouch;
    CGPoint _lastPrimaryPoint;
    CGPoint _lastTwoFingerCenter;
    BOOL _twoFingerActive;
    BOOL _ready;
    BOOL _firstFrameReported;
    BOOL _firstFramePending;
    BOOL _loggedMissingDrawable;
    unsigned _loggedDrawableLag;

    // These flags/counters are owned by main. Only nextDrawable runs on the
    // serial acquisition queue; it captures immutable size/generation values.
    dispatch_queue_t _drawableQueue;
    dispatch_semaphore_t _frameCredits;
    BOOL _rendering;
    BOOL _drawablePending;
    uint64_t _renderGeneration;

    // A slow acquisition still owns its slot and frame credit. A timeout can
    // diagnose the wait, but cannot cancel Metal or return that credit early.
    CFTimeInterval _drawablePendingAt;      // _drawablePending 置 YES 的时刻，0 = 没在途
    BOOL _loggedPendingDrawable;
    CFTimeInterval _lastTickAt;             // 最近一次 tick 的时刻
    dispatch_source_t _livenessTimer;       // 独立于 displayLink 的看门狗

    // ── 局部命中（穿透）──────────────────────────────────
    CGRect _interactiveRects[kMFOverlayMaxInteractiveRects];
    NSUInteger _interactiveRectCount;
    BOOL _rectsReportedOnce;
    BOOL _captureRectInitialized;

    // ── 自适应帧率 ──────────────────────────────────────
    NSTimeInterval _activeUntil;
    std::shared_ptr<MFOverlayFrameStats> _frameStats;
    CFTimeInterval _fpsSampleTime;
    uint64_t _fpsSampleCount;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.layer;
}

- (instancetype)initWithFrame:(CGRect)frame interactive:(BOOL)interactive {
    if ((self = [super initWithFrame:frame])) {
        _interactive = interactive;
        _preferredFPS = 60;
        _effectiveFPS = 60;
        _idleFPS = 0;                 // 0 = 不降频（绘制层保持稳定输出）
        _activeWindow = 0.6;
        _automaticallyStartsRendering = YES;
        _captureRect = CGRectNull;
        _headerDragRect = CGRectNull;
        _passthroughAll = NO;
        _drawableQueue = dispatch_queue_create("org.baimifan.hud.drawable", DISPATCH_QUEUE_SERIAL);
        _frameCredits = dispatch_semaphore_create(kMFOverlayFrameCredits);

        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clearsContextBeforeDrawing = NO;
        self.userInteractionEnabled = interactive;
        self.multipleTouchEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        CAMetalLayer *ml = self.metalLayer;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        ml.device = dev;
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ml.framebufferOnly = YES;
        ml.opaque = NO;
        ml.backgroundColor = [UIColor clearColor].CGColor;
        ml.allowsNextDrawableTimeout = YES;
        // nextDrawable can still block. It is called only on _drawableQueue.
        ml.maximumDrawableCount = 3;
        ml.presentsWithTransaction = NO;
        if (@available(iOS 16.0, *)) { /* drawableSize 在 layoutSubviews 里同步 */ }

        _imgui = [[MFImGuiContext alloc] initWithDevice:dev];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale ?: 2.0;
    CGSize px = CGSizeMake(std::ceil(self.bounds.size.width * scale),
                           std::ceil(self.bounds.size.height * scale));
    if (std::isfinite(px.width) && std::isfinite(px.height) && px.width > 0 && px.height > 0 &&
        !CGSizeEqualToSize(self.metalLayer.drawableSize, px)) {
        self.metalLayer.drawableSize = px;
        [self invalidateRenderingGeneration];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self layoutSubviews];
    if (self.window && self.automaticallyStartsRendering) {
        [self startRenderingWithError:NULL];
    } else if (!self.window) {
        [self stopRendering];
    }
}

#pragma mark - 渲染循环

- (BOOL)startRenderingWithError:(NSString **)err {
    NSAssert(NSThread.isMainThread, @"Overlay rendering is owned by main");
    if (!_ready) {
        NSString *e = nil;
        if (![self.imgui setupWithError:&e]) {
            if (err) *err = e;
            MFHUDLogLine(@"ImGui 初始化失败: %@", e);
            return NO;
        }
        _ready = YES;
    }
    // ImGui readiness and display-link liveness are separate. A view that has
    // left and rejoined its window must recreate the invalidated display link.
    if (_link) return YES;
    [self invalidateRenderingGeneration];
    [self.imgui resetFrameTime];
    _rendering = YES;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self requestRedraw];   // 首帧必须马上出来，不能被空闲降频拖住
    [self startLivenessWatchdog];
    NSLog(@"[MF][Overlay] 渲染已启动 (interactive=%d, %.0fx%.0f, 满帧%ld/空闲%ld)",
          self.interactive, self.bounds.size.width, self.bounds.size.height,
          (long)_preferredFPS, (long)_idleFPS);
    return YES;
}

/*
 * [M5.211] 渲染看门狗。
 *
 * 为什么必须有：displayLink 的回调一旦停（系统因为遮挡 / 场景切换把它暂停，
 * 或者 link 被失效），我们就没有任何机会再被调用 —— 所有"在 tick 里检查"的
 * 兜底都失去意义。所以活性检查必须挂在独立定时器上。
 *
 * 阈值 2 秒：正常帧间隔是 8~33ms，2 秒没有任何回调只可能是真停了。
 */
- (void)startLivenessWatchdog {
    if (_livenessTimer) return;
    _livenessTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
    if (!_livenessTimer) return;
    const uint64_t interval = (uint64_t)(0.5 * NSEC_PER_SEC);
    dispatch_source_set_timer(_livenessTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, (uint64_t)(50 * NSEC_PER_MSEC));
    __weak MFOverlayView *weakSelf = self;
    dispatch_source_set_event_handler(_livenessTimer, ^{
        MFOverlayView *owner = weakSelf;
        if (!owner || !owner->_rendering) return;
        const CFTimeInterval now = CACurrentMediaTime();
        /*
         * 先排掉"本来就不该出帧"的状态：暂停、隐藏、尚未挂到窗口、ImGui 未就绪。
         * 这些情况下 tick 被前面的守卫挡掉是设计如此，不是停摆 —— 不排掉的话
         * 看门狗会每 2 秒重建一次渲染循环，日志刷屏还白烧 CPU。
         */
        if (owner.paused || owner.hidden || !owner.window || owner.window.hidden || !owner->_ready) {
            owner->_lastTickAt = now;
            return;
        }
        // 还没开始 tick（刚启动）不算异常
        if (owner->_lastTickAt <= 0) return;
        if (now - owner->_lastTickAt < 2.0) return;

        MFHUDLogLine(@"%@ 渲染看门狗：displayLink %.1fs 无回调，重建渲染循环",
                     owner.interactive ? @"菜单" : @"绘制", now - owner->_lastTickAt);
        owner->_lastTickAt = now;
        if (owner->_link) {
            owner->_link.paused = NO;
            [owner->_link invalidate];
            owner->_link = nil;
        }
        // Replacing the display link does not cancel an outstanding Metal
        // acquisition. Its callback remains the sole owner of that slot.
        owner->_rendering = YES;
        NSString *error = nil;
        if (![owner startRenderingWithError:&error])
            MFHUDLogLine(@"%@ 渲染看门狗：重建失败 %@",
                         owner.interactive ? @"菜单" : @"绘制", error ?: @"");
    });
    dispatch_resume(_livenessTimer);
}

- (void)stopRendering {
    NSAssert(NSThread.isMainThread, @"Overlay rendering is owned by main");
    _rendering = NO;
    if (_livenessTimer) {
        dispatch_source_cancel(_livenessTimer);
        _livenessTimer = nil;
    }
    _lastTickAt = 0;
    [self invalidateRenderingGeneration];
    [_link invalidate];
    _link = nil;
}

- (void)invalidateRenderingGeneration {
    _renderGeneration++;
    _firstFrameReported = NO;
    _firstFramePending = NO;
    _hasCompletedFrame = NO;
    // Each generation owns a counter. Late GPU work can only increment its
    // retired counter, without queueing one main-thread block per frame.
    _frameStats = std::make_shared<MFOverlayFrameStats>();
    _fpsSampleTime = CACurrentMediaTime();
    _fpsSampleCount = 0;
    _renderedFPS = 0;
    _presentedFPS = 0;
    // Do not clear _drawablePending: the old driver's wait still occupies the
    // one acquisition slot, even across stop/resize/restart.
}

- (void)reportFirstFrameError:(NSString *)error {
    if (_firstFrameReported) return;
    _firstFrameReported = YES;
    _hasCompletedFrame = (error == nil);
    void (^completion)(NSString *) = self.firstFrameCompletion;
    self.firstFrameCompletion = nil;
    if (completion) completion(error);
}

- (void)tick:(CADisplayLink *)link {
    NSAssert(NSThread.isMainThread, @"Overlay ticks are owned by main");
    _lastTickAt = CACurrentMediaTime();
    if (!_rendering || self.paused || !self.window || self.window.hidden || self.hidden) return;
    if (!_ready) return;
    if (self.bounds.size.width < 1 || self.bounds.size.height < 1) return;

    [self applyAdaptiveFrameRate];
    [self sampleCompletedFrames];

    CAMetalLayer *ml = self.metalLayer;
    [self layoutSubviews];

    // Never clear a still-owned acquisition or signal its credit on timeout:
    // the delayed callback will run later and return/submit the same credit.
    // Releasing early queues more work behind the wait and inflates the GPU
    // budget every time a slow drawable eventually returns.
    if (_drawablePending && _drawablePendingAt > 0 && !_loggedPendingDrawable) {
        const CFTimeInterval elapsed = CACurrentMediaTime() - _drawablePendingAt;
        if (elapsed > 1.2) {
            _loggedPendingDrawable = YES;
            MFHUDLogLine(@"%@ drawable 在途 %.1fs，保留获取槽与帧信用并等待返回",
                         self.interactive ? @"菜单" : @"绘制", elapsed);
        }
    }

    if (_drawablePending || dispatch_semaphore_wait(_frameCredits, DISPATCH_TIME_NOW) != 0) return;
    _drawablePending = YES;
    _drawablePendingAt = CACurrentMediaTime();
    _loggedPendingDrawable = NO;
    uint64_t generation = _renderGeneration;
    CGSize size = self.bounds.size;
    CGSize pixels = ml.drawableSize;
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale ?: 2.0;
    dispatch_semaphore_t credits = _frameCredits;
    __weak MFOverlayView *weakSelf = self;
    dispatch_async(_drawableQueue, ^{
        @autoreleasepool {
            CFTimeInterval started = CACurrentMediaTime();
            id<CAMetalDrawable> drawable = nil;
            NSString *exceptionError = nil;
            @try { drawable = [ml nextDrawable]; }
            @catch (NSException *exception) {
                exceptionError = [NSString stringWithFormat:@"Metal drawable 获取异常：%@", exception.reason];
            }
            CFTimeInterval delay = CACurrentMediaTime() - started;
            dispatch_async(dispatch_get_main_queue(), ^{
                MFOverlayView *owner = weakSelf;
                if (!owner) { dispatch_semaphore_signal(credits); return; }
                owner->_drawablePending = NO;
                owner->_drawablePendingAt = 0;
                if (!owner->_rendering || generation != owner->_renderGeneration || owner.paused ||
                    !owner.window || owner.window.hidden || owner.hidden ||
                    !CGSizeEqualToSize(size, owner.bounds.size) ||
                    !CGSizeEqualToSize(pixels, owner.metalLayer.drawableSize)) {
                    dispatch_semaphore_signal(credits);
                    return;
                }
                if (exceptionError) {
                    dispatch_semaphore_signal(credits);
                    [owner reportFirstFrameError:exceptionError];
                    [owner stopRendering];
                    return;
                }
                if (delay > 0.06 && owner->_loggedDrawableLag++ < 8)
                    MFHUDLogLine(@"%@ drawable 获取 %.0fms（独立队列，主线程未等待）",
                        owner.interactive ? @"菜单" : @"绘制", delay * 1000);
                if (!drawable) {
                    dispatch_semaphore_signal(credits);
                    if (!owner->_loggedMissingDrawable) {
                        owner->_loggedMissingDrawable = YES;
                        MFHUDLogLine(@"%@：nextDrawable 为 nil，等待窗口合成器（drawableSize=%@）",
                            owner.interactive ? @"菜单" : @"绘制", NSStringFromCGSize(pixels));
                    }
                    return;
                }
                if (drawable.texture.width != (NSUInteger)pixels.width ||
                    drawable.texture.height != (NSUInteger)pixels.height) {
                    dispatch_semaphore_signal(credits);
                    return;
                }
                [owner renderDrawable:drawable generation:generation size:size scale:scale credits:credits];
            });
        }
    });
}

- (void)renderDrawable:(id<CAMetalDrawable>)drawable generation:(uint64_t)generation
                 size:(CGSize)size scale:(CGFloat)scale credits:(dispatch_semaphore_t)credits {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [self.imgui.queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:rp];
    if (!cb || !encoder) {
        dispatch_semaphore_signal(credits);
        [self reportFirstFrameError:cb ? @"Metal renderCommandEncoder 创建失败" : @"Metal commandBuffer 创建失败"];
        [self stopRendering];
        return;
    }
    [self.imgui beginFrameWithSize:size scale:scale descriptor:rp];
    [self.imgui buildUI:^{
        if (self.delegate) [self.delegate overlayBuildUI:self.imgui overlay:self];
    }];
    // UI actions may synchronously collapse/resize or stop the view. End the
    // CPU frame without presenting the drawable from the previous geometry.
    if (!_rendering || generation != _renderGeneration || self.paused ||
        !CGSizeEqualToSize(size, self.bounds.size)) {
        [self.imgui discardFrame];
        [encoder endEncoding];
        dispatch_semaphore_signal(credits);
        return;
    }
    [self.imgui endFrameWithCommandBuffer:cb encoder:encoder];
    [encoder endEncoding];
    std::shared_ptr<MFOverlayFrameStats> stats = _frameStats;
#if !TARGET_OS_SIMULATOR
    // The iPhoneSimulator SDK omits these MTLDrawable presentation APIs.
    // Keep its sample unavailable (0); GPU completions remain renderedFPS.
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        // The captured generation owns this sampler. Late callbacks after a
        // resize, pause or stop cannot change the active generation's value.
        stats->presented.Record(presented.presentedTime);
    }];
#endif
    [cb presentDrawable:drawable];
    BOOL reportFirstFrame = !_firstFrameReported && !_firstFramePending;
    if (reportFirstFrame) _firstFramePending = YES;
    __weak MFOverlayView *weakSelf = self;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_semaphore_signal(credits);
        if (completed.status == MTLCommandBufferStatusCompleted)
            stats->completed.fetch_add(1, std::memory_order_relaxed);
        if (!reportFirstFrame) return;
        NSString *error = completed.status == MTLCommandBufferStatusCompleted ? nil :
            (completed.error.localizedDescription ?: @"Metal 首帧执行失败");
        dispatch_async(dispatch_get_main_queue(), ^{
            MFOverlayView *owner = weakSelf;
            if (!owner || !owner->_rendering || generation != owner->_renderGeneration) return;
            owner->_firstFramePending = NO;
            [owner reportFirstFrameError:error];
            if (error) [owner stopRendering];
        });
    }];
    [cb commit];
}

#pragma mark - 触摸：主触点策略（调研 §2.3）

// This is local geometry, shared by UIKit and HID. Cross-process delivery is
// still a window-server behavior; a local nil hit alone cannot prove it.
- (BOOL)acceptsInteractionAtPoint:(CGPoint)point {
    if (!self.interactive || self.passthroughAll || !std::isfinite(point.x) ||
        !std::isfinite(point.y) || !MFValidInteractiveRect(self.bounds)) return NO;
    CGRect capture = self.captureRect;
    if (!MFValidInteractiveRect(capture)) return NO;
    capture = CGRectIntersection(capture, self.bounds);
    if (!CGRectContainsPoint(capture, point)) return NO;

    CGRect drag = self.headerDragRect;
    if (MFValidInteractiveRect(drag) &&
        CGRectContainsPoint(CGRectIntersection(drag, capture), point)) {
        return YES;
    }

    // 还没有上报过控件（例如绘制层、或菜单首帧尚未构建完）→ 退化成整面板。
    if (!_rectsReportedOnce) return YES;

    for (NSUInteger i = 0; i < _interactiveRectCount; i++) {
        CGRect r = CGRectIntersection(_interactiveRects[i], capture);
        if (CGRectContainsPoint(r, point)) return YES;
    }
    return NO;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [self acceptsInteractionAtPoint:point];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 显式走一遍点的判定：super 会再问一次 pointInside，行为一致且没有副作用。
    if (![self pointInside:point withEvent:event]) return nil;
    return [super hitTest:point withEvent:event];
}

- (void)setPassthroughAll:(BOOL)passthroughAll {
    if (_passthroughAll == passthroughAll) return;
    _passthroughAll = passthroughAll;
    [self requestRedraw];
}

#pragma mark - 可交互矩形收集

- (void)beginInteractiveRects {
    _interactiveRectCount = 0;
}

- (void)addInteractiveRect:(CGRect)rect {
    if (_interactiveRectCount >= kMFOverlayMaxInteractiveRects) return;
    if (!MFValidInteractiveRect(rect) || !MFValidInteractiveRect(self.bounds)) return;
    rect = CGRectIntersection(rect, self.bounds);
    if (!MFValidInteractiveRect(rect)) return;
    _interactiveRects[_interactiveRectCount++] = rect;
}

- (void)endInteractiveRects {
    // 只要上报过一次，就严格按矩形表判定命中 —— 哪怕本次是 0 个。
    // 只有这样「空白区穿透」才是确定的；否则会退化回整面板命中。
    _rectsReportedOnce = YES;
}

- (BOOL)hasInteractiveRects { return _rectsReportedOnce; }

- (void)setCaptureRect:(CGRect)rect {
    if (!MFValidInteractiveRect(rect)) rect = CGRectNull;
    // 每帧都写同一个矩形时不再回调 —— 原来每帧都会去动 window.hidden。
    if (_captureRectInitialized && CGRectEqualToRect(_captureRect, rect)) return;
    _captureRectInitialized = YES;
    _captureRect = rect;
    if (self.captureRectDidChange) self.captureRectDidChange(rect);
}

#pragma mark - 自适应帧率

- (void)requestRedraw {
    NSTimeInterval window = (self.activeWindow > 0.0) ? self.activeWindow : 0.6;
    _activeUntil = CACurrentMediaTime() + window;
    [self applyAdaptiveFrameRate];
}

- (void)applyAdaptiveFrameRate {
    BOOL busy = (CACurrentMediaTime() < _activeUntil);
    NSInteger want = busy ? _preferredFPS : (_idleFPS > 0 ? _idleFPS : _preferredFPS);
    _effectiveFPS = MIN(self.maximumFPS, MAX(5, MIN(_preferredFPS, want)));
    if (!_link) return;
    if (@available(iOS 15.0, *)) {
        float target = (float)_effectiveFPS;
        CAFrameRateRange range = _link.preferredFrameRateRange;
        float minimum = MIN(30.0f, target);
        if (range.minimum != minimum || range.maximum != target || range.preferred != target)
            _link.preferredFrameRateRange = CAFrameRateRangeMake(minimum, target, target);
    } else if (_link.preferredFramesPerSecond != _effectiveFPS) {
        _link.preferredFramesPerSecond = _effectiveFPS;
    }
}

- (NSInteger)screenMaximumFPS {
    return (self.window.screen ?: UIScreen.mainScreen).maximumFramesPerSecond;
}

- (NSInteger)maximumFPS {
    NSInteger maximum = [self screenMaximumFPS];
    return maximum > 0 ? MIN(120, maximum) : 60;
}

- (void)sampleCompletedFrames {
    CFTimeInterval now = CACurrentMediaTime();
    _presentedFPS = _frameStats ? _frameStats->presented.Sample(now) : 0;
    CFTimeInterval elapsed = now - _fpsSampleTime;
    if (!_frameStats || elapsed < 0.5) return;
    uint64_t count = _frameStats->completed.load(std::memory_order_relaxed);
    _renderedFPS = (count - _fpsSampleCount) / elapsed;
    _fpsSampleCount = count;
    _fpsSampleTime = now;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.usesExternalTouchInput) return;
    NSSet *all = event.allTouches;
    if (all.count >= 2) {
        _twoFingerActive = YES;
        _lastTwoFingerCenter = [self centerOfTouches:all];
        return;
    }
    if (_primaryTouch) return;                            // 已有主触点，忽略后续手指
    UITouch *t = touches.anyObject;
    _primaryTouch = t;
    [self sendPos:t down:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.usesExternalTouchInput) return;
    NSSet *all = event.allTouches;

    // 双指 → 滚轮
    if (all.count >= 2) {
        CGPoint c = [self centerOfTouches:all];
        if (_twoFingerActive) {
            CGFloat dy = c.y - _lastTwoFingerCenter.y;
            if (fabs(dy) > 0.5) [self.imgui addScrollY:(float)(-dy * 3.0)];
        }
        _lastTwoFingerCenter = c;
        _twoFingerActive = YES;
        return;                                          // 双指期间不动主触点
    }

    _twoFingerActive = NO;
    if (_primaryTouch && [touches containsObject:_primaryTouch]) {
        [self sendPos:_primaryTouch down:YES];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.usesExternalTouchInput) return;
    [self maybeRelease:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.usesExternalTouchInput) return;
    // ★ 必须处理：来电/系统手势/切后台会走这里，漏掉会造成按钮永久按下
    [self maybeRelease:touches];
    _twoFingerActive = NO;
}

- (void)maybeRelease:(NSSet<UITouch *> *)touches {
    if (_primaryTouch == nil) return;
    if ([touches containsObject:_primaryTouch]) {
        [self.imgui addTouchX:(float)_lastPrimaryPoint.x
                            y:(float)_lastPrimaryPoint.y
                         down:NO];
        _primaryTouch = nil;
        _twoFingerActive = NO;
        [self requestRedraw];
    }
}

- (CGPoint)centerOfTouches:(NSSet<UITouch *> *)touches {
    CGFloat x = 0, y = 0;
    NSUInteger n = 0;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        x += p.x; y += p.y; n++;
    }
    return n ? CGPointMake(x / n, y / n) : CGPointZero;
}

- (void)sendPos:(UITouch *)t down:(BOOL)down {
    CGPoint p = [t locationInView:self];
    _lastPrimaryPoint = p;
    [self.imgui addTouchX:(float)p.x y:(float)p.y down:down];
    [self requestRedraw];
}

#pragma mark - 焦点 / 帧率

- (void)setPreferredFPS:(NSInteger)fps {
    NSInteger value = MAX(15, MIN(120, fps));
    if (_preferredFPS == value) return;
    NSInteger prev = _preferredFPS;
    _preferredFPS = value;
    [self requestRedraw];               // 立刻按新帧率跑起来，别停在旧节奏上
    NSLog(@"[MF][Overlay] 满帧率 %ld → %ld", (long)prev, (long)value);
}

- (void)setIdleFPS:(NSInteger)fps {
    NSInteger value = MAX(0, MIN(120, fps));
    if (_idleFPS == value) return;
    _idleFPS = value;
    [self applyAdaptiveFrameRate];
    NSLog(@"[MF][Overlay] 空闲帧率 → %ld", (long)value);
}

- (void)setPaused:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    [self invalidateRenderingGeneration];
    [self.imgui resetFrameTime];
    if (!paused) {
        [self.imgui addFocus:YES];
        [self requestRedraw];
    }
}

@end
