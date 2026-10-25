//
//  MFRadar.mm — 圆形雷达（实现）
//
//  移植自 小玉源码 jni/src/radar.h（ComputeRadarLayout / ProjectRadarOffset /
//  RenderRadarBase 三段的数学与配色），只保留玩家雷达部分。
//
#import "MFRadar.h"
#include <math.h>
#include <float.h>     /* FLT_MAX —— CalcTextSizeA */
#include <stdio.h>

static const float kMFRA_PI = 3.14159265358979323846f;

static inline float MFRAClamp(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

typedef struct { ImVec2 center; float radius; } MFRALayout;

/// 短边自适应布局（对齐 ComputeRadarLayout）
static MFRALayout MFRALayoutFor(ImVec2 screen, const MFRadarConfig *cfg) {
    MFRALayout L = { ImVec2(0, 0), 0 };
    if (!cfg || screen.x <= 0 || screen.y <= 0) return L;

    float xr = isfinite(cfg->xRatio) ? cfg->xRatio : 0.125f;
    float yr = isfinite(cfg->yRatio) ? cfg->yRatio : (400.0f / 1080.0f);
    float rr = isfinite(cfg->radiusRatio) ? cfg->radiusRatio : (150.0f / 1080.0f);

    float shortSide = (screen.x < screen.y) ? screen.x : screen.y;
    L.radius = shortSide * MFRAClamp(rr, 0.08f, 0.25f);
    L.center = ImVec2(MFRAClamp(screen.x * xr, L.radius, screen.x - L.radius),
                      MFRAClamp(screen.y * yr, L.radius, screen.y - L.radius));
    return L;
}

/// 世界坐标差 → 雷达内偏移（对齐 ProjectRadarOffset，单位换算成 cm）
static BOOL MFRAProject(const MFRadarConfig *cfg, float tx, float ty,
                        float radius, float markerR, ImVec2 *out) {
    if (!cfg || !out) return NO;
    float dx = tx - cfg->selfX;
    float dy = ty - cfg->selfY;
    if (!isfinite(dx) || !isfinite(dy)) return NO;

    float rangeCm = cfg->rangeM * 100.0f;
    if (!(rangeCm > 0.0f) || !(radius > 0.0f)) return NO;

    float dist = sqrtf(dx * dx + dy * dy);
    if (!isfinite(dist) || dist > rangeCm) return NO;

    float rad = cfg->yawDeg * (kMFRA_PI / 180.0f);
    float s = sinf(rad), c = cosf(rad);
    float scale = radius / rangeCm;

    if (cfg->northUp) {
        out->x = dx * scale;
        out->y = -dy * scale;
    } else {
        out->x = (dy * c - dx * s) * scale;
        out->y = -(dx * c + dy * s) * scale;
    }

    /* 贴边：整个点必须留在圆环内 */
    float pd = sqrtf(out->x * out->x + out->y * out->y);
    float limit = radius - markerR - 1.0f;
    if (limit < 0.0f) limit = 0.0f;
    if (pd > limit && pd > 0.0f) {
        out->x *= limit / pd;
        out->y *= limit / pd;
    }
    return YES;
}

static void MFRAText(ImDrawList *dl, float size, ImVec2 pos, ImU32 col, const char *s) {
    ImFont *font = ImGui::GetFont();
    if (!font || !s) return;
    dl->AddText(font, size, pos, col, s);
}

static ImVec2 MFRATextSize(float size, const char *s) {
    ImFont *font = ImGui::GetFont();
    if (!font || !s) return ImVec2(0, 0);
    return font->CalcTextSizeA(size, FLT_MAX, 0.0f, s);
}

void MFRadarRender(ImDrawList *dl, ImVec2 screen,
                   const MFRadarConfig *cfg,
                   const MFRadarBlip *blips, int count) {
    if (!dl || !cfg) return;

    MFRALayout L = MFRALayoutFor(screen, cfg);
    if (L.radius <= 0.0f) return;

    const float radius = L.radius;
    const ImVec2 center = L.center;
    const float scale = MFRAClamp(radius / 150.0f, 0.65f, 1.6f);
    const ImU32 accent = IM_COL32(190, 220, 245, 225);
    const ImU32 grid   = IM_COL32(200, 220, 235, 65);

    /* ── 底盘 ── */
    dl->AddCircleFilled(center, radius, IM_COL32(12, 18, 24, 145), 100);
    dl->AddCircle(center, radius * 0.25f, grid, 100);
    dl->AddCircle(center, radius * 0.50f, IM_COL32(255, 170, 60, 95), 100);
    dl->AddCircle(center, radius, accent, 100, 1.4f * scale);
    dl->AddLine(ImVec2(center.x - radius, center.y), ImVec2(center.x + radius, center.y), grid);
    dl->AddLine(ImVec2(center.x, center.y - radius), ImVec2(center.x, center.y + radius), grid);
    {
        const float diag = kMFRA_PI * 0.25f;
        float dx = radius * cosf(diag), dy = radius * sinf(diag);
        dl->AddLine(ImVec2(center.x + dx, center.y + dy), ImVec2(center.x - dx, center.y - dy), grid);
        dl->AddLine(ImVec2(center.x + dx, center.y - dy), ImVec2(center.x - dx, center.y + dy), grid);
    }

    /* ── 朝向三角 ── */
    {
        float yaw = isfinite(cfg->yawDeg) ? (cfg->yawDeg * (kMFRA_PI / 180.0f)) : 0.0f;
        ImVec2 fwd = cfg->northUp ? ImVec2(cosf(yaw), -sinf(yaw)) : ImVec2(0, -1);
        ImVec2 rgt = ImVec2(-fwd.y, fwd.x);
        dl->AddTriangleFilled(
            ImVec2(center.x + fwd.x * 9 * scale, center.y + fwd.y * 9 * scale),
            ImVec2(center.x - fwd.x * 4 * scale + rgt.x * 4 * scale,
                   center.y - fwd.y * 4 * scale + rgt.y * 4 * scale),
            ImVec2(center.x - fwd.x * 4 * scale - rgt.x * 4 * scale,
                   center.y - fwd.y * 4 * scale - rgt.y * 4 * scale),
            accent);
    }

    /* ── 方位字母（N/E/S/W）── */
    {
        const float fontSize = 12.0f * scale;
        const char *dirs[4] = { "N", "E", "S", "W" };
        const float cr = radius - 13.0f * scale;
        float yaw = isfinite(cfg->yawDeg) ? (cfg->yawDeg * (kMFRA_PI / 180.0f)) : 0.0f;
        float s = sinf(yaw), c = cosf(yaw);
        ImVec2 offs[4];
        if (cfg->northUp) {
            offs[0] = ImVec2(0, -cr); offs[1] = ImVec2(cr, 0);
            offs[2] = ImVec2(0, cr);  offs[3] = ImVec2(-cr, 0);
        } else {
            offs[0] = ImVec2(c * cr, -s * cr);
            offs[1] = ImVec2(-s * cr, -c * cr);
            offs[2] = ImVec2(-c * cr, s * cr);
            offs[3] = ImVec2(s * cr, c * cr);
        }
        for (int i = 0; i < 4; i++) {
            ImVec2 ts = MFRATextSize(fontSize, dirs[i]);
            MFRAText(dl, fontSize,
                     ImVec2(center.x + offs[i].x - ts.x * 0.5f,
                            center.y + offs[i].y - ts.y * 0.5f),
                     accent, dirs[i]);
        }
    }

    /* ── 量程 ── */
    {
        const float fontSize = 12.0f * scale;
        char buf[24];
        snprintf(buf, sizeof(buf), "%.0fm", cfg->rangeM);
        ImVec2 ts = MFRATextSize(fontSize, buf);
        MFRAText(dl, fontSize,
                 ImVec2(center.x - ts.x * 0.5f, center.y + radius * 0.5f + 3.0f * scale),
                 IM_COL32(200, 220, 235, 170), buf);
    }

    /* ── 光点 ── */
    if (!blips || count <= 0) return;

    for (int i = 0; i < count; i++) {
        const MFRadarBlip *b = &blips[i];
        float markerR = (b->isBot ? 2.5f : 3.5f) * scale;

        ImVec2 off;
        if (!MFRAProject(cfg, b->x, b->y, radius, markerR, &off)) continue;

        ImVec2 p(center.x + off.x, center.y + off.y);

        /* 外描边让红点在浅色地面也看得清 */
        dl->AddCircleFilled(p, markerR + 1.2f * scale, IM_COL32(0, 0, 0, 130), 16);
        dl->AddCircleFilled(p, markerR, b->color, 16);

        if (b->distM > 0.0f && b->distM < 900.0f) {
            const float fs = 10.0f * scale;
            char buf[16];
            snprintf(buf, sizeof(buf), "%.0f", b->distM);
            ImVec2 ts = MFRATextSize(fs, buf);
            MFRAText(dl, fs,
                     ImVec2(p.x - ts.x * 0.5f, p.y + markerR + 1.0f * scale),
                     IM_COL32(235, 235, 235, 200), buf);
        }
    }
}
