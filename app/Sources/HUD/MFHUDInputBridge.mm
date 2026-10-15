#import "MFHUDInputBridge.h"
#import "MFHUDTouchRouter.h"
#import "MFHUDLog.h"
#import "../Render/MFOverlayView.h"
#import <dlfcn.h>
#import <notify.h>
#include <math.h>

// ABI from TrollSpeed's BackboardServices/AXEventRepresentation headers.
@protocol MFAXPath <NSObject>
- (unsigned char)pathIdentity;
@end
@protocol MFAXHand <NSObject>
- (NSArray<id<MFAXPath>> *)paths;
@end
@protocol MFAXEvent <NSObject>
+ (instancetype)representationWithHIDEvent:(CFTypeRef)event hidStreamIdentifier:(NSString *)identifier;
- (id<MFAXHand>)handInfo;
- (CGPoint)location;
- (BOOL)isTouchDown;
- (BOOL)isMove;
- (BOOL)isCancel;
- (BOOL)isLift;
- (BOOL)isInRangeLift;
@end

@interface MFHUDInputBridge () <MFHUDTouchOutput>
- (void)receiveHIDEvent:(CFTypeRef)event;
@end
static __weak MFHUDInputBridge *sActiveBridge;
static void MFHUDEventCallback(void *target, void *refcon, void *service, CFTypeRef event) {
    if (!event) return;
    // BKS owns event only during this callback. Preserve it until main consumes it.
    CFRetain(event);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try { [sActiveBridge receiveHIDEvent:event]; }
            @catch (NSException *exception) {
                [sActiveBridge cancelAll];
                MFHUDLogLine(@"HUD 触摸解析异常：%@", exception.reason);
            }
            @finally { CFRelease(event); }
        }
    });
}

@implementation MFHUDInputBridge {
    __weak MFOverlayView *_overlay;
    __weak UIWindow *_window;
    Class _representationClass;
    MFHUDTouchRouter *_router;
    NSNumber *_dragIdentity;
    CGPoint _dragStart, _windowStart;
    unsigned _loggedBegins;
    int _lockToken;
    BOOL _installed;
}
- (instancetype)initWithOverlay:(MFOverlayView *)overlay window:(UIWindow *)window {
    if ((self = [super init])) {
        _overlay = overlay; _window = window;
        _router = [[MFHUDTouchRouter alloc] initWithOutput:self];
        _lockToken = NOTIFY_TOKEN_INVALID;
    }
    return self;
}
- (BOOL)installWithError:(NSString **)error {
    if (_installed) return YES;
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
    _representationClass = NSClassFromString(@"AXEventRepresentation");
    typedef void (*Callback)(void *, void *, void *, CFTypeRef);
    typedef void *(*Register)(Callback);
    Register reg = (Register)dlsym(RTLD_DEFAULT, "BKSHIDEventRegisterEventCallback");
    if (!reg || ![_representationClass respondsToSelector:
                 @selector(representationWithHIDEvent:hidStreamIdentifier:)]) {
        if (error) *error = @"HUD 触摸服务不可用（BKS/AX），已停止悬浮窗以免遮挡屏幕。";
        return NO;
    }
    sActiveBridge = self;
    _overlay.usesExternalTouchInput = YES;
    reg(MFHUDEventCallback);
    _installed = YES;
    __weak MFHUDInputBridge *weakSelf = self;
    notify_register_dispatch("com.apple.springboard.lockstate", &_lockToken,
                             dispatch_get_main_queue(), ^(int token) { [weakSelf cancelAll]; });
    MFHUDLogLine(@"HID 输入已接通：BKS → AX → 菜单主触点；原生触摸转发已停用以避免双击");
    return YES;
}
- (void)dealloc { if (_lockToken != NOTIFY_TOKEN_INVALID) notify_cancel(_lockToken); }
- (void)cancelAll { [_router cancelAll]; _dragIdentity = nil; }
- (void)touchAtPoint:(CGPoint)point down:(BOOL)down {
    [_overlay.imgui addTouchX:(float)point.x y:(float)point.y down:down];
}
- (void)cancelTouch { [_overlay.imgui cancelTouch]; }
- (void)receiveHIDEvent:(CFTypeRef)event {
    MFOverlayView *overlay = _overlay; UIWindow *window = _window;
    if (!overlay.hasCompletedFrame || window.hidden || CGRectIsNull(overlay.captureRect) ||
        CGRectIsEmpty(overlay.captureRect)) { [self cancelAll]; return; }
    id<MFAXEvent> rep = [(Class<MFAXEvent>)_representationClass
        representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];
    NSArray<id<MFAXPath>> *paths = rep.handInfo.paths;
    // AX's aggregate location describes one path. Never assign it to other fingers.
    // Use the visible scrollbar for content scrolling; multi-touch cancels input.
    if (paths.count > 1 || rep.isCancel) { [self cancelAll]; return; }
    if (paths.count == 0) return;
    NSInteger identity = paths.firstObject.pathIdentity;
    MFHUDTouchPhase phase;
    if (rep.isTouchDown) phase = MFHUDTouchBegan;
    else if (rep.isMove) phase = MFHUDTouchMoved;
    else if (rep.isLift || rep.isInRangeLift) phase = MFHUDTouchEnded;
    else return;  // Hover/range notifications are not finger lifts.
    CGPoint global = rep.location;
    if (!isfinite(global.x) || !isfinite(global.y) || identity <= 0) return;
    CGPoint inWindow = [window convertPoint:global fromCoordinateSpace:window.screen.fixedCoordinateSpace];
    CGPoint local = [overlay convertPoint:inWindow fromView:window];
    if (phase == MFHUDTouchBegan && _loggedBegins++ < 24)
        MFHUDLogLine(@"触摸 begin id=%ld fixed=%@ window=%@ local=%@ capture=%@",
            (long)identity, NSStringFromCGPoint(global), NSStringFromCGPoint(inWindow),
            NSStringFromCGPoint(local), NSStringFromCGRect(overlay.captureRect));

    CGRect dragRect = overlay.headerDragRect;
    if (phase == MFHUDTouchBegan && !_dragIdentity && !_router.hasActiveTouch &&
        !CGRectIsNull(dragRect) && CGRectContainsPoint(dragRect, local)) {
        _dragIdentity = @(identity); _dragStart = global; _windowStart = window.center;
    }
    if (_dragIdentity) {
        if (_dragIdentity.integerValue != identity) return;
        CGPoint center = CGPointMake(_windowStart.x + global.x - _dragStart.x,
                                     _windowStart.y + global.y - _dragStart.y);
        CGRect screen = window.screen.fixedCoordinateSpace.bounds;
        CGFloat halfW = window.bounds.size.width / 2, halfH = window.bounds.size.height / 2;
        center.x = MIN(CGRectGetMaxX(screen) - halfW, MAX(CGRectGetMinX(screen) + halfW, center.x));
        center.y = MIN(CGRectGetMaxY(screen) - halfH, MAX(CGRectGetMinY(screen) + halfH, center.y));
        window.center = center;
        if (phase == MFHUDTouchEnded) _dragIdentity = nil;
        return;
    }
    [_router handleTouchID:identity point:local phase:phase captureRect:overlay.captureRect];
}
@end
