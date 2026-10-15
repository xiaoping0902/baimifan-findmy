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
- (BOOL)gestureContinuesAt:(CGPoint)global now:(CFTimeInterval)now;
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
    NSNumber *_dragIdentity;
    CGPoint _dragStart, _windowStart;
    unsigned _loggedBegins, _loggedMoves, _loggedOther, _loggedLag, _loggedTraces;
    int _lockToken;
    BOOL _installed;

    /*
     * ★ 手势归一化（M5.66）★
     *
     * 真机证据（M5.65，hud.log 03:27:47）：
     *     同一根手指、同一坐标 (821,498.5)、间隔 33ms
     *     按下 rawID=3 → 抬起 rawID=2 → 路由器拒绝了松手 → 按钮一直按下
     *
     * 也就是说：这台设备上报的 digitizer identity **在一次手势内会变**，
     * 不能当作所有权键。BackBoard 内部的 touchIdentifier 全程不变（420），
     * 但那个值不在我们能拿到的字段里。
     *
     * 处理办法：HUD 内部给手势编一个自己的号，只要「原始 ID 相同」
     * 或「位置+时间连续」就认为是同一根手指，对外统一用这个内部号。
     * 连续性判据同时挡住了另一根手指的松手（它不会出现在原地）。
     */
    NSInteger _gestureID;        // 当前手势的内部编号（0 = 没有）
    NSInteger _gestureRawID;     // 该手势最近一次观察到的原始 identity
    NSInteger _gestureCounter;   // 只增，保证编号不重复
    CGPoint _gestureLastPoint;   // 最近一次已知的屏幕坐标
    CFTimeInterval _gestureLastTime;
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
- (void)cancelAll { [_router cancelAll]; _dragIdentity = nil; _gestureID = 0; }
- (void)touchAtPoint:(CGPoint)point down:(BOOL)down {
    [_overlay.imgui addTouchX:(float)point.x y:(float)point.y down:down];
    [_overlay requestRedraw];       // 有输入就保持满帧，静止时不烧 GPU
}
- (void)cancelTouch {
    [_overlay.imgui cancelTouch];
    [_overlay requestRedraw];
}

/// 原始 identity 变了，但位置和时间都连续 → 还是同一根手指。
- (BOOL)gestureContinuesAt:(CGPoint)global now:(CFTimeInterval)now {
    if (_gestureID == 0) return NO;
    CFTimeInterval dt = now - _gestureLastTime;
    if (!(dt >= 0.0) || dt > 0.25) return NO;         // 太久了，不认
    CGFloat dx = global.x - _gestureLastPoint.x;
    CGFloat dy = global.y - _gestureLastPoint.y;
    CGFloat slop = MIN(600.0, MAX(48.0, 4000.0 * dt));
    return (dx * dx + dy * dy) <= (slop * slop);
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

    const CFTimeInterval now = CACurrentMediaTime();

    /*
     * ── 手势归一化 ──
     *
     * 设备上 identity 在一次手势里会变（3 → 2），所以只要「原始 ID 相同」
     * 或「位置 + 时间连续」就按同一根手指处理，对外统一用内部编号。
     */
    NSInteger token = identity;
    if (_gestureID != 0 && identity != _gestureRawID &&
        [self gestureContinuesAt:global now:now]) {
        NSInteger previous = _gestureRawID;
        _gestureRawID = identity;
        token = _gestureID;
        if (trace)
            MFHUDLogLine(@"触点身份变化：raw %ld → %ld（同位置、%.0fms 内）→ 归一手势 #%ld",
                         (long)previous, (long)identity,
                         (now - _gestureLastTime) * 1000, (long)_gestureID);
    } else if (_gestureID != 0 && identity == _gestureRawID) {
        token = _gestureID;
    }

    if (phase == MFHUDTouchBegan &&
        ((_dragIdentity && _dragIdentity.integerValue != token) ||
         (_router.hasActiveTouch && ![_router ownsTouchID:token]))) {
        // A changed-only packet can introduce a second finger without carrying
        // the first. Cancel the previous press; never transfer it or click it.
        [self cancelAll]; return;
    }

    CGPoint inWindow = [window convertPoint:global fromCoordinateSpace:window.screen.fixedCoordinateSpace];
    CGPoint local = [overlay convertPoint:inWindow fromView:window];

    // 只有真正落在面板里的按下才占用手势编号（面板外的按下要穿透给下层）。
    if (phase == MFHUDTouchBegan && _gestureID == 0) {
        CGRect capture = overlay.captureRect;
        if (!CGRectIsNull(capture) && !CGRectIsEmpty(capture) &&
            CGRectContainsPoint(capture, local)) {
            _gestureID = ++_gestureCounter;
            _gestureRawID = identity;
            token = _gestureID;
        }
    }
    _gestureLastPoint = global;
    _gestureLastTime = now;

    CGRect dragRect = CGRectStandardize(overlay.headerDragRect);
    if (phase == MFHUDTouchBegan && !_dragIdentity && !_router.hasActiveTouch &&
        !CGRectIsNull(dragRect) && !CGRectIsEmpty(dragRect) &&
        CGRectContainsPoint(dragRect, local)) {
        _dragIdentity = @(token); _dragStart = global; _windowStart = window.center;
    }
    if (_dragIdentity) {
        if (_dragIdentity.integerValue != token) return;
        CGPoint center = CGPointMake(_windowStart.x + global.x - _dragStart.x,
                                     _windowStart.y + global.y - _dragStart.y);
        CGRect screen = window.screen.fixedCoordinateSpace.bounds;
        CGFloat halfW = window.bounds.size.width / 2, halfH = window.bounds.size.height / 2;
        center.x = MIN(CGRectGetMaxX(screen) - halfW, MAX(CGRectGetMinX(screen) + halfW, center.x));
        center.y = MIN(CGRectGetMaxY(screen) - halfH, MAX(CGRectGetMinY(screen) + halfH, center.y));
        window.center = center;
        [_overlay requestRedraw];
        if (phase == MFHUDTouchEnded) {
            _dragIdentity = nil;
            if (token == _gestureID) _gestureID = 0;
        }
        if (trace) MFHUDLogLine(@"触摸路由=drag phase=%ld local=%@ center=%@",
            (long)phase, NSStringFromCGPoint(local), NSStringFromCGPoint(center));
        return;
    }

    BOOL handled = [_router handleTouchID:token point:local phase:phase captureRect:overlay.captureRect];
    if (phase == MFHUDTouchEnded || phase == MFHUDTouchCancelled) {
        if (token == _gestureID) _gestureID = 0;
    }
    if (trace) MFHUDLogLine(@"触摸路由=menu phase=%ld token=%ld raw=%ld local=%@ handled=%d header=%@",
        (long)phase, (long)token, (long)identity, NSStringFromCGPoint(local), handled,
        NSStringFromCGRect(overlay.headerDragRect));
}
@end
