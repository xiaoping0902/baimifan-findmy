#pragma once

@interface MFDrawingLayer (SkeletonScaleRegressionEntryPoint)
- (void)drawEntity:(MFEntity *)entity drawList:(ImDrawList *)drawList
          settings:(MFSettings *)settings screen:(ImVec2)screen camera:(MFCamera)camera;
- (void)drawSkeleton:(MFEntity *)entity drawList:(ImDrawList *)drawList
            settings:(MFSettings *)settings camera:(MFCamera)camera at:(ImVec2)point
              height:(float)height;
@end

// Observe the height at the real fallback boundary, then execute the real
// skeleton renderer as well. Neither the projection nor draw methods are mocked.
@interface SkeletonScaleDrawing : MFDrawingLayer
@property (nonatomic) float lastFallbackHeight;
@end
@implementation SkeletonScaleDrawing
- (void)drawSkeleton:(MFEntity *)entity drawList:(ImDrawList *)drawList
            settings:(MFSettings *)settings camera:(MFCamera)camera at:(ImVec2)point
              height:(float)height {
    self.lastFallbackHeight = height;
    [super drawSkeleton:entity drawList:drawList settings:settings camera:camera at:point height:height];
}
@end

static void TestSkeletonPerspectiveScaling(void) {
    ImGuiContext *previous = ImGui::GetCurrentContext();
    ImGuiContext *context = ImGui::CreateContext();
    ImGui::SetCurrentContext(context);
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.DisplaySize = ImVec2(640, 720);
    unsigned char *pixels; int width, height;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);

    MFSettings *settings = [MFSettings new];
    [settings resetToDefaults];
    settings.showName = settings.showTeam = settings.showArmor = settings.showHeld = NO;
    settings.showHealth = settings.showDistance = settings.showTracer = NO;
    settings.showSkeleton = YES; settings.skeletonDistance = 500;
    settings.skeletonThickness = 1; settings.smoothAim = NO;
    SkeletonScaleDrawing *drawing = [SkeletonScaleDrawing new];

    struct Sample { float bodyHeight, drawnHeight; };
    auto render = [&](float meters, float fov) -> Sample {
        MFEntity *entity = [MFEntity new];
        entity.address = 0; // Forces fallback before any remote bone read.
        entity.worldX = meters * 100; entity.worldY = entity.worldZ = 0;
        entity.distanceMeters = meters;
        entity.screen = (MFPoint2D){320, 360, YES}; entity.isVisible = YES;
        MFCamera camera = {}; camera.fov = fov;
        drawing.lastFallbackHeight = 0;
        ImGui::NewFrame();
        ImDrawList *list = ImGui::GetBackgroundDrawList();
        [drawing drawEntity:entity drawList:list settings:settings screen:ImVec2(640,720) camera:camera];
        float top = INFINITY, bottom = -INFINITY;
        for (const ImDrawVert &vertex : list->VtxBuffer) {
            top = fminf(top, vertex.pos.y); bottom = fmaxf(bottom, vertex.pos.y);
        }
        const Sample sample{drawing.lastFallbackHeight, bottom - top};
        ImGui::Render();
        CHECK(std::isfinite(sample.drawnHeight) && sample.drawnHeight > 0,
              "skeleton scale fixture must draw the production fallback without remote reads");
        return sample;
    };

    const Sample near = render(40, 90), far = render(80, 90), farther = render(160, 90);
    CHECK(fabsf(near.bodyHeight - 14.08f) < .02f &&
          fabsf(far.bodyHeight - 7.04f) < .02f && fabsf(farther.bodyHeight - 3.52f) < .02f,
          "the projected 176cm fallback body must halve at 40m, 80m and 160m without an 8pt floor");
    CHECK(near.drawnHeight > far.drawnHeight + 3 && far.drawnHeight > farther.drawnHeight + 1,
          "actual fallback line geometry must keep shrinking beyond the old minimum-size distance");

    // The failed-projection branch estimates a 180cm body using focal/depth.
    // Its independent clamp must not reintroduce the same fixed-size plateau.
    const Sample estimatedFar = render(80, NAN), estimatedFarther = render(160, NAN);
    CHECK(fabsf(estimatedFar.bodyHeight - 7.2f) < .02f &&
          fabsf(estimatedFarther.bodyHeight - 3.6f) < .02f &&
          estimatedFar.drawnHeight > estimatedFarther.drawnHeight + 1,
          "estimated fallback bodies must also retain perspective scaling at long distance");

    ImGui::DestroyContext(context);
    ImGui::SetCurrentContext(previous);
    puts("PASS: production fallback skeletons shrink with distance in projected and estimated paths");
}
