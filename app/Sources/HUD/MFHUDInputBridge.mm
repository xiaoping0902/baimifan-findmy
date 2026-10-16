#import "MFHUDInputBridge.h"
#import "MFHUDTouchRouter.h"
#import "MFHUDLog.h"
#import "../Render/MFOverlayView.h"
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <notify.h>
#include <math.h>

// AX supplies phase/location. Its narrow pathIdentity is diagnostic only.
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

// Track the full digitizer index of the finger child. On the target iPad,
// raw identity changes 3 -> 2 on lift while index stays stable. The factory
// probe below validates field locations, not hardware identity stability.
typedef CFTypeRef (*MFCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double,
    Boolean, Boolean, uint32_t);
struct MFHIDFunctions {
    uint32_t (*type)(CFTypeRef);
    CFArrayRef (*children)(CFTypeRef);
    CFIndex (*integer)(CFTypeRef, uint32_t);
    uint32_t typeField = 0, indexField = 0, identityField = 0;
    BOOL available() const { return type && children && integer &&
        typeField && indexField && identityField; }
};
static const MFHIDFunctions &HIDFunctions(void) {
    static MFHIDFunctions functions = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        functions.type = (uint32_t (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        functions.children = (CFArrayRef (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
        functions.integer = (CFIndex (*)(CFTypeRef, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
        MFCreateDigitizer create = (MFCreateDigitizer)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        if (!create || !functions.integer) return;
        // Private field layouts vary between IOKit releases. Determine the
        // fields from known factory arguments, never from a user's gesture.
        CFTypeRef finger = create(kCFAllocatorDefault, 0, 2, 0x1234, 0x5678,
                                   2, 0, 0.3, 0.4, 0, 1, 0, true, true, 0);
        CFTypeRef hand = create(kCFAllocatorDefault, 0, 3, 0x2468, 0x1357,
                                 2, 0, 0.3, 0.4, 0, 1, 0, true, true, 0);
        unsigned typeMatches = 0, indexMatches = 0, identityMatches = 0;
        if (finger && hand) {
            for (uint32_t offset = 0; offset < 64; offset++) {
                uint32_t field = (11u << 16) + offset;
                CFIndex f = functions.integer(finger, field), h = functions.integer(hand, field);
                if (f == 2 && h == 3) { functions.typeField = field; typeMatches++; }
                if (f == 0x1234 && h == 0x2468) { functions.indexField = field; indexMatches++; }
                if (f == 0x5678 && h == 0x1357) { functions.identityField = field; identityMatches++; }
            }
        }
        if (finger) CFRelease(finger);
        if (hand) CFRelease(hand);
        if (typeMatches != 1 || indexMatches != 1 || identityMatches != 1)
            functions.typeField = functions.indexField = functions.identityField = 0;
        MFHUDLogLine(@"IOHID 字段探测：type=0x%x index=0x%x identity=0x%x validated=%d",
            functions.typeField, functions.indexField, functions.identityField, functions.available());
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
    uint32_t type = (uint32_t)api.integer(event, api.typeField);
    if (type == 3 || type == 0x23) return NO;  // Hand collections, including the historical enum.
    result.count++;
    result.identity = (uint32_t)api.integer(event, api.identityField);
    result.index = (uint32_t)api.integer(event, api.indexField);
    result.type = type;
    if (result.index == 0) result.invalid = YES;
    // Do not filter touch/range: both can be false on the final finger event.
    return YES;
}

/*
 * 重绘请求的防御性包装。
 *
 * 生产里的 overlay 一定是 MFOverlayView，但回归夹具用普通 UIView/InputPanel
 * 冒充它（模拟器里不起 Metal）。缺一个选择器不该让整条输入链崩掉。
 */
static void MFRequestOverlayRedraw(MFOverlayView *overlay) {
    if ([overlay respondsToSelector:@selector(requestRedraw)]) [overlay requestRedraw];
}

@interface MFHUDInputBridge () <MFHUDTouchOutput>
- (void)receiveHIDEvent:(CFTypeRef)event queuedAt:(CFTimeInterval)queuedAt;
- (void)cancelAll;
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
    NSNumber *_dragIndex;
    CGPoint _dragStart, _windowStart;
    unsigned _loggedBegins, _loggedMoves, _loggedOther, _loggedLag, _loggedTraces;
    int _lockToken;
    BOOL _installed;

    NSInteger _gestureIndex; // Full uint32_t contact index; zero means no owner.
    BOOL _dragMoved;

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
    MFHUDLogLine(@"HID 输入已接通：IOHID 完整触点 index + AX 阶段/坐标（rawID 仅诊断）；原生触摸转发已停用以避免双击");
    return YES;
}
- (void)dealloc { if (_lockToken != NOTIFY_TOKEN_INVALID) notify_cancel(_lockToken); }
- (void)cancelAll {
    // A completed tap can still have position/down/up queued in ImGui after
    // the router has released its owner. Clear that queue on every cancel,
    // while letting an active router send its one existing cancellation.
    BOOL routerWillCancel = _router.hasActiveTouch;
    [_router cancelAll];
    if (!routerWillCancel) [self cancelTouch];
    _dragIndex = nil; _gestureIndex = 0; _dragMoved = NO;
}
- (void)touchAtPoint:(CGPoint)point down:(BOOL)down {
    [_overlay.imgui addTouchX:(float)point.x y:(float)point.y down:down];
    MFRequestOverlayRedraw(_overlay);   // 有输入就保持满帧，静止时不烧 GPU
}
- (void)cancelTouch {
    [_overlay.imgui cancelTouch];
    MFRequestOverlayRedraw(_overlay);
}

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
            NSStringFromCGPoint(rep.location), _router.hasActiveTouch, _dragIndex, delay * 1000);
    }
    // AX's aggregate location describes one path. Never assign it to other fingers.
    // Use the visible scrollbar for content scrolling; multi-touch cancels input.
    if (paths.count > 1 || contacts.count > 1 || contacts.invalid || rep.isCancel) {
        [self cancelAll]; return;
    }
    if (paths.count == 0) return;
    if (contacts.count != 1) { [self cancelAll]; return; }
    NSInteger contactIndex = (NSInteger)contacts.index;
    MFHUDTouchPhase phase;
    if (rep.isTouchDown) phase = MFHUDTouchBegan;
    else if (rep.isMove) phase = MFHUDTouchMoved;
    else if (rep.isLift || rep.isInRangeLift) phase = MFHUDTouchEnded;
    else return;  // Hover/range notifications are not finger lifts.
    CGPoint global = rep.location;
    if (!isfinite(global.x) || !isfinite(global.y) || contactIndex <= 0) return;

    // A new contact cancels an existing press. Move/up from an unowned
    // contact cannot alter ownership, position, drag state or a button.
    if (phase == MFHUDTouchBegan && _gestureIndex != 0) {
        if (contactIndex != _gestureIndex) [self cancelAll];
        return;
    }
    if (phase != MFHUDTouchBegan && contactIndex != _gestureIndex) return;

    CGPoint inWindow = [window convertPoint:global fromCoordinateSpace:window.screen.fixedCoordinateSpace];
    CGPoint local = [overlay convertPoint:inWindow fromView:window];
    if (phase == MFHUDTouchBegan) {
        // The shared window never takes the system hit. Observe menu controls
        // using overlay geometry independently; a touch starting in a hole
        // must not become a menu gesture when it later crosses a control.
        if (![overlay acceptsInteractionAtPoint:local]) return;
        _gestureIndex = contactIndex;
        CGRect dragRect = overlay.headerDragRect;
        if (!CGRectIsNull(dragRect) && !CGRectIsEmpty(dragRect) &&
            CGRectContainsPoint(dragRect, local)) {
            _dragIndex = @(contactIndex); _dragStart = global;
            _windowStart = window.center; _dragMoved = NO;
        }
    }
    if (_dragIndex) {
        CGFloat dx = global.x - _dragStart.x, dy = global.y - _dragStart.y;
        if (dx * dx + dy * dy >= 64.0) _dragMoved = YES;
        if (_dragMoved) {
            CGPoint center = CGPointMake(_windowStart.x + dx, _windowStart.y + dy);
            CGRect screen = window.screen.fixedCoordinateSpace.bounds;
            CGFloat halfW = window.bounds.size.width / 2, halfH = window.bounds.size.height / 2;
            center.x = MIN(CGRectGetMaxX(screen) - halfW, MAX(CGRectGetMinX(screen) + halfW, center.x));
            center.y = MIN(CGRectGetMaxY(screen) - halfH, MAX(CGRectGetMinY(screen) + halfH, center.y));
            window.center = center;
            MFRequestOverlayRedraw(overlay);
        }
        if (phase == MFHUDTouchEnded) {
            // Header and ball start as a pending drag. A tap gets one full
            // ImGui click; movement beyond 8 points never also clicks.
            if (!_dragMoved && [overlay acceptsInteractionAtPoint:local]) {
                [self touchAtPoint:local down:YES];
                [self touchAtPoint:local down:NO];
            }
            _dragIndex = nil; _gestureIndex = 0; _dragMoved = NO;
        }
        return;
    }
    BOOL handled = [_router handleTouchID:contactIndex point:local phase:phase captureRect:overlay.captureRect];
    if (phase == MFHUDTouchEnded) _gestureIndex = 0;
    if (trace) MFHUDLogLine(@"触摸路由=menu phase=%ld index=%ld local=%@ handled=%d",
        (long)phase, (long)contactIndex, NSStringFromCGPoint(local), handled);
}

@end
