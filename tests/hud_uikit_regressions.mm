#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "MFHUDAppDelegate.h"
#include <stdio.h>
#include <stdlib.h>
#include <cmath>
#include "HUDRegressionOutput.h"

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); fflush(stderr); exit(1); } } while (0)

@interface UIWindow (MFRegressionPrivateAPI)
- (BOOL)_ignoresHitTest;
- (BOOL)_canBecomeKeyWindow;
- (unsigned int)_contextId;
- (NSDictionary *)_contextOptionsWithInitialOptions:(NSDictionary *)options;
@end

// Observe the actual UIKit context creation boundary. Do not replace its result.
static IMP originalContextOptions;
static unsigned drawingContextCreations, interactiveDrawingCreations;
static NSDictionary *ObserveOptions(UIWindow *window, SEL selector, NSDictionary *options) {
    if ([window isKindOfClass:NSClassFromString(@"MFHUDDrawingWindow")] ||
        [window isKindOfClass:NSClassFromString(@"MFHUDWindow")]) {
        drawingContextCreations++;
        if (![window _ignoresHitTest]) interactiveDrawingCreations++;
    }
    return ((NSDictionary *(*)(id, SEL, NSDictionary *))originalContextOptions)(window, selector, options);
}

static void TestDrawingIsPassthroughBeforeInitialization(void) {
    // Falling back to the old shared window reproduces the M5.63 failure.
    Class drawingClass = NSClassFromString(@"MFHUDDrawingWindow") ?: MFHUDWindow.class;
    UIWindow *allocated = [drawingClass alloc];
    BOOL ignoresBeforeInit = [allocated _ignoresHitTest];
    BOOL acceptsKeyBeforeInit = [allocated _canBecomeKeyWindow];

    Method options = class_getInstanceMethod(UIWindow.class,
                                             @selector(_contextOptionsWithInitialOptions:));
    CHECK(options != NULL, "UIKit context creation options must be observable");
    originalContextOptions = method_setImplementation(options, (IMP)ObserveOptions);
    UIWindow *drawing = [allocated initWithFrame:UIScreen.mainScreen.fixedCoordinateSpace.bounds];
    // Replay the previous delegate's late property assignment when comparing
    // an older revision. The dedicated drawing class has no mutable flag.
    SEL lateSetter = NSSelectorFromString(@"setIgnoresHitTestOverride:");
    if ([drawing respondsToSelector:lateSetter])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(drawing, lateSetter, YES);
    drawing.rootViewController = [UIViewController new];
    drawing.hidden = NO;
    [drawing layoutIfNeeded];
    [CATransaction flush];
    method_setImplementation(options, originalContextOptions);
    printf("Drawing class=%s beforeInit=%d optionsCalls=%u interactiveOptionsCalls=%u context=0x%x\n",
        class_getName(drawingClass), ignoresBeforeInit, drawingContextCreations,
        interactiveDrawingCreations, drawing._contextId);
    fflush(stdout);
    CHECK(drawingContextCreations > 0, "test must observe a real UIKit context creation");
    CHECK(drawing._contextId != 0, "drawing window must have a real nonzero native context");
    CHECK(ignoresBeforeInit,
          "drawing window must ignore server hit testing BEFORE UIWindow initialization");
    CHECK(!acceptsKeyBeforeInit,
          "drawing window must be ineligible for key focus, even before initialization");
    CHECK(interactiveDrawingCreations == 0,
          "UIKit must never create an interactive context for the drawing window");
    CHECK(!drawing.isKeyWindow, "a display-only window must not take application key focus");
    CHECK([drawing hitTest:CGPointMake(30, 30) withEvent:nil] == nil,
          "drawing content must reject local touch hit testing too");
    drawing.hidden = YES;
}

static void TestMenuUsesItsVisiblePanel(void) {
    MFHUDWindow *allocated = [MFHUDWindow alloc];
    CHECK(![allocated _ignoresHitTest],
          "interactive menu role must be fixed before superclass context initialization");
    MFHUDWindow *menu = [allocated initWithFrame:CGRectMake(24, 90, 348, 520)];
    CHECK(![menu _ignoresHitTest], "menu must remain eligible for server hit testing");
    menu.rootViewController = [UIViewController new];
    UIView *panel = [[UIView alloc] initWithFrame:menu.bounds];
    [menu.rootViewController.view addSubview:panel];
    menu.interactiveView = panel;
    menu.hidden = NO;
    [menu layoutIfNeeded];
    CHECK([menu hitTest:CGPointMake(40, 60) withEvent:nil] == panel,
          "touches inside the visible menu must reach its content");
    CHECK([menu hitTest:CGPointMake(600, 700) withEvent:nil] == nil,
          "the small menu window must not capture the desktop outside its bounds");
    menu.hidden = YES;
}

@interface NSObject (CaptureShieldRegression)
- (instancetype)initWithFrame:(CGRect)frame error:(NSString **)error;
- (BOOL)captureProtectionEnabled;
- (BOOL)setCaptureProtectionEnabled:(BOOL)enabled error:(NSString **)error;
@end

static UITextField *FindSecureField(UIView *view) {
    if ([view isKindOfClass:UITextField.class] && ((UITextField *)view).secureTextEntry)
        return (UITextField *)view;
    for (UIView *child in view.subviews) {
        UITextField *field = FindSecureField(child);
        if (field) return field;
    }
    return nil;
}

static void TestCaptureShieldPreservesHitsAndResizing(void) {
    Class shieldClass = NSClassFromString(@"MFHUDCaptureShieldView");
    CHECK(shieldClass != Nil, "HUD surfaces require a secure content container");
    NSString *error = nil;
    UIView *shield = [[shieldClass alloc] initWithFrame:CGRectMake(0, 0, 348, 520) error:&error];
    CHECK(shield != nil && error == nil, "default HUD content must not require a private secure canvas");
    UIView *content = [shield valueForKey:@"contentView"];
    CHECK(content.superview == shield && FindSecureField(shield) == nil,
          "capture protection must default OFF so HUD content can be captured for debugging");
    CHECK([shield respondsToSelector:@selector(setCaptureProtectionEnabled:error:)],
          "capture protection needs an explicit opt-in switch");
    CHECK(![shield captureProtectionEnabled], "new HUD surfaces must report capture protection OFF");
    CHECK([shield setCaptureProtectionEnabled:YES error:&error] && error == nil,
          "capture protection must be available when explicitly enabled");
    UITextField *field = FindSecureField(shield);
    CHECK(content && field && [content isDescendantOfView:field],
          "protected content must actually descend from the secure text canvas");
    CHECK(!field.canBecomeFirstResponder, "capture protection must never open a text keyboard");
    MFHUDWindow *window = [[MFHUDWindow alloc] initWithFrame:CGRectMake(24, 90, 348, 520)];
    window.rootViewController = [UIViewController new];
    [window.rootViewController.view addSubview:shield];
    window.interactiveView = shield;
    UIView *control = [[UIView alloc] initWithFrame:CGRectMake(20, 20, 40, 30)];
    [content addSubview:control];
    window.hidden = NO;
    [window layoutIfNeeded]; [shield layoutIfNeeded];
    CHECK([window hitTest:CGPointMake(30, 30) withEvent:nil] == control,
          "a protected control must still receive the window hit");
    CHECK([window hitTest:CGPointMake(200, 200) withEvent:nil] == nil,
          "the secure text hierarchy must not intercept transparent blank space");
    window.bounds = CGRectMake(0, 0, 56, 56);
    shield.frame = window.bounds; [shield layoutIfNeeded];
    control.frame = CGRectMake(8, 8, 40, 40);
    CHECK(CGSizeEqualToSize(content.bounds.size, CGSizeMake(56, 56)) &&
          [window hitTest:CGPointMake(28, 28) withEvent:nil] == control &&
          [window hitTest:CGPointMake(100, 100) withEvent:nil] == nil,
          "protected ball geometry must follow native shrink without retaining the old hit area");
    window.bounds = CGRectMake(0, 0, 520, 348);
    window.rootViewController.view.frame = window.bounds;
    shield.bounds = CGRectMake(0, 0, 348, 520);
    shield.center = CGPointMake(260, 174);
    shield.transform = CGAffineTransformMakeRotation(M_PI_2);
    [shield layoutIfNeeded];
    CGPoint rotatedControl = [shield convertPoint:CGPointMake(28, 28) toView:window];
    CHECK([window hitTest:rotatedControl withEvent:nil] == control &&
          CGSizeEqualToSize(content.bounds.size, CGSizeMake(348, 520)) && FindSecureField(shield) == field,
          "rotation must preserve protected content coordinates without rebuilding the secure field");
    CHECK([shield setCaptureProtectionEnabled:NO error:&error] && ![shield captureProtectionEnabled] &&
          content.superview == shield && [window hitTest:rotatedControl withEvent:nil] == control,
          "disabling protection must retain the same content and rotated control hit coordinates");
    CHECK([shield setCaptureProtectionEnabled:YES error:&error] &&
          FindSecureField(shield) == field && [content isDescendantOfView:field] &&
          [window hitTest:rotatedControl withEvent:nil] == control,
          "re-enabling protection must reuse the secure canvas without losing controls");
    window.hidden = YES;
}

@interface RegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation RegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        TestCaptureShieldPreservesHitsAndResizing();
        TestDrawingIsPassthroughBeforeInitialization();
        TestMenuUsesItsVisiblePanel();
        puts("PASS: real UIKit drawing initialization and menu hit bounds");
        fflush(stdout);
        exit(0);
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RegressionDelegate.class)); }
}
