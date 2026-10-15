#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#if __has_include("MFHUDTouchRouter.h")
#import "MFHUDTouchRouter.h"
#else
typedef NS_ENUM(NSInteger, MFHUDTouchPhase) {
    MFHUDTouchBegan, MFHUDTouchMoved, MFHUDTouchEnded, MFHUDTouchCancelled
};
@protocol MFHUDTouchOutput <NSObject>
- (void)touchAtPoint:(CGPoint)point down:(BOOL)down;
- (void)scrollY:(CGFloat)delta;
@end
@interface MFHUDTouchRouter : NSObject
- (instancetype)initWithOutput:(id<MFHUDTouchOutput>)output;
- (BOOL)handleTouchID:(NSInteger)identity point:(CGPoint)point
               phase:(MFHUDTouchPhase)phase captureRect:(CGRect)rect;
- (void)cancelAll;
@end
#endif

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } } while (0)
@interface TouchOutput : NSObject <MFHUDTouchOutput>
@property NSUInteger presses, releases, positions, scrolls;
@property CGPoint lastPoint;
@property CGFloat lastScroll;
@end
@implementation TouchOutput
- (void)touchAtPoint:(CGPoint)p down:(BOOL)down {
    self.positions++; self.lastPoint = p;
    if (down) self.presses++; else self.releases++;
}
- (void)scrollY:(CGFloat)delta { self.scrolls++; self.lastScroll = delta; }
@end

static CGRect panel = CGRectMake(24, 90, 348, 520);
static MFHUDTouchRouter *NewRouter(TouchOutput *output) {
    Class cls = NSClassFromString(@"MFHUDTouchRouter");
    CHECK(cls != Nil, "HUD has no input router: visible windows cannot consume HID touches");
    return [[cls alloc] initWithOutput:output];
}

static void TestOutsideAndHiddenAreNotCaptured(void) {
    TouchOutput *o = [TouchOutput new]; MFHUDTouchRouter *r = NewRouter(o);
    CHECK(![r handleTouchID:8 point:CGPointMake(700, 400) phase:MFHUDTouchBegan captureRect:panel],
          "a gesture starting outside the panel must pass through");
    CHECK(![r handleTouchID:8 point:CGPointMake(70, 110) phase:MFHUDTouchMoved captureRect:panel],
          "moving an outside gesture into the panel must not steal it");
    CHECK(![r handleTouchID:9 point:CGPointMake(70, 110) phase:MFHUDTouchBegan captureRect:CGRectNull],
          "a hidden panel must not reserve a fallback touch rectangle");
    CHECK(![r handleTouchID:0 point:CGPointMake(70, 110) phase:MFHUDTouchBegan captureRect:panel],
          "invalid pointer IDs must not create a stuck press");
    CHECK(o.positions == 0 && o.scrolls == 0, "pass-through gestures must not enter ImGui");
}

static void TestDragOwnsFingerUntilRelease(void) {
    TouchOutput *o = [TouchOutput new]; MFHUDTouchRouter *r = NewRouter(o);
    CHECK([r handleTouchID:120 point:CGPointMake(60, 110) phase:MFHUDTouchBegan captureRect:panel],
          "valid pointer IDs must not be clamped into another finger");
    CHECK([r handleTouchID:120 point:CGPointMake(900, 700) phase:MFHUDTouchMoved captureRect:panel],
          "a captured drag must continue beyond the original panel");
    CHECK(o.presses == 2 && o.lastPoint.x == 900, "drag positions must reach the output");
    CHECK([r handleTouchID:120 point:CGPointMake(900, 700) phase:MFHUDTouchEnded captureRect:panel],
          "the release outside the panel must reach the same captured finger");
    CHECK(o.releases == 1, "a completed drag must release ImGui's mouse button");
    CHECK(![r handleTouchID:120 point:CGPointMake(900, 700) phase:MFHUDTouchEnded captureRect:panel],
          "a repeated lift must not produce a second release");
}

static void TestCancelAndHideReleaseButton(void) {
    TouchOutput *o = [TouchOutput new]; MFHUDTouchRouter *r = NewRouter(o);
    [r handleTouchID:1 point:CGPointMake(60, 110) phase:MFHUDTouchBegan captureRect:panel];
    [r handleTouchID:1 point:CGPointMake(60, 110) phase:MFHUDTouchCancelled captureRect:panel];
    CHECK(o.releases == 1, "cancel must not leave a button held");
    [r handleTouchID:2 point:CGPointMake(60, 110) phase:MFHUDTouchBegan captureRect:panel];
    [r handleTouchID:2 point:CGPointMake(65, 115) phase:MFHUDTouchMoved captureRect:CGRectNull];
    CHECK(o.releases == 2, "hiding a panel during a gesture must release its button");
    [r cancelAll];
    CHECK(o.releases == 2, "cancelling an empty router must be idempotent");
}

static void TestTwoFingerScrollDoesNotClickOnLift(void) {
    TouchOutput *o = [TouchOutput new]; MFHUDTouchRouter *r = NewRouter(o);
    [r handleTouchID:1 point:CGPointMake(60, 110) phase:MFHUDTouchBegan captureRect:panel];
    [r handleTouchID:2 point:CGPointMake(100, 150) phase:MFHUDTouchBegan captureRect:panel];
    CHECK(o.releases == 1, "starting a scroll must release the single-finger button");
    [r handleTouchID:2 point:CGPointMake(100, 170) phase:MFHUDTouchMoved captureRect:panel];
    CHECK(o.scrolls == 1 && fabs(o.lastScroll) > 0, "two fingers must generate scroll input");
    [r handleTouchID:2 point:CGPointMake(100, 170) phase:MFHUDTouchEnded captureRect:panel];
    [r handleTouchID:1 point:CGPointMake(60, 120) phase:MFHUDTouchMoved captureRect:panel];
    [r handleTouchID:1 point:CGPointMake(60, 120) phase:MFHUDTouchEnded captureRect:panel];
    CHECK(o.presses == 1 && o.releases == 1, "lifting one scroll finger must not create a phantom click");
}

int main(void) {
    @autoreleasepool {
        TestOutsideAndHiddenAreNotCaptured();
        TestDragOwnsFingerUntilRelease();
        TestCancelAndHideReleaseButton();
        TestTwoFingerScrollDoesNotClickOnLift();
        puts("PASS: HUD capture boundaries, drag lifetime, cancellation and two-finger scrolling");
    }
    return 0;
}
