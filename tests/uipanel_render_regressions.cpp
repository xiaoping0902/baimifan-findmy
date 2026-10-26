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
int main() {
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); io.IniFilename = nullptr;
    unsigned char* pixels; int width, height;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
    TestHostedLayoutUsesTheNativeViewport();
    TestUsefulProductionPagesAndMinimize();
    TestResizeAllowsSmallerAndLargerPanels();
    TestIndependentLootControls();
    TestInertiaKeepsFramesActiveUntilSettled();
    TestPersonalitySizeSliderAndFixedIsland();
    ImGui::DestroyContext();
    std::puts("PASS: production hosted panel geometry, useful pages, minimize and bidirectional resize");
}
