//
//  MFRadar.mm — 圆形雷达（实现）
//
//  移植自 小玉源码 jni/src/radar.h（ComputeRadarLayout / ProjectRadarOffset /
//  RenderRadarBase 三段的数学与配色），只保留玩家雷达部分。
//
#include "MFRadar.h"
#include <math.h>
#include <float.h>     /* FLT_MAX —— CalcTextSizeA */
#include <stdio.h>

static const float kMFRA_PI = 3.14159265358979323846f;

static inline float MFRAClamp(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

ImU32 MFRadarTeamColor(int teamID) {
    if (teamID <= 0) return IM_COL32(225, 232, 240, 255);
    // Golden-angle hue spacing keeps consecutive squad numbers visibly apart;
    // no frame-order allocation means the same squad keeps its color on return.
    const float hue = (float)fmod((double)teamID * 0.3819660112501051, 1.0);
    float r, g, b;
    ImGui::ColorConvertHSVtoRGB(hue, 0.78f, 1.0f, r, g, b);
    // Preserve the valid squad ID (1..999) in the low channel nibbles so
    // quantizing nearby hues never makes two known squads exactly the same.
    const unsigned identity = (unsigned)teamID;
    const int red = ((int)lroundf(r * 255) & 0xF0) | (identity & 0x0F);
    const int green = ((int)lroundf(g * 255) & 0xF0) | ((identity >> 4) & 0x0F);
    const int blue = ((int)lroundf(b * 255) & 0xF0) | ((identity >> 8) & 0x0F);
    return IM_COL32(red, green, blue, 255);
}

typedef struct { ImVec2 center; float radius; } MFRALayout;

/// 短边自适应布局（对齐 ComputeRadarLayout）
static MFRALayout MFRALayoutFor(ImVec2 screen, const MFRadarConfig *cfg) {
    MFRALayout L = { ImVec2(0, 0), 0 };
    if (!cfg || !isfinite(screen.x) || !isfinite(screen.y) || screen.x <= 0 || screen.y <= 0) return L;

    float xr = isfinite(cfg->xRatio) ? cfg->xRatio : 0.125f;
    float yr = isfinite(cfg->yRatio) ? cfg->yRatio : (400.0f / 1080.0f);
    float rr = isfinite(cfg->radiusRatio) ? cfg->radiusRatio : (150.0f / 1080.0f);

    float shortSide = (screen.x < screen.y) ? screen.x : screen.y;
    if (shortSide < 48.0f) return L;
    L.radius = shortSide * MFRAClamp(rr, 0.08f, 0.25f);
    // Include stroke anti-aliasing when the user moves the radar to an edge.
    const float inset = L.radius + 2.0f;
    L.center = ImVec2(MFRAClamp(screen.x * xr, inset, screen.x - inset),
                      MFRAClamp(screen.y * yr, inset, screen.y - inset));
    return L;
}

/// 世界坐标差 → 雷达内偏移（对齐 ProjectRadarOffset，单位换算成 cm）
static bool MFRAProject(const MFRadarConfig *cfg, float tx, float ty,
                        float radius, float markerR, ImVec2 *out) {
    if (!cfg || !out) return false;
    float dx = tx - cfg->selfX;
    float dy = ty - cfg->selfY;
    if (!isfinite(dx) || !isfinite(dy)) return false;

    float rangeCm = cfg->rangeM * 100.0f;
    if (!(rangeCm > 0.0f) || !(radius > 0.0f)) return false;

    float dist = hypotf(dx, dy);
    if (!isfinite(dist) || dist > rangeCm) return false;

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
    return true;
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
    if (!dl || !cfg || !isfinite(cfg->yawDeg) || fabsf(cfg->yawDeg) > 720.0f ||
        !isfinite(cfg->selfX) || !isfinite(cfg->selfY) ||
        !isfinite(cfg->rangeM) || cfg->rangeM <= 0.0f) return;

    MFRALayout L = MFRALayoutFor(screen, cfg);
    if (L.radius <= 0.0f) return;

    const float radius = L.radius;
    const ImVec2 center = L.center;
    const float scale = MFRAClamp(radius / 150.0f, 0.65f, 1.6f);
    const ImU32 accent = IM_COL32(205, 225, 240, 210);
    const ImU32 grid   = IM_COL32(200, 220, 235, 35);

    /* ── 底盘 ── */
    dl->AddCircleFilled(center, radius, IM_COL32(9, 15, 22, 155), 80);
    dl->AddCircle(center, radius * 0.50f, grid, 64);
    dl->AddCircle(center, radius, accent, 80, 1.2f * scale);
    dl->AddLine(ImVec2(center.x - radius, center.y), ImVec2(center.x + radius, center.y), grid);
    dl->AddLine(ImVec2(center.x, center.y - radius), ImVec2(center.x, center.y + radius), grid);
    /* ── 自己：小型导航箭头，凹口与目标圆点容易区分 ── */
    {
        float yaw = isfinite(cfg->yawDeg) ? (cfg->yawDeg * (kMFRA_PI / 180.0f)) : 0.0f;
        ImVec2 fwd = cfg->northUp ? ImVec2(cosf(yaw), -sinf(yaw)) : ImVec2(0, -1);
        ImVec2 rgt = ImVec2(-fwd.y, fwd.x);
        ImVec2 tip(center.x + fwd.x * 7 * scale, center.y + fwd.y * 7 * scale);
        ImVec2 left(center.x - fwd.x * 3.5f * scale + rgt.x * 4 * scale,
                    center.y - fwd.y * 3.5f * scale + rgt.y * 4 * scale);
        ImVec2 right(center.x - fwd.x * 3.5f * scale - rgt.x * 4 * scale,
                     center.y - fwd.y * 3.5f * scale - rgt.y * 4 * scale);
        ImVec2 notch(center.x - fwd.x * 0.8f * scale, center.y - fwd.y * 0.8f * scale);
        dl->AddCircleFilled(center, 8.5f * scale, IM_COL32(9, 15, 22, 210), 24);
        dl->AddTriangleFilled(tip, left, notch, IM_COL32(240, 248, 255, 255));
        dl->AddTriangleFilled(tip, notch, right, IM_COL32(240, 248, 255, 255));
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
        float markerR = (b->isBot ? 2.8f : 3.5f) * scale;
        const bool hasHeading = isfinite(b->yawDeg) && fabsf(b->yawDeg) <= 720.0f;
        // Reserve the full facing marker, including its anti-aliased edge.
        const float footprintR = markerR + (hasHeading ? 10.0f * scale : 1.2f * scale);

        ImVec2 off;
        if (!MFRAProject(cfg, b->x, b->y, radius, footprintR, &off)) continue;

        ImVec2 p(center.x + off.x, center.y + off.y);

        /* 外描边让红点在浅色地面也看得清 */
        dl->AddCircleFilled(p, markerR + 1.2f * scale, IM_COL32(0, 0, 0, 130), 16);
        dl->AddCircleFilled(p, markerR, b->color, 16);

        /*
         * 已验证的控制/复制身体朝向才画短楔形；未知朝向仍保留目标圆点。
         *
         * 世界前向量 = (cos θ, sin θ)，θ = 目标世界 Yaw。
         * 和光点用同一套旋转（ProjectRadarOffset），所以"前方朝上/北朝上"两种模式都对。
         */
        if (hasHeading) {
            const float th = b->yawDeg * (kMFRA_PI / 180.0f);
            const float wx = cosf(th), wy = sinf(th);
            float rx, ry;
            if (cfg->northUp) {
                rx =  wx;
                ry = -wy;
            } else {
                const float camRad = cfg->yawDeg * (kMFRA_PI / 180.0f);
                const float cs = sinf(camRad), cc = cosf(camRad);
                rx =  (wy * cc - wx * cs);
                ry = -(wx * cc + wy * cs);
            }
            const float len = markerR + 9.0f * scale;
            const ImVec2 tip(p.x + rx * len, p.y + ry * len);
            const float root = markerR;
            const float halfWidth = 3.0f * scale;
            const ImVec2 left(p.x + rx * root - ry * halfWidth, p.y + ry * root + rx * halfWidth);
            const ImVec2 right(p.x + rx * root + ry * halfWidth, p.y + ry * root - rx * halfWidth);
            dl->AddTriangle(tip, left, right, IM_COL32(2, 7, 12, 230), 1.8f * scale);
            dl->AddTriangleFilled(tip, left, right, b->color);
        }

        if (b->distM > 0.0f && b->distM < 900.0f) {
            const float fs = 10.0f * scale;
            char buf[16];
            snprintf(buf, sizeof(buf), "%.0f", b->distM);
            ImVec2 ts = MFRATextSize(fs, buf);
            MFRAText(dl, fs,
                     ImVec2(MFRAClamp(p.x - ts.x * 0.5f, center.x-radius+2, center.x+radius-ts.x-2),
                            MFRAClamp(p.y + markerR + 1.0f * scale, center.y-radius+2, center.y+radius-ts.y-2)),
                     IM_COL32(235, 235, 235, 200), buf);
        }
    }
}
