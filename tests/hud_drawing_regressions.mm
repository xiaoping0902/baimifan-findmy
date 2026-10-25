#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import "MFDrawingLayer.h"
#import "MFGameReader.h"
#import "MFUEReader.h"
#import "MFSettings.h"
#import "../app/Sources/Read/MFExternalFeed.h"
#import "../app/Sources/Read/MFReadBackend.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include "../app/Sources/Render/imgui/imgui.h"
#include "HUDRegressionOutput.h"
#include <cmath>

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } } while (0)

@interface MFDrawingLayer (RegressionEntryPoint)
- (void)overlayBuildUI:(MFImGuiContext *)context overlay:(MFOverlayView *)overlay;
@end

// Exercise the real renderer with synthetic entities at its frame-acquisition
// boundary. Production uses local sources; this suite must neither enable an
// obsolete UDP source nor attach to a game. Fail on any remote memory read.
static BOOL RejectRemoteRead(id object, SEL selector, uint64_t address, void *out, size_t size) {
    CHECK(NO, "synthetic drawing regression must not attempt any remote memory read");
    return NO;
}

static NSArray<MFEntity *> *sEntities;
static NSArray<MFEntity *> *sLoot;
static NSUInteger sAcquisitions;
static BOOL SupplySyntheticFrame(id object, SEL selector, CGSize size, MFCamera *camera,
                                  NSArray<MFEntity *> **entities, NSArray<MFEntity *> **loot,
                                  NSInteger *source) {
    sAcquisitions++;
    if (!sEntities) return NO;
    if (camera) { *camera = (MFCamera){0}; camera->fov = 90; }
    if (entities) *entities = sEntities;
    if (loot) *loot = sLoot ?: @[];
    // MFDrawSource uses NSInteger as its underlying ABI. Only the acquisition
    // method is replaced; overlayBuildUI and every drawing/filter method remain
    // production code. A nonzero source denotes this ready synthetic frame.
    if (source) *source = 1;
    return YES;
}

static MFEntity *Entity(float x, float y, BOOL loot, BOOL box) {
    MFEntity *entity = [MFEntity new];
    entity.address = (uint64_t)(x + 10000) + (uint64_t)(y + 10000) * 100000;
    entity.worldX = x; entity.worldY = y; entity.worldZ = 0;
    entity.distanceMeters = hypotf(x, y) / 100.0f;
    entity.bearingDeg = atan2f(y, x) * 180.0f / (float)M_PI;
    entity.isBehind = x < 0;
    entity.yawDeg = NAN;
    entity.isLoot = loot; entity.isBox = box;
    entity.name = box ? @"Fixture Box" : @"Fixture Item";
    entity.level = 4; entity.value = 20000;
    MFCamera camera = {0}; camera.fov = 90;
    MFScreen screen = [MFProjection screenWithSize:CGSizeMake(640, 720) fov:90];
    const float position[] = {x, y, 0};
    entity.screen = [MFProjection projectTarget:position camera:camera screen:screen];
    entity.isVisible = entity.screen.valid;
    return entity;
}

static ImDrawData *Frame(MFDrawingLayer *drawing, MFOverlayView *overlay) {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(640, 720);
    io.DeltaTime = 1.0f / 60.0f;
    ImGui::NewFrame();
    [drawing overlayBuildUI:nil overlay:overlay];
    ImGui::Render();
    return ImGui::GetDrawData();
}

static void TestSyntheticDrawing(void) {
    MFGameReader *reader = [MFGameReader shared];
    reader.targetTaskPort = MACH_PORT_NULL;
    reader.rootObjectBase = reader.entityArrayBase = reader.lootArrayBase = 0;
    [MFUEReader shared].libBase = 0;
    CHECK(!reader.ready && ![MFReadBackend shared].gateOpen,
          "synthetic fixture must begin with no local reader readiness or target port");
    Method remoteRead = class_getInstanceMethod(MFReadBackend.class, @selector(readRemote:into:size:));
    CHECK(remoteRead != NULL, "production memory boundary must exist for the fail-fast guard");
    IMP originalRemoteRead = method_setImplementation(remoteRead, (IMP)RejectRemoteRead);

    MFSettings *settings = [MFSettings shared];
    [settings resetToDefaults];
    settings.masterEnabled = settings.drawEnabled = YES;
    settings.renderSelfTest = NO;
    settings.showName = settings.showArmor = settings.showHealth = NO;
    settings.showDistance = settings.showTeam = NO;
    [MFDrawingLayer setEnabled:YES];
    MFExternalFeed *feed = [MFExternalFeed shared];
    MFOverlayView *overlay = [[MFOverlayView alloc] initWithFrame:CGRectMake(0, 0, 640, 720)
                                                               interactive:NO];
    overlay.automaticallyStartsRendering = NO;
    MFDrawingLayer *drawing = [MFDrawingLayer new];
    drawing.overlay = overlay;

    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO(); io.IniFilename = nullptr;
    unsigned char *pixels; int fontWidth, fontHeight;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &fontWidth, &fontHeight);

    // Check the actual current source selection before injecting any frame.
    const int unavailableVertices = Frame(drawing, overlay)->TotalVtxCount;
    CHECK(unavailableVertices == 0 && !drawing.lastCameraOK && !feed.running,
          "unavailable local sources must remain empty without starting the retired UDP source");

    Method acquisition = class_getInstanceMethod(MFDrawingLayer.class,
        @selector(acquireFrameWithSize:camera:entities:loot:source:));
    CHECK(acquisition != NULL, "the production frame acquisition boundary must exist");
    IMP originalAcquisition = method_setImplementation(acquisition, (IMP)SupplySyntheticFrame);
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0 && !drawing.lastCameraOK,
          "an unavailable synthetic frame must produce no drawing content");

    sEntities = @[Entity(1000, 0, NO, NO)]; sLoot = @[];
    ImDrawData *data = Frame(drawing, overlay);
    CHECK(drawing.lastCameraOK && drawing.lastEntityCount == 1 && drawing.lastLootCount == 0,
          "production drawing must consume the synthetic camera and entity");
    CHECK(data->CmdLists.Size > 0 && data->TotalVtxCount >= 4 && data->TotalIdxCount >= 6,
          "a synthetic frame must generate actual nonempty ImGui drawing commands");
    BOOL visibleVertex = NO;
    for (int list = 0; list < data->CmdLists.Size; list++) {
        for (const ImDrawVert &vertex : data->CmdLists[list]->VtxBuffer) {
            CHECK(std::isfinite(vertex.pos.x) && std::isfinite(vertex.pos.y),
                  "synthetic drawing coordinates must remain finite");
            if (vertex.pos.x > 0 && vertex.pos.x < 640 && vertex.pos.y > 0 && vertex.pos.y < 720 &&
                (vertex.col & IM_COL32_A_MASK) != 0) visibleVertex = YES;
        }
    }
    CHECK(visibleVertex, "synthetic drawing must generate a nontransparent vertex inside the logical screen");

    sEntities = @[Entity(1000, 0, NO, NO), Entity(-1000, 0, NO, NO)];
    settings.backEnemyEnabled = NO;
    // Copy counts: ImGui reuses its ImDrawData object on the next frame.
    const int withoutBackEnemy = Frame(drawing, overlay)->TotalVtxCount;
    settings.backEnemyEnabled = YES;
    const int withBackEnemy = Frame(drawing, overlay)->TotalVtxCount;
    CHECK(withBackEnemy > withoutBackEnemy + 8,
          "enabling back-enemy must render a marker for the behind-camera person");

    settings.backEnemyEnabled = NO;
    sEntities = @[Entity(1000, 0, NO, NO)];
    sLoot = @[Entity(1000, 80, YES, NO), Entity(1000, -80, NO, YES)];
    settings.showLoot = NO; settings.showBox = NO; settings.showLootName = YES;
    const int boxesHidden = Frame(drawing, overlay)->TotalVtxCount;
    settings.showBox = YES;
    const int lootHidden = Frame(drawing, overlay)->TotalVtxCount;
    settings.showLoot = YES;
    const int lootDetails = Frame(drawing, overlay)->TotalVtxCount;
    settings.showLootName = NO;
    const int lootMarker = Frame(drawing, overlay)->TotalVtxCount;
    CHECK(boxesHidden + 8 < lootHidden,
          "the box switch must control box marks independently of item visibility");
    CHECK(lootHidden + 8 < lootDetails,
          "the loot switch must hide item labels while independently enabled boxes remain visible");
    CHECK(lootMarker + 8 < lootDetails,
          "the loot-name switch must reduce detailed labels to simple markers");

    const NSUInteger acquiredBeforeDisable = sAcquisitions;
    settings.drawEnabled = NO;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0 && sAcquisitions == acquiredBeforeDisable,
          "disabled drawing must clear its draw list without acquiring another frame");
    settings.drawEnabled = YES; settings.masterEnabled = NO;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0 && sAcquisitions == acquiredBeforeDisable,
          "the master switch must also suppress acquisition and drawing");
    CHECK(!reader.ready && ![MFReadBackend shared].gateOpen && !feed.running,
          "synthetic rendering must not enable memory access or an external receiver");
    printf("TRACE: synthetic_frames=%lu back_marker_vertices=%d loot_detail_vertices=%d\n",
           (unsigned long)sAcquisitions, withBackEnemy - withoutBackEnemy, lootDetails - lootHidden);
    method_setImplementation(acquisition, originalAcquisition);
    method_setImplementation(remoteRead, originalRemoteRead);
    ImGui::DestroyContext();
}

@interface DrawingRegressionDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation DrawingRegressionDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            TestSyntheticDrawing();
            puts("PASS: production drawing consumes synthetic frames (no game data)");
            exit(0);
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: synthetic drawing regression raised %s: %s\n",
                    exception.name.UTF8String, exception.reason.UTF8String);
            exit(1);
        }
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    MFOpenRegressionOutput();
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(DrawingRegressionDelegate.class)); }
}
