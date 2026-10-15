#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "MFHUDInputBridge.h"
#import "MFHUDLog.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); fflush(stderr); exit(1); } } while (0)

// Use real IOHID events and production input/coordinate/ownership code. Only AX
// decoding and Metal output are substituted: the device's AX IDs change 3 -> 2
// during one tap, while BackBoard retains touch ID 420 on path 12 throughout it.
typedef CFTypeRef (*CreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double,
    Boolean, Boolean, uint32_t);
typedef void (*AppendEvent)(CFTypeRef, CFTypeRef, uint32_t);
static CreateDigitizer createDigitizer;
static AppendEvent appendEvent;

@interface MFHUDInputBridge (Regression)
- (void)receiveHIDEvent:(CFTypeRef)event queuedAt:(CFTimeInterval)queuedAt;
@end

@interface AXFixturePath : NSObject
@property unsigned char pathIdentity;
@end
@implementation AXFixturePath
@end
@interface AXFixtureHand : NSObject
@property (strong) NSArray *paths;
@end
@implementation AXFixtureHand
@end
@interface AXFixtureEvent : NSObject
@property (strong) AXFixtureHand *handInfo;
@property CGPoint location;
@property BOOL isTouchDown, isMove, isCancel, isLift, isInRangeLift, isInRange;
+ (instancetype)representationWithHIDEvent:(CFTypeRef)event hidStreamIdentifier:(NSString *)identifier;
@end
static AXFixtureEvent *currentAX;
@implementation AXFixtureEvent
+ (instancetype)representationWithHIDEvent:(CFTypeRef)event hidStreamIdentifier:(NSString *)identifier {
    return currentAX;
}
@end

@interface TouchRecorder : NSObject
@property NSUInteger presses, releases, cancellations;
@property CGPoint lastPoint;
- (void)addTouchX:(float)x y:(float)y down:(BOOL)down;
- (void)cancelTouch;
@end
@implementation TouchRecorder
- (void)addTouchX:(float)x y:(float)y down:(BOOL)down {
    if (down) self.presses++; else self.releases++;
    self.lastPoint = CGPointMake(x, y);
}
- (void)cancelTouch { self.cancellations++; }
@end

// A real UIView supplies UIKit coordinate conversion, without starting Metal.
@interface InputPanel : UIView
@property CGRect captureRect, headerDragRect;
@property BOOL hasCompletedFrame;
@property (strong) TouchRecorder *imgui;
@end
@implementation InputPanel
@end

void MFHUDLogLine(NSString *format, ...) { }

static CFTypeRef Contact(uint32_t identity, BOOL touch, BOOL range) {
    CFTypeRef event = createDigitizer(kCFAllocatorDefault, 0, 2, 12, identity,
        2, 0, 0.3, 0.4, 0, touch ? 1 : 0, 0, range, touch, 0);
    CHECK(event, "the test must create real IOKit digitizer contacts");
    return event;
}
static CFTypeRef Hand(uint32_t identity, BOOL touch, uint32_t secondary = 0, BOOL range = YES) {
    CFTypeRef parent = createDigitizer(kCFAllocatorDefault, 0, 3, 0, 0,
        2, 0, 0.3, 0.4, 0, 0, 0, range, touch, 0);
    CHECK(parent, "the test must create a real IOKit hand collection");
    CFTypeRef child = Contact(identity, touch, range);
    appendEvent(parent, child, 0); CFRelease(child);
    if (secondary) {
        child = Contact(secondary, YES, YES);
        appendEvent(parent, child, 0); CFRelease(child);
    }
    return parent;
}
static void Send(MFHUDInputBridge *bridge, UIWindow *window, InputPanel *panel,
                 uint32_t identity, unsigned char axIdentity, NSInteger phase,
                 CGPoint local, uint32_t secondary = 0) {
    currentAX = [AXFixtureEvent new];
    currentAX.handInfo = [AXFixtureHand new];
    AXFixturePath *path = [AXFixturePath new]; path.pathIdentity = axIdentity;
    currentAX.handInfo.paths = secondary ? @[path, path] : @[path];
    currentAX.location = [panel convertPoint:local toCoordinateSpace:window.screen.fixedCoordinateSpace];
    currentAX.isTouchDown = phase == 0;
    currentAX.isMove = phase == 1;
    currentAX.isLift = phase == 2;
    currentAX.isInRangeLift = phase == 3;
    CFTypeRef event = Hand(identity, phase < 2, secondary, phase != 3);
    [bridge receiveHIDEvent:event queuedAt:CACurrentMediaTime()];
    CFRelease(event);
}
static MFHUDInputBridge *NewBridge(UIWindow **windowOut, InputPanel **panelOut) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(50, 100, 348, 520)];
    window.rootViewController = [UIViewController new];
    InputPanel *panel = [[InputPanel alloc] initWithFrame:window.bounds];
    panel.captureRect = panel.bounds; panel.headerDragRect = CGRectMake(0, 0, 248, 31);
    panel.hasCompletedFrame = YES; panel.imgui = [TouchRecorder new];
    [window.rootViewController.view addSubview:panel]; window.hidden = NO;
    MFHUDInputBridge *bridge = [[MFHUDInputBridge alloc] initWithOverlay:(MFOverlayView *)panel window:window];
    [bridge setValue:AXFixtureEvent.class forKey:@"representationClass"];
    *windowOut = window; *panelOut = panel;
    return bridge;
}
static void TestDeviceTapReleasesDespiteChangingAXIdentity(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 420, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 420, 2, 2, CGPointMake(80, 100));
    CHECK(p.imgui.presses == 1 && p.imgui.releases == 1,
          "one device tap must release even when AX pathIdentity changes from 3 to 2");
    Send(b, w, p, 420, 2, 3, CGPointMake(80, 100));
    CHECK(p.imgui.releases == 1, "range-out after lift must not release twice");
    Send(b, w, p, 421, 3, 0, CGPointMake(180, 200));
    Send(b, w, p, 421, 2, 3, CGPointMake(180, 200));
    CHECK(p.imgui.presses == 2 && p.imgui.releases == 2 && p.imgui.lastPoint.x == 180,
          "the next tap at another control must get its own complete press and release");
    Send(b, w, p, 0x800001A4u, 3, 0, CGPointMake(100, 150));
    Send(b, w, p, 0x800001A4u, 2, 3, CGPointMake(100, 150));
    CHECK(p.imgui.presses == 3 && p.imgui.releases == 3,
          "a contact with bit 31 set must remain a valid positive full-width ID");
    w.hidden = YES;
}
static void TestDifferentRawContactCannotReleasePrimary(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 420, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 676, 3, 1, CGPointMake(180, 200));
    Send(b, w, p, 676, 3, 2, CGPointMake(180, 200));
    CHECK(p.imgui.presses == 1 && p.imgui.releases == 0,
          "another raw contact, including one with equal low eight bits, cannot move or release the primary");
    Send(b, w, p, 420, 2, 2, CGPointMake(80, 100));
    CHECK(p.imgui.releases == 1, "only the full original raw contact ID may release");
    w.hidden = YES;
}
static void TestTitleDragEndsWithTheSameRawContact(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    CGPoint start = w.center;
    Send(b, w, p, 422, 3, 0, CGPointMake(80, 15));
    Send(b, w, p, 422, 3, 1, CGPointMake(100, 25));
    CHECK(fabs(w.center.x - start.x - 20) < 0.1, "title movement must move the actual window");
    Send(b, w, p, 422, 2, 2, CGPointMake(80, 15));
    CGPoint released = w.center;
    Send(b, w, p, 423, 3, 0, CGPointMake(180, 200));
    Send(b, w, p, 423, 2, 2, CGPointMake(180, 200));
    CHECK(CGPointEqualToPoint(released, w.center) && p.imgui.presses == 1 && p.imgui.releases == 1,
          "a released title must not swallow the next control tap or keep moving the window");
    w.hidden = YES;
}
static void TestMultipleContactsCancelWithoutActivating(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 420, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 420, 3, 1, CGPointMake(80, 100), 421);
    CHECK(p.imgui.cancellations == 1 && p.imgui.releases == 0,
          "multi-contact aggregate coordinates must cancel without activating a control");
    Send(b, w, p, 421, 2, 2, CGPointMake(180, 200));
    CHECK(p.imgui.releases == 0, "a secondary lift after cancellation must not activate a control");
    w.hidden = YES;
}

@interface InputRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation InputRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        createDigitizer = (CreateDigitizer)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        appendEvent = (AppendEvent)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        CHECK(createDigitizer && appendEvent, "real IOKit event factories must be available");
        TestDeviceTapReleasesDespiteChangingAXIdentity();
        TestDifferentRawContactCannotReleasePrimary();
        TestTitleDragEndsWithTheSameRawContact();
        TestMultipleContactsCancelWithoutActivating();
        puts("PASS: production HID bridge releases device taps and drags with stable raw contact ownership");
        fflush(stdout); exit(0);
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(InputRegressionDelegate.class)); }
}
