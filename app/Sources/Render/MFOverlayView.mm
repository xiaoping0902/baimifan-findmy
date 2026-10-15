//
//  MFOverlayView.mm — 透明 Metal 覆盖层（实现）
//
#import "MFOverlayView.h"
#import "../HUD/MFHUDLog.h"
#import <QuartzCore/CAMetalLayer.h>

/// 每帧上报的可交互矩形上限。菜单控件约 40 个，256 足够且不占内存。
static const NSUInteger kMFOverlayMaxInteractiveRects = 256;
/// 命中判定容差（点）：手指比鼠标粗，给控件外扩一点更好点。
static const CGFloat kMFOverlayHitSlop = 6.0;
/// nextDrawable 等待超过这个值就停一帧，别把主线程钉在等 GPU 上。
static const CFTimeInterval kMFOverlayDrawableBackoffThreshold = 0.06;

@interface MFOverlayView ()
/// 点是否落在「真正可交互」的区域（控件 / 标题拖动区 / 面板）
- (BOOL)isInteractivePoint:(CGPoint)point;
/// 按「是否刚交互过」切换满帧率与空闲帧率
- (void)applyAdaptiveFrameRate;
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

    // ── 局部命中（穿透）──────────────────────────────────
    CGRect _interactiveRects[kMFOverlayMaxInteractiveRects];
    NSUInteger _interactiveRectCount;
    BOOL _rectsReportedOnce;
    BOOL _captureRectInitialized;

    // ── 自适应帧率 ──────────────────────────────────────
    NSTimeInterval _activeUntil;
    unsigned _drawableBackoff;
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
        _idleFPS = 0;                 // 0 = 不降频（绘制层保持稳定输出）
        _activeWindow = 0.6;
        _automaticallyStartsRendering = YES;
        _captureRect = CGRectNull;
        _headerDragRect = CGRectNull;
        _passthroughAll = NO;

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
        // 三个 drawable + 不等待事务：把「等 GPU 回收纹理」的阻塞压到最小。
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
    CGSize px = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
    if (px.width > 0 && px.height > 0) {
        self.metalLayer.drawableSize = px;
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
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFramesPerSecond = _preferredFPS;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self requestRedraw];   // 首帧必须马上出来，不能被空闲降频拖住
    NSLog(@"[MF][Overlay] 渲染已启动 (interactive=%d, %.0fx%.0f, 满帧%ld/空闲%ld)",
          self.interactive, self.bounds.size.width, self.bounds.size.height,
          (long)_preferredFPS, (long)_idleFPS);
    return YES;
}

- (void)stopRendering {
    [_link invalidate];
    _link = nil;
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
    if (self.paused || !self.window) return;
    if (!_ready) return;
    if (self.bounds.size.width < 1 || self.bounds.size.height < 1) return;

    [self applyAdaptiveFrameRate];

    // 上一次 nextDrawable 让我们等了很久 → 主动让出一帧。
    // 这比「继续等」更好：主线程还有触摸解析和 ImGui 构建要做。
    if (_drawableBackoff > 0) { _drawableBackoff--; return; }

    CAMetalLayer *ml = self.metalLayer;
    if (ml.drawableSize.width < 1) [self layoutSubviews];

    @autoreleasepool {
        CFTimeInterval drawableStart = CACurrentMediaTime();
        id<CAMetalDrawable> drawable = [ml nextDrawable];
        CFTimeInterval drawableDelay = CACurrentMediaTime() - drawableStart;
        if (drawableDelay > kMFOverlayDrawableBackoffThreshold) {
            _drawableBackoff = 2;
            if (_loggedDrawableLag++ < 8)
                MFHUDLogLine(@"%@ nextDrawable 等待 %.0fms hidden=%d → 让出 2 帧抢回主线程",
                    self.interactive ? @"菜单" : @"绘制", drawableDelay * 1000, self.window.hidden);
        }
        if (!drawable) {
            if (!_loggedMissingDrawable) {
                _loggedMissingDrawable = YES;
                MFHUDLogLine(@"%@：nextDrawable 为 nil，等待窗口合成器（drawableSize=%@）",
                             self.interactive ? @"菜单" : @"绘制", NSStringFromCGSize(ml.drawableSize));
            }
            return;
        }

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);  // ★ 透明
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [self.imgui.queue commandBuffer];
        if (!cb) {
            [self reportFirstFrameError:@"Metal commandBuffer 创建失败"];
            [self stopRendering];
            return;
        }

        CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale ?: 2.0;
        [self.imgui beginFrameWithSize:self.bounds.size scale:scale descriptor:rp];
        [self.imgui buildUI:^{
            if (self.delegate) [self.delegate overlayBuildUI:self.imgui overlay:self];
        }];

        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        if (!enc) {
            [self reportFirstFrameError:@"Metal renderCommandEncoder 创建失败"];
            [self stopRendering];
            return;
        }
        [self.imgui endFrameWithCommandBuffer:cb encoder:enc];
        [enc endEncoding];
        [cb presentDrawable:drawable];
        if (!_firstFrameReported && !_firstFramePending) {
            _firstFramePending = YES;
            __weak MFOverlayView *weakSelf = self;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                NSString *error = completed.status == MTLCommandBufferStatusCompleted ? nil :
                    (completed.error.localizedDescription ?: @"Metal 首帧执行失败");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf reportFirstFrameError:error];
                });
            }];
        }
        [cb commit];
    }
}

#pragma mark - 触摸：主触点策略（调研 §2.3）

/*
 * ★★ 局部命中（穿透）★★
 *
 * 之前：pointInside 只看 captureRect —— 整个 348×520 面板矩形都吃掉触摸，
 *       面板透明的地方点下去也是菜单接住，下层 App（游戏）收不到。
 *
 * 现在：菜单每帧把「真正可交互的控件矩形」上报进来，只有落在这些矩形
 *       （或标题拖动区）上的点才算命中；其余点 hitTest 返回 nil，
 *       窗口服务器把它交给下层窗口。
 *
 * 为什么能这样做：HUD 的 ImGui 输入来自 BKSHIDEventRegisterEventCallback
 * 全局事件流，不依赖 UIKit 的事件分发 —— 所以命中范围缩到控件上
 * 不会让菜单自己点不了。
 */
- (BOOL)isInteractivePoint:(CGPoint)point {
    CGRect capture = self.captureRect;
    if (CGRectIsNull(capture) || CGRectIsEmpty(capture)) return NO;
    if (!CGRectContainsPoint(capture, point)) return NO;

    // 标题拖动区永远可交互：那是窗口唯一的手柄。
    CGRect drag = CGRectStandardize(self.headerDragRect);
    if (!CGRectIsNull(drag) && !CGRectIsEmpty(drag) &&
        CGRectContainsPoint(CGRectInset(drag, -kMFOverlayHitSlop, -kMFOverlayHitSlop), point)) {
        return YES;
    }

    // 还没有上报过控件（例如绘制层、或菜单首帧尚未构建完）→ 退化成整面板。
    if (!_rectsReportedOnce) return YES;

    for (NSUInteger i = 0; i < _interactiveRectCount; i++) {
        CGRect r = CGRectInset(_interactiveRects[i], -kMFOverlayHitSlop, -kMFOverlayHitSlop);
        if (CGRectContainsPoint(r, point)) return YES;
    }
    return NO;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.interactive) return NO;                    // 绘制层完全穿透
    if (self.passthroughAll) return NO;                  // 整窗穿透模式
    return [self isInteractivePoint:point];
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
    rect = CGRectStandardize(rect);
    if (rect.size.width < 1.0 || rect.size.height < 1.0) return;   // 空/负尺寸直接丢
    _interactiveRects[_interactiveRectCount++] = rect;
}

- (void)endInteractiveRects {
    // 只要上报过一次，就严格按矩形表判定命中 —— 哪怕本次是 0 个。
    // 只有这样「空白区穿透」才是确定的；否则会退化回整面板命中。
    _rectsReportedOnce = YES;
}

- (BOOL)hasInteractiveRects { return _rectsReportedOnce; }

- (void)setCaptureRect:(CGRect)rect {
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
    if (!_link) return;
    BOOL busy = (CACurrentMediaTime() < _activeUntil);
    NSInteger want = busy ? _preferredFPS : (_idleFPS > 0 ? _idleFPS : _preferredFPS);
    want = MAX(5, MIN(120, want));
    if (_link.preferredFramesPerSecond != want) _link.preferredFramesPerSecond = want;
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
    _paused = paused;
    if (!paused) {
        [self.imgui addFocus:YES];
        [self requestRedraw];
    }
}

@end
