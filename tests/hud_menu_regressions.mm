#import <UIKit/UIKit.h>
#import "MFMenuUI.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include "../app/Sources/Render/imgui/imgui.h"
#include "../app/Sources/Render/imgui/imgui_internal.h"
#include "HUDRegressionOutput.h"

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } } while (0)

static void Frame(MFMenuUI *menu, MFOverlayView *overlay) {
    ImGui::GetIO().DisplaySize = ImVec2(348, 520);
    ImGui::GetIO().DeltaTime = 1.0f / 60;
    ImGui::NewFrame();
    [menu overlayBuildUI:nil overlay:overlay];
    ImGui::Render();
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

@interface MenuRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation MenuRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        TestProductionMenuLayout();
        puts("PASS: production menu layout, clipping and collapse");
        exit(0);
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(MenuRegressionDelegate.class)); }
}
