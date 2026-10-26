#import <UIKit/UIKit.h>
#import "MFMenuUI.h"
#import "MFMenuPanel.h"
#import "MFHUDIslandView.h"
#import "MFHUDCaptureShieldView.h"
#import "../app/Sources/Game/MFSettings.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include "../app/Sources/Render/imgui/imgui.h"
#include "../app/Sources/Render/imgui/imgui_internal.h"
#include "HUDRegressionOutput.h"
#include <cmath>

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

static CGFloat PanelScale(MFOverlayView *overlay) {
    return overlay.bounds.size.width / 360.0;
}
static CGPoint NavPoint(MFOverlayView *overlay, int tab) {
    const CGFloat scale = PanelScale(overlay);
    return CGPointMake(42 * scale, (96.5 + tab * 49) * scale);
}
static void WaitForSettingsSave(BOOL expected, NSDate *deadline, void (^completion)(void)) {
    // Yield the main queue: the production debounce also runs there. A nested
    // run loop inside our dispatch callback cannot reenter the main queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        MFSettings *reloaded = [[MFSettings alloc] init];
        if (reloaded.showBot == expected) { completion(); return; }
        CHECK(deadline.timeIntervalSinceNow > 0,
              "an idle drawing edit must persist without a manual save");
        WaitForSettingsSave(expected, deadline, completion);
    });
}
static void TestDrawingTileAndAutomaticSave(MFMenuUI *menu, MFOverlayView *overlay,
                                           void (^completion)(void)) {
    MFSettings *settings = [MFSettings shared];
    const BOOL initial = settings.showBot;
    ClickMenu(menu, overlay, NavPoint(overlay, 1));
    const CGFloat scale = PanelScale(overlay);
    // Actual production renderer: first full-width row on the people page.
    const CGPoint botTile = CGPointMake(222 * scale, 192 * scale);
    CHECK([overlay acceptsInteractionAtPoint:botTile],
          "the visible production drawing tile must accept input");
    ClickMenu(menu, overlay, botTile);
    CHECK(settings.showBot != initial,
          "tapping the active drawing page must change its production setting");
    WaitForSettingsSave(settings.showBot, [NSDate dateWithTimeIntervalSinceNow:3], ^{
        ClickMenu(menu, overlay, botTile);
        CHECK(settings.showBot == initial, "a second drawing tap must restore its preference");
        WaitForSettingsSave(initial, [NSDate dateWithTimeIntervalSinceNow:3], ^{
            ClickMenu(menu, overlay, NavPoint(overlay, 0));
            completion();
        });
    });
}
static void WaitForLootStatsSave(BOOL expected, NSDate *deadline, void (^completion)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        MFSettings *reloaded = [[MFSettings alloc] init];
        if (reloaded.showLootStats == expected) { completion(); return; }
        CHECK(deadline.timeIntervalSinceNow > 0,
              "an independent loot statistics edit must persist while idle");
        WaitForLootStatsSave(expected, deadline, completion);
    });
}
static void TestIndependentLootStatsAndSave(MFMenuUI *menu, MFOverlayView *overlay,
                                           void (^completion)(void)) {
    MFSettings *settings = [MFSettings shared];
    const BOOL initial = settings.showLootStats;
    const BOOL loot = settings.showLoot, boxes = settings.showBox, names = settings.showLootName;
    ClickMenu(menu, overlay, NavPoint(overlay, 2));
    const CGFloat scale = PanelScale(overlay);
    const CGPoint statsRow = CGPointMake(222 * scale, 300 * scale);
    ClickMenu(menu, overlay, statsRow);
    CHECK(settings.showLootStats != initial && settings.showLoot == loot &&
          settings.showBox == boxes && settings.showLootName == names,
          "the production statistics row must change only its own loot setting");
    WaitForLootStatsSave(!initial, [NSDate dateWithTimeIntervalSinceNow:3], ^{
        ClickMenu(menu, overlay, statsRow);
        CHECK(settings.showLootStats == initial,
              "a second statistics tap must restore the original preference");
        WaitForLootStatsSave(initial, [NSDate dateWithTimeIntervalSinceNow:3], ^{
            ClickMenu(menu, overlay, NavPoint(overlay, 0));
            completion();
        });
    });
}
static BOOL RectMatchesAtDisplayScale(CGRect actual, CGRect expected) {
    // UIKit's secure text canvas snaps fractional point sizes to physical
    // pixels. Preserve subpixel geometry checks without requiring bit equality.
    const CGFloat tolerance = 0.5 / UIScreen.mainScreen.scale + 1e-6;
    return fabs(actual.origin.x - expected.origin.x) <= tolerance &&
           fabs(actual.origin.y - expected.origin.y) <= tolerance &&
           fabs(actual.size.width - expected.size.width) <= tolerance &&
           fabs(actual.size.height - expected.size.height) <= tolerance;
}
static void ResizeProtectedMenu(UIWindow *window, MFHUDCaptureShieldView *shield,
                                MFOverlayView *overlay, CGSize panel, CGFloat angle) {
    const BOOL landscape = fabs(angle) > .1;
    const CGSize physical = landscape ? CGSizeMake(panel.height, panel.width) : panel;
    window.bounds = (CGRect){CGPointZero, physical};
    window.rootViewController.view.frame = window.bounds;
    shield.bounds = (CGRect){CGPointZero, panel};
    shield.center = CGPointMake(physical.width / 2, physical.height / 2);
    shield.transform = CGAffineTransformMakeRotation(angle);
    // Match the production host's layout, including while already rotated.
    overlay.bounds = shield.bounds;
    overlay.center = CGPointMake(panel.width / 2, panel.height / 2);
    [window layoutIfNeeded]; [overlay layoutIfNeeded];
    fprintf(stderr, "TRACE: angle=%.17g panel=%s window=%s root=%s shieldBounds=%s shieldFrame=%s content=%s overlayFrame=%s overlayBounds=%s\n",
            (double)angle, NSStringFromCGSize(panel).UTF8String,
            NSStringFromCGRect(window.bounds).UTF8String,
            NSStringFromCGRect(window.rootViewController.view.bounds).UTF8String,
            NSStringFromCGRect(shield.bounds).UTF8String,
            NSStringFromCGRect(shield.frame).UTF8String,
            NSStringFromCGRect(shield.contentView.bounds).UTF8String,
            NSStringFromCGRect(overlay.frame).UTF8String,
            NSStringFromCGRect(overlay.bounds).UTF8String);
    CHECK(RectMatchesAtDisplayScale(overlay.frame, shield.contentView.bounds) &&
          RectMatchesAtDisplayScale(overlay.bounds, (CGRect){CGPointZero, panel}),
          "the nested Metal view must fill its native host within physical pixel rounding");
}
static void InitializeImGui(void) {
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO(); io.IniFilename = nullptr;
    unsigned char *pixels; int width, height;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
}
static void TestProductionMenuLayoutAndControls(void (^completion)(void)) {
    MFSettings *settings = [MFSettings shared];
    settings.masterEnabled = NO; settings.drawEnabled = YES;
    const CGSize panel = MFMenuPanelPreferredSize(CGSizeMake(390, 844));
    UIWindow *window = [[UIWindow alloc] initWithFrame:(CGRect){CGPointMake(0, 100), panel}];
    window.rootViewController = [UIViewController new];
    window.rootViewController.view.frame = window.bounds;
    NSString *error = nil;
    MFHUDCaptureShieldView *shield = [[MFHUDCaptureShieldView alloc] initWithFrame:window.bounds error:&error];
    CHECK(shield && !error, "production layout must use the real capture shield");
    CHECK([shield setCaptureProtectionEnabled:YES error:&error] && !error,
          "layout regression must also cover the secure canvas");
    [window.rootViewController.view addSubview:shield];
    MFOverlayView *overlay = [[MFOverlayView alloc] initWithFrame:window.bounds interactive:YES];
    overlay.automaticallyStartsRendering = NO;
    [shield.contentView addSubview:overlay]; window.hidden = NO;
    MFMenuUI *menu = [MFMenuUI new];
    [MFMenuUI setGlobalVisible:YES]; [MFMenuUI setCollapsed:NO];
    __block NSUInteger collapseChanges = 0;
    [MFMenuUI setCollapseChangeHandler:^(BOOL collapsed) { collapseChanges++; }];
    InitializeImGui(); Frame(menu, overlay); Frame(menu, overlay);
    CHECK(fabs(overlay.captureRect.size.width - panel.width) < 1.1 &&
          fabs(overlay.captureRect.size.height - panel.height) < 1.1,
          "active UIPort must fill the native host without a second 66-percent size reduction");
    const CGRect header = overlay.headerDragRect;
    CHECK(!CGRectIsNull(header) && !CGRectIsEmpty(header) &&
          CGRectGetMaxX(header) < panel.width && CGRectGetMaxY(header) < panel.height / 4,
          "the active menu must publish a bounded native title drag area excluding its buttons");
    // The previous UI only enabled drawEnabled, leaving a persisted master
    // gate off. Re-enable a mixed legacy configuration through the actual row.
    const CGFloat masterScale = PanelScale(overlay);
    ClickMenu(menu, overlay, CGPointMake(222 * masterScale, 348 * masterScale));
    CHECK(settings.masterEnabled && settings.drawEnabled,
          "the visible drawing master must enable both production draw gates");
    ClickMenu(menu, overlay, CGPointMake(222 * masterScale, 348 * masterScale));
    CHECK(!settings.masterEnabled && !settings.drawEnabled,
          "the drawing master must also disable both gates");
    ClickMenu(menu, overlay, CGPointMake(222 * masterScale, 348 * masterScale));
    const int tabs[] = {1,2,3,0};
    for (int tab : tabs) {
        const CGPoint point = NavPoint(overlay, tab);
        CHECK([overlay acceptsInteractionAtPoint:point], "each useful navigation target must be reachable");
        ClickMenu(menu, overlay, point);
        CHECK(ImGui::GetDrawData()->TotalVtxCount > 100 && ImGui::GetActiveID() == 0,
              "page selection must render content and release its touch owner");
    }
    TestDrawingTileAndAutomaticSave(menu, overlay, ^{
      TestIndependentLootStatsAndSave(menu, overlay, ^{
        for (int cycle = 0; cycle < 3; cycle++) {
            const CGFloat scale = PanelScale(overlay);
            ClickMenu(menu, overlay, CGPointMake((360 - 78) * scale, 30 * scale));
            CHECK([MFMenuUI collapsed] && collapseChanges == (NSUInteger)(cycle * 2 + 1),
                  "the active minimize button must notify the native presentation owner once");
            Frame(menu, overlay); Frame(menu, overlay);
            CHECK(CGRectIsNull(overlay.captureRect) || CGRectIsEmpty(overlay.captureRect),
                  "a collapsed panel must release its former touch surface to the separate island");
            [MFMenuUI setCollapsed:NO];
            Frame(menu, overlay); Frame(menu, overlay);
            CHECK(collapseChanges == (NSUInteger)(cycle * 2 + 2) &&
                  !CGRectIsEmpty(overlay.headerDragRect) && !CGRectIsNull(overlay.captureRect),
                  "native island expansion must restore the same complete, draggable panel");
        }
        const CGFloat angles[] = {(CGFloat)M_PI_2, (CGFloat)-M_PI_2, 0};
        for (CGFloat angle : angles) {
            ResizeProtectedMenu(window, shield, overlay, panel, angle);
            Frame(menu, overlay); Frame(menu, overlay);
            const CGPoint tab = [overlay convertPoint:NavPoint(overlay, 1) toView:window];
            CHECK([window hitTest:tab withEvent:nil] == overlay,
                  "secure hosted content must preserve visible navigation hits in both landscape directions");
            CHECK(RectMatchesAtDisplayScale(header, overlay.headerDragRect),
                  "rotating the host must not alter the panel's logical title drag area");
        }
        [MFMenuUI setCollapseChangeHandler:nil];
        ImGui::DestroyContext(); window.hidden = YES;
        completion();
      });
    });
}

@interface IslandFixtureTouch : NSObject
@property CGPoint point;
@end
@implementation IslandFixtureTouch
- (CGPoint)locationInView:(UIView *)view { return self.point; }
@end
static void TestNativeIslandInputAndAccessibility(void) {
    MFHUDIslandView *island = [[MFHUDIslandView alloc] initWithFrame:(CGRect){CGPointZero, MFHUDIslandView.preferredSize}];
    [island layoutIfNeeded];
    CHECK(CGSizeEqualToSize(island.intrinsicContentSize, CGSizeMake(212,44)) &&
          [island.accessibilityIdentifier isEqual:@"hud.dynamicIsland"],
          "the native island must keep its compact, accessible touch surface");
    [island setExpanded:YES animated:NO];
    CHECK(island.isExpanded && [island.accessibilityValue isEqual:@"已展开"],
          "island accessibility must reflect the current expanded state");
    [island setExpanded:NO animated:NO];
    CHECK(!island.isExpanded && [island.accessibilityValue isEqual:@"已收起"],
          "island accessibility must reflect the current collapsed state");
    [island updateRealCount:3 botCount:7 lootCount:12 cameraValid:YES];
    UILabel *summary = [island valueForKey:@"titleLabel"];
    UILabel *detail = [island valueForKey:@"actionLabel"];
    CHECK([summary.text isEqual:@"真人 3  人机 7"] && [detail.text isEqual:@"物资 12 · 展开"],
          "native island must display real counters as system-font text");
    CHECK([island.accessibilityValue containsString:@"真人3，人机7，物资12"],
          "island counters must also reach accessibility");
    [island setExpanded:YES animated:NO];
    CHECK([detail.text isEqual:@"物资 12 · 收起"],
          "toggling the menu must preserve the current island statistics");
    [island updateRealCount:99 botCount:99 lootCount:99 cameraValid:NO];
    CHECK([summary.text isEqual:@"小玉 · 等待画面"] && [detail.text isEqual:@"轻点收起"],
          "an unavailable camera must clear stale counts instead of advertising old data");
    __block NSUInteger deliveries = 0;
    MFMenuPanelReportStats(0, 0, 0, NO, 0);
    MFMenuPanelSetStatsChangeHandler(^(int real, int bot, int loot, BOOL cameraOK) {
        deliveries++;
        [island updateRealCount:real botCount:bot lootCount:loot cameraValid:cameraOK];
    });
    MFMenuPanelReportStats(2, 4, 31, YES, 0);
    MFMenuPanelReportStats(2, 4, 31, YES, 0);
    CHECK(deliveries == 2 && [summary.text isEqual:@"真人 2  人机 4"],
          "production stats must reach the island even without panel rendering and skip unchanged counts");
    MFMenuPanelReportStats(2, 4, 31, NO, 0);
    CHECK([summary.text isEqual:@"小玉 · 等待画面"],
          "production stats must clear the native island after acquisition fails");
    MFMenuPanelSetStatsChangeHandler(nil);
    __block NSUInteger activations = 0;
    island.activationHandler = ^{ activations++; };
    IslandFixtureTouch *touch = [IslandFixtureTouch new]; touch.point = CGPointMake(71,18);
    NSSet<UITouch *> *touches = (NSSet<UITouch *> *)[NSSet setWithObject:touch];
    [island touchesBegan:touches withEvent:nil];
    CHECK(island.isPressed && activations == 0, "UIKit fallback must wait for touch release before toggling");
    [island touchesEnded:touches withEvent:nil];
    CHECK(!island.isPressed && activations == 1, "UIKit fallback must activate once on release inside");
    island.usesExternalTouchInput = YES;
    [island touchesBegan:touches withEvent:nil]; [island touchesEnded:touches withEvent:nil];
    CHECK(!island.isPressed && activations == 1,
          "native touch delivery must be suppressed when the HID bridge owns island input");
    CHECK([island accessibilityActivate] && activations == 2,
          "VoiceOver activation must remain available when external touch routing is enabled");
    island.hidden = YES;
    CHECK(![island accessibilityActivate] && activations == 2, "hidden island accessibility must not toggle a panel");
}

// Capture the actual Metal-rendered production menu after the CPU layout
// checks, so the release's header/footer and Chinese labels can be inspected.
static UIWindow *sPreviewWindow;
static MFOverlayView *sPreviewOverlay;
static MFMenuUI *sPreviewMenu;
static UIWindow *sPreviewIslandWindow;
static BOOL sPreviewFinished;
static void PreviewProductionMenu(void) {
    const CGSize size = MFMenuPanelPreferredSize(UIScreen.mainScreen.fixedCoordinateSpace.bounds.size);
    [MFMenuUI setCollapsed:NO];
    sPreviewWindow = [[UIWindow alloc] initWithFrame:(CGRect){CGPointMake(16, 90), size}];
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
    sPreviewIslandWindow = [[UIWindow alloc] initWithFrame:CGRectMake(
        (UIScreen.mainScreen.bounds.size.width - MFHUDIslandView.preferredSize.width) * .5,
        42, MFHUDIslandView.preferredSize.width, MFHUDIslandView.preferredSize.height)];
    sPreviewIslandWindow.windowLevel = UIWindowLevelAlert + 1;
    sPreviewIslandWindow.rootViewController = [UIViewController new];
    sPreviewIslandWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
    MFHUDIslandView *previewIsland = [[MFHUDIslandView alloc] initWithFrame:sPreviewIslandWindow.bounds];
    [previewIsland setExpanded:YES animated:NO];
    [previewIsland updateRealCount:3 botCount:7 lootCount:12 cameraValid:YES];
    [sPreviewIslandWindow.rootViewController.view addSubview:previewIsland];
    sPreviewIslandWindow.hidden = NO;
    [sPreviewIslandWindow layoutIfNeeded];
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
        TestProductionMenuLayoutAndControls(^{
            TestNativeIslandInputAndAccessibility();
            PreviewProductionMenu();
        });
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(MenuRegressionDelegate.class)); }
}
