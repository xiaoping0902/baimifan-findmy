#import "MFHUDInputBridge.h"
#import "MFHUDTouchRouter.h"
#import "MFHUDLog.h"
#import "../Render/MFOverlayView.h"
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <notify.h>
#include <math.h>

// AX still supplies phase/location. Its narrow pathIdentity is diagnostic only:
// on the device it changes 3 -> 2 during one BackBoard contact's down/up.
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
- (BOOL)isInRange;
@end

// IOHID digitizer fields retain the full contact identity across touch/range
// changes. Read children from the retained BKS event, never the hand's own ID.
struct MFHIDFunctions {
    uint32_t (*type)(CFTypeRef);
    CFArrayRef (*children)(CFTypeRef);
    CFIndex (*integer)(CFTypeRef, uint32_t);
    BOOL available() const { return type && children && integer; }
};
static const MFHIDFunctions &HIDFunctions(void) {
    static MFHIDFunctions functions = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        functions.type = (uint32_t (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        functions.children = (CFArrayRef (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
        functions.integer = (CFIndex (*)(CFTypeRef, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
    });
    return functions;
}
struct MFHIDContacts {
    NSUInteger count = 0, visited = 0;
    uint32_t identity = 0, index = 0, type = 0;
    BOOL invalid = NO;
};
static BOOL ReadContacts(CFTypeRef event, const MFHIDFunctions &api,
                         MFHIDContacts &result, unsigned depth = 0) {
    if (!event || ++result.visited > 128 || depth > 8) { result.invalid = YES; return YES; }
    BOOL hasContactDescendant = NO;
    CFArrayRef children = api.children(event);  // Borrowed from the retained parent.
    for (CFIndex i = 0, n = children ? CFArrayGetCount(children) : 0; i < n; i++) {
        hasContactDescendant |= ReadContacts(CFArrayGetValueAtIndex(children, i), api, result, depth + 1);
        if (result.invalid || result.count > 1) return YES;
    }
    if (api.type(event) != 11 || hasContactDescendant) return hasContactDescendant;
    constexpr uint32_t digitizer = 11u << 16;
    uint32_t type = (uint32_t)api.integer(event, digitizer + 4);
    if (type == 3 || type == 0x23) return NO;  // Hand collections, including the historical enum.
    result.count++;
    result.identity = (uint32_t)api.integer(event, digitizer + 6);
    result.index = (uint32_t)api.integer(event, digitizer + 5);
    result.type = type;
    if (result.identity == 0) result.invalid = YES;
    // Do not filter touch/range: both can be false on the final finger event.
    return YES;
}

@interface MFHUDInputBridge () <MFHUDTouchOutput>
- (void)receiveHIDEvent:(CFTypeRef)event queuedAt:(CFTimeInterval)queuedAt;
@end
static __weak MFHUDInputBridge *sActiveBridge;
static void MFHUDEventCallback(void *target, void *refcon, void *service, CFTypeRef event) {
    if (!event) return;
    // BKS owns event only during this callback. Preserve it until main consumes it.
    CFRetain(event);
    CFTimeInterval queuedAt = CACurrentMediaTime();
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try { [sActiveBridge receiveHIDEvent:event queuedAt:queuedAt]; }
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
    unsigned _loggedBegins, _loggedMoves, _loggedOther, _loggedLag, _loggedTraces;
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
    if (!reg || !HIDFunctions().available() || ![_representationClass respondsToSelector:
                 @selector(representationWithHIDEvent:hidStreamIdentifier:)]) {
        if (error) *error = @"HUD 触摸服务不可用（BKS/AX/IOHID），已停止悬浮窗以免遮挡屏幕。";
        return NO;
    }
    sActiveBridge = self;
    _overlay.usesExternalTouchInput = YES;
    reg(MFHUDEventCallback);
    _installed = YES;
    __weak MFHUDInputBridge *weakSelf = self;
    notify_register_dispatch("com.apple.springboard.lockstate", &_lockToken,
                             dispatch_get_main_queue(), ^(int token) { [weakSelf cancelAll]; });
    MFHUDLogLine(@"HID 输入已接通：IOHID 完整触点编号 + AX 阶段/坐标；原生触摸转发已停用以避免双击");
    return YES;
}
- (void)dealloc { if (_lockToken != NOTIFY_TOKEN_INVALID) notify_cancel(_lockToken); }
- (void)cancelAll { [_router cancelAll]; _dragIdentity = nil; }
- (void)touchAtPoint:(CGPoint)point down:(BOOL)down {
    [_overlay.imgui addTouchX:(float)point.x y:(float)point.y down:down];
}
- (void)cancelTouch { [_overlay.imgui cancelTouch]; }
- (void)receiveHIDEvent:(CFTypeRef)event queuedAt:(CFTimeInterval)queuedAt {
    CFTimeInterval receivedAt = CACurrentMediaTime();
    CFTimeInterval delay = receivedAt - queuedAt;
    MFOverlayView *overlay = _overlay; UIWindow *window = _window;
    if (!overlay.hasCompletedFrame || window.hidden || CGRectIsNull(overlay.captureRect) ||
        CGRectIsEmpty(overlay.captureRect)) { [self cancelAll]; return; }
    id<MFAXEvent> rep = [(Class<MFAXEvent>)_representationClass
        representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];
    NSArray<id<MFAXPath>> *paths = rep.handInfo.paths;
    const MFHIDFunctions &api = HIDFunctions();
    if (!api.available()) { [self cancelAll]; return; }
    MFHIDContacts contacts;
    ReadContacts(event, api, contacts);
    CFTimeInterval parseDelay = CACurrentMediaTime() - receivedAt;
    if ((delay > 0.1 || parseDelay > 0.05) && _loggedLag++ < 8)
        MFHUDLogLine(@"HID 主队列等待 %.0fms，AX 解析 %.0fms", delay * 1000, parseDelay * 1000);
    if (rep.isTouchDown) { _loggedBegins++; _loggedMoves = 0; }
    BOOL trace = _loggedTraces < 192 && _loggedBegins <= 32 && (rep.isTouchDown || rep.isLift ||
        rep.isInRangeLift || rep.isCancel || (rep.isMove && _loggedMoves++ < 2) ||
        (!rep.isMove && _loggedOther++ < 8));
    if (trace) {
        _loggedTraces++;
        MFHUDLogLine(@"AX paths=%lu down=%d move=%d lift=%d rangeLift=%d range=%d cancel=%d id=%u rawPaths=%lu rawID=%u rawIndex=%u rawType=%u invalid=%d point=%@ active=%d drag=%@ lag=%.1fms",
            (unsigned long)paths.count, rep.isTouchDown, rep.isMove, rep.isLift,
            rep.isInRangeLift, rep.isInRange, rep.isCancel,
            (unsigned)(paths.firstObject ? paths.firstObject.pathIdentity : 0),
            (unsigned long)contacts.count, contacts.identity, contacts.index, contacts.type, contacts.invalid,
            NSStringFromCGPoint(rep.location), _router.hasActiveTouch, _dragIdentity, delay * 1000);
    }
    // AX's aggregate location describes one path. Never assign it to other fingers.
    // Use the visible scrollbar for content scrolling; multi-touch cancels input.
    if (paths.count > 1 || contacts.count > 1 || contacts.invalid || rep.isCancel) {
        [self cancelAll]; return;
    }
    if (paths.count == 0) return;
    if (contacts.count != 1) { [self cancelAll]; return; }
    NSInteger identity = (NSInteger)contacts.identity;
    MFHUDTouchPhase phase;
    if (rep.isTouchDown) phase = MFHUDTouchBegan;
    else if (rep.isMove) phase = MFHUDTouchMoved;
    else if (rep.isLift || rep.isInRangeLift) phase = MFHUDTouchEnded;
    else return;  // Hover/range notifications are not finger lifts.
    CGPoint global = rep.location;
    if (!isfinite(global.x) || !isfinite(global.y) || identity <= 0) return;
    if (phase == MFHUDTouchBegan &&
        ((_dragIdentity && _dragIdentity.integerValue != identity) ||
         (_router.hasActiveTouch && ![_router ownsTouchID:identity]))) {
        // A changed-only packet can introduce a second finger without carrying
        // the first. Cancel the previous press; never transfer it or click it.
        [self cancelAll]; return;
    }
    CGPoint inWindow = [window convertPoint:global fromCoordinateSpace:window.screen.fixedCoordinateSpace];
    CGPoint local = [overlay convertPoint:inWindow fromView:window];

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
        if (trace) MFHUDLogLine(@"触摸路由=drag phase=%ld local=%@ center=%@",
            (long)phase, NSStringFromCGPoint(local), NSStringFromCGPoint(center));
        return;
    }
    BOOL handled = [_router handleTouchID:identity point:local phase:phase captureRect:overlay.captureRect];
    if (trace) MFHUDLogLine(@"触摸路由=menu phase=%ld id=%ld local=%@ handled=%d header=%@",
        (long)phase, (long)identity, NSStringFromCGPoint(local), handled,
        NSStringFromCGRect(overlay.headerDragRect));
}
@end
