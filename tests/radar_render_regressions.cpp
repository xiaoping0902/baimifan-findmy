#include "../app/Sources/HUD/MFRadar.mm"
#include <cstdio>
#include <cstdlib>
#include <cmath>

#define CHECK(c, msg) do { if (!(c)) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); } } while (0)

static constexpr ImU32 kTarget = IM_COL32(240, 25, 125, 255);
struct Bounds { float l = INFINITY, t = INFINITY, r = -INFINITY, b = -INFINITY; int count = 0; };

static ImDrawData *Frame(const MFRadarConfig &config, const MFRadarBlip *blip) {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(640, 720); io.DeltaTime = 1.0f / 60.0f;
    ImGui::NewFrame();
    MFRadarRender(ImGui::GetForegroundDrawList(), io.DisplaySize, &config, blip, blip ? 1 : 0);
    ImGui::Render();
    return ImGui::GetDrawData();
}

static Bounds TargetBounds(ImDrawData *data, bool checkCircle = false, ImU32 color = kTarget) {
    Bounds b;
    for (int i = 0; i < data->CmdLists.Size; ++i) {
        for (const ImDrawVert &v : data->CmdLists[i]->VtxBuffer) {
            CHECK(std::isfinite(v.pos.x) && std::isfinite(v.pos.y), "radar must never emit nonfinite vertices");
            if (v.col != color) continue;
            if (checkCircle)
                CHECK(std::hypot(v.pos.x - 320, v.pos.y - 360) <= 100.05f,
                      "a target facing outward at the range limit must stay inside the radar circle");
            b.l = fminf(b.l, v.pos.x); b.r = fmaxf(b.r, v.pos.x);
            b.t = fminf(b.t, v.pos.y); b.b = fmaxf(b.b, v.pos.y); ++b.count;
        }
    }
    return b;
}

int main() {
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO(); io.IniFilename = nullptr;
    unsigned char *pixels; int w, h; io.Fonts->GetTexDataAsRGBA32(&pixels, &w, &h);
    MFRadarConfig cfg{};
    cfg.rangeM = 120; cfg.xRatio = cfg.yRatio = 0.5f; cfg.radiusRatio = 100.0f / 640.0f;
    constexpr ImU32 selfColor = IM_COL32(240, 248, 255, 255);
    Bounds self = TargetBounds(Frame(cfg, nullptr), false, selfColor);
    CHECK(self.count > 0 && 360 - self.t > self.b - 360 + 0.5f && self.r - self.l < 10,
          "the self navigation glyph must remain compact and point up in camera-up mode");
    cfg.northUp = true;
    self = TargetBounds(Frame(cfg, nullptr), false, selfColor);
    CHECK(self.r - 320 > 320 - self.l + 0.5f && self.b - self.t < 10,
          "north-up must rotate the self glyph to world +X when camera yaw is zero");
    cfg.yawDeg = 90;
    self = TargetBounds(Frame(cfg, nullptr), false, selfColor);
    CHECK(360 - self.t > self.b - 360 + 0.5f,
          "north-up must rotate the self glyph to world +Y when camera yaw is ninety");
    cfg.northUp = false; cfg.yawDeg = 0;
    MFRadarBlip blip{}; blip.x = 3000; blip.color = kTarget; blip.yawDeg = NAN;
    Bounds point = TargetBounds(Frame(cfg, &blip));
    CHECK(point.count > 0 && point.r - point.l < 8 && point.b - point.t < 8,
          "an unknown heading must render only its point");
    blip.yawDeg = 90;
    Bounds east = TargetBounds(Frame(cfg, &blip));
    CHECK(east.r > point.r + 2 && fabsf(east.l - point.l) < 0.1f,
          "UE +Y facing must point right while the camera faces +X");
    blip.yawDeg = 0;
    Bounds forward = TargetBounds(Frame(cfg, &blip));
    CHECK(forward.t < point.t - 2 && fabsf(forward.b - point.b) < 0.1f,
          "matching target and camera yaw must point up");
    cfg.yawDeg = 90; blip.x = 0; blip.y = 3000; blip.yawDeg = NAN;
    point = TargetBounds(Frame(cfg, &blip));
    blip.yawDeg = 0;
    Bounds left = TargetBounds(Frame(cfg, &blip));
    CHECK(left.l < point.l - 2 && fabsf(left.r - point.r) < 0.1f,
          "target +X facing must rotate left when the camera faces +Y");
    cfg.northUp = true; blip.x = 3000; blip.y = 0; blip.yawDeg = NAN;
    point = TargetBounds(Frame(cfg, &blip)); blip.yawDeg = 90;
    Bounds north = TargetBounds(Frame(cfg, &blip));
    CHECK(north.t < point.t - 2 && fabsf(north.b - point.b) < 0.1f,
          "north-up must keep world +Y facing up independently of camera yaw");
    cfg.northUp = false; cfg.yawDeg = 0; blip.x = 12000; blip.y = 0; blip.yawDeg = 0;
    TargetBounds(Frame(cfg, &blip), true);
    blip.x = 12001;
    CHECK(TargetBounds(Frame(cfg, &blip)).count == 0, "targets beyond range must not create blips");
    blip.x = 3000; blip.yawDeg = NAN;
    point = TargetBounds(Frame(cfg, &blip)); blip.yawDeg = 1.0e30f;
    CHECK(TargetBounds(Frame(cfg, &blip)).count == point.count,
          "an implausible finite heading must not create a direction marker");
    cfg.yawDeg = NAN;
    CHECK(Frame(cfg, &blip)->TotalVtxCount == 0, "unknown camera orientation must suppress the radar");
    ImGui::DestroyContext();
    std::puts("PASS: production radar orientation, unknown headings, range and marker bounds");
}
