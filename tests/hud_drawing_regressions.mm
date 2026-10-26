#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import "MFDrawingLayer.h"
#import "MFGameReader.h"
#import "MFUEReader.h"
#import "../app/Sources/Game/MFUEOffsets.h"
#import "MFSettings.h"
#import "../app/Sources/Read/MFExternalFeed.h"
#import "../app/Sources/Read/MFReadBackend.h"
#import "../app/Sources/Render/MFOverlayView.h"
#include "../app/Sources/Game/MFUEPlayerDataObjC.h"
#include "../app/Sources/Render/imgui/imgui.h"
#include "../app/Sources/Render/imgui/imgui_internal.h"
#include "HUDRegressionOutput.h"
#include <cmath>
#include <cstring>

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } } while (0)

@interface MFDrawingLayer (RegressionEntryPoint)
- (void)overlayBuildUI:(MFImGuiContext *)context overlay:(MFOverlayView *)overlay;
- (void)refreshPersonPosition:(id)actor reader:(MFReadBackend *)reader
                      profile:(MFUEProfile *)profile now:(CFTimeInterval)now;
@end

// A narrow byte source for the actual heading read path. It accepts only the
// SDK root/controller/rotation addresses and fails on unexpected access.
@interface HeadingReadFixture : MFReadBackend
@property (nonatomic, assign) BOOL hasController, hasRotation, hasBodyRotation;
@property (nonatomic, assign) float pitch, yaw, roll;
@end
@implementation HeadingReadFixture
- (BOOL)readRemote:(uint64_t)address into:(void *)out size:(size_t)size {
    if (address == 0x110000000ULL + 0x168 && size == 8) {
        const uint64_t root = 0x120000000ULL; memcpy(out, &root, size); return YES;
    }
    if (address == 0x120000000ULL + 0x240 && size == 12) {
        const float position[3] = {1000, 20, 0}; memcpy(out, position, size); return YES;
    }
    if (address == 0x110000000ULL + kMFUE_Pawn_Controller && size == 8) {
        const uint64_t controller = _hasController ? 0x130000000ULL : 0; memcpy(out, &controller, size); return YES;
    }
    if (address == 0x130000000ULL + kMFUE_Controller_ControlRotation && size == 12) {
        if (!_hasRotation) return NO;
        const float rotation[3] = {_pitch, _yaw, _roll}; memcpy(out, rotation, size); return YES;
    }
    if (address == 0x110000000ULL + 0x90 && size == 6) {
        const uint8_t replicationFlags[6] = {}; memcpy(out, replicationFlags, size); return YES;
    }
    if (address == 0x120000000ULL + 0x108 && size == 8) {
        const uint64_t parent = 0; memcpy(out, &parent, size); return YES;
    }
    if (address == 0x120000000ULL + 0x178 && size == 12) {
        if (!_hasBodyRotation) return NO;
        const float bodyRotation[3] = {0, 270, 0}; memcpy(out, bodyRotation, size); return YES;
    }
    CHECK(NO, "heading fixture must never read outside its SDK field map");
    return NO;
}
@end

static void TestHeadingReadFailures(void) {
    id actor = [NSClassFromString(@"MFUECachedActor") new];
    CHECK(actor != nil, "the production actor cache must be available");
    [actor setValue:@(0x110000000ULL) forKey:@"address"];
    [actor setValue:@(NAN) forKey:@"yawDeg"];
    [actor setValue:@(10.0) forKey:@"seenAt"];
    HeadingReadFixture *reader = [HeadingReadFixture new];
    reader.hasController = reader.hasRotation = YES; reader.yaw = 450;
    MFUEProfile *profile = [MFUEProfile new];
    profile.actor_rootComponent = 0x168; profile.scenecomponent_worldLocation = 0x240;
    MFDrawingLayer *drawing = [MFDrawingLayer new];
    [drawing refreshPersonPosition:actor reader:reader profile:profile now:10.0];
    CHECK(fabsf([[actor valueForKey:@"yawDeg"] floatValue] - 90) < 0.001f,
          "heading refresh must run even when actor discovery already refreshed position this frame");
    reader.hasRotation = NO;
    [drawing refreshPersonPosition:actor reader:reader profile:profile now:10.1];
    CHECK(std::isnan([[actor valueForKey:@"yawDeg"] floatValue]),
          "a failed ControlRotation read must clear the previous heading");
    reader.hasRotation = YES; reader.hasController = NO;
    [actor setValue:@(90) forKey:@"yawDeg"];
    [drawing refreshPersonPosition:actor reader:reader profile:profile now:10.2];
    CHECK(std::isnan([[actor valueForKey:@"yawDeg"] floatValue]),
          "a missing controller must clear the previous heading");
    reader.hasBodyRotation = YES;
    [drawing refreshPersonPosition:actor reader:reader profile:profile now:10.4];
    CHECK(fabsf([[actor valueForKey:@"yawDeg"] floatValue] + 90) < .001f,
          "remote actors without controllers must receive validated root body facing");
    reader.hasBodyRotation = NO;
    reader.hasController = YES; reader.pitch = NAN;
    [actor setValue:@(90) forKey:@"yawDeg"];
    [drawing refreshPersonPosition:actor reader:reader profile:profile now:10.5];
    CHECK(std::isnan([[actor valueForKey:@"yawDeg"] floatValue]),
          "a partially invalid rotation must never produce a heading");
}

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

static ImDrawData *Frame(MFDrawingLayer *drawing, MFOverlayView *overlay, float delta = 1.0f/60.0f) {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(640, 720);
    io.DeltaTime = delta;
    ImGui::NewFrame();
    [drawing overlayBuildUI:nil overlay:overlay];
    ImGui::Render();
    return ImGui::GetDrawData();
}

static float ColoredWidth(ImDrawData *data, ImU32 color) {
    float left = INFINITY, right = -INFINITY;
    for (int list = 0; list < data->CmdLists.Size; ++list) {
        for (const ImDrawVert &vertex : data->CmdLists[list]->VtxBuffer) {
            if (vertex.col == color) { left = fminf(left, vertex.pos.x); right = fmaxf(right, vertex.pos.x); }
        }
    }
    return std::isfinite(left) ? right - left : 0;
}

static float ColoredBottom(ImDrawData *data, ImU32 color) {
    float bottom = -INFINITY;
    for (int list = 0; list < data->CmdLists.Size; ++list)
        for (const ImDrawVert &vertex : data->CmdLists[list]->VtxBuffer)
            if (vertex.col == color) bottom = fmaxf(bottom, vertex.pos.y);
    return bottom;
}

static float ColoredHeight(ImDrawData *data, ImU32 color) {
    float top = INFINITY, bottom = -INFINITY;
    for (int list = 0; list < data->CmdLists.Size; ++list)
        for (const ImDrawVert &vertex : data->CmdLists[list]->VtxBuffer)
            if (vertex.col == color) { top = fminf(top, vertex.pos.y); bottom = fmaxf(bottom, vertex.pos.y); }
    return std::isfinite(top) ? bottom - top : 0;
}

static int ColoredVertices(ImDrawData *data, ImU32 color) {
    int count = 0;
    for (int list = 0; list < data->CmdLists.Size; ++list)
        for (const ImDrawVert &vertex : data->CmdLists[list]->VtxBuffer)
            if (vertex.col == color) ++count;
    return count;
}

@interface DrawingOverlayFixture : MFOverlayView
@property (nonatomic, assign) double sampleFPS;
@end
@implementation DrawingOverlayFixture
- (double)presentedFPS { return self.sampleFPS; }
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsMake(20, 12, 0, 0); }
@end

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
    CHECK(settings.showFPS, "the requested realtime FPS display must default on");
    settings.showFPS = NO;
    settings.masterEnabled = settings.drawEnabled = YES;
    settings.renderSelfTest = NO;
    settings.showName = settings.showArmor = settings.showHealth = NO;
    settings.showDistance = settings.showTeam = NO;
    settings.showHeld = settings.showSkeleton = NO;
    settings.showTracer = YES;

    [MFDrawingLayer setEnabled:YES];
    MFExternalFeed *feed = [MFExternalFeed shared];
    DrawingOverlayFixture *overlay = [[DrawingOverlayFixture alloc] initWithFrame:CGRectMake(0, 0, 640, 720)
                                                                                  interactive:NO];
    overlay.automaticallyStartsRendering = NO;
    MFDrawingLayer *drawing = [MFDrawingLayer new];
    drawing.overlay = overlay;

    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO(); io.IniFilename = nullptr;
    unsigned char *pixels; int fontWidth, fontHeight;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &fontWidth, &fontHeight);

    CHECK([MFReadUEHeroName([MFReadBackend shared], 10010) isEqualToString:@"威龙"] &&
          MFReadUEHeroName([MFReadBackend shared], 99999) == nil,
          "a missing live hero table must use exact local IDs without any remote read or invented name");
    CHECK([MFResolveUEHeroName(20003, @"蜂医") isEqualToString:@"蜂医"],
          "live localized hero names must override a local nickname");

    // FPS remains available before a game source connects, follows the actual
    // presented rate rather than the configured target, and has its own switch.
    settings.showFPS = YES; overlay.sampleFPS = 59;
    ImDrawData *fpsData = Frame(drawing, overlay);
    const ImU32 fpsText = IM_COL32(246,248,252,255);
    const float rate59Width = ColoredWidth(fpsData, fpsText);
    CHECK(rate59Width > 20 && !drawing.lastCameraOK,
          "the top-left FPS badge must draw even when no game camera is connected");
    for (int list = 0; list < fpsData->CmdLists.Size; ++list)
        for (const ImDrawVert &v : fpsData->CmdLists[list]->VtxBuffer)
            CHECK(v.pos.x >= 21 && v.pos.y >= 27 && v.pos.x <= 117 && v.pos.y <= 57,
                  "the FPS badge must stay at the top-left inside the safe-area anchor");
    overlay.sampleFPS = 119;
    CHECK(ColoredWidth(Frame(drawing,overlay),fpsText) > rate59Width + 3,
          "the rendered FPS text must change with measured presentation rate");
    settings.drawEnabled = NO;
    CHECK(ColoredWidth(Frame(drawing,overlay),fpsText) > 20,
          "FPS must remain independent of the game drawing switch");
    settings.drawEnabled = YES; settings.showFPS = NO;
    CHECK(Frame(drawing,overlay)->TotalVtxCount == 0,
          "disabling the FPS switch must remove the entire top-left badge");

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

    // Damage must change actual colored geometry; unknown data must not become
    // a fabricated full bar. These colors belong only to the health fill.
    MFEntity *patient = Entity(1000, 0, NO, NO);
    patient.health = 100; patient.maxHealth = 100;
    sEntities = @[patient]; settings.showTracer = NO; settings.showHealth = YES;
    const ImU32 healthyColor = IM_COL32(52, 211, 153, 245);
    const ImU32 injuredColor = IM_COL32(248, 113, 113, 245);
    const float fullWidth = ColoredWidth(Frame(drawing, overlay), healthyColor);
    patient.health = 25;
    const float quarterWidth = ColoredWidth(Frame(drawing, overlay), injuredColor);
    CHECK(fullWidth > 50 && quarterWidth > 10 && fabsf(quarterWidth / fullWidth - 0.25f) < 0.035f,
          "actual health fill must shrink to a quarter at 25/100 HP");
    patient.health = 50; patient.maxHealth = 200;
    const float quarterOf200 = ColoredWidth(Frame(drawing, overlay), injuredColor);
    CHECK(fabsf(quarterOf200 - quarterWidth) < 0.1f, "actual maximum HP must control the fill width");
    patient.health = -1; patient.maxHealth = 0;
    data = Frame(drawing, overlay);
    CHECK(ColoredWidth(data, healthyColor) == 0 && ColoredWidth(data, injuredColor) == 0,
          "unavailable health must have no colored fill");
    patient.health = 100; patient.maxHealth = 100;
    settings.healthBarStyle = 0;
    data = Frame(drawing, overlay);
    const float thinHeight = ColoredHeight(data, healthyColor);
    const int solidVertices = ColoredVertices(data, healthyColor);
    settings.healthBarStyle = 1;
    CHECK(ColoredHeight(Frame(drawing, overlay), healthyColor) > thinHeight + 2,
          "capsule health style must produce a thicker readable bar");
    settings.healthBarStyle = 2;
    data = Frame(drawing, overlay);
    const int segmentedFullVertices = ColoredVertices(data, healthyColor);
    CHECK(segmentedFullVertices > solidVertices,
          "segmented health style must render separate fill segments");
    patient.health = 25;
    data = Frame(drawing, overlay);
    CHECK(ColoredVertices(data, injuredColor) * 4 == segmentedFullVertices,
          "25/100 HP must fill two of eight health segments");
    patient.health = 0;
    CHECK(ColoredWidth(Frame(drawing, overlay), injuredColor) == 0,
          "zero health must leave every health segment empty");
    settings.healthBarStyle = 0;
    settings.showHealth = NO;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0,
          "hiding all information must leave no unwanted entity rectangle");

    // Actual production draw lists must keep lower-rate categories visible
    // while the real-player line follows every 120Hz frame.
    MFEntity *real=Entity(1000,-100,NO,NO), *bot=Entity(1000,100,NO,NO); bot.isBot=YES;
    sEntities=@[real,bot]; settings.showTracer=YES; settings.showBot=YES;
    auto packed=[&](MFColorSlot slot){CGFloat r,g,b,a;[[settings colorForSlot:slot]getRed:&r green:&g blue:&b alpha:&a];
        return IM_COL32((int)(r*255),(int)(g*255),(int)(b*255),(int)(a*255));};
    const ImU32 redLine=packed(MFColorSlotSkeleton), greenLine=packed(MFColorSlotBotSkeleton);
    data=Frame(drawing,overlay,1.f/120);
    const float firstBot=ColoredWidth(data,greenLine), firstReal=ColoredWidth(data,redLine);
    CHECK(firstBot>20 && firstReal>20,
          "cadence fixture must begin with visible bot and real-player lines");
    MFPoint2D movedReal=real.screen,movedBot=bot.screen;
    movedReal.x-=30;movedBot.x+=30;real.screen=movedReal;bot.screen=movedBot;
    data=Frame(drawing,overlay,1.f/120);
    CHECK(fabsf(ColoredWidth(data,greenLine)-firstBot)<.01f &&
          fabsf(ColoredWidth(data,redLine)-firstReal)>20,
          "120Hz real-player geometry must move while cached bot geometry remains visible");
    data=Frame(drawing,overlay,1.f/120);
    CHECK(fabsf(ColoredWidth(data,greenLine)-firstBot)>20,
          "bot geometry must update on the next 60Hz tick");
    settings.showBot=NO;
    CHECK(ColoredWidth(Frame(drawing,overlay,1.f/120),greenLine)==0,
          "bot visibility changes must invalidate cached geometry immediately");
    settings.showBot=YES; settings.showTracer=NO; sEntities=@[patient];
    settings.showRadar = YES;
    CHECK(Frame(drawing, overlay)->TotalVtxCount > 8,
          "the independent radar switch must enable its actual geometry");
    // The radar consumes every enemy, including a target behind the camera,
    // while team/bot filters remain independent of projection visibility.
    settings.showBot = YES;
    sEntities = @[];
    const int radarBase = Frame(drawing, overlay)->TotalVtxCount;
    MFEntity *radarTarget = Entity(-1000, 0, NO, NO);
    sEntities = @[radarTarget];
    const int radarEnemy = Frame(drawing, overlay)->TotalVtxCount;
    CHECK(radarEnemy > radarBase + 8, "behind-camera opponents must remain visible on the radar");
    const uint32_t originalTeam = gMFUELocalTeam;
    gMFUELocalTeam = 7; radarTarget.teamId = 7;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == radarBase,
          "known teammates must never create radar geometry");
    radarTarget.teamId = 8; radarTarget.isBot = YES; settings.showBot = NO;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == radarBase,
          "the bot filter must remove radar points and their facing markers");
    settings.showBot = YES; radarTarget.isBot = NO; radarTarget.yawDeg = 90;
    CHECK(Frame(drawing, overlay)->TotalVtxCount > radarEnemy,
          "a validated enemy heading must add actual radar direction geometry");
    gMFUELocalTeam = originalTeam;
    sEntities = @[patient];
    CHECK([settings save], "the radar preference must save successfully");
    CHECK([[MFSettings alloc] init].showRadar,
          "an enabled radar preference must survive reloading settings");
    settings.showRadar = NO;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0,
          "disabling radar must remove its base, grid and blips");
    CHECK([settings save] && ![[MFSettings alloc] init].showRadar,
          "a disabled radar preference must also survive reloading settings");
    settings.showTracer = YES;

    settings.showHeld = settings.showArmor = settings.showTeam = settings.showName = YES;
    patient.equipKnown = YES; patient.helmetLevel = 4; patient.helmetHP = 35; patient.helmetMaxHP = 45;
    patient.armorLevel = 5; patient.armorHP = 105; patient.armorMaxHP = 120; patient.backpackLevel = 6;
    patient.weaponRawID = 18010000001ULL;
    CGFloat red = 1, green = 1, blue = 1, alpha = 1;
    [[settings colorForSlot:MFColorSlotSkeleton] getRed:&red green:&green blue:&blue alpha:&alpha];
    const ImU32 tracerColor = IM_COL32((int)(red * 255), (int)(green * 255), (int)(blue * 255), (int)(alpha * 255));
    MFCamera camera = {0}; camera.fov = 90;
    const float headWorld[] = {1000, 0, 88};
    MFScreen projection = [MFProjection screenWithSize:CGSizeMake(640, 720) fov:90];
    const MFPoint2D head = [MFProjection projectTarget:headWorld camera:camera screen:projection];
    const float lineHeight = fmaxf(14, fmaxf(settings.fontInfo, settings.fontPerson) + 3);
    const float gearCenter = head.y - 6 - 3 * lineHeight + settings.fontInfo * 0.5f;
    CHECK(fabsf(ColoredBottom(Frame(drawing, overlay), tracerColor) - gearCenter) <= 2,
          "tracer must end at the center of the gear row above the head, not at the hip");
    data=Frame(drawing,overlay);
    CHECK(ColoredVertices(data,packed(MFColorSlotLoot4))>0 && ColoredVertices(data,packed(MFColorSlotLoot5))>0 &&
          ColoredVertices(data,packed(MFColorSlotLoot6))>0,
          "head, armor and bag must each use their own quality color in the same gear row");
    const float helmetWidthWithMax=ColoredWidth(data,packed(MFColorSlotLoot4));
    const float armorWidthWithMax=ColoredWidth(data,packed(MFColorSlotLoot5));
    patient.helmetMaxHP=patient.armorMaxHP=0;
    data=Frame(drawing,overlay);
    CHECK(fabsf(ColoredWidth(data,packed(MFColorSlotLoot4))-helmetWidthWithMax)<.01f &&
          fabsf(ColoredWidth(data,packed(MFColorSlotLoot5))-armorWidthWithMax)<.01f,
          "known current durability must draw the same digits when maximum durability is unavailable");
    settings.showHeld=settings.showArmor=NO;
    patient.name=@"PlayerNickname"; patient.heroName=@"Hero"; patient.teamId=7;
    patient.uin=1234567890123ULL;
    data=Frame(drawing,overlay);
    const ImU32 infoColor=packed(MFColorSlotPersonInfo), heroColor=packed(MFColorSlotTeam);
    const float nicknameWidth=ColoredWidth(data,infoColor), heroWidth=ColoredWidth(data,heroColor);
    patient.uin=9;
    CHECK(fabsf(ColoredWidth(Frame(drawing,overlay),infoColor)-nicknameWidth)<.01f,
          "changing UIN must never replace the player-authored nickname in the team row");
    patient.name=@"N";
    CHECK(ColoredWidth(Frame(drawing,overlay),infoColor)<nicknameWidth-30,
          "the identity row must follow the authored nickname");
    patient.heroName=@"HeroWithLongerName";
    CHECK(ColoredWidth(Frame(drawing,overlay),heroColor)>heroWidth+30,
          "the hero and nickname must render as separate identity rows");
    patient.teamId=0;
    settings.showHeld = settings.showArmor = settings.showTeam = settings.showName = NO;

    sEntities = @[Entity(1000, 0, NO, NO), Entity(-1000, 0, NO, NO)];
    settings.backEnemyEnabled = NO;
    // Copy counts: ImGui reuses its ImDrawData object on the next frame.
    const int withoutBackEnemy = Frame(drawing, overlay)->TotalVtxCount;
    settings.backEnemyEnabled = YES;
    const int withBackEnemy = Frame(drawing, overlay)->TotalVtxCount;
    CHECK(withBackEnemy > withoutBackEnemy + 8,
          "enabling back-enemy must render a marker for the behind-camera person");
    settings.showTracer = NO;
    MFEntity *back = Entity(-1000, 0, NO, NO);
    sEntities = @[back];
    const int oneBack = Frame(drawing, overlay)->TotalVtxCount;
    const uint32_t originalBackTeam = gMFUELocalTeam;
    gMFUELocalTeam = 7; back.teamId = 7;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0,
          "known teammates must never trigger a behind-enemy indicator");
    back.teamId = 8; back.isBot = YES; settings.showBot = NO;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0,
          "hiding bots must suppress their behind-enemy indicator");
    settings.showBot = YES; back.isBot = NO;
    back.bearingDeg = NAN;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0,
          "an unknown bearing must never produce invalid offscreen vertices");
    back.bearingDeg = 180; back.distanceMeters = settings.backEnemyDistance + 1;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0,
          "the offscreen distance limit must remove distant threats");
    back.distanceMeters = 10;
    MFEntity *adjacentBack = Entity(-1200, 10, NO, NO);
    sEntities = @[back, adjacentBack];
    const int clusteredBack = Frame(drawing, overlay)->TotalVtxCount;
    CHECK(clusteredBack >= oneBack * 2,
          "nearby bearings must retain separate arrows and individual distance labels");
    sEntities = @[];
    CHECK(Frame(drawing, overlay)->TotalVtxCount == 0,
          "the offscreen guide must disappear immediately with no threats");
    gMFUELocalTeam = originalBackTeam;

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

    settings.showLoot = settings.showBox = settings.showTracer = NO;
    sEntities=@[];
    MFEntity *qualityItem=Entity(1000,80,YES,NO); sLoot=@[qualityItem];
    settings.showLoot=YES;
    const ImU32 qualityColors[]={0,IM_COL32(255,255,255,255),IM_COL32(40,255,85,255),
        packed(MFColorSlotLoot3),packed(MFColorSlotLoot4),packed(MFColorSlotLoot5),packed(MFColorSlotLoot6)};
    for(int level=1;level<=6;level++){
        qualityItem.level=level;Frame(drawing,overlay);data=Frame(drawing,overlay);
        CHECK(ColoredVertices(data,qualityColors[level])>0,"each loot quality must draw its distinct six-level color");
    }
    settings.showLoot=NO;
    settings.showLootStats = NO;
    const int statsHidden = Frame(drawing, overlay)->TotalVtxCount;
    settings.showLootStats = YES;
    Frame(drawing, overlay); // ImGui measures a new auto-sized window on its first frame.
    CHECK(Frame(drawing, overlay)->TotalVtxCount > statsHidden + 8,
          "loot statistics must render independently while all loot markers are hidden");
    settings.showLootStats = NO;
    CHECK(Frame(drawing, overlay)->TotalVtxCount == statsHidden,
          "the statistics switch must remove the entire statistics window");
    settings.showLootStats=YES;
    settings.lootStatsXRatio=0; settings.lootStatsYRatio=0;
    Frame(drawing,overlay);
    ImGuiWindow *stats=ImGui::FindWindowByName("物资统计");
    CHECK(stats && stats->Pos.x==0 && stats->Pos.y==0,"statistics anchor must reach the top-left");
    settings.lootStatsXRatio=1; settings.lootStatsYRatio=1;
    Frame(drawing,overlay);
    CHECK(stats->Pos.x+stats->Size.x<=640.1f && stats->Pos.y+stats->Size.y<=720.1f && stats->Pos.x>100,
          "statistics position must move and remain inside the screen");
    settings.showLootStats=NO;

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
            TestHeadingReadFailures();
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
