//
//  MFStyle.mm — 浅色 iOS 主题（token 照抄 小玉源码 jni/src/ui.h · GetTheme）
//
#import "MFStyle.h"
#include <math.h>

static inline ImVec4 MFV(ImU32 c) {
    return ImGui::ColorConvertU32ToFloat4(c);
}

MFStyleOptions MFStyleDefaultOptions(void) {
    MFStyleOptions o;
    o.theme = 0;
    o.accentHue = 0.58f;      /* ≈ #0A84FF */
    o.alpha = 0.96f;
    return o;
}

void MFApplyLightStyle(ImGuiStyle *style, MFStyleOptions options) {
    if (!style) return;
    ImGuiStyle &s = *style;

    /* ── 底色（参考实现 palette）── */
    static const int palette[4][3] = {
        {242, 242, 247},   /* 0 纯白灰 */
        {239, 244, 250},   /* 1 雾蓝 */
        {243, 241, 248},   /* 2 浅紫 */
        {248, 241, 243},   /* 3 柔粉 */
    };
    int t = (options.theme < 0 || options.theme > 3) ? 0 : options.theme;
    const int *rgb = palette[t];

    float a = options.alpha;
    if (!isfinite(a)) a = 0.96f;
    if (a < 0.60f) a = 0.60f;
    if (a > 1.00f) a = 1.00f;
    const int alpha = (int)(a * 255.0f);

    const ImU32 panel    = IM_COL32(rgb[0], rgb[1], rgb[2], alpha);
    const ImU32 surface  = IM_COL32(255, 255, 255, alpha);
    const ImU32 track    = IM_COL32(237, 242, 250, alpha);
    const ImU32 border   = IM_COL32(60, 60, 67, 60);      /* 参考值 20，放大一点保证可见 */
    const ImU32 divider  = IM_COL32(60, 60, 67, 45);
    const ImU32 text     = IM_COL32(28, 28, 30, 255);
    const ImU32 muted    = IM_COL32(99, 99, 102, 255);
    const ImU32 faint    = IM_COL32(118, 118, 128, 255);

    float r = 0.0f, g = 0.0f, b = 0.0f;
    ImGui::ColorConvertHSVtoRGB(options.accentHue, 0.85f, 0.96f, r, g, b);
    const ImU32 accent = IM_COL32((int)(r * 255), (int)(g * 255), (int)(b * 255), 255);
    const ImU32 accentSoft = IM_COL32((int)(r * 255), (int)(g * 255), (int)(b * 255), 40);
    const ImU32 danger = IM_COL32(217, 45, 32, 255);
    const ImU32 success = IM_COL32(36, 138, 61, 255);
    const ImU32 warning = IM_COL32(169, 103, 5, 255);

    /* ── 圆角与内边距（参考实现更圆：iOS 卡片感）── */
    s.WindowRounding    = 16.0f;
    s.ChildRounding     = 12.0f;
    s.FrameRounding     = 10.0f;
    s.PopupRounding     = 14.0f;
    s.ScrollbarRounding = 10.0f;
    s.GrabRounding      = 10.0f;
    s.TabRounding       = 10.0f;

    s.WindowBorderSize  = 1.0f;
    s.ChildBorderSize   = 1.0f;
    s.FrameBorderSize   = 0.0f;
    s.PopupBorderSize   = 1.0f;

    s.WindowPadding     = ImVec2(16, 14);
    s.FramePadding      = ImVec2(12, 9);
    s.ItemSpacing       = ImVec2(10, 10);
    s.ItemInnerSpacing  = ImVec2(8, 6);
    s.ScrollbarSize     = 10.0f;
    s.GrabMinSize       = 18.0f;

    /* ── 颜色 ── */
    ImVec4 *c = s.Colors;
    c[ImGuiCol_Text]                  = MFV(text);
    c[ImGuiCol_TextDisabled]          = MFV(faint);
    c[ImGuiCol_WindowBg]              = MFV(panel);
    c[ImGuiCol_ChildBg]               = MFV(IM_COL32(255, 255, 255, 245));
    c[ImGuiCol_PopupBg]               = MFV(surface);
    c[ImGuiCol_Border]                = MFV(IM_COL32(60, 60, 67, 42));
    c[ImGuiCol_BorderShadow]          = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_FrameBg]               = MFV(surface);
    c[ImGuiCol_FrameBgHovered]        = MFV(track);
    c[ImGuiCol_FrameBgActive]         = MFV(accentSoft);
    c[ImGuiCol_TitleBg]               = MFV(panel);
    c[ImGuiCol_TitleBgActive]         = MFV(panel);
    c[ImGuiCol_TitleBgCollapsed]      = MFV(panel);
    c[ImGuiCol_MenuBarBg]             = MFV(panel);
    c[ImGuiCol_ScrollbarBg]           = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_ScrollbarGrab]         = MFV(IM_COL32(60, 60, 67, 60));
    c[ImGuiCol_ScrollbarGrabHovered]  = MFV(IM_COL32(60, 60, 67, 90));
    c[ImGuiCol_ScrollbarGrabActive]   = MFV(IM_COL32(60, 60, 67, 130));
    c[ImGuiCol_CheckMark]             = MFV(accent);
    c[ImGuiCol_SliderGrab]            = MFV(accent);
    c[ImGuiCol_SliderGrabActive]      = MFV(accent);
    c[ImGuiCol_Button]                = MFV(surface);
    c[ImGuiCol_ButtonHovered]         = MFV(track);
    c[ImGuiCol_ButtonActive]          = MFV(accentSoft);
    c[ImGuiCol_Header]                = MFV(track);
    c[ImGuiCol_HeaderHovered]         = MFV(accentSoft);
    c[ImGuiCol_HeaderActive]          = MFV(accentSoft);
    c[ImGuiCol_Separator]             = MFV(divider);
    c[ImGuiCol_SeparatorHovered]      = MFV(accent);
    c[ImGuiCol_SeparatorActive]       = MFV(accent);
    c[ImGuiCol_ResizeGrip]            = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_Tab]                   = MFV(track);
    c[ImGuiCol_TabHovered]            = MFV(accentSoft);
    c[ImGuiCol_TabSelected]           = MFV(accent);
    c[ImGuiCol_TextSelectedBg]        = MFV(accentSoft);
    c[ImGuiCol_NavHighlight]          = MFV(accent);
    c[ImGuiCol_ModalWindowDimBg]      = ImVec4(0, 0, 0, 0.35f);

    /* 语义色单独暴露：菜单里用 ColorConvertU32ToFloat4 取用 */
    (void)danger; (void)success; (void)warning; (void)muted;
}
