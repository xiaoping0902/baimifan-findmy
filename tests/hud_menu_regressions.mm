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
#include <string>
#include <vector>

#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); exit(1); } } while (0)

struct MenuTestHit { std::string name; ImVec2 origin, size; };
static std::vector<MenuTestHit> sMenuHits;
extern "C" void MFRecordMenuTestItem(const char *name, ImVec2 origin, ImVec2 size) {
    sMenuHits.push_back({name,origin,size});
}
static MenuTestHit MenuItem(const char *name, size_t ordinal=0) {
    for (const auto& hit:sMenuHits) if(hit.name==name && ordinal--==0)return hit;
    fprintf(stderr,"FAIL: visible native menu item missing: %s\n",name);exit(1);
}

static void Frame(MFMenuUI *menu, MFOverlayView *overlay) {
    sMenuHits.clear();
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
static void ClickItem(MFMenuUI *menu, MFOverlayView *overlay,const char *name,size_t ordinal=0) {
    const MenuTestHit hit=MenuItem(name,ordinal);
    ClickMenu(menu,overlay,CGPointMake(hit.origin.x+hit.size.x*.5f,hit.origin.y+hit.size.y*.5f));
}
static void ScrollMenuToBottom(MFMenuUI *menu, MFOverlayView *overlay) {
    const CGFloat scale=PanelScale(overlay);
    ImGui::GetIO().AddMousePosEvent(220*scale,360*scale);
    ImGui::GetIO().AddMouseWheelEvent(0,-10);
    for(int i=0;i<90;++i)Frame(menu,overlay);
}
static void CheckNativeFeatureTileLabels(MFOverlayView *overlay) {
    size_t labels = 0;
    const float scale = PanelScale(overlay);
    for (size_t i = 1; i < sMenuHits.size(); ++i) if (sMenuHits[i].name == "feature_tile_text") {
        const MenuTestHit &label = sMenuHits[i], &tile = sMenuHits[i-1];
        CHECK(label.size.x <= tile.size.x-8*scale+.1f && label.size.y <= 29*scale+.1f,
              "the actual Chinese font must fit each four-column feature label inside its tile");
        labels++;
    }
    CHECK(labels >= 4, "the native menu must expose at least one row of four functional tiles");
}
static BOOL ColorMatches(UIColor *color,CGFloat r,CGFloat g,CGFloat b,CGFloat a=1) {
    CGFloat cr=0,cg=0,cb=0,ca=0;
    return [color getRed:&cr green:&cg blue:&cb alpha:&ca] &&
        fabs(cr-r)<.001&&fabs(cg-g)<.001&&fabs(cb-b)<.001&&fabs(ca-a)<.001;
}
static void TestIndependentBotSettingsPersistence(void) {
    MFSettings *settings = MFSettings.shared;
    [settings resetToDefaults];
    CHECK(settings.showBot && settings.showBotName && settings.showBotSkeleton &&
          !settings.showBotHealth && !settings.showBotTracer && !settings.showBotArmor,
          "fresh bot settings must display only bot names and skeletons");
    const BOOL name = settings.showName, skeleton = settings.showSkeleton;
    const BOOL health = settings.showHealth, tracer = settings.showTracer, armor = settings.showArmor;
    settings.showBot = NO; settings.showBotName = NO; settings.showBotSkeleton = NO;
    settings.showBotHealth = YES; settings.showBotTracer = YES; settings.showBotArmor = YES;
    CHECK([settings save], "independent bot settings must save through the production plist writer");
    MFSettings *loaded = [MFSettings new];
    CHECK(!loaded.showBot && !loaded.showBotName && !loaded.showBotSkeleton &&
          loaded.showBotHealth && loaded.showBotTracer && loaded.showBotArmor &&
          loaded.showName == name && loaded.showSkeleton == skeleton && loaded.showHealth == health &&
          loaded.showTracer == tracer && loaded.showArmor == armor,
          "all five bot preferences and their master must persist independently of human preferences");
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"mf_settings.plist"];
    NSMutableDictionary *legacy = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    for (NSString *key in @[@"showBotName", @"showBotSkeleton", @"showBotHealth", @"showBotTracer", @"showBotArmor"])
        [legacy removeObjectForKey:key];
    legacy[@"showName"] = @NO; legacy[@"showSkeleton"] = @NO;
    legacy[@"showHealth"] = @YES; legacy[@"showTracer"] = @YES; legacy[@"showArmor"] = @YES;
    CHECK([legacy writeToFile:path atomically:YES], "legacy bot preferences must save");
    [settings load];
    CHECK(!settings.showBot && settings.showBotName && settings.showBotSkeleton &&
          !settings.showBotHealth && !settings.showBotTracer && !settings.showBotArmor,
          "loading an old plist must retain its explicit bot master and seed missing bot details independently of humans");
    legacy[@"showBot"] = @YES;
    CHECK([legacy writeToFile:path atomically:YES], "legacy enabled bot master fixture must save");
    loaded = [MFSettings new];
    CHECK(loaded.showBot && loaded.showBotName && loaded.showBotSkeleton &&
          !loaded.showBotHealth && !loaded.showBotTracer && !loaded.showBotArmor,
          "an old enabled bot master must stay enabled with the new concise detail defaults");
    [settings resetToDefaults];
    CHECK([settings save], "bot settings fixture must leave normal production defaults for menu interaction");
}
static void TestSettingsColorAndAnchorPersistence(void) {
    CHECK(MFColorSlotSkeleton==8&&MFColorSlotBackEnemy==9&&MFColorSlotBotSkeleton==10,
          "appending bot skeleton color must keep all existing persisted color slot numbers");
    MFSettings *settings=MFSettings.shared;
    [settings resetToDefaults];
    CHECK(settings.showFPS,"fresh settings must show the realtime overlay frame rate");
    settings.showFPS=NO;
    settings.radarXRatio=-1;settings.radarYRatio=4;settings.radarRadiusRatio=9;
    CHECK(settings.radarXRatio==0&&settings.radarYRatio==1&&settings.radarRadiusRatio==.25f,
          "radar settings must clamp position and size at the model boundary");
    settings.radarXRatio=NAN;settings.radarYRatio=INFINITY;settings.radarRadiusRatio=NAN;
    CHECK(fabs(settings.radarXRatio-.125f)<.001&&fabs(settings.radarYRatio-400.0f/1080.0f)<.001&&
          fabs(settings.radarRadiusRatio-150.0f/1080.0f)<.001,
          "invalid radar placement values must recover to the original default layout");
    settings.radarXRatio=.82f;settings.radarYRatio=.21f;settings.radarRadiusRatio=.23f;
    CHECK(ColorMatches([settings colorForSlot:MFColorSlotSkeleton],1,.08,.08)&&
          ColorMatches([settings colorForSlot:MFColorSlotBotSkeleton],1,1,1),
          "fresh native settings must use vivid red humans and white bots");
    settings.lootStatsXRatio=-2;settings.lootStatsYRatio=4;
    CHECK(settings.lootStatsXRatio==0&&settings.lootStatsYRatio==1,
          "statistics screen anchors must clamp at their model setters");
    settings.lootStatsXRatio=NAN;settings.lootStatsYRatio=INFINITY;
    CHECK(fabs(settings.lootStatsXRatio-.01f)<.001&&fabs(settings.lootStatsYRatio-.18f)<.001,
          "non-finite statistics anchors must recover to their own defaults");
    settings.lootStatsXRatio=.43;settings.lootStatsYRatio=.72;
    [settings setColor:[UIColor colorWithRed:.36 green:.24 blue:.72 alpha:1] forSlot:MFColorSlotSkeleton];
    [settings setColor:[UIColor colorWithRed:.64 green:.52 blue:.23 alpha:1] forSlot:MFColorSlotBotSkeleton];
    CHECK([settings save],"native color/anchor settings fixture must save");
    MFSettings *loaded=[[MFSettings alloc] init];
    CHECK(fabs(loaded.radarXRatio-.82f)<.001&&fabs(loaded.radarYRatio-.21f)<.001&&
          fabs(loaded.radarRadiusRatio-.23f)<.001,"radar layout must survive a full disk roundtrip");
    CHECK(!loaded.showFPS&&fabs(loaded.lootStatsXRatio-.43f)<.001&&fabs(loaded.lootStatsYRatio-.72f)<.001&&
          ColorMatches([loaded colorForSlot:MFColorSlotSkeleton],.36,.24,.72)&&
          ColorMatches([loaded colorForSlot:MFColorSlotBotSkeleton],.64,.52,.23),
          "native colors and statistics position must survive a full disk roundtrip");
    NSString *path=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"mf_settings.plist"];
    NSMutableDictionary *legacy=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    [legacy removeObjectForKey:@"lootStatsXRatio"];[legacy removeObjectForKey:@"lootStatsYRatio"];
    [legacy removeObjectForKey:@"colorDefaultsVersion"];
    [legacy removeObjectForKey:@"showFPS"];
    [legacy removeObjectForKey:@"radarXRatio"];[legacy removeObjectForKey:@"radarYRatio"];
    [legacy removeObjectForKey:@"radarRadiusRatio"];
    legacy[@"showTeammates"]=@YES;
    NSMutableDictionary *colors=[legacy[@"colors"] mutableCopy];
    [colors removeObjectForKey:@"10"];legacy[@"colors"]=colors;
    CHECK([legacy writeToFile:path atomically:YES],"legacy settings fixture must save");
    loaded=[[MFSettings alloc] init];
    CHECK(fabs(loaded.radarXRatio-.125f)<.001&&fabs(loaded.radarYRatio-400.0f/1080.0f)<.001&&
          fabs(loaded.radarRadiusRatio-150.0f/1080.0f)<.001,"old configurations must inherit radar layout defaults");
    CHECK(loaded.showFPS&&fabs(loaded.lootStatsXRatio-.01f)<.001&&fabs(loaded.lootStatsYRatio-.18f)<.001&&
          ColorMatches([loaded colorForSlot:MFColorSlotBotSkeleton],1,1,1)&&
          ColorMatches([loaded colorForSlot:MFColorSlotSkeleton],.36,.24,.72)&&!loaded.showTeammates,
          "legacy settings must retain human colors, default new anchors/bot color, and exclude teammates");
    colors[@"10"]=@[@.10,@1.0,@.20,@1.0];legacy[@"colors"]=colors;
    CHECK([legacy writeToFile:path atomically:YES],"previous bot-color default fixture must save");
    loaded=[[MFSettings alloc] init];
    CHECK(ColorMatches([loaded colorForSlot:MFColorSlotBotSkeleton],1,1,1)&&
          ColorMatches([loaded colorForSlot:MFColorSlotSkeleton],.36,.24,.72),
          "the previous shipped green bot default must migrate to white while custom human color survives");
    colors[@"8"]=@[@1.0,@.45,@.45,@1.0];legacy[@"colors"]=colors;
    CHECK([legacy writeToFile:path atomically:YES],"previous human-color default fixture must save");
    loaded=[[MFSettings alloc] init];
    CHECK(ColorMatches([loaded colorForSlot:MFColorSlotSkeleton],1,.08,.08)&&
          ColorMatches([loaded colorForSlot:MFColorSlotBotSkeleton],1,1,1),
          "legacy pale-red human and green bot defaults must migrate together");
    [loaded setColor:[UIColor colorWithRed:.10 green:1 blue:.20 alpha:1] forSlot:MFColorSlotBotSkeleton];
    [loaded setColor:[UIColor colorWithRed:1 green:.45 blue:.45 alpha:1] forSlot:MFColorSlotSkeleton];
    CHECK([loaded save],"current-version colors matching old defaults must save");
    loaded=[[MFSettings alloc] init];
    CHECK(ColorMatches([loaded colorForSlot:MFColorSlotSkeleton],1,.45,.45)&&
          ColorMatches([loaded colorForSlot:MFColorSlotBotSkeleton],.10,1,.20),
          "newly selected colors must survive restart even when their RGBA equals a previous shipped default");
    settings.showFPS=YES;
    CHECK([settings save],"restore the seeded production menu preferences");
}
static void WaitForMenuPreferences(BOOL (^ready)(MFSettings *),NSDate *deadline,void (^completion)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(ready([[MFSettings alloc] init])){completion();return;}
        CHECK(deadline.timeIntervalSinceNow>0,"color and statistics anchors must persist after idle debounce");
        WaitForMenuPreferences(ready,deadline,completion);
    });
}
static void TestBotDetailControlsAndSave(MFMenuUI *menu, MFOverlayView *overlay, void (^completion)(void)) {
    MFSettings *settings = MFSettings.shared;
    NSArray<NSString *> *keys = @[@"showBotName", @"showBotSkeleton", @"showBotHealth", @"showBotTracer", @"showBotArmor"];
    const char *ids[] = {"bot_name", "bot_skeleton", "bot_health", "bot_tracer", "bot_armor"};
    NSArray<NSString *> *humanKeys = @[@"showName", @"showSkeleton", @"showHealth", @"showTracer", @"showArmor", @"showBot"];
    NSDictionary *humanBefore = [settings dictionaryWithValuesForKeys:humanKeys];
    NSDictionary *botBefore = [settings dictionaryWithValuesForKeys:keys];
    ScrollMenuToBottom(menu, overlay);
    for (NSUInteger i = 0; i < keys.count; ++i) {
        NSDictionary *before = [settings dictionaryWithValuesForKeys:keys];
        ClickItem(menu, overlay, ids[i]);
        for (NSUInteger j = 0; j < keys.count; ++j) {
            const BOOL expected = i == j ? ![before[keys[j]] boolValue] : [before[keys[j]] boolValue];
            CHECK([[settings valueForKey:keys[j]] boolValue] == expected,
                  "a native bot switch must change its corresponding production setting only");
        }
        CHECK([[settings dictionaryWithValuesForKeys:humanKeys] isEqual:humanBefore],
              "native bot detail switches must leave human settings and the bot master untouched");
    }
    NSDictionary *changed = [settings dictionaryWithValuesForKeys:keys];
    WaitForMenuPreferences(^BOOL(MFSettings *s) {
        return [[s dictionaryWithValuesForKeys:keys] isEqual:changed] &&
               [[s dictionaryWithValuesForKeys:humanKeys] isEqual:humanBefore];
    }, [NSDate dateWithTimeIntervalSinceNow:3], ^{
        const char *restoreIds[] = {"bot_name", "bot_skeleton", "bot_health", "bot_tracer", "bot_armor"};
        for (const char *id : restoreIds) ClickItem(menu, overlay, id);
        CHECK([[settings dictionaryWithValuesForKeys:keys] isEqual:botBefore],
              "each native bot detail control must be reversible");
        WaitForMenuPreferences(^BOOL(MFSettings *s) {
            return [[s dictionaryWithValuesForKeys:keys] isEqual:botBefore];
        }, [NSDate dateWithTimeIntervalSinceNow:3], ^{
            ClickMenu(menu, overlay, NavPoint(overlay, 0));
            completion();
        });
    });
}
static void TestNativeColorPopupStability(MFMenuUI *menu,MFOverlayView *overlay) {
    for(int frame=0;frame<8;++frame)Frame(menu,overlay);
    CHECK(GImGui->OpenPopupStack.Size==1 && GImGui->OpenPopupStack[0].Window,
          "the real menu must own its live color popup");
    ImGuiWindow *popup=GImGui->OpenPopupStack[0].Window;
    const ImVec2 size=popup->Size,position=popup->Pos;
    const MenuTestHit first=MenuItem("color_preset",0);
    for(int frame=0;frame<30;++frame){
        Frame(menu,overlay);
        const MenuTestHit current=MenuItem("color_preset",0);
        CHECK(popup->Active && fabs(popup->Size.y-size.y)<.5f &&
              fabs(popup->Pos.x-position.x)<.5f && fabs(popup->Pos.y-position.y)<.5f &&
              fabs(current.origin.y-first.origin.y)<.5f,
              "native color popup controls must stay stationary over repeated idle frames");
    }
    const MenuTestHit picker=MenuItem("color_picker");
    const float scale=PanelScale(overlay);
    const ImVec2 pointer(picker.origin.x+picker.size.x-8*scale,picker.origin.y+50*scale);
    ImGuiIO &io=ImGui::GetIO();
    io.AddMousePosEvent(pointer.x,pointer.y);io.AddMouseButtonEvent(0,true);
    Frame(menu,overlay);Frame(menu,overlay);
    CGFloat r=0,g=0,b=0,a=0;
    [[MFSettings.shared colorForSlot:MFColorSlotSkeleton]getRed:&r green:&g blue:&b alpha:&a];
    CHECK(a<.9 && a>.3 && GImGui->ActiveId,
          "the native popup alpha bar must update actual production settings while held");
    const CGFloat held=a;const ImGuiID active=GImGui->ActiveId;
    for(int frame=0;frame<20;++frame){
        Frame(menu,overlay);
        [[MFSettings.shared colorForSlot:MFColorSlotSkeleton]getRed:&r green:&g blue:&b alpha:&a];
        CHECK(GImGui->ActiveId==active && fabs(a-held)<.001 && fabs(popup->Size.y-size.y)<.5f,
              "a native color slider must keep the same active touch and value without a geometry feedback loop");
    }
    io.AddMouseButtonEvent(0,false);Frame(menu,overlay);Frame(menu,overlay);
}
static void TestRadarControlsAndSave(MFMenuUI *menu,MFOverlayView *overlay,void (^completion)(void)) {
    MFSettings *settings=MFSettings.shared;
    ClickMenu(menu,overlay,NavPoint(overlay,4));
    const BOOL radar=settings.showRadar,bot=settings.showBot,loot=settings.showLoot;
    ClickItem(menu,overlay,"radar_enabled");
    CHECK(settings.showRadar!=radar&&settings.showBot==bot&&settings.showLoot==loot,
          "the dedicated radar page switch must affect only radar visibility");
    ClickItem(menu,overlay,"radar_enabled");
    MenuTestHit x=MenuItem("radar_x");
    ClickMenu(menu,overlay,CGPointMake(x.origin.x+x.size.x-2,x.origin.y+x.size.y*.5));
    ScrollMenuToBottom(menu,overlay);
    MenuTestHit y=MenuItem("radar_y"),size=MenuItem("radar_size");
    ClickMenu(menu,overlay,CGPointMake(y.origin.x+2,y.origin.y+y.size.y*.5));
    ClickMenu(menu,overlay,CGPointMake(size.origin.x+size.size.x-2,size.origin.y+size.size.y*.5));
    CHECK(settings.radarXRatio==1&&settings.radarYRatio==0&&fabs(settings.radarRadiusRatio-.25f)<.001&&
          settings.showRadar==radar&&settings.showBot==bot&&settings.showLoot==loot,
          "radar controls must bind independent production X/Y/size values");
    WaitForMenuPreferences(^BOOL(MFSettings *s){return s.radarXRatio==1&&s.radarYRatio==0&&
        fabs(s.radarRadiusRatio-.25f)<.001&&s.showRadar==radar;},[NSDate dateWithTimeIntervalSinceNow:3],^{
            ClickItem(menu,overlay,"radar_reset");
            CHECK(settings.showRadar==radar,"resetting radar placement must preserve its own switch");
            WaitForMenuPreferences(^BOOL(MFSettings *s){return fabs(s.radarXRatio-.125f)<.001&&
                fabs(s.radarYRatio-400.0f/1080.0f)<.001&&fabs(s.radarRadiusRatio-150.0f/1080.0f)<.001;},
                [NSDate dateWithTimeIntervalSinceNow:3],completion);
        });
}
static void TestColorsAndPositionPersistence(MFMenuUI *menu,MFOverlayView *overlay,void (^completion)(void)) {
    MFSettings *settings=MFSettings.shared;
    CHECK(ColorMatches([settings colorForSlot:MFColorSlotSkeleton],.36,.24,.72) &&
          ColorMatches([settings colorForSlot:MFColorSlotBotSkeleton],.64,.52,.23),
          "saved human and bot colors must load independently before the menu opens");
    ClickMenu(menu,overlay,NavPoint(overlay,3));ScrollMenuToBottom(menu,overlay);
    ClickItem(menu,overlay,"human_skeleton_color");
    TestNativeColorPopupStability(menu,overlay);
    ClickItem(menu,overlay,"color_preset",2);
    CHECK(ColorMatches([settings colorForSlot:MFColorSlotSkeleton],.12,.48,1) &&
          ColorMatches([settings colorForSlot:MFColorSlotBotSkeleton],.64,.52,.23),
          "the human color swatch must update only its bound production settings slot");
    ImGui::ClosePopupsOverWindow(nullptr,false);Frame(menu,overlay);Frame(menu,overlay);
    ClickItem(menu,overlay,"bot_skeleton_color");ClickItem(menu,overlay,"color_preset",3);
    CHECK(ColorMatches([settings colorForSlot:MFColorSlotSkeleton],.12,.48,1) &&
          ColorMatches([settings colorForSlot:MFColorSlotBotSkeleton],1,.85,.08),
          "the bot color swatch must update only its bound production settings slot");
    ImGui::ClosePopupsOverWindow(nullptr,false);Frame(menu,overlay);Frame(menu,overlay);
    ClickMenu(menu,overlay,NavPoint(overlay,2));ScrollMenuToBottom(menu,overlay);
    const BOOL loot=settings.showLoot,boxes=settings.showBox,stats=settings.showLootStats;
    MenuTestHit x=MenuItem("loot_stats_x"),y=MenuItem("loot_stats_y");
    ClickMenu(menu,overlay,CGPointMake(x.origin.x+x.size.x-2,x.origin.y+x.size.y*.5));
    ClickMenu(menu,overlay,CGPointMake(y.origin.x+2,y.origin.y+y.size.y*.5));
    CHECK(settings.lootStatsXRatio==1&&settings.lootStatsYRatio==0&&
          settings.showLoot==loot&&settings.showBox==boxes&&settings.showLootStats==stats,
          "statistics position sliders must update only their independent screen anchors");
    WaitForMenuPreferences(^BOOL(MFSettings *s){return s.lootStatsXRatio==1&&s.lootStatsYRatio==0&&
        ColorMatches([s colorForSlot:MFColorSlotSkeleton],.12,.48,1)&&
        ColorMatches([s colorForSlot:MFColorSlotBotSkeleton],1,.85,.08);},
        [NSDate dateWithTimeIntervalSinceNow:3],^{
            ClickItem(menu,overlay,"loot_stats_reset");
            WaitForMenuPreferences(^BOOL(MFSettings *s){return fabs(s.lootStatsXRatio-.01f)<.001&&
                fabs(s.lootStatsYRatio-.18f)<.001;},[NSDate dateWithTimeIntervalSinceNow:3],^{
                    TestRadarControlsAndSave(menu,overlay,^{
                        ClickMenu(menu,overlay,NavPoint(overlay,0));completion();
                    });
                });
        });
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
    NSArray<NSString *> *botKeys = @[@"showBotName", @"showBotSkeleton", @"showBotHealth", @"showBotTracer", @"showBotArmor"];
    NSDictionary *botDetails = [settings dictionaryWithValuesForKeys:botKeys];
    ClickMenu(menu, overlay, NavPoint(overlay, 1));
    ScrollMenuToBottom(menu, overlay);
    const MenuTestHit hit = MenuItem("drawing_1");
    const CGPoint botTile = CGPointMake(hit.origin.x+hit.size.x*.5,hit.origin.y+hit.size.y*.5);
    CHECK([overlay acceptsInteractionAtPoint:botTile],
          "the visible production drawing tile must accept input");
    ClickMenu(menu, overlay, botTile);
    CHECK(settings.showBot != initial,
          "tapping the active drawing page must change its production setting");
    CHECK([[settings dictionaryWithValuesForKeys:botKeys] isEqual:botDetails],
          "temporarily hiding all bots must retain every individual bot feature preference");
    WaitForSettingsSave(settings.showBot, [NSDate dateWithTimeIntervalSinceNow:3], ^{
        ClickMenu(menu, overlay, botTile);
        CHECK(settings.showBot == initial, "a second drawing tap must restore its preference");
        CHECK([[settings dictionaryWithValuesForKeys:botKeys] isEqual:botDetails],
              "restoring bot visibility must preserve its previous detail preferences");
        WaitForSettingsSave(initial, [NSDate dateWithTimeIntervalSinceNow:3], ^{
            TestBotDetailControlsAndSave(menu, overlay, completion);
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
    const MenuTestHit statsHit = MenuItem("loot_stats");
    const CGPoint statsRow = CGPointMake(statsHit.origin.x+statsHit.size.x*.5,statsHit.origin.y+statsHit.size.y*.5);
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
    [window layoutIfNeeded];
    [shield setNeedsLayout]; [shield layoutIfNeeded];
    const CGRect content = shield.contentView.bounds;
    overlay.bounds = (CGRect){CGPointZero, content.size};
    overlay.center = CGPointMake(CGRectGetMidX(content), CGRectGetMidY(content));
    [overlay layoutIfNeeded];
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
    const int tabs[] = {1,2,3,4,0};
    for (int tab : tabs) {
        const CGPoint point = NavPoint(overlay, tab);
        CHECK([overlay acceptsInteractionAtPoint:point], "each useful navigation target must be reachable");
        ClickMenu(menu, overlay, point);
        CHECK(ImGui::GetDrawData()->TotalVtxCount > 100 && ImGui::GetActiveID() == 0,
              "page selection must render content and release its touch owner");
        if (tab == 1 || tab == 2) CheckNativeFeatureTileLabels(overlay);
    }
    ScrollMenuToBottom(menu,overlay);
    const BOOL fpsBefore=settings.showFPS, masterBefore=settings.masterEnabled, drawingBefore=settings.drawEnabled;
    ClickItem(menu,overlay,"fps_enabled");
    CHECK(settings.showFPS!=fpsBefore&&settings.masterEnabled==masterBefore&&settings.drawEnabled==drawingBefore,
          "the realtime FPS switch must bind only its independent production setting");
    ClickItem(menu,overlay,"fps_enabled");
    CHECK(settings.showFPS==fpsBefore,"the FPS display must be reversible through the actual menu control");
    TestDrawingTileAndAutomaticSave(menu, overlay, ^{
      TestIndependentLootStatsAndSave(menu, overlay, ^{
       TestColorsAndPositionPersistence(menu,overlay,^{
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
        const CGFloat angles[] = {(CGFloat)M_PI_2, (CGFloat)-M_PI_2, 0,
                                 (CGFloat)M_PI_2, (CGFloat)-M_PI_2, 0,
                                 (CGFloat)M_PI_2, (CGFloat)-M_PI_2, 0};
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
    CHECK(CGSizeEqualToSize(island.intrinsicContentSize, CGSizeMake(132,36)) &&
          [island.accessibilityIdentifier isEqual:@"hud.dynamicIsland"],
          "the native island must keep its compact, accessible touch surface");
    [island setExpanded:YES animated:NO];
    CHECK(island.isExpanded && [island.accessibilityValue hasPrefix:@"已展开"],
          "island accessibility must reflect the current expanded state");
    [island setExpanded:NO animated:NO];
    CHECK(!island.isExpanded && [island.accessibilityValue hasPrefix:@"已收起"],
          "island accessibility must reflect the current collapsed state");
    [island updateRealCount:4 botCount:5 cameraValid:YES];
    UILabel *realLabel = [island valueForKey:@"realLabel"];
    UILabel *botLabel = [island valueForKey:@"botLabel"];
    CHECK([realLabel.text isEqual:@"4"] && [botLabel.text isEqual:@"5"] && island.subviews.count == 2,
          "native island must show only two numbers without category, loot or action text");
    CHECK([realLabel.textColor isEqual:[UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0]] &&
          [botLabel.textColor isEqual:UIColor.whiteColor] &&
          CGRectGetMaxX(realLabel.frame) < CGRectGetMinX(botLabel.frame) &&
          CGRectGetMidY(realLabel.frame) == CGRectGetMidY(botLabel.frame),
          "real players must be red on the left and bots white on the right in a single row");
    [island updateRealCount:999 botCount:999 cameraValid:YES];
    CHECK(realLabel.intrinsicContentSize.width<=realLabel.bounds.size.width&&
          botLabel.intrinsicContentSize.width<=botLabel.bounds.size.width,
          "both three-digit counts must fit the reduced island without clipping");
    [island updateRealCount:4 botCount:5 cameraValid:YES];
    CHECK([island.accessibilityValue containsString:@"真人4，人机5"] &&
          ![island.accessibilityValue containsString:@"物资"],
          "VoiceOver must identify both numeric counters without announcing loot");
    [island setExpanded:YES animated:NO];
    CHECK([realLabel.text isEqual:@"4"] && [botLabel.text isEqual:@"5"] &&
          [island.accessibilityValue hasPrefix:@"已展开"],
          "toggling the menu must preserve the current island statistics");
    [island updateRealCount:99 botCount:99 cameraValid:NO];
    CHECK([realLabel.text isEqual:@"0"] && [botLabel.text isEqual:@"0"] &&
          [island.accessibilityValue containsString:@"等待画面"],
          "an unavailable camera must clear stale counts instead of advertising old data");
    __block NSUInteger deliveries = 0;
    MFMenuPanelReportStats(0, 0, 0, NO, 0);
    MFMenuPanelSetStatsChangeHandler(^(int real, int bot, int loot, BOOL cameraOK) {
        deliveries++;
        [island updateRealCount:real botCount:bot cameraValid:cameraOK];
    });
    MFMenuPanelReportStats(2, 4, 31, YES, 0);
    MFMenuPanelReportStats(2, 4, 31, YES, 0);
    CHECK(deliveries == 2 && [realLabel.text isEqual:@"2"] && [botLabel.text isEqual:@"4"],
          "production stats must reach the island even without panel rendering and skip unchanged counts");
    MFMenuPanelReportStats(2, 4, 31, NO, 0);
    CHECK([realLabel.text isEqual:@"0"] && [botLabel.text isEqual:@"0"],
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
static NSString *sPreviewAcknowledgement;
static void PreviewMenuPage(NSUInteger stage);
static void WaitForPreviewScreenshot(NSUInteger stage) {
    const char *names[] = {"menu", "menu-drawing", "menu-loot"};
    NSString *suffixes[] = {@"", @".drawing", @".loot"};
    NSString *acknowledgement = [sPreviewAcknowledgement stringByAppendingString:suffixes[stage]];
    printf("READY: %s screenshot\n", names[stage]); fflush(stdout);
    // Keep each real Metal surface visible until the runner captures its PNG.
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:acknowledgement]) return;
        [timer invalidate];
        if (stage < 2) { PreviewMenuPage(stage+1); return; }
        sPreviewFinished = YES;
        [sPreviewOverlay stopRendering]; sPreviewWindow.hidden = YES;
        puts("PASS: production menu layout, clipping, collapse and Metal preview"); fflush(stdout);
        exit(0);
    }];
}
static void PreviewMenuPage(NSUInteger stage) {
    [sPreviewOverlay stopRendering];
    // Use the real navigation hit and input frames, retaining the production
    // renderer/state. The CPU frames settle page animation before GPU capture.
    ClickMenu(sPreviewMenu, sPreviewOverlay, NavPoint(sPreviewOverlay, (int)stage));
    const CGFloat scale = PanelScale(sPreviewOverlay);
    ImGui::GetIO().AddMousePosEvent(220*scale, 360*scale);
    ImGui::GetIO().AddMouseWheelEvent(0, 10);
    for (int frame = 0; frame < 90; ++frame) Frame(sPreviewMenu, sPreviewOverlay);
    CheckNativeFeatureTileLabels(sPreviewOverlay);
    (void)MenuItem(stage == 1 ? "drawing_2" : "loot_enabled");
    (void)MenuItem(stage == 1 ? "drawing_5" : "loot_stats");
    sPreviewOverlay.firstFrameCompletion = ^(NSString *error) {
        CHECK(error == nil, "each menu screenshot page must complete a real GPU frame");
        WaitForPreviewScreenshot(stage);
    };
    NSString *error = nil;
    CHECK([sPreviewOverlay startRenderingWithError:&error], "each menu screenshot page renderer must restart");
}
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
    [previewIsland updateRealCount:4 botCount:5 cameraValid:YES];
    [sPreviewIslandWindow.rootViewController.view addSubview:previewIsland];
    sPreviewIslandWindow.hidden = NO;
    [sPreviewIslandWindow layoutIfNeeded];
    sPreviewOverlay.firstFrameCompletion = ^(NSString *error) {
        CHECK(error == nil, "the production menu must complete a real GPU frame");
        const char *ackPath = getenv("MF_REGRESSION_SCREENSHOT_ACK");
        CHECK(ackPath && *ackPath, "the menu preview requires a screenshot acknowledgement path");
        sPreviewAcknowledgement = [NSString stringWithUTF8String:ackPath];
        WaitForPreviewScreenshot(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CHECK(sPreviewFinished, "all three menu screenshots must be acknowledged before their deadline");
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
        TestIndependentBotSettingsPersistence();
        TestSettingsColorAndAnchorPersistence();
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
