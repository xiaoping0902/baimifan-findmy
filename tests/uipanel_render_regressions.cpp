// Run the actual UIPort renderer and input loop without UIKit or a GPU.
// This covers the hosted layout used by the native floating window.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "imgui.h"
#include "imgui_internal.h"
#include "../app/Sources/HUD/MFDrawGeometryCache.h"

struct Hit { std::string name; ImVec2 origin, size; };
static std::vector<Hit> hits;
static void RecordHit(const char* name, ImVec2 origin, ImVec2 size) {
    hits.push_back({name, origin, size});
}
#define HEIHUANG_UI_TEST_ITEM(name, origin, size) RecordHit(name, origin, size)
#include "../app/Sources/HUD/UIPort/MFUiCanvas.h"

#define CHECK(condition, message) do { if (!(condition)) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); } } while (0)

static ImVec2 Center(const Hit& hit) {
    return ImVec2(hit.origin.x + hit.size.x / 2, hit.origin.y + hit.size.y / 2);
}
static Hit Item(const char* name, size_t ordinal = 0) {
    for (const Hit& hit : hits) if (hit.name == name) {
        if (ordinal-- == 0) return hit;
    }
    std::fprintf(stderr, "FAIL: visible production item missing: %s\n", name);
    std::exit(1);
}
static void Frame(UIState& state, const UIPanelLayout& layout) {
    hits.clear();
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = layout.size;
    io.DeltaTime = 1.0f / 120.0f;
    ImGui::NewFrame();
    RenderUI(state, layout.size, ImGui::GetFont(), 0, nullptr, 0, &layout);
    ImGui::Render();
}
static void Click(UIState& state, const UIPanelLayout& layout, const Hit& item) {
    ImGuiIO& io = ImGui::GetIO();
    const ImVec2 point = Center(item);
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent(point.x, point.y);
    io.AddMouseButtonEvent(0, true);
    Frame(state, layout); Frame(state, layout);
    io.AddMouseButtonEvent(0, false);
    Frame(state, layout); Frame(state, layout);
}
static void ScrollToBottom(UIState& state,const UIPanelLayout& layout) {
    ImGuiIO& io=ImGui::GetIO();
    io.AddMousePosEvent(220*layout.scale,360*layout.scale);
    io.AddMouseWheelEvent(0,-10);
    for(int i=0;i<180;++i)Frame(state,layout);
}
static void TestHostedLayoutUsesTheNativeViewport(void) {
    const ImVec2 screens[] = {{390,844}, {844,390}, {768,1024}, {1024,768}};
    const float scales[] = {kPanelScaleMinimum, 1.0f, kPanelScaleMaximum};
    for (ImVec2 screen : screens) for (float scale : scales) {
        UIState state;
        state.expanded = true; state.anim = 1;
        state.uiScale = state.uiScaleVisual = scale;
        const UIPanelLayout layout = ComputePanelLayout(screen, scale);
        CHECK(layout.size.x > 0 && layout.size.y > 0 &&
              layout.size.x <= screen.x && layout.size.y <= screen.y,
              "native panel dimensions must fit portrait, landscape, phone and tablet screens");
        Frame(state, layout); Frame(state, layout);
        ImGuiWindow* window = ImGui::FindWindowByName("##ios_panel");
        CHECK(window && window->Active && std::fabs(window->Pos.x) < .01f &&
              std::fabs(window->Pos.y) < .01f &&
              std::fabs(window->Size.x - layout.size.x) < 1.1f &&
              std::fabs(window->Size.y - layout.size.y) < 1.1f,
              "the real panel must fill its native viewport without applying screen scaling twice");
        CHECK(std::none_of(hits.begin(), hits.end(), [](const Hit& hit) {
                  return hit.name == "panel_drag" || hit.name == "island_toggle";
              }), "hosted rendering must leave native movement and island input to their native owners");
        CHECK(ImGui::GetDrawData()->TotalVtxCount > 100,
              "hosted layout must produce actual page geometry at every supported size");
    }
}
static void TestUsefulProductionPagesAndMinimize(void) {
    UIState state;
    state.expanded = true; state.anim = 1;
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    CHECK(std::count_if(hits.begin(), hits.end(), [](const Hit& hit) {
              return hit.name == "nav";
          }) == 4, "navigation must expose the four implemented pages without inactive feature pages");
    const int sequence[] = {1, 2, 3, 0, 3, 1, 0};
    for (int tab : sequence) {
        Click(state, layout, Item("nav", tab));
        CHECK(state.tab == tab, "each visible navigation button must select its production page");
        CHECK(ImGui::GetActiveID() == 0, "a page change must not retain a stuck touch owner");
    }
    Click(state, layout, Item("nav", 1));
    const bool initial = state.feat[DrawingBot];
    Click(state, layout, Item("drawing_1"));
    CHECK(state.feat[DrawingBot] != initial, "a visible drawing tile must change the real UI preference");
    Click(state, layout, Item("header_minimize"));
    CHECK(!state.expanded, "the explicit minimize control must request native panel collapse");
    Frame(state, layout);
    CHECK(hits.empty(), "a collapsed hosted panel must not create a second ImGui island or invisible controls");
}
static void TestResizeAllowsSmallerAndLargerPanels(void) {
    UIState state;
    state.expanded = true; state.anim = 1;
    state.uiScale = state.uiScaleVisual = 1.0f;
    const ImVec2 screen(844,390);
    UIPanelLayout layout = ComputePanelLayout(screen, state.uiScale);
    Frame(state, layout); Frame(state, layout);
    ImGuiIO& io = ImGui::GetIO();
    ImVec2 point = Center(Item("resize"));
    io.AddMousePosEvent(point.x, point.y);
    io.AddMouseButtonEvent(0, true);
    Frame(state, layout); Frame(state, layout);
    io.AddMousePosEvent(point.x - 90, point.y - 50);
    Frame(state, layout); Frame(state, layout);
    const float smaller = state.uiScale;
    io.AddMouseButtonEvent(0, false); Frame(state, layout); Frame(state, layout);
    CHECK(smaller < 1.0f && smaller >= kPanelScaleMinimum,
          "dragging the resize corner inward must make the native panel smaller");
    layout = ComputePanelLayout(screen, state.uiScale);
    Frame(state, layout); Frame(state, layout);
    point = Center(Item("resize"));
    io.AddMousePosEvent(point.x, point.y);
    io.AddMouseButtonEvent(0, true);
    Frame(state, layout); Frame(state, layout);
    io.AddMousePosEvent(point.x + 160, point.y + 100);
    Frame(state, layout); Frame(state, layout);
    io.AddMouseButtonEvent(0, false); Frame(state, layout); Frame(state, layout);
    CHECK(state.uiScale > smaller && state.uiScale <= kPanelScaleMaximum,
          "dragging the resize corner outward must make the native panel larger within its screen limit");
    const UIPanelLayout larger = ComputePanelLayout(screen, state.uiScale);
    CHECK(larger.size.x > layout.size.x && larger.size.y > layout.size.y,
          "a changed resize preference must change the native host dimensions");
}
static void TestIndependentLootControls(void) {
    UIState state;
    state.expanded = true; state.anim = 1;
    state.lootEnabled = false; state.boxesEnabled = false;
    state.lootStatsEnabled = false; state.lootNamesEnabled = true;
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    Click(state, layout, Item("nav", 2));
    Click(state, layout, Item("loot_stats"));
    CHECK(state.lootStatsEnabled && !state.lootEnabled && !state.boxesEnabled,
          "loot statistics must have an independent switch without enabling markers");
    Click(state, layout, Item("loot_enabled"));
    CHECK(state.lootEnabled && state.lootStatsEnabled && !state.boxesEnabled,
          "item markers must not change container or statistics preferences");
    Click(state, layout, Item("loot_boxes"));
    Click(state, layout, Item("loot_names"));
    CHECK(state.boxesEnabled && !state.lootNamesEnabled && state.lootEnabled && state.lootStatsEnabled,
          "container markers and item names must keep separate preferences");
    CHECK(std::none_of(hits.begin(), hits.end(), [](const Hit& hit) {
              return hit.name == "track_enabled" || hit.name == "aim_enabled" ||
                     hit.name == "loot_zipline" || hit.name == "loot_weapon_box";
          }), "implemented loot controls must not expose inactive imported features");
}
static void TestIndependentRadarControl(void) {
    UIState state;
    state.expanded = true; state.anim = 1; state.tab = 1;
    CHECK(!state.radarEnabled, "radar must start hidden in the simplified HUD");
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    CHECK(std::none_of(hits.begin(), hits.end(), [](const Hit& hit) {
              return hit.name == "show_teammates";
          }), "the people page must not expose a teammate drawing control");
    state.pageOffsets[1] = 190;
    Frame(state, layout); Frame(state, layout);
    const bool bot = state.feat[DrawingBot], teammates = state.showTeammates;
    Click(state, layout, Item("radar_enabled"));
    CHECK(state.radarEnabled && state.feat[DrawingBot] == bot && state.showTeammates == teammates,
          "the radar row must enable only the radar preference");
    Click(state, layout, Item("radar_enabled"));
    CHECK(!state.radarEnabled, "the radar row must also disable its preference");
}
static void TestMovableIndependentLootStatistics(void) {
    UIState state;
    state.expanded = true; state.anim = 1; state.tab = 2;
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    ScrollToBottom(state, layout);
    Hit x = Item("loot_stats_x");
    x.origin.x += x.size.x - 8*layout.scale; x.size.x = 0;
    Click(state, layout, x);
    CHECK(state.lootStatsXRatio == 1 && std::fabs(state.lootStatsYRatio-.18f)<.001f &&
          !state.lootStatsEnabled && !state.lootEnabled && !state.boxesEnabled,
          "moving the statistics anchor horizontally must preserve Y and independent display toggles");
    Hit y = Item("loot_stats_y");
    y.origin.x += 8*layout.scale; y.size.x = 0;
    Click(state, layout, y);
    CHECK(state.lootStatsYRatio == 0 && state.lootStatsXRatio == 1,
          "vertical statistics positioning must reach the top edge without moving X");
    state.configDirty = false;
    Click(state, layout, Item("loot_stats_reset"));
    CHECK(std::fabs(state.lootStatsXRatio-.01f)<.001f && std::fabs(state.lootStatsYRatio-.18f)<.001f &&
          state.configDirty && !state.lootStatsEnabled,
          "resetting statistics placement must restore only the anchor and request persistence");
}
static void TestInertiaKeepsFramesActiveUntilSettled(void) {
    UIState state;
    state.expanded = true; state.anim = 1; state.tab = 2;
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    CHECK(state.pageHeights[2] > layout.baseHeight - 158,
          "the real loot settings page must provide a scrollable viewport");
    state.pageOffsets[2] = 100;
    state.pageSpeeds[2] = 500;
    const float initial = state.pageOffsets[2];
    Frame(state, layout);
    CHECK(state.animationActive && state.pageOffsets[2] != initial,
          "scroll inertia after release must keep the menu at its active refresh rate");
    for (int frame = 0; frame < 180; frame++) Frame(state, layout);
    CHECK(!state.animationActive && std::fabs(state.pageSpeeds[2]) < .001f,
          "a settled menu must release the active refresh request instead of burning full-rate idle frames");
}
static void TestPersonalitySizeSliderAndFixedIsland(void) {
    UIState state;
    state.expanded = true; state.anim = 1;
    state.uiScale = state.uiScaleVisual = 1.0f;
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    Click(state, layout, Item("nav", 3));
    CHECK(std::none_of(hits.begin(), hits.end(), [](const Hit& hit) {
              return hit.name == "island_y" || hit.name == "island_alpha";
          }), "hosted appearance settings must not advertise controls that move or hide the fixed native island");
    Hit low = Item("panel_size");
    const float inset = 8.0f * layout.scale;
    const float right = low.origin.x + low.size.x - inset;
    low.origin.x += inset; low.size.x = 0;
    Click(state, layout, low);
    CHECK(std::fabs(state.uiScale - kPanelScaleMinimum) < .001f,
          "the appearance size slider must allow shrinking to its supported minimum");
    Hit high = Item("panel_size");
    high.origin.x = right; high.size.x = 0;
    Click(state, layout, high);
    CHECK(std::fabs(state.uiScale - kPanelScaleMaximum) < .001f,
          "the appearance size slider must allow enlarging to its supported maximum");
}
static bool SameColor(const ImVec4& a, const ImVec4& b) {
    return std::fabs(a.x-b.x)<.001f && std::fabs(a.y-b.y)<.001f &&
           std::fabs(a.z-b.z)<.001f && std::fabs(a.w-b.w)<.001f;
}
static void TestColorPopupKeepsItsGeometryStable(void) {
    UIState state;
    state.expanded = true; state.anim = 1; state.tab = 3;
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    ScrollToBottom(state, layout);
    Click(state, layout, Item("human_skeleton_color"));
    for (int frame = 0; frame < 6; ++frame) Frame(state, layout);
    CHECK(GImGui->OpenPopupStack.Size == 1 && GImGui->OpenPopupStack[0].Window,
          "the color row must open a live popup");
    ImGuiWindow *popup = GImGui->OpenPopupStack[0].Window;
    const ImVec2 size = popup->Size, position = popup->Pos;
    const Hit preset = Item("color_preset", 0);
    for (int frame = 0; frame < 30; ++frame) {
        Frame(state, layout);
        const Hit current = Item("color_preset", 0);
        CHECK(popup->Active && std::fabs(popup->Size.x-size.x)<.5f &&
              std::fabs(popup->Size.y-size.y)<.5f &&
              std::fabs(popup->Pos.x-position.x)<.5f && std::fabs(popup->Pos.y-position.y)<.5f &&
              std::fabs(current.origin.x-preset.origin.x)<.5f &&
              std::fabs(current.origin.y-preset.origin.y)<.5f,
              "an idle color popup must keep its text and controls stationary instead of flashing each frame");
    }
    const Hit picker = Item("color_picker");
    // The far-right strip is the production alpha bar. Hold a touch there,
    // then slide it down: the value must follow the same pointer continuously.
    const ImVec4 initialBot = state.botSkeletonColor;
    const ImVec2 pointer(picker.origin.x+picker.size.x-8*layout.scale,
                         picker.origin.y+50*layout.scale);
    ImGuiIO& io = ImGui::GetIO();
    state.configDirty = false;
    io.AddMousePosEvent(pointer.x,pointer.y);
    io.AddMouseButtonEvent(0,true);
    Frame(state,layout); Frame(state,layout);
    CHECK(state.humanSkeletonColor.w<.9f && state.humanSkeletonColor.w>.3f &&
          SameColor(state.botSkeletonColor,initialBot) && state.configDirty && GImGui->ActiveId,
          "dragging the actual alpha bar must edit only its bound human color");
    const float heldAlpha = state.humanSkeletonColor.w;
    const ImGuiID active = GImGui->ActiveId;
    for (int frame = 0; frame < 20; ++frame) {
        Frame(state,layout);
        CHECK(GImGui->ActiveId==active && std::fabs(state.humanSkeletonColor.w-heldAlpha)<.001f &&
              std::fabs(popup->Size.y-size.y)<.5f,
              "holding a color slider must preserve its geometry, active touch and value across frames");
    }
    io.AddMousePosEvent(pointer.x,pointer.y+30*layout.scale);
    Frame(state,layout); Frame(state,layout);
    CHECK(state.humanSkeletonColor.w<heldAlpha-.1f && GImGui->ActiveId==active,
          "the same color-bar gesture must keep adjusting smoothly after the touch moves");
    io.AddMouseButtonEvent(0,false); Frame(state,layout); Frame(state,layout);
    ImGui::ClosePopupsOverWindow(nullptr, false);
    Frame(state, layout);
}
static void TestIndependentSkeletonColorControls(void) {
    UIState state;
    state.expanded = true; state.anim = 1; state.tab = 3;
    CHECK(SameColor(state.humanSkeletonColor, ImVec4(1,.08f,.08f,1)) &&
          SameColor(state.botSkeletonColor, ImVec4(1,1,1,1)),
          "fresh skeleton colors must be vivid red for humans and white for bots");
    const UIPanelLayout layout = ComputePanelLayout(ImVec2(390,844), 1.0f);
    Frame(state, layout); Frame(state, layout);
    ScrollToBottom(state, layout);
    const ImVec4 initialBot = state.botSkeletonColor;
    Click(state, layout, Item("human_skeleton_color"));
    Click(state, layout, Item("color_preset", 2));
    CHECK(SameColor(state.humanSkeletonColor, ImVec4(.12f,.48f,1,1)) &&
          SameColor(state.botSkeletonColor, initialBot) && state.configDirty,
          "choosing a human color must dirty config and leave the bot color independent");
    ImGui::ClosePopupsOverWindow(nullptr, false);
    Frame(state, layout); Frame(state, layout);
    const ImVec4 human = state.humanSkeletonColor;
    state.configDirty = false;
    Click(state, layout, Item("bot_skeleton_color"));
    Click(state, layout, Item("color_preset", 3));
    CHECK(SameColor(state.botSkeletonColor, ImVec4(1,.85f,.08f,1)) &&
          SameColor(state.humanSkeletonColor, human) && state.configDirty,
          "choosing a bot color must dirty config and leave the human color independent");
    ImGui::ClosePopupsOverWindow(nullptr, false);
    Frame(state, layout);
}
int main() {
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); io.IniFilename = nullptr;
    unsigned char* pixels; int width, height;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
    {
        MFDrawGeometryCache geometry;
        io.DisplaySize=ImVec2(640,720); io.DeltaTime=1.f/120;
        ImGui::NewFrame();
        ImDrawList *list=ImGui::GetBackgroundDrawList();
        CHECK(geometry.due(1.0,60), "new category must update immediately");
        list->AddLine(ImVec2(10,20),ImVec2(70,90),IM_COL32(255,0,0,255),2);
        geometry.capture(list,0,1.0);
        ImGui::Render();
        CHECK(!geometry.due(1.0+1.0/120,60) && geometry.due(1.0+1.0/60,60),
              "bot work must skip one 120Hz tick and update at 60Hz");
        CHECK(!geometry.due(1.0+1.0/60,30) && geometry.due(1.0+1.0/30,30),
              "loot work must update at 30Hz");
        ImGui::NewFrame(); list=ImGui::GetBackgroundDrawList();
        geometry.append(list);
        CHECK(list->IdxBuffer.Size>0 && list->VtxBuffer.Size>0,
              "skipped category work must retain visible geometry instead of flickering");
        CHECK(list->VtxBuffer[0].col==IM_COL32(255,0,0,255), "cached category must retain its color");
        ImGui::Render();
        geometry.clear();
        CHECK(geometry.due(1.001,60), "visibility or settings invalidation must update immediately");
    }
    TestHostedLayoutUsesTheNativeViewport();
    TestUsefulProductionPagesAndMinimize();
    TestResizeAllowsSmallerAndLargerPanels();
    TestIndependentLootControls();
    TestIndependentRadarControl();
    TestMovableIndependentLootStatistics();
    TestInertiaKeepsFramesActiveUntilSettled();
    TestPersonalitySizeSliderAndFixedIsland();
    TestColorPopupKeepsItsGeometryStable();
    TestIndependentSkeletonColorControls();
    ImGui::DestroyContext();
    std::puts("PASS: production hosted panel geometry, useful pages, minimize and bidirectional resize");
}
