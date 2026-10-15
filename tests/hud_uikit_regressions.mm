#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "MFHUDAppDelegate.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); fflush(stderr); exit(1); } } while (0)

@interface UIWindow (MFRegressionPrivateAPI)
- (BOOL)_ignoresHitTest;
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
    CHECK([allocated _ignoresHitTest],
          "drawing window must ignore server hit testing BEFORE UIWindow initialization");

    Method options = class_getInstanceMethod(UIWindow.class,
                                             @selector(_contextOptionsWithInitialOptions:));
    CHECK(options != NULL, "UIKit context creation options must be observable");
    originalContextOptions = method_setImplementation(options, (IMP)ObserveOptions);
    UIWindow *drawing = [allocated initWithFrame:UIScreen.mainScreen.fixedCoordinateSpace.bounds];
    drawing.rootViewController = [UIViewController new];
    drawing.hidden = NO;
    [drawing layoutIfNeeded];
    [CATransaction flush];
    method_setImplementation(options, originalContextOptions);
    CHECK(drawingContextCreations > 0, "test must observe a real UIKit context creation");
    CHECK(interactiveDrawingCreations == 0,
          "UIKit must never create an interactive context for the drawing window");
    CHECK(!drawing.isKeyWindow, "a display-only window must not take application key focus");
    CHECK([drawing hitTest:CGPointMake(30, 30) withEvent:nil] == nil,
          "drawing content must reject local touch hit testing too");
    drawing.hidden = YES;
}

static void TestMenuUsesItsVisiblePanel(void) {
    MFHUDWindow *menu = [[MFHUDWindow alloc] initWithFrame:CGRectMake(24, 90, 348, 520)];
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

@interface RegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation RegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
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
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RegressionDelegate.class)); }
}
