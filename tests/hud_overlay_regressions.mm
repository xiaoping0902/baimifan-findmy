#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "../app/Sources/Render/MFOverlayView.h"
#include "HUDRegressionOutput.h"
#include "imgui.h"
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>

// Compile this suite with the production overlay, ImGui context, Metal backend
// and ImGui sources. Only the driver's drawable wait is controlled: UIKit,
// CAMetalDrawable, command buffers, ImGui frames and the main run loop are real.
// Breaks caught: main-thread drawable waits, unbounded acquisitions, accepting a
// stopped generation's drawable, malformed input regions and a fixed timestep.

@interface MFOverlayView (RegressionEntryPoints)
- (void)tick:(CADisplayLink *)link;
// A category declaration keeps the RED suite linkable against the old API.
- (BOOL)acceptsInteractionAtPoint:(CGPoint)point;
@end

static unsigned sFailures;
static void Expect(BOOL condition, const char *message) {
    NSCAssert(NSThread.isMainThread, @"Assertions belong to the main queue");
    if (condition) return;
    sFailures++;
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::fflush(stderr);
}

// The deliberate wait is below the production acquisition boundary, before
// entering the driver (which may itself wait for a main-thread transaction).
// The drawable is then obtained and presented by real Metal.
@interface WaitingMetalLayer : CAMetalLayer
@property (nonatomic, strong, readonly) dispatch_semaphore_t entered;
@property (nonatomic, strong, readonly) dispatch_semaphore_t releaseOne;
@property (nonatomic, readonly) unsigned calls;
@property (nonatomic, readonly) unsigned maxConcurrent;
@property (nonatomic, readonly) unsigned mainThreadCalls;
@property (nonatomic, readonly) unsigned missingDrawables;
@property (nonatomic, readonly) BOOL waitingEnabled;
- (void)releaseAll;
@end

@implementation WaitingMetalLayer {
    std::atomic<unsigned> _calls, _concurrent, _maxConcurrent, _mainThreadCalls, _missingDrawables;
    std::atomic<bool> _waitingEnabled;
}
- (instancetype)init {
    if ((self = [super init])) {
        _entered = dispatch_semaphore_create(0);
        _releaseOne = dispatch_semaphore_create(0);
        _calls = _concurrent = _maxConcurrent = _mainThreadCalls = _missingDrawables = 0;
        _waitingEnabled = true;
    }
    return self;
}
- (id<CAMetalDrawable>)nextDrawable {
    _calls.fetch_add(1);
    unsigned concurrent = _concurrent.fetch_add(1) + 1;
    unsigned previous = _maxConcurrent.load();
    while (previous < concurrent && !_maxConcurrent.compare_exchange_weak(previous, concurrent)) { }
    if (NSThread.isMainThread) _mainThreadCalls.fetch_add(1);
    dispatch_semaphore_signal(self.entered);
    if (_waitingEnabled.load()) {
        // Finite even if a test fails: no simulator process can hang forever.
        dispatch_semaphore_wait(self.releaseOne,
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    id<CAMetalDrawable> drawable = [super nextDrawable];
    if (!drawable) _missingDrawables.fetch_add(1);
    _concurrent.fetch_sub(1);
    return drawable;
}
- (unsigned)calls { return _calls.load(); }
- (unsigned)maxConcurrent { return _maxConcurrent.load(); }
- (unsigned)mainThreadCalls { return _mainThreadCalls.load(); }
- (unsigned)missingDrawables { return _missingDrawables.load(); }
- (BOOL)waitingEnabled { return _waitingEnabled.load(); }
- (void)releaseAll {
    _waitingEnabled = false;
    for (unsigned i = 0; i < 8; i++) dispatch_semaphore_signal(self.releaseOne);
}
@end

@interface WaitingOverlay : MFOverlayView
@end
@implementation WaitingOverlay
+ (Class)layerClass { return WaitingMetalLayer.class; }
@end

@interface FrameCounter : NSObject <MFOverlayViewDelegate>
@property unsigned builds, offMainBuilds;
@property (strong) dispatch_semaphore_t built;
@end
@implementation FrameCounter
- (void)overlayBuildUI:(MFImGuiContext *)context overlay:(MFOverlayView *)overlay {
    self.builds++;
    if (!NSThread.isMainThread) self.offMainBuilds++;
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(2, 2), ImVec2(12, 12), IM_COL32_WHITE);
    if (self.built) dispatch_semaphore_signal(self.built);
}
@end

@interface OverlayFixture : NSObject
@property (strong) UIWindow *window;
@property (strong) WaitingOverlay *overlay;
@property (strong) FrameCounter *counter;
- (void)start;
- (void)dispose;
@end
@implementation OverlayFixture
- (instancetype)init {
    if ((self = [super init])) {
        self.window = [[UIWindow alloc] initWithFrame:CGRectMake(40, 80, 348, 520)];
        self.window.rootViewController = [UIViewController new];
        self.window.rootViewController.view.frame = self.window.bounds;
        self.overlay = [[WaitingOverlay alloc] initWithFrame:self.window.bounds interactive:YES];
        self.overlay.automaticallyStartsRendering = NO;
        self.overlay.preferredFPS = 120;
        self.counter = [FrameCounter new];
        self.overlay.delegate = self.counter;
        [self.window.rootViewController.view addSubview:self.overlay];
        self.window.hidden = NO;
        [self.window layoutIfNeeded];
        [self.overlay layoutIfNeeded];
        [CATransaction flush];
    }
    return self;
}
- (void)start {
    NSString *error = nil;
    Expect([self.overlay startRenderingWithError:&error],
           "the real simulator Metal/ImGui context must start");
    if (error) std::fprintf(stderr, "Metal setup: %s\n", error.UTF8String);
}
- (void)dispose {
    [self.overlay stopRendering];
    [(WaitingMetalLayer *)self.overlay.layer releaseAll];
    self.window.hidden = YES;
    [self.overlay removeFromSuperview];
}
@end

static void TestInteractionGeometry(void) {
    MFOverlayView *view = [[MFOverlayView alloc] initWithFrame:CGRectMake(0, 0, 348, 520)
                                                interactive:YES];
    view.automaticallyStartsRendering = NO;
    view.captureRect = view.bounds;
    [view beginInteractiveRects];
    [view addInteractiveRect:CGRectMake(20, 20, 40, 30)];
    [view endInteractiveRects];
    Expect([view pointInside:CGPointMake(30, 30) withEvent:nil], "a visible control must accept UIKit input");
    Expect(![view pointInside:CGPointMake(200, 200) withEvent:nil], "blank panel space must reject UIKit input");
    BOOL sharedAPI = [view respondsToSelector:@selector(acceptsInteractionAtPoint:)];
    Expect(sharedAPI, "HID and UIKit need the same acceptsInteractionAtPoint: geometry API");
    if (sharedAPI) {
        Expect([view acceptsInteractionAtPoint:CGPointMake(30, 30)], "shared geometry must accept a control");
        Expect(![view acceptsInteractionAtPoint:CGPointMake(200, 200)], "shared geometry must reject blank space");
    }

    [view beginInteractiveRects];
    [view addInteractiveRect:CGRectMake(40, 40, -30, -30)];
    [view endInteractiveRects];
    Expect(![view pointInside:CGPointMake(20, 20) withEvent:nil],
           "a negative-size control must be rejected, never standardized into an input region");
    view.headerDragRect = CGRectMake(40, 40, -30, -30);
    Expect(![view pointInside:CGPointMake(20, 20) withEvent:nil],
           "a malformed header must not become a drag handle after standardization");
    view.headerDragRect = CGRectNull;

    view.captureRect = CGRectMake(0, 0, 56, 56);
    [view beginInteractiveRects];
    [view addInteractiveRect:CGRectMake(60, 20, 20, 20)];
    [view endInteractiveRects];
    Expect(![view pointInside:CGPointMake(55, 30) withEvent:nil],
           "a wholly clipped control must not leak hit padding back into the capture region");

    view.captureRect = CGRectMake(-100, -100, 500, 700);
    [view beginInteractiveRects];
    [view addInteractiveRect:CGRectMake(-50, 20, 20, 20)];
    [view addInteractiveRect:CGRectMake(NAN, 0, INFINITY, 40)];
    [view endInteractiveRects];
    Expect(![view pointInside:CGPointMake(-40, 30) withEvent:nil], "input regions must be clipped to view bounds");

    view.captureRect = view.bounds;
    [view beginInteractiveRects];
    [view addInteractiveRect:CGRectMake(20, 20, 40, 30)];
    [view endInteractiveRects];
    view.passthroughAll = YES;
    Expect(![view pointInside:CGPointMake(30, 30) withEvent:nil], "passthrough must reject UIKit input");
    if (sharedAPI) Expect(![view acceptsInteractionAtPoint:CGPointMake(30, 30)],
                          "passthrough must also reject the shared HID geometry");
}

static void TestActualFrameTime(dispatch_block_t completion) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    MFImGuiContext *context = [[MFImGuiContext alloc] initWithDevice:device];
    NSString *error = nil;
    if (![context setupWithError:&error]) {
        Expect(NO, "actual frame-time regression requires a real Metal device");
        completion(); return;
    }
    MTLTextureDescriptor *texture = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    texture.usage = MTLTextureUsageRenderTarget;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = [device newTextureWithDescriptor:texture];
    [context beginFrameWithSize:CGSizeMake(64, 64) scale:1 descriptor:pass];
    ImGui::EndFrame();
    CFTimeInterval started = CACurrentMediaTime();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [context beginFrameWithSize:CGSizeMake(64, 64) scale:1 descriptor:pass];
        double actual = CACurrentMediaTime() - started;
        double step = ImGui::GetIO().DeltaTime;
        Expect(step > 0.08 && std::fabs(step - actual) < 0.05,
               "ImGui DeltaTime must follow elapsed frame time, including idle intervals");
        ImGui::EndFrame();
        [context shutdown];
        completion();
    });
}

static void TestDrawableWaitDoesNotBlockMain(dispatch_block_t completion) {
    std::puts("CASE: drawable wait preserves main-queue responsiveness");
    OverlayFixture *fixture = [OverlayFixture new];
    WaitingMetalLayer *layer = (WaitingMetalLayer *)fixture.overlay.layer;
    [fixture start];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL entered = dispatch_semaphore_wait(layer.entered,
            dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0;
        dispatch_semaphore_t pulse = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            // On RED the gate has already been released before this block can
            // execute. Only issue pressure ticks while a wait is still held.
            if (layer.waitingEnabled) for (unsigned i = 0; i < 32; i++) [fixture.overlay tick:nil];
            dispatch_semaphore_signal(pulse);
        });
        BOOL responsive = dispatch_semaphore_wait(pulse,
            dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC)) == 0;
        if (!responsive) {
            // A blocked main queue cannot run Expect() or finish the suite.
            // Report from this independent deadline before touching the driver.
            std::fprintf(stderr, "FAIL: main queue must run input work while nextDrawable remains blocked\n");
            std::fflush(stderr);
            std::exit(1);
        }
        unsigned acquisitionsWhileHeld = layer.calls;
        [layer releaseAll];
        dispatch_async(dispatch_get_main_queue(), ^{
            Expect(entered, "the test must reach the actual CAMetalLayer acquisition boundary");
            Expect(responsive, "main queue must run input work while nextDrawable remains blocked");
            Expect(layer.mainThreadCalls == 0, "nextDrawable must never execute on the main thread");
            Expect(acquisitionsWhileHeld == 1 && layer.maxConcurrent == 1,
                   "display ticks must permit only one outstanding drawable acquisition");
            Expect(layer.missingDrawables == 0, "the simulator must supply real CAMetalDrawables");
            Expect(fixture.counter.offMainBuilds == 0, "ImGui and UI construction must remain on main");
            [fixture dispose];
            completion();
        });
    });
}

static void TestStoppedGenerationCannotBuildAfterRestart(dispatch_block_t completion) {
    std::puts("CASE: stop/resize/restart rejects a late drawable");
    OverlayFixture *fixture = [OverlayFixture new];
    WaitingMetalLayer *layer = (WaitingMetalLayer *)fixture.overlay.layer;
    dispatch_semaphore_t firstFrame = dispatch_semaphore_create(0);
    __block unsigned firstFrameCallbacks = 0;
    __block NSString *firstFrameError;
    fixture.overlay.firstFrameCompletion = ^(NSString *error) {
        firstFrameCallbacks++;
        firstFrameError = error;
        dispatch_semaphore_signal(firstFrame);
    };
    [fixture start];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL entered = dispatch_semaphore_wait(layer.entered,
            dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0;
        dispatch_semaphore_t restarted = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [fixture.overlay stopRendering];
            fixture.overlay.bounds = CGRectMake(0, 0, 56, 56);
            [fixture.overlay layoutSubviews];
            [fixture start];
            dispatch_semaphore_signal(restarted);
        });
        BOOL restartBeforeOldDrawableReturns = dispatch_semaphore_wait(restarted,
            dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC)) == 0;
        if (!entered || !restartBeforeOldDrawableReturns) {
            [layer releaseAll];
            dispatch_async(dispatch_get_main_queue(), ^{
                Expect(entered, "generation regression must hold a real drawable");
                Expect(restartBeforeOldDrawableReturns, "stop/restart must run while an old drawable is waiting");
                [fixture dispose]; completion();
            });
            return;
        }
        dispatch_semaphore_signal(layer.releaseOne); // Only the old acquisition may finish.
        BOOL freshAcquisition = dispatch_semaphore_wait(layer.entered,
            dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            Expect(freshAcquisition, "restart must request a fresh drawable after rejecting the old generation");
            // The new drawable is still gated. Any built UI used the stale one.
            Expect(fixture.counter.builds == 0,
                   "a stopped generation's late drawable must not build or present a restarted frame");
            Expect(!fixture.overlay.hasCompletedFrame,
                   "a discarded old drawable must not report first-frame readiness");
            Expect(firstFrameCallbacks == 0, "the first-frame observer must ignore a stopped generation");
            [layer releaseAll];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                BOOL completed = dispatch_semaphore_wait(firstFrame,
                    dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
                dispatch_async(dispatch_get_main_queue(), ^{
                    Expect(fixture.counter.builds > 0, "the restarted renderer must resume with a fresh drawable");
                    Expect(completed && firstFrameCallbacks == 1 && firstFrameError == nil &&
                           fixture.overlay.hasCompletedFrame,
                           "only the restarted generation's GPU completion may notify first-frame readiness");
                    Expect(fixture.counter.offMainBuilds == 0, "restarted ImGui frames must remain on main");
                    [fixture dispose]; completion();
                });
            });
        });
    });
}

static void PumpTicks(MFOverlayView *overlay, unsigned remaining, dispatch_block_t completion) {
    if (!remaining) { completion(); return; }
    [overlay tick:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        PumpTicks(overlay, remaining - 1, completion);
    });
}

static void TestGPUBackpressureIsBounded(dispatch_block_t completion) {
    std::puts("CASE: held GPU work bounds drawable acquisitions and resumes after completion");
    OverlayFixture *fixture = [OverlayFixture new];
    WaitingMetalLayer *layer = (WaitingMetalLayer *)fixture.overlay.layer;
    [layer releaseAll];
    id<MTLSharedEvent> barrier = [fixture.overlay.imgui.device newSharedEvent];
    if (!barrier) {
        Expect(NO, "GPU backpressure regression requires Metal shared events");
        [fixture dispose]; completion(); return;
    }
    // Hold the real production command queue with a GPU-side wait. No Metal
    // methods, command buffers or completion callbacks are replaced.
    id<MTLCommandBuffer> blocker = [fixture.overlay.imgui.queue commandBuffer];
    [blocker encodeWaitForEvent:barrier value:1];
    [blocker commit];
    dispatch_semaphore_t firstFrame = dispatch_semaphore_create(0);
    fixture.overlay.firstFrameCompletion = ^(NSString *error) {
        Expect(error == nil, "releasing GPU backpressure must complete without a Metal error");
        dispatch_semaphore_signal(firstFrame);
    };
    fixture.counter.built = dispatch_semaphore_create(0);
    [fixture start];
    // Also release on an independent deadline if the broken implementation
    // blocks main while trying to acquire a fourth layer drawable.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ barrier.signaledValue = 1; });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL built = dispatch_semaphore_wait(fixture.counter.built,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            Expect(built, "GPU backpressure regression must build a real production frame");
            PumpTicks(fixture.overlay, 40, ^{
                Expect(barrier.signaledValue == 0, "GPU pressure assertions must run before the independent safety release");
                Expect(fixture.counter.builds > 0 && fixture.counter.builds <= 2 && layer.calls <= 2,
                       "held GPU completions must bound reserved/acquired/in-flight frames to two");
                barrier.signaledValue = 1;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    BOOL completed = dispatch_semaphore_wait(firstFrame,
                        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        Expect(completed && fixture.overlay.hasCompletedFrame,
                               "GPU completion must return frame credits and restore renderer progress");
                        PumpTicks(fixture.overlay, 20, ^{
                            Expect(fixture.counter.builds > 2, "returned GPU credits must permit subsequent frames");
                            [fixture dispose]; completion();
                        });
                    });
                });
            });
        });
    });
}

@interface OverlayRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation OverlayRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::fprintf(stderr, "FAIL: production overlay suite exceeded its independent deadline\n");
        std::fflush(stderr);
        std::exit(1);
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        TestInteractionGeometry();
        TestActualFrameTime(^{
            TestDrawableWaitDoesNotBlockMain(^{
                TestStoppedGenerationCannotBuildAfterRestart(^{
                    TestGPUBackpressureIsBounded(^{
                        if (!sFailures) std::puts("PASS: production overlay responsiveness, generations, geometry and frame time");
                        else std::fprintf(stderr, "FAIL: production overlay has %u regression failures\n", sFailures);
                        std::fflush(stdout); std::fflush(stderr);
                        std::exit(sFailures ? 1 : 0);
                    });
                });
            });
        });
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(OverlayRegressionDelegate.class));
    }
}
