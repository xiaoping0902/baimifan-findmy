#import <UIKit/UIKit.h>
#import "MFMenuUI.h"
#import "MFHUDCaptureShieldView.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include "../app/Sources/Render/imgui/imgui.h"
#include "../app/Sources/Render/imgui/imgui_internal.h"
#include "HUDRegressionOutput.h"

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } } while (0)

static void Frame(MFMenuUI *menu, MFOverlayView *overlay) {
    ImGui::GetIO().DisplaySize = ImVec2(overlay.bounds.size.width, overlay.bounds.size.height);
    ImGui::GetIO().DeltaTime = 1.0f / 60;
    ImGui::NewFrame();
    [menu overlayBuildUI:nil overlay:overlay];
    ImGui::Render();
}

static void ClickMenu(MFMenuUI *menu, MFOverlayView *overlay, CGPoint point) {
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent(point.x, point.y);
    io.AddMouseButtonEvent(0, true);
    Frame(menu, overlay); Frame(menu, overlay);
    io.AddMouseButtonEvent(0, false);
    Frame(menu, overlay); Frame(menu, overlay);
}

static void TestButtonsAndBallAtNativeSize(void) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 100, 348, 520)];
    window.rootViewController = [UIViewController new];
    NSString *captureError = nil;
    MFHUDCaptureShieldView *shield = [[MFHUDCaptureShieldView alloc] initWithFrame:window.bounds
                                                                          error:&captureError];
    CHECK(shield && !captureError, "production menu cycles require the real secure canvas");
    [window.rootViewController.view addSubview:shield];
    MFOverlayView *overlay = [[MFOverlayView alloc] initWithFrame:window.bounds interactive:YES];
    overlay.automaticallyStartsRendering = NO;
    [shield.contentView addSubview:overlay]; window.hidden = NO;
    MFMenuUI *menu = [MFMenuUI new];
    [MFMenuUI setCollapsed:NO];
    __block BOOL resizePending = NO;
    [MFMenuUI setCollapseChangeHandler:^(BOOL collapsed) { resizePending = YES; }];
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO(); io.IniFilename = nullptr;
    unsigned char *pixels; int width, height;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
    Frame(menu, overlay); Frame(menu, overlay);
    // These are the actual production buttons, not a replacement ball widget.
    const int tabSequence[] = {1, 2, 0, 2, 1, 0};
    for (int tab : tabSequence) {
        ClickMenu(menu, overlay, CGPointMake(64 + tab * 110, 80));
        CHECK([[menu valueForKey:@"tab"] intValue] == tab,
              "each production tab click must select its page without a stuck press");
    }
    for (int cycle = 0; cycle < 3; cycle++) {
        ClickMenu(menu, overlay, CGPointMake(220, 28));
        CHECK([MFMenuUI collapsed] && resizePending,
              "the production collapse button must request a native-window resize");
        resizePending = NO;
        window.bounds = CGRectMake(0, 0, 56, 56);
        window.rootViewController.view.frame = window.bounds;
        shield.frame = window.bounds; [shield layoutIfNeeded];
        overlay.frame = window.bounds;
        Frame(menu, overlay); Frame(menu, overlay);
        CHECK(CGSizeEqualToSize(overlay.captureRect.size, CGSizeMake(56, 56)) &&
              [overlay acceptsInteractionAtPoint:CGPointMake(28, 28)] &&
              ![overlay acceptsInteractionAtPoint:CGPointMake(100, 100)] &&
              ImGui::GetDrawData()->TotalVtxCount > 20,
              "the 56pt native window must contain a drawn, hittable ball and release the old panel area");
        CHECK([shield hitTest:CGPointMake(28, 28) withEvent:nil] == overlay &&
              [shield hitTest:CGPointMake(100, 100) withEvent:nil] == nil,
              "secure canvas must preserve actual ImGui ball hits and reject the old panel area");
        ClickMenu(menu, overlay, CGPointMake(28, 28));
        CHECK(![MFMenuUI collapsed] && resizePending,
              "one tap on the real small ball must restore the production menu");
        resizePending = NO;
        window.bounds = CGRectMake(0, 0, 348, 520);
        window.rootViewController.view.frame = window.bounds;
        shield.frame = window.bounds; [shield layoutIfNeeded]; overlay.frame = window.bounds;
        Frame(menu, overlay); Frame(menu, overlay);
        CHECK(overlay.captureRect.size.width == 348 && !CGRectIsEmpty(overlay.headerDragRect),
              "restored native window must draw the reachable full menu on every cycle");
        CHECK([shield hitTest:CGPointMake(64, 80) withEvent:nil] == overlay &&
              [shield hitTest:CGPointMake(2, 200) withEvent:nil] == nil,
              "expanded secure canvas must retain tab hits and transparent menu margins");
    }
    [MFMenuUI setCollapseChangeHandler:nil];
    ImGui::DestroyContext(); window.hidden = YES;
}

static void TestProductionMenuLayout(void) {
    MFOverlayView *overlay = [[MFOverlayView alloc] initWithFrame:CGRectMake(0, 0, 348, 520)
                                                     interactive:YES];
    overlay.automaticallyStartsRendering = NO;
    MFMenuUI *menu = [MFMenuUI new];
    [MFMenuUI setGlobalVisible:YES];
    [MFMenuUI setCollapsed:NO];
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    unsigned char *pixels; int width, height;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
    Frame(menu, overlay); Frame(menu, overlay);
    CHECK(![overlay pointInside:CGPointMake(2, 200) withEvent:nil],
          "panel inner margin must remain a hole, not the whole tab content rectangle");
    CGRect header = overlay.headerDragRect;
    CHECK(!CGRectIsEmpty(header) && header.size.height < 90,
          "the menu must expose a bounded visible title drag handle");
    // Scroll the real production windows to the end; fixed chrome must survive.
    ImGuiContext *context = ImGui::GetCurrentContext();
    for (ImGuiWindow *window : context->Windows) {
        if (window->Active && window->ScrollMax.y > 0) window->Scroll.y = window->ScrollMax.y;
    }
    Frame(menu, overlay); Frame(menu, overlay);
    CHECK(CGRectEqualToRect(header, overlay.headerDragRect),
          "scrolling long settings must not scroll the title, collapse or exit out of reach");
    [MFMenuUI setCollapsed:YES];
    Frame(menu, overlay); Frame(menu, overlay);
    CHECK(overlay.captureRect.size.width == 56 && overlay.captureRect.size.height == 56,
          "collapsed menu must publish only the ball surface");
    CHECK(![overlay pointInside:CGPointMake(100, 200) withEvent:nil],
          "the previous expanded panel must stop accepting touches after collapse");
    [MFMenuUI setCollapsed:NO];
    Frame(menu, overlay); Frame(menu, overlay);
    CHECK(overlay.captureRect.size.width == 348 && !CGRectIsEmpty(overlay.headerDragRect),
          "expansion restores the complete reachable menu");
    ImGui::DestroyContext();
}

// Capture the actual Metal-rendered production menu after the CPU layout
// checks, so the release's header/footer and Chinese labels can be inspected.
static UIWindow *sPreviewWindow;
static MFOverlayView *sPreviewOverlay;
static MFMenuUI *sPreviewMenu;
static BOOL sPreviewFinished;
static void PreviewProductionMenu(void) {
    sPreviewWindow = [[UIWindow alloc] initWithFrame:CGRectMake(16, 90, 348, 520)];
    sPreviewWindow.rootViewController = [UIViewController new];
    sPreviewWindow.rootViewController.view.frame = sPreviewWindow.bounds;
    sPreviewOverlay = [[MFOverlayView alloc] initWithFrame:sPreviewWindow.bounds interactive:YES];
    sPreviewOverlay.automaticallyStartsRendering = NO;
    sPreviewMenu = [MFMenuUI new]; sPreviewMenu.overlay = sPreviewOverlay;
    sPreviewOverlay.delegate = sPreviewMenu;
    [sPreviewWindow.rootViewController.view addSubview:sPreviewOverlay];
    sPreviewWindow.hidden = NO;
    [sPreviewWindow makeKeyAndVisible];
    [sPreviewWindow layoutIfNeeded]; [sPreviewOverlay layoutIfNeeded];
    sPreviewOverlay.firstFrameCompletion = ^(NSString *error) {
        CHECK(error == nil, "the production menu must complete a real GPU frame");
        const char *ackPath = getenv("MF_REGRESSION_SCREENSHOT_ACK");
        CHECK(ackPath && *ackPath, "the menu preview requires a screenshot acknowledgement path");
        NSString *acknowledgement = [NSString stringWithUTF8String:ackPath];
        puts("READY: menu screenshot"); fflush(stdout);
        // Keep the Metal surface alive until simctl has actually saved its
        // screenshot. A fixed eight-second lifetime raced slow CI captures.
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:acknowledgement]) return;
            [timer invalidate]; sPreviewFinished = YES;
            [sPreviewOverlay stopRendering]; sPreviewWindow.hidden = YES;
            puts("PASS: production menu layout, clipping, collapse and Metal preview"); fflush(stdout);
            exit(0);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CHECK(sPreviewFinished, "the menu screenshot must be acknowledged before its deadline");
        });
    };
    NSString *error = nil;
    CHECK([sPreviewOverlay startRenderingWithError:&error], "the production menu renderer must start");
}

@interface MenuRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation MenuRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        TestProductionMenuLayout();
        TestButtonsAndBallAtNativeSize();
        PreviewProductionMenu();
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(MenuRegressionDelegate.class)); }
}
