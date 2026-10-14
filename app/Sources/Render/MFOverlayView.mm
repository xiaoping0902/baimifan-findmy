//
//  MFOverlayView.mm — 透明 Metal 覆盖层（实现）
//
#import "MFOverlayView.h"
#import <QuartzCore/CAMetalLayer.h>

@implementation MFOverlayView {
    CADisplayLink *_link;
    UITouch *_primaryTouch;
    CGPoint _lastPrimaryPoint;
    CGPoint _lastTwoFingerCenter;
    BOOL _twoFingerActive;
    BOOL _ready;
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
        _captureRect = CGRectNull;

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
    if (self.window) {
        [self startRenderingWithError:NULL];
    } else {
        [self stopRendering];
    }
}

#pragma mark - 渲染循环

- (BOOL)startRenderingWithError:(NSString **)err {
    if (_ready) return YES;

    NSString *e = nil;
    if (![self.imgui setupWithError:&e]) {
        if (err) *err = e;
        NSLog(@"[MF][Overlay] ImGui 初始化失败: %@", e);
        return NO;
    }
    _ready = YES;

    if (_link) return YES;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFramesPerSecond = _preferredFPS;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSLog(@"[MF][Overlay] 渲染已启动 (interactive=%d, %.0fx%.0f)",
          self.interactive, self.bounds.size.width, self.bounds.size.height);
    return YES;
}

- (void)stopRendering {
    [_link invalidate];
    _link = nil;
}

- (void)tick:(CADisplayLink *)link {
    if (self.paused || !self.window) return;
    if (!_ready) return;
    if (self.bounds.size.width < 1 || self.bounds.size.height < 1) return;

    CAMetalLayer *ml = self.metalLayer;
    if (ml.drawableSize.width < 1) [self layoutSubviews];

    @autoreleasepool {
        id<CAMetalDrawable> drawable = [ml nextDrawable];
        if (!drawable) return;

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);  // ★ 透明
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [self.imgui.queue commandBuffer];

        CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale ?: 2.0;
        [self.imgui beginFrameWithSize:self.bounds.size scale:scale descriptor:rp];
        [self.imgui buildUI:^{
            if (self.delegate) [self.delegate overlayBuildUI:self.imgui overlay:self];
        }];

        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [self.imgui endFrameWithCommandBuffer:cb encoder:enc];
        [enc endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];
    }
}

#pragma mark - 触摸：主触点策略（调研 §2.3）

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.interactive) return NO;                    // 绘制层完全穿透
    if (CGRectIsNull(self.captureRect)) return NO;       // 还没拿到面板矩形
    return CGRectContainsPoint(self.captureRect, point);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
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
    [self maybeRelease:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
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
}

#pragma mark - 焦点 / 帧率

- (void)setPreferredFPS:(NSInteger)fps {
    _preferredFPS = MAX(15, MIN(120, fps));
    if (_link) {
        NSInteger prev = _link.preferredFramesPerSecond;
        _link.preferredFramesPerSecond = _preferredFPS;
        if (prev != _preferredFPS) {
            NSLog(@"[MF][Overlay] 帧率 %ld → %ld", (long)prev, (long)_preferredFPS);
        }
    }
}

- (void)setPaused:(BOOL)paused {
    _paused = paused;
    if (!paused) [self.imgui addFocus:YES];
}

@end
