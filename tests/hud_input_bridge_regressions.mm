#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "MFHUDInputBridge.h"
#import "MFHUDLog.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include "../app/Sources/Render/MFImGuiInput.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "HUDRegressionOutput.h"

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); fflush(stderr); exit(1); } } while (0)

// Use real IOHID events and production input/coordinate/ownership code. Only AX
// decoding and Metal output are substituted. Real M5.69 logs show both AX
// pathIdentity and raw identity changing 3 -> 2; raw index owns the gesture.
typedef CFTypeRef (*CreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double,
    Boolean, Boolean, uint32_t);
typedef void (*AppendEvent)(CFTypeRef, CFTypeRef, uint32_t);
typedef CFTypeRef (*CreateVendor)(CFAllocatorRef, uint64_t, uint16_t, uint16_t,
    uint32_t, const uint8_t *, uint32_t, uint32_t);
static CreateDigitizer createDigitizer;
static AppendEvent appendEvent;
static CreateVendor createVendor;

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
@property BOOL forwardsToImGui;
- (void)addTouchX:(float)x y:(float)y down:(BOOL)down;
- (void)cancelTouch;
@end
@implementation TouchRecorder
- (void)addTouchX:(float)x y:(float)y down:(BOOL)down {
    if (down) self.presses++; else self.releases++;
    self.lastPoint = CGPointMake(x, y);
    if (self.forwardsToImGui) {
        ImGuiIO &io = ImGui::GetIO();
        io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
        io.AddMousePosEvent(x, y);
        io.AddMouseButtonEvent(0, down);
    }
}
- (void)cancelTouch {
    self.cancellations++;
    if (self.forwardsToImGui) MFCancelImGuiTouch();
}
@end

// A real UIView supplies UIKit coordinate conversion, without starting Metal.
// M5.66: the production bridge asks the overlay for a redraw after every input
// event, so the fixture stands in for that too (a real MFOverlayView throttles
// itself down to an idle frame rate).
@interface InputPanel : UIView
@property CGRect captureRect, headerDragRect;
@property CGRect interactionRect;
@property BOOL hasCompletedFrame;
@property (strong) TouchRecorder *imgui;
@property NSUInteger redrawRequests;
- (void)requestRedraw;
@end
@implementation InputPanel
- (void)requestRedraw { self.redrawRequests++; }
- (BOOL)acceptsInteractionAtPoint:(CGPoint)point {
    return CGRectContainsPoint(self.interactionRect, point) ||
           CGRectContainsPoint(self.headerDragRect, point);
}
@end

void MFHUDLogLine(NSString *format, ...) { }

static CFTypeRef IndexedContact(uint32_t index, uint32_t identity, BOOL touch, BOOL range) {
    CFTypeRef event = createDigitizer(kCFAllocatorDefault, 0, 2, index, identity,
        2, 0, 0.3, 0.4, 0, touch ? 1 : 0, 0, range, touch, 0);
    CHECK(event, "the test must create real IOKit digitizer contacts");
    return event;
}
static CFTypeRef Contact(uint32_t identity, BOOL touch, BOOL range) {
    return IndexedContact(identity, identity, touch, range);
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
static void Deliver(MFHUDInputBridge *bridge, UIWindow *window, UIView *panel,
                    CFTypeRef event, unsigned char axIdentity, NSInteger phase,
                    CGPoint local, NSUInteger axPaths = 1) {
    currentAX = [AXFixtureEvent new];
    currentAX.handInfo = [AXFixtureHand new];
    AXFixturePath *path = [AXFixturePath new]; path.pathIdentity = axIdentity;
    currentAX.handInfo.paths = axPaths == 0 ? @[] : (axPaths == 1 ? @[path] : @[path, path]);
    currentAX.location = [panel convertPoint:local toCoordinateSpace:window.screen.fixedCoordinateSpace];
    currentAX.isTouchDown = phase == 0;
    currentAX.isMove = phase == 1;
    currentAX.isLift = phase == 2;
    currentAX.isInRangeLift = phase == 3;
    [bridge receiveHIDEvent:event queuedAt:CACurrentMediaTime()];
}
static void Send(MFHUDInputBridge *bridge, UIWindow *window, InputPanel *panel,
                 uint32_t identity, unsigned char axIdentity, NSInteger phase,
                 CGPoint local, uint32_t secondary = 0, BOOL axSeesSecondary = YES) {
    CFTypeRef event = Hand(identity, phase < 2, secondary, phase != 3);
    Deliver(bridge, window, panel, event, axIdentity, phase, local,
            secondary && axSeesSecondary ? 2 : 1);
    CFRelease(event);
}
static MFHUDInputBridge *NewBridge(UIWindow **windowOut, InputPanel **panelOut) {
    // Keep room for the title's 20pt drag on narrow iPhone simulators. Starting
    // at x=50 leaves too little room and correctly triggers clamping.
    CHECK(UIScreen.mainScreen.fixedCoordinateSpace.bounds.size.width >= 368,
          "the drag fixture needs at least 20pt of horizontal screen clearance");
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 100, 348, 520)];
    window.rootViewController = [UIViewController new];
    InputPanel *panel = [[InputPanel alloc] initWithFrame:window.bounds];
    panel.captureRect = panel.bounds; panel.headerDragRect = CGRectMake(0, 0, 248, 31);
    panel.interactionRect = panel.bounds;
    panel.hasCompletedFrame = YES; panel.imgui = [TouchRecorder new];
    [window.rootViewController.view addSubview:panel]; window.hidden = NO;
    MFHUDInputBridge *bridge = [[MFHUDInputBridge alloc] initWithOverlay:(MFOverlayView *)panel window:window];
    [bridge setValue:AXFixtureEvent.class forKey:@"representationClass"];
    *windowOut = window; *panelOut = panel;
    return bridge;
}
// Fresh M5.69 device logs: index 11 stays fixed while both AX pathIdentity
// and factory-validated raw identity change 3 (down) -> 2 (lift). Factory
// field discovery alone cannot establish that a hardware value is stable.
static void DeviceEvent(MFHUDInputBridge *bridge, UIWindow *window, InputPanel *panel,
                        uint32_t index, uint32_t identity, NSInteger phase, CGPoint local) {
    CFTypeRef finger = IndexedContact(index, identity, phase < 2, phase < 2);
    Deliver(bridge, window, panel, finger, (unsigned char)identity, phase, local);
    CFRelease(finger);
}
static void TestDeviceIndexOwnsTheCompleteGesture(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    DeviceEvent(b, w, p, 11, 3, 0, CGPointMake(220, 100));
    DeviceEvent(b, w, p, 11, 2, 3, CGPointMake(220, 100));
    CHECK(p.imgui.presses == 1 && p.imgui.releases == 1,
          "device index 11 must release when its raw identity changes 3 to 2");
    DeviceEvent(b, w, p, 12, 3, 0, CGPointMake(120, 100));
    DeviceEvent(b, w, p, 13, 3, 1, CGPointMake(125, 100));
    DeviceEvent(b, w, p, 13, 2, 3, CGPointMake(125, 100));
    CHECK(p.imgui.presses == 2 && p.imgui.releases == 1 && p.imgui.lastPoint.x == 120,
          "another index with the same hardware identity must not move or release the owner");
    DeviceEvent(b, w, p, 12, 2, 3, CGPointMake(120, 100));
    CHECK(p.imgui.releases == 2, "the original device index must still release");
    p.captureRect = p.interactionRect = p.headerDragRect = CGRectMake(0, 0, 56, 56);
    DeviceEvent(b, w, p, 0x80000006u, 3, 0, CGPointMake(28, 28));
    DeviceEvent(b, w, p, 0x80000006u, 2, 3, CGPointMake(28, 28));
    CHECK(p.imgui.presses == 3 && p.imgui.releases == 3,
          "a full-width device index must deliver the collapsed ball's expansion click");
    DeviceEvent(b, w, p, 6, 3, 0, CGPointMake(28, 28));
    DeviceEvent(b, w, p, 7, 3, 0, CGPointMake(29, 28));
    DeviceEvent(b, w, p, 6, 2, 3, CGPointMake(28, 28));
    DeviceEvent(b, w, p, 7, 2, 3, CGPointMake(29, 28));
    CHECK(p.imgui.cancellations == 1 && p.imgui.presses == 3,
          "a second index must cancel a pending ball gesture even with equal raw identities");
    w.hidden = YES;
}
static void TestOnlyTheIndexDeterminesContactValidity(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    DeviceEvent(b, w, p, 14, 0, 0, CGPointMake(120, 100));
    DeviceEvent(b, w, p, 14, 0, 3, CGPointMake(120, 100));
    CHECK(p.imgui.presses == 1 && p.imgui.releases == 1,
          "raw identity is diagnostic and must not invalidate a nonzero contact index");
    DeviceEvent(b, w, p, 15, 3, 0, CGPointMake(120, 100));
    DeviceEvent(b, w, p, 0, 3, 3, CGPointMake(120, 100));
    CHECK(p.imgui.cancellations == 1 && p.imgui.releases == 1,
          "a zero index with a nonzero raw identity must cancel without clicking");
    w.hidden = YES;
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
    Send(b, w, p, 422, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 422, 3, 1, CGPointMake(80, 100), 423, NO);
    CHECK(p.imgui.cancellations == 2 && p.imgui.releases == 0,
          "two raw fingers must cancel even if AX reports only one aggregate path");
    w.hidden = YES;
}
static CFTypeRef Metadata(void) {
    uint8_t byte = 0;
    CFTypeRef event = createVendor(kCFAllocatorDefault, 0, 0xFF00, 1, 0, &byte, 1, 0);
    CHECK(event, "the test must create real non-digitizer metadata events");
    return event;
}
static void TestMetadataWrappersAndStandaloneFinger(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    CFTypeRef wrapper = Metadata(), hand = Hand(424, YES), metadata = Metadata();
    // The first hand child is a vendor event; the contact is further down.
    appendEvent(wrapper, metadata, 0); appendEvent(wrapper, hand, 0);
    CFRelease(metadata); CFRelease(hand);
    Deliver(b, w, p, wrapper, 3, 0, CGPointMake(80, 100)); CFRelease(wrapper);
    CFTypeRef finger = Contact(424, NO, NO);
    Deliver(b, w, p, finger, 2, 3, CGPointMake(80, 100)); CFRelease(finger);
    CHECK(p.imgui.presses == 1 && p.imgui.releases == 1,
          "non-digitizer wrappers must not hide a contact, and a standalone finger range-out must release it");
    w.hidden = YES;
}
static void TestMetadataDoesNotEndGestureButInvalidContactCancels(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 420, 3, 0, CGPointMake(80, 100));
    CFTypeRef metadata = Metadata();
    Deliver(b, w, p, metadata, 0, 4, CGPointMake(80, 100), 0); CFRelease(metadata);
    CHECK(p.imgui.cancellations == 0 && p.imgui.releases == 0,
          "a metadata-only BKS notification must preserve the active gesture");
    Send(b, w, p, 420, 2, 2, CGPointMake(80, 100));
    CHECK(p.imgui.releases == 1, "the primary must still release after metadata");
    Send(b, w, p, 421, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 0, 3, 2, CGPointMake(80, 100));
    CHECK(p.imgui.cancellations == 1 && p.imgui.releases == 1,
          "an explicit digitizer contact without an index must cancel without clicking");
    w.hidden = YES;
}
static void TestNewFingerBeginCancelsAnExistingOwner(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 420, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 676, 3, 0, CGPointMake(180, 200));
    Send(b, w, p, 676, 2, 2, CGPointMake(180, 200));
    Send(b, w, p, 420, 2, 2, CGPointMake(80, 100));
    CHECK(p.imgui.cancellations == 1 && p.imgui.presses == 1 && p.imgui.releases == 0,
          "a new different finger must cancel the existing press even in a single-child change packet");
    w.hidden = YES;
}

// Field layout and gesture ownership are separate checks. Even at identical
// coordinates, a different full index cannot release the owner; a changing
// raw identity on the same index is covered by the hardware replay above.
static void TestForeignLiftAtSamePointCannotRelease(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 3, 3, 0, CGPointMake(80, 100));
    CHECK(p.imgui.presses == 1 && p.redrawRequests > 0,
          "a known factory index must reach ImGui and request redraw");
    Send(b, w, p, 2, 2, 2, CGPointMake(80, 100));
    CHECK(p.imgui.releases == 0,
          "a different validated contact at the same point cannot release the owner");
    Send(b, w, p, 3, 2, 3, CGPointMake(80, 100));
    CHECK(p.imgui.releases == 1, "the original contact must release despite AX identity changing");
    w.hidden = YES;
}

/*
 * 连续性兜底不能变成「谁都能释放主触点」：
 * 另一根手指出现在别处，即使它的 identity 变了也无权结束这次手势。
 */
static void TestContinuityDoesNotTransferOwnershipAcrossTheScreen(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 3, 3, 0, CGPointMake(60, 80));
    Send(b, w, p, 9, 9, 2, CGPointMake(300, 500));   // 远处、异 ID 的抬起
    CHECK(p.imgui.releases == 0,
          "a far-away contact must not end the primary gesture even when IDs change");
    Send(b, w, p, 3, 2, 2, CGPointMake(60, 80));
    CHECK(p.imgui.releases == 1, "the real owner must still be able to release");
    w.hidden = YES;
}

static void TestNearbySecondFingerCannotBorrowPrimaryIdentity(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 420, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 676, 3, 0, CGPointMake(90, 105));
    Send(b, w, p, 676, 2, 2, CGPointMake(90, 105));
    CHECK(p.imgui.cancellations == 1 && p.imgui.releases == 0,
          "a nearby new finger must cancel, never inherit an active button press");
    w.hidden = YES;
}

static void TestRawIdentityCannotCollideWithInternalToken(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    Send(b, w, p, 420, 3, 0, CGPointMake(80, 100));
    Send(b, w, p, 1, 2, 2, CGPointMake(310, 490));
    CHECK(p.imgui.releases == 0,
          "raw index 1 must not release an unrelated internal gesture token 1");
    [b cancelAll]; w.hidden = YES;
}

static void TestBlankSpaceCannotStartMenuInteraction(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    p.interactionRect = CGRectMake(30, 100, 80, 40);
    Send(b, w, p, 420, 3, 0, CGPointMake(250, 300));
    Send(b, w, p, 420, 3, 1, CGPointMake(60, 120));
    Send(b, w, p, 420, 2, 2, CGPointMake(60, 120));
    CHECK(p.imgui.presses == 0 && p.imgui.releases == 0,
          "a gesture beginning in passthrough space must never slide into a menu control");
    Send(b, w, p, 421, 3, 0, CGPointMake(60, 120));
    Send(b, w, p, 421, 2, 2, CGPointMake(60, 120));
    CHECK(p.imgui.presses == 1 && p.imgui.releases == 1,
          "visible controls must still accept a fresh complete gesture");
    w.hidden = YES;
}

static void TestBallTapAndDragHaveDifferentOutcomes(void) {
    UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
    p.captureRect = p.interactionRect = p.headerDragRect = CGRectMake(0, 0, 56, 56);
    Send(b, w, p, 420, 3, 0, CGPointMake(28, 28));
    Send(b, w, p, 420, 2, 2, CGPointMake(28, 28));
    CHECK(p.imgui.presses == 1 && p.imgui.releases == 1,
          "tapping the collapsed ball must deliver an expansion click instead of swallowing it as a drag");
    CGPoint start = w.center;
    Send(b, w, p, 421, 3, 0, CGPointMake(28, 28));
    Send(b, w, p, 421, 3, 1, CGPointMake(48, 38));
    Send(b, w, p, 421, 2, 2, CGPointMake(28, 28));
    CHECK(!CGPointEqualToPoint(start, w.center) && p.imgui.presses == 1,
          "dragging the ball moves its window without also expanding it");
    w.hidden = YES;
}

static bool BallFrame(void) {
    ImGui::NewFrame();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(56, 56));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::Begin("##ball", nullptr, ImGuiWindowFlags_NoTitleBar |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoMove |
                 ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoScrollbar);
    bool expanded = ImGui::InvisibleButton("##expand", ImVec2(56, 56));
    ImGui::End();
    ImGui::PopStyleVar();
    ImGui::Render();
    return expanded;
}

// The production bridge queues both halves of a ball tap without giving the
// router an owner. Real ImGui trickles these events across multiple frames;
// lock/rotation cancellation must discard them at every point in that sequence.
static void TestCancellationDiscardsQueuedBallTap(void) {
    for (int consumedFrames = -1; consumedFrames <= 2; consumedFrames++) {
        UIWindow *w; InputPanel *p; MFHUDInputBridge *b = NewBridge(&w, &p);
        p.captureRect = p.interactionRect = p.headerDragRect = CGRectMake(0, 0, 56, 56);
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = nullptr;
        io.DisplaySize = ImVec2(348, 520);
        io.DeltaTime = 1.0f / 60;
        io.ConfigInputTrickleEventQueue = true;
        unsigned char *pixels; int width, height;
        io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
        BallFrame(); BallFrame();
        p.imgui.forwardsToImGui = YES;
        Send(b, w, p, 420, 3, 0, CGPointMake(28, 28));
        Send(b, w, p, 420, 2, 2, CGPointMake(28, 28));
        CHECK(p.imgui.presses == 1 && p.imgui.releases == 1 &&
              ImGui::GetCurrentContext()->InputEventsQueue.Size > 0,
              "a real ball tap must queue an ImGui click before testing cancellation");
        bool expanded = false;
        if (consumedFrames >= 0) {
            for (int frame = 0; frame < consumedFrames; frame++) expanded |= BallFrame();
            CHECK(!expanded, "the cancellation fixture must stop before release activation");
            [b cancelAll];
            CHECK(p.imgui.cancellations == 1,
                  "bridge cancellation must reach ImGui exactly once after a completed ball tap");
        }
        for (int frame = 0; frame < 5; frame++) expanded |= BallFrame();
        if (consumedFrames < 0)
            CHECK(expanded, "an uncancelled queued ball tap must expand with real ImGui processing");
        else
            CHECK(!expanded && ImGui::GetActiveID() == 0 && !io.MouseDown[0] &&
                  ImGui::GetCurrentContext()->InputEventsQueue.Size == 0,
                  "a cancelled queued ball tap must never expand on a later frame");
        p.imgui.forwardsToImGui = NO;
        ImGui::DestroyContext();
        w.hidden = YES;
    }
}

// The island owns a separate, small native window. It must remain usable while
// the Metal panel is hidden or has no completed frame, without creating a
// second BKS callback or forwarding the same tap into ImGui.
static UIWindow *IslandWindow(MFHUDInputBridge *bridge, UIView **viewOut) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(80, 12, 142, 36)];
    window.rootViewController = [UIViewController new];
    window.rootViewController.view.frame = window.bounds;
    UIView *view = [[UIView alloc] initWithFrame:window.bounds];
    [window.rootViewController.view addSubview:view];
    window.hidden = NO;
    bridge.auxiliaryView = view;
    *viewOut = view;
    return window;
}
static void SendIsland(MFHUDInputBridge *bridge, UIView *view, uint32_t index,
                        NSInteger phase, CGPoint point, uint32_t secondary = 0) {
    CFTypeRef event = Hand(index, phase < 2, secondary, phase != 3);
    Deliver(bridge, view.window, view, event, phase < 2 ? 3 : 2, phase, point,
            secondary ? 2 : 1);
    CFRelease(event);
}
static void TestIslandTapDoesNotDependOnThePanel(void) {
    UIWindow *menu; InputPanel *panel; MFHUDInputBridge *bridge = NewBridge(&menu, &panel);
    UIView *island; UIWindow *islandWindow = IslandWindow(bridge, &island);
    __block NSUInteger activations = 0, presses = 0;
    __block BOOL pressed = NO;
    bridge.auxiliaryActivationHandler = ^{ activations++; };
    bridge.auxiliaryPressHandler = ^(BOOL value) { pressed = value; if (value) presses++; };
    bridge.menuInputEnabled = NO;
    menu.hidden = YES;
    panel.hasCompletedFrame = NO;
    panel.captureRect = CGRectNull;
    SendIsland(bridge, island, 0x800001A4u, 0, CGPointMake(71, 18));
    CHECK(pressed && activations == 0, "a hidden-panel island must show press feedback before activation");
    SendIsland(bridge, island, 0x800001A5u, 2, CGPointMake(71, 18));
    CHECK(pressed && activations == 0, "a foreign contact must not release the island's owner");
    SendIsland(bridge, island, 0x800001A4u, 3, CGPointMake(71, 18));
    SendIsland(bridge, island, 0x800001A4u, 2, CGPointMake(71, 18));
    CHECK(!pressed && presses == 1 && activations == 1,
          "the full-width owner index must activate a hidden-panel island exactly once on release");
    CHECK(panel.imgui.presses == 0 && panel.imgui.releases == 0,
          "an island tap must never be delivered to the Metal panel as a second click");
    islandWindow.hidden = YES;
    SendIsland(bridge, island, 20, 0, CGPointMake(71, 18));
    SendIsland(bridge, island, 20, 2, CGPointMake(71, 18));
    CHECK(activations == 1 && !pressed, "a hidden auxiliary window must not accept touches");
}
static void TestIslandCancellationAndGestureOrigin(void) {
    UIWindow *menu; InputPanel *panel; MFHUDInputBridge *bridge = NewBridge(&menu, &panel);
    UIView *island; UIWindow *islandWindow = IslandWindow(bridge, &island);
    __block NSUInteger activations = 0;
    __block BOOL pressed = NO;
    bridge.auxiliaryActivationHandler = ^{ activations++; };
    bridge.auxiliaryPressHandler = ^(BOOL value) { pressed = value; };

    SendIsland(bridge, island, 30, 0, CGPointMake(-20, 18));
    SendIsland(bridge, island, 30, 1, CGPointMake(40, 18));
    SendIsland(bridge, island, 30, 2, CGPointMake(40, 18));
    CHECK(!pressed && activations == 0,
          "a gesture beginning outside the island must not become an island tap when it crosses it");

    SendIsland(bridge, island, 31, 0, CGPointMake(40, 18));
    SendIsland(bridge, island, 31, 1, CGPointMake(55, 18));
    SendIsland(bridge, island, 31, 2, CGPointMake(55, 18));
    CHECK(!pressed && activations == 0, "movement past the tap threshold must not activate the island");
    SendIsland(bridge, island, 32, 0, CGPointMake(40, 18));
    SendIsland(bridge, island, 32, 1, CGPointMake(-10, 18));
    SendIsland(bridge, island, 32, 1, CGPointMake(40, 18));
    SendIsland(bridge, island, 32, 2, CGPointMake(40, 18));
    CHECK(!pressed && activations == 0, "dragging out and back must not turn into a release click");

    SendIsland(bridge, island, 33, 0, CGPointMake(40, 18));
    [bridge cancelAll];
    SendIsland(bridge, island, 33, 2, CGPointMake(40, 18));
    CHECK(!pressed && activations == 0, "lock or rotation cancellation must clear an island press");
    SendIsland(bridge, island, 34, 0, CGPointMake(40, 18));
    SendIsland(bridge, island, 34, 1, CGPointMake(40, 18), 35);
    SendIsland(bridge, island, 34, 2, CGPointMake(40, 18));
    CHECK(!pressed && activations == 0, "multiple contacts must cancel island activation");

    SendIsland(bridge, island, 36, 0, CGPointMake(40, 18));
    SendIsland(bridge, island, 36, 2, CGPointMake(40, 18));
    CHECK(activations == 1 && !pressed, "a fresh tap after cancellation must still work");
    CHECK(panel.imgui.presses == 0 && panel.imgui.releases == 0,
          "cancelled auxiliary gestures must never become ImGui button events");
    menu.hidden = islandWindow.hidden = YES;
}
static void TestIslandCoordinatesInBothLandscapeDirections(void) {
    UIWindow *menu; InputPanel *panel; MFHUDInputBridge *bridge = NewBridge(&menu, &panel);
    UIView *island; UIWindow *islandWindow = IslandWindow(bridge, &island);
    __block NSUInteger activations = 0;
    bridge.auxiliaryActivationHandler = ^{ activations++; };
    const CGFloat angles[] = { (CGFloat)M_PI_2, (CGFloat)-M_PI_2, 0 };
    for (CGFloat angle : angles) {
        const BOOL landscape = fabs(angle) > .1;
        islandWindow.bounds = CGRectMake(0, 0, landscape ? 36 : 142, landscape ? 142 : 36);
        islandWindow.rootViewController.view.frame = islandWindow.bounds;
        island.transform = CGAffineTransformIdentity;
        island.bounds = CGRectMake(0, 0, 142, 36);
        island.center = CGPointMake(CGRectGetMidX(islandWindow.bounds), CGRectGetMidY(islandWindow.bounds));
        island.transform = CGAffineTransformMakeRotation(angle);
        SendIsland(bridge, island, 40, 0, CGPointMake(71, 18));
        SendIsland(bridge, island, 40, 2, CGPointMake(71, 18));
    }
    CHECK(activations == 3, "fixed-screen HID coordinates must reach the rotated island in every orientation");
    Send(bridge, menu, panel, 41, 3, 0, CGPointMake(180, 200));
    Send(bridge, menu, panel, 41, 2, 2, CGPointMake(180, 200));
    CHECK(panel.imgui.presses == 1 && panel.imgui.releases == 1,
          "routing the island must preserve independent Metal panel controls");
    menu.hidden = islandWindow.hidden = YES;
}
static void TestResizeFrameGapPreservesOnlyTheEstablishedContact(void) {
    UIWindow *window; InputPanel *panel; MFHUDInputBridge *bridge = NewBridge(&window, &panel);
    Send(bridge, window, panel, 60, 3, 0, CGPointMake(180, 200));
    CHECK(panel.imgui.presses == 1 && panel.imgui.releases == 0,
          "a menu resize gesture must establish its owner before the frame generation changes");
    const NSUInteger cancellations = panel.imgui.cancellations;
    panel.hasCompletedFrame = NO;
    Send(bridge, window, panel, 60, 3, 1, CGPointMake(190, 210));
    CHECK(panel.imgui.presses == 2 && panel.imgui.releases == 0 &&
          panel.imgui.cancellations == cancellations &&
          fabs(panel.imgui.lastPoint.x - 190) < .1 && fabs(panel.imgui.lastPoint.y - 210) < .1,
          "the established contact must keep moving while resize waits for a new Metal frame");
    Send(bridge, window, panel, 60, 2, 3, CGPointMake(195, 215));
    CHECK(panel.imgui.releases == 1 && panel.imgui.cancellations == cancellations &&
          fabs(panel.imgui.lastPoint.x - 195) < .1 && fabs(panel.imgui.lastPoint.y - 215) < .1,
          "the established contact must release once during the temporary incomplete-frame gap");

    Send(bridge, window, panel, 61, 3, 0, CGPointMake(180, 200));
    Send(bridge, window, panel, 61, 2, 2, CGPointMake(180, 200));
    CHECK(panel.imgui.presses == 2 && panel.imgui.releases == 1,
          "an incomplete generation must still reject a fresh contact after the previous owner lifts");
    panel.hasCompletedFrame = YES;
    Send(bridge, window, panel, 62, 3, 0, CGPointMake(180, 200));
    Send(bridge, window, panel, 62, 2, 2, CGPointMake(180, 200));
    CHECK(panel.imgui.presses == 3 && panel.imgui.releases == 2,
          "a fresh contact must work once the resized Metal generation completes");
    window.hidden = YES;
}
static void TestTitleCanReachEveryScreenEdge(void) {
    UIWindow *window; InputPanel *panel; MFHUDInputBridge *bridge = NewBridge(&window, &panel);
    const CGRect screen = window.screen.fixedCoordinateSpace.bounds;
    Send(bridge, window, panel, 50, 3, 0, CGPointMake(80, 15));
    Send(bridge, window, panel, 50, 3, 1, CGPointMake(10000, 10000));
    CHECK(fabs(CGRectGetMaxX(window.frame) - CGRectGetMaxX(screen)) < .1 &&
          fabs(CGRectGetMaxY(window.frame) - CGRectGetMaxY(screen)) < .1,
          "title dragging must reach the real screen's bottom-right edge");
    Send(bridge, window, panel, 50, 2, 2, CGPointMake(80, 15));
    Send(bridge, window, panel, 51, 3, 0, CGPointMake(80, 15));
    Send(bridge, window, panel, 51, 3, 1, CGPointMake(-10000, -10000));
    CHECK(fabs(CGRectGetMinX(window.frame) - CGRectGetMinX(screen)) < .1 &&
          fabs(CGRectGetMinY(window.frame) - CGRectGetMinY(screen)) < .1,
          "title dragging must reach the real screen's top-left edge");
    Send(bridge, window, panel, 51, 2, 2, CGPointMake(80, 15));
    CHECK(panel.imgui.presses == 0 && panel.imgui.releases == 0,
          "moving across the full display must not click a panel control on release");
    window.hidden = YES;
}

@interface InputRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation InputRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        createDigitizer = (CreateDigitizer)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        appendEvent = (AppendEvent)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        createVendor = (CreateVendor)dlsym(RTLD_DEFAULT, "IOHIDEventCreateVendorDefinedEvent");
        CHECK(createDigitizer && appendEvent && createVendor, "real IOKit event factories must be available");
        TestDeviceIndexOwnsTheCompleteGesture();
        TestOnlyTheIndexDeterminesContactValidity();
        TestDeviceTapReleasesDespiteChangingAXIdentity();
        TestDifferentRawContactCannotReleasePrimary();
        TestTitleDragEndsWithTheSameRawContact();
        TestMultipleContactsCancelWithoutActivating();
        TestMetadataWrappersAndStandaloneFinger();
        TestMetadataDoesNotEndGestureButInvalidContactCancels();
        TestNewFingerBeginCancelsAnExistingOwner();
        TestForeignLiftAtSamePointCannotRelease();
        TestContinuityDoesNotTransferOwnershipAcrossTheScreen();
        TestNearbySecondFingerCannotBorrowPrimaryIdentity();
        TestRawIdentityCannotCollideWithInternalToken();
        TestBlankSpaceCannotStartMenuInteraction();
        TestBallTapAndDragHaveDifferentOutcomes();
        TestCancellationDiscardsQueuedBallTap();
        TestIslandTapDoesNotDependOnThePanel();
        TestIslandCancellationAndGestureOrigin();
        TestIslandCoordinatesInBothLandscapeDirections();
        TestResizeFrameGapPreservesOnlyTheEstablishedContact();
        TestTitleCanReachEveryScreenEdge();
        puts("PASS: production HID bridge releases device taps and drags with full digitizer-index ownership");
        fflush(stdout); exit(0);
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(InputRegressionDelegate.class)); }
}
