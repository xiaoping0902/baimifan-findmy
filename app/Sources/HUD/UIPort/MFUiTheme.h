#pragma once

/* 小玉原版 ui.h（原样搬运）。原文件直接吃 aim_assist.h / mortar_math.h，
 * 这里用 MFUiCompat.h 提供同名的枚举、AimState 与上限常量 —— 页面代码一行不用改。 */
#include "MFUiCompat.h"
#include "imgui.h"
#include "imgui_internal.h"

#include <cmath>
#include <cstdio>

static constexpr int kDrawingItemCount = 17;
static constexpr int kConfigurableDrawingItemCount = kDrawingItemCount - 1;
static constexpr int kLootItemCount = 22;
static constexpr int kAlwaysOnSignalLootCategoryCount = 2;
// 信号枪0/信号弹1/指挥官密钥12/自救器15/经典黑箱16/密室钥匙21 固定启用不进面板(6个)。
static constexpr int kHiddenFixedLootCategoryCount = 6;
static constexpr int kConfigurableLootItemCount =
    kLootItemCount - kHiddenFixedLootCategoryCount;
static constexpr int kConfigurableLootCategoryIndices[kConfigurableLootItemCount] = {
    2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14,
    17, 18, 19, 20 // 地铁独立开关: 军事宝箱17/保险箱18/超级物资箱19/海盗福利箱20
};
static constexpr int kNavTabCount = 4;
static constexpr int kUIBackgroundCount = 3;
static constexpr float kUIBackgroundCycleSeconds = 10.0f;
static constexpr float kUIBackgroundFadeSeconds = 0.7f;
// Keep the serialized scale relative to the original 66% default, while the
// slider displays the requested share of screen width (35% through 80%).
static constexpr float kPanelDefaultWidthRatio = 0.66f;
static constexpr float kPanelScaleMinimum = 0.35f / kPanelDefaultWidthRatio;
static constexpr float kPanelScaleMaximum = 0.80f / kPanelDefaultWidthRatio;

// The native window and the canvas use the same layout.  A hosted canvas is
// fitted to the resulting window size; it must not apply uiScale a second time.
struct UIPanelLayout
{
    bool portrait;
    float baseWidth;
    float baseHeight;
    float scale;
    ImVec2 size;
};

static UIPanelLayout ComputePanelLayout(ImVec2 screenSize, float uiScale)
{
    const bool portrait = screenSize.y > screenSize.x * 1.08f;
    // A phone-sized design grid keeps the text readable at the default zoom.
    // Scaling a desktop-width 640px grid into a 296pt window made 12px labels
    // only 5.5pt tall, regardless of the font atlas resolution.
    const float baseWidth = portrait ? 360.0f : 620.0f;
    const float baseHeight = portrait ? 500.0f : 400.0f;
    const float requested = screenSize.x * kPanelDefaultWidthRatio / baseWidth *
        ImClamp(uiScale, kPanelScaleMinimum, kPanelScaleMaximum);
    const float available = ImMin(ImMax(1.0f, screenSize.x - 24.0f) / baseWidth,
                                 ImMax(1.0f, screenSize.y - 24.0f) / baseHeight);
    const float scale = ImMax(.001f, ImMin(requested, available));
    return {portrait, baseWidth, baseHeight, scale,
            ImVec2(baseWidth * scale, baseHeight * scale)};
}
enum DrawingFeatureIndex : int
{
    DrawingHuman = 0,
    DrawingBot,
    DrawingSkeleton,
    DrawingRay,
    DrawingHealth,
    DrawingName,
    DrawingTeam,
    DrawingWeapon,
    DrawingOffscreen,
    DrawingDistance,
    DrawingVehicle,
    DrawingAirDrop,
    DrawingExplosiveRange,
    DrawingSmokeTime,
    DrawingEquipment,
    DrawingStance,
    DrawingPhysX,
};
static_assert(DrawingPhysX + 1 == kDrawingItemCount, "drawing feature count mismatch");
// The serialized feature array keeps the fixed PhysX slot out of the drawing
// page, while the ordinary skeleton switch remains user-configurable.
static constexpr int kStandaloneHorseDrawingItem = -1;
static constexpr int kStandaloneOffscreenDistanceItem = -2;
static constexpr int kStandaloneWeaponIconItem = -3; // 手持贴图(独立开关, 不进 feat 序列化)
static constexpr int kStandaloneVehicleIconItem = -4; // 载具贴图(独立开关, 不进 feat 序列化)
static constexpr int kStandaloneRadarDrawingItem = -5;
static constexpr int kVisibleDrawingItemCount = 11;
static constexpr int kVisibleDrawingFeatureIndices[kVisibleDrawingItemCount] = {
    DrawingHuman, DrawingBot, DrawingSkeleton, DrawingRay, DrawingHealth, DrawingName,
    DrawingTeam, DrawingWeapon, DrawingOffscreen, DrawingDistance, DrawingEquipment
};
static constexpr int kVisibleLootItemCount = kConfigurableLootItemCount + 1;
static constexpr int kHealthBarStyleOptionCount = 3;
static constexpr int kHealthBarStyleThin = 0;
static constexpr int kHealthBarStyleCapsule = 1;
static constexpr int kHealthBarStyleSegmented = 2;
static constexpr float kDynamicIslandScale = 1.18f;
static constexpr float kDynamicIslandHeightUnits = 46.0f;
static constexpr float kDynamicIslandBaseTopUnits = 27.0f;
static constexpr float kDynamicIslandTopUnits = kDynamicIslandBaseTopUnits +
    (kDynamicIslandBaseTopUnits +
     kDynamicIslandHeightUnits * kDynamicIslandScale * 0.5f) * 0.15f;

static constexpr int NormalizeHealthBarStyleId(int style)
{
    return style >= kHealthBarStyleThin && style < kHealthBarStyleOptionCount
        ? style : kHealthBarStyleThin;
}

// "Only horses" narrows the vehicle master switch; it never enables vehicle
// scanning or drawing on its own.
static constexpr bool ShouldRenderVehicle(bool vehicleDrawingEnabled,
                                          bool horseOnlyEnabled,
                                          bool isHorse)
{
    return vehicleDrawingEnabled && (!horseOnlyEnabled || isHorse);
}

// Synchronous player reads are the expensive part of the overlay loop. The
// selected drawing rate now also controls responsive data paths, while simple
// overlays remain capped below the render rate to preserve headroom.
static constexpr int kPlayerScanFpsMinimum = 30;
static constexpr int kPlayerScanFpsRegularMaximum = 120;
static constexpr int kPlayerScanFpsResponsiveMaximum = 144;

static constexpr int ComputePlayerScanFps(int requestedFps,
                                          bool skeletonEnabled,
                                          bool rayEnabled,
                                          bool aimEnabled,
                                          bool trackingEnabled)
{
    const int minimum = requestedFps < kPlayerScanFpsMinimum
        ? kPlayerScanFpsMinimum : requestedFps;
    const bool needsResponsiveSampling = skeletonEnabled || rayEnabled ||
                                          aimEnabled || trackingEnabled;
    const int maximum = needsResponsiveSampling
        ? kPlayerScanFpsResponsiveMaximum : kPlayerScanFpsRegularMaximum;
    return minimum > maximum ? maximum : minimum;
}

struct UIState
{
    bool  expanded = false;
    float anim = 0.0f;

    int   tab = 0;
    bool  feat[kDrawingItemCount] = {true, true, true, true, false, true, true,
                                     false, false, true, false, true, false, false,
                                     false, false, true};
    bool  horseEnabled = false;       // 载具开启时，仅绘制马
    bool  offscreenDistanceEnabled = false;
    bool  weaponIconEnabled = false; // 手持贴图(V19 独立开关, 默认关)
    bool  vehicleIconEnabled = true;  // 载具贴图(V20 独立开关, 默认开=保持现状)
    // 极简浏览器同款玩家雷达；V29 在配置末尾保存，不占 feat[] 槽位。
    bool  radarEnabled = true;
    float radarXRatio = .125f;
    float radarYRatio = 400.0f/1080.0f;
    float radarRadiusRatio = 150.0f/1080.0f;
    float radarRangeM = 300.0f;
    // 信号枪/弹（含召回变体）与指挥官密钥固定保持启用。训练营箱子(人物盒子)默认开。
    // ⚠️ 2026-09-19: 地铁四个箱子(军事宝箱17/保险箱18/超级物资箱19/海盗福利箱20)
    //    默认值 0 -> 1。原来默认关，用户在地铁里对着保险箱看不到任何绘制，
    //    误判成"箱子不绘制"（真机截图：开发者面板读出 CG030_Market_SafeBox_2_C，
    //    但 grid[18]=0 让分类结果被丢弃）。这四个都是地铁必抢箱，默认开才合理。
    int   grid[kLootItemCount] = {1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    // 索引: 0信号枪1 1信号弹1 2-11物资0 12密钥1 13宝箱1 14人物盒1 15自救器1
    //       16经典黑箱1(固定) 17军事宝箱1 18保险箱1 19超级物资箱1 20海盗福利箱1 21密室钥匙1(固定)
    AimSettings aim;
    float bgAlpha = 0.96f;
    int   theme = 0;                 // 0 white, 1 mist blue, 2 lavender, 3 blush
    float accentHue = 0.587f;
    int   fpsSel = 90;
    float uiScale = 1.0f;            // 1.0 = 66% of screen width
    float uiScaleVisual = 1.0f;
    int   healthBarStyle = kHealthBarStyleThin;
    float islandYOffset = 0.0f;
    float islandAlpha = 1.0f;
    float panelCenterXRatio = 0.5f;
    float panelCenterYRatio = 0.5f;
    bool  volumeKeyPanelControl = true;
    bool  excludeFromRecording = false;
    bool  backgroundSlideshowEnabled = false;
    // ESP overlay sizing controls (personality page).  Values are runtime
    // tunables and intentionally default to the compact layout requested by
    // the iOS style; config persistence can append them without disturbing
    // the existing serialized prefix.
    float espFontScale = 0.90f;      // 人物绘制文字/距离/状态
    float lootFontScale = 0.85f;     // 物资名称
    float vehicleFontScale = 1.0f;   // 载具文字与血条
    float vehicleIconScale = 1.0f;   // 载具贴图
    bool ladderEnabled = false;      // 梯子提示（个性绘制）
    bool activityBarEnabled = false; // 活动条提示（个性绘制）
    // 骨骼线条粗细倍率（V25 起持久化）。
    // 1.00 = 原始线宽（1.9~4.5px 随距离变化）；面板可调 0.50~3.00。
    float boneLineWidth = 1.0f;
    // 飞索（抓钩/钩锁）绘制（V26 起持久化，默认开）。
    // 极简浏览器同款：Actor 类名含 Finger/Zipline/Rope 就画出来。
    bool  ziplineEnabled = true;
    // 地铁武器箱/药箱（V27 起持久化，默认开）。
    // 类名 EscapeBox_Weapon_*/EscapeBoxHight_Weapon_* 与 EscapeBox_Medical_*。
    // 同样走独立开关，不占物资面板的 grid[] 格子。
    bool  weaponBoxEnabled = true;
    bool  medicalBoxEnabled = true;
    // 模型显示（2026-09-22 用户要求，对齐巴巴托斯"绘制Physx"）：
    // 准心射线命中哪个三角网格就把它的三角面画成绿色线框。
    // 数据来自项目里已有的 PhysX 场景（LineTrace::getNextHint）。
    bool  aimModelEnabled = false;
    float aimModelRangeM = 60.0f;    // 只画这个距离内的三角形（米）
    // 模型显示自查(2026-09-22)：格式 = PhysX就绪 / 命中网格三角形数 / 实际画出数
    bool  physxReady = false;
    int   modelMeshTris = 0;
    int   modelTrisDrawn = 0;
    // 活动密钥诊断(2026-09-23): 扫到几个 / 进列表几个
    // ★ 2026-09-23 性能面板(每秒快照, 单位 ms/帧)
    int   perfFps = 0;
    int   perfPlayersMs = 0;
    int   perfWorldMs = 0;
    int   perfRenderMs = 0;
    int   perfAimMs = 0;
    int   perfGameLinkMs = 0;
    int   perfTextureMs = 0;
    int   perfImguiMs = 0;
    int   keyTraceSeen = 0;
    int   keyTraceAdded = 0;
    float modelV0X = 0.0f;   // 命中网格首个顶点坐标(看量级判断是世界坐标还是局部坐标)
    float modelV0Y = 0.0f;
    float modelV0Z = 0.0f;
    // 通用箱子（按 BoxType 识别：保险箱/储物柜/文件柜/工具箱/木箱/垃圾桶…共 18 种）。
    // 2026-09-22 起持久化（V28），默认开。
    bool  containerEnabled = true;
    bool  developerMode = false;
    bool  decryptEnabled = false;
    bool  decryptReady = false;
    // When enabled, the ESP keeps only human and bot actors in the player
    // overlay; disabling it restores pet rendering.
    bool  petFilterEnabled = true;
    // The anti-flicker policy remains active at runtime; only its settings-page
    // toggle is hidden.  Keep the field for backwards-compatible config I/O.
    bool  boneAntiFlicker = true;

    // Legacy V30/V31 slots remain for config compatibility. The mortar is
    // always enabled with built-in ranges; these fields are not UI controls.
    bool  mortarRadar = true;
    float mortarLaunchSpeedMps = kMortarAdsSpeedMps;
    float mortarGravityMps2 = kMortarGravityMps2;
    float mortarHipMaxRangeM = kMortarHipMaximumM;

    ImVec4 humanSkeletonColor = ImVec4(1.0f, 0.16f, 0.16f, 1.0f);
    ImVec4 botSkeletonColor = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
    ImVec4 coverColor = ImVec4(1.0f, 0.30f, 0.30f, 1.0f);
    ImVec4 energyDrinkColor = ImVec4(0.24f, 0.67f, 1.0f, 1.0f);
    ImVec4 painkillerColor = ImVec4(1.0f, 0.57f, 0.19f, 1.0f);
    ImVec4 adrenalineColor = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
    ImVec4 medKitColor = ImVec4(0.36f, 0.91f, 0.62f, 1.0f);

    // Transient UI motion only; never serialized with feature settings.
    float pageOffsets[7] = {};
    float pageSpeeds[7] = {};
    float pageHeights[7] = {};
    int gesturePage = -1;
    int gestureAxis = 0;
    ImVec2 gestureStart = ImVec2(0, 0);
    float gestureScrollStart = 0.0f;
    float gestureLastY = 0.0f;
    int visualTab = -1;
    float pageReveal = 1.0f;
    bool animationActive = false;
    bool hostedViewport = false;

    int   resizeCorner = -1;
    bool  resizing = false;
    float resizeStartScale = 1.0f;
    ImVec2 resizeStartMouse = ImVec2(0.0f, 0.0f);
    ImVec2 resizeStartHalfSize = ImVec2(1.0f, 1.0f);

    bool  configDirty = false;
    // Settings that have real consumers in the drawing layer. Unimplemented
    // imported feature slots remain private for source compatibility.
    bool  showTeammates = false;
    bool  lootEnabled = false;
    bool  boxesEnabled = false;
    bool  lootNamesEnabled = true;
    bool  lootStatsEnabled = false;
    float minLootLevel = 0;
    float minLootValue = 0;
    float lootDistance = 120;
    float boxDistance = 200;
    float skeletonDistance = 80;
    float backEnemyDistance = 80;
    // Set by the home page and consumed by the main loop.  Keeping the
    // file operation out of the UI module prevents a frame from blocking on
    // filesystem I/O and gives reset the same persistence path as edits.
    bool  resetConfigRequested = false;
    bool  wantExit = false;
    float time = 0.0f;
    int   realCount = 0;   // 真人数量 (灵动岛显示)
    int   botCount = 0;    // 人机数量
    // ---- 运行时读数（2026-09-22）----
    // 面板首页「数据读取」那一行用它。用户报"什么都没画"时，这一行能直接指出
    // 断在哪一环：相机没读到 / 状态没进 GameLinked / 物资载具列表是空的。
    // 纯运行时统计，不写进配置。
    bool  cameraValid = false;
    int   gameStateId = 0;
    int   lootCount = 0;
    int   vehicleCount = 0;
    int   eventCount = 0;
    // ---- 观战检测（2026-09-15）----
    int   observerCount = 0;   // 正在观战你的观察者数量 (灵动岛显示，0=不显示)
    bool  selfObserver = false; // 你自己是否处于观战状态
    // 成功提交到 EGL 的悬浮绘制帧率（运行时统计，不写入配置）。
    // 与 fpsSel 的目标值分开，避免把 ImGui 内部采样误当成实际出屏帧率。
    float renderFps = 0.0f;
    float islandWidthVisual = 0.0f;
    float islandHoverVisual = 0.0f;
    float islandPressVisual = 0.0f;
    ImVec2 panelDragStartMouse = ImVec2(0.0f, 0.0f);
    float panelDragStartXRatio = 0.5f;
    float panelDragStartYRatio = 0.5f;
    float drawingScrollY = 0.0f;
    float lootScrollY = 0.0f;
    float aimScrollY = 0.0f;
    bool  aimScrollDragging = false;
    float aimScrollDragStartY = 0.0f;
    float aimScrollDragStartScroll = 0.0f;
    float trackingScrollY = 0.0f;
    bool  trackingScrollDragging = false;
    float trackingScrollDragStartY = 0.0f;
    float trackingScrollDragStartScroll = 0.0f;
    float settingsScrollY = 0.0f;
    bool  settingsScrollDragging = false;
    float settingsScrollDragStartY = 0.0f;
    float settingsScrollDragStartScroll = 0.0f;
    bool  selectionGridDragging = false;
    int   selectionGridPage = -1;
    float selectionGridDragStartY = 0.0f;
    float selectionGridDragStartScroll = 0.0f;
};

struct UIBackgroundTexture
{
    ImTextureID id = 0;
    int width = 0;
    int height = 0;
};

struct UIBackgroundBlend
{
    int current = 0;
    int next = 1;
    float nextAlpha = 0.0f;
};

struct ThemeColors
{
    ImU32 panel;
    ImU32 sidebar;
    ImU32 canvas;
    ImU32 track;
    ImU32 surface;
    ImU32 surfaceHover;
    ImU32 border;
    ImU32 divider;
    ImU32 text;
    ImU32 textMuted;
    ImU32 textFaint;
    ImU32 accent;
    ImU32 accentSoft;
    ImU32 success;
    ImU32 warning;
    ImU32 danger;
    ImU32 onAccent;
    ImU32 shadow;
    bool  dark;
};

static ImVec4 HueAccent(float hue, float alpha = 1.0f)
{
    float h = hue - std::floor(hue);
    float r = std::fabs(h * 6.0f - 3.0f) - 1.0f;
    float g = 2.0f - std::fabs(h * 6.0f - 2.0f);
    float b = 2.0f - std::fabs(h * 6.0f - 4.0f);
    const float saturation = 0.58f;
    const float value = 0.88f;
    r = (ImClamp(r, 0.0f, 1.0f) * saturation + (1.0f - saturation)) * value;
    g = (ImClamp(g, 0.0f, 1.0f) * saturation + (1.0f - saturation)) * value;
    b = (ImClamp(b, 0.0f, 1.0f) * saturation + (1.0f - saturation)) * value;
    return ImVec4(r, g, b, alpha);
}

static ImU32 WithAlpha(ImU32 color, int alpha)
{
    return (color & 0x00FFFFFFu) | ((ImU32)ImClamp(alpha, 0, 255) << 24);
}

static ImU32 MixColor(ImU32 a, ImU32 b, float t)
{
    t = ImClamp(t, 0.0f, 1.0f);
    const int ar = (a >> 0) & 0xFF, ag = (a >> 8) & 0xFF, ab = (a >> 16) & 0xFF, aa = (a >> 24) & 0xFF;
    const int br = (b >> 0) & 0xFF, bg = (b >> 8) & 0xFF, bb = (b >> 16) & 0xFF, ba = (b >> 24) & 0xFF;
    return IM_COL32(ar + (int)((br - ar) * t),
                    ag + (int)((bg - ag) * t),
                    ab + (int)((bb - ab) * t),
                    aa + (int)((ba - aa) * t));
}

static ImU32 MultiplyAlpha(ImU32 color, float opacity)
{
    const int alpha = (color >> 24) & 0xFF;
    return WithAlpha(color, (int)(alpha * ImClamp(opacity, 0.0f, 1.0f) + 0.5f));
}

static ThemeColors FadeTheme(const ThemeColors& colors, float opacity)
{
    ThemeColors faded = colors;
    faded.panel = MultiplyAlpha(faded.panel, opacity);
    faded.sidebar = MultiplyAlpha(faded.sidebar, opacity);
    faded.canvas = MultiplyAlpha(faded.canvas, opacity);
    faded.track = MultiplyAlpha(faded.track, opacity);
    faded.surface = MultiplyAlpha(faded.surface, opacity);
    faded.surfaceHover = MultiplyAlpha(faded.surfaceHover, opacity);
    faded.border = MultiplyAlpha(faded.border, opacity);
    faded.divider = MultiplyAlpha(faded.divider, opacity);
    faded.text = MultiplyAlpha(faded.text, opacity);
    faded.textMuted = MultiplyAlpha(faded.textMuted, opacity);
    faded.textFaint = MultiplyAlpha(faded.textFaint, opacity);
    faded.accent = MultiplyAlpha(faded.accent, opacity);
    faded.accentSoft = MultiplyAlpha(faded.accentSoft, opacity);
    faded.success = MultiplyAlpha(faded.success, opacity);
    faded.warning = MultiplyAlpha(faded.warning, opacity);
    faded.danger = MultiplyAlpha(faded.danger, opacity);
    faded.onAccent = MultiplyAlpha(faded.onAccent, opacity);
    faded.shadow = MultiplyAlpha(faded.shadow, opacity);
    return faded;
}

static float SmootherStep(float value)
{
    const float t = ImClamp(value, 0.0f, 1.0f);
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

static UIBackgroundBlend ComputeUIBackgroundBlend(float elapsedSeconds)
{
    const float cycle = ImMax(0.0f, elapsedSeconds) / kUIBackgroundCycleSeconds;
    const int completedCycles = (int)std::floor(cycle);
    const float phase = cycle - (float)completedCycles;
    UIBackgroundBlend blend;
    blend.current = completedCycles % kUIBackgroundCount;
    blend.next = (blend.current + 1) % kUIBackgroundCount;
    // Hold each wallpaper steady, then cross-fade during the final 0.7 s.
    const float secondsInCycle = phase * kUIBackgroundCycleSeconds;
    blend.nextAlpha = SmootherStep((secondsInCycle -
        (kUIBackgroundCycleSeconds - kUIBackgroundFadeSeconds)) / kUIBackgroundFadeSeconds);
    return blend;
}

static ThemeColors GetTheme(int theme, float alpha, float accentHue)
{
    ThemeColors c{};
    const int a = ImClamp((int)(alpha * 255.0f), 153, 255);
    static const int palette[4][3] = {{242,242,247},{239,244,250},{243,241,248},{248,241,243}};
    const int* rgb = palette[ImClamp(theme,0,3)];
    c.panel = IM_COL32(rgb[0],rgb[1],rgb[2],a);
    c.canvas = c.panel;
    c.sidebar = c.panel;
    c.surface = IM_COL32(255,255,255,a);
    c.surfaceHover = MixColor(c.canvas,c.surface,.45f);
    c.track = IM_COL32(237,242,250,a);
    c.border = IM_COL32(60,60,67,20);
    c.divider = IM_COL32(60,60,67,25);
    c.text = IM_COL32(28,28,30,255);
    c.textMuted = IM_COL32(99,99,102,255);
    c.textFaint = IM_COL32(118,118,128,255);
    float r,g,b;
    ImGui::ColorConvertHSVtoRGB(accentHue, .85f, .96f, r,g,b);
    c.accent = IM_COL32((int)(r*255),(int)(g*255),(int)(b*255),255);
    c.accentSoft = WithAlpha(c.accent,28);
    c.success = IM_COL32(36,138,61,255);
    c.warning = IM_COL32(169,103,5,255);
    c.danger = IM_COL32(217,45,32,255);
    c.onAccent = IM_COL32(255,255,255,255);
    c.shadow = IM_COL32(53,74,107,32);
    c.dark = false;
    return c;
}

static void BuildUIChineseRanges(ImGuiIO& io, ImVector<ImWchar>& out)
{
    ImFontGlyphRangesBuilder builder;
    builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
    // ★★ 2026-09-23 彻底解决"新加的字显示成 ?":
    //    下面是**构建时自动生成**的全量字符表(tools/gen_font_chars.py 扫描
    //    jni/src 下所有字符串字面量里的汉字/标点/全角符号, 实测 900+ 字)。
    //    以前白名单是手写的, 每加一句文案就可能缺字(骨骼线条/密室钥匙/侦察兵密钥…),
    //    现在 rebuild_xiaoyu.bat 每次编译前会自动重新生成, 新增文案必然包含在内。
#include "MFUiFontChars.h"
    builder.AddText(kGeneratedFontChars);
    builder.AddText("灵动岛固定在屏幕顶部中央");
    // 固定界面文字在启动时建立；玩家昵称的字形由主循环按需加入，避免整套汉字图集占满显存。
    builder.AddText(
        "黑皇主页绘制瞄准物资设置退出主页运行状态在线刷新项目筛选应用背景图"
        "基础绘制个性绘制面板控制面板大小过录屏恢复默认配置重置配置纯白雾蓝浅紫柔粉只绘制马全局速度"
        "运行正常实时帧率目标概况暂无目标目标在线状态持续刷新界面与状态一目了然"
        "常用绘制项目管理辅助参数调整武器追踪参数物资显示筛选主题与界面外观帧率与运行选项"
        "界面已展开已收起性能策略空闲自动降帧配置自动保存显示项目已启用全部关闭"
        "真人人机骨骼射线血量名字队伍手持背敌距离载具空投爆炸范围烟雾时间头甲包人物状态人物变色掩体变色"
        "信号枪信号弹召回爆炸猎弓子弹箭矢三级套金插医疗箱急救包止痛药肾上腺素能量饮料投掷物指挥官密钥宝箱人物盒子"
        "外观主题曜石云白高对比强调色背景透明度灵动岛上下位置灵动岛透明度默认上移下移绘制帧率省电均衡流畅"
        "个性窗口圆角面板亮度信息密度动画速度边框强度绘制字体大小物资字体大小载具文字血条载具贴图大小梯子活动条"
        "开发者模式准心对准物资显示类名真人骨骼人机骨骼掩体变色能量饮料止痛药肾上腺素医疗箱点击色块调整"
        "解密逻辑已开启已关闭就绪不可用宠物过滤仅包含宠物真人/人机"
        // ---- 2026-09-18 补齐缺字 ----
        // ⚠️ 外挂的汉字是**白名单式烘焙**的：只有出现在这些 AddText 串里的字才会被
        //    做进字体图集，漏掉的字在界面上会直接渲染成方框（"骨骼线条□□"）。
        //    下面这批是扫描 ios_pages.h / ios_ui.h 全部界面文案后找出来、上面各串漏掉的：
        //      骨骼线条【粗细】、【拟】人化拉枪、【颜】色、海盗【福利】箱、
        //      【军】事宝箱、保【险】箱、【经】典黑箱、先开启一【种】追踪【型】、
        //      解密逻辑·【法】自检通过、结束悬浮窗运行、【使】用单发参数、【该】用户
        //    多写几个字只是图集大一点点，但漏一个字界面就会出现方框，所以宁可写全。
        "骨骼线条粗细拟人化拉枪自定义颜色海盗福利箱军事宝箱保险箱经典黑箱"
        // ---- 2026-09-19 再补 ----
        //   「飞」索（物资页开关 + 地面标签「飞索」）、观「战」/观战中（灵动岛徽标）、
        //   密「室」钥「匙」（main.cpp LootDisplayName 的 LootRoomKey 标签，之前一直缺）。
        //   漏字就会渲染成方框，所以这些字必须进图集。
        "飞战室匙"
        // ---- 2026-09-22 再补：物品名字表用到的字 ----
        //   箱子内容物现在会显示具体名字(半截握把/激光瞄准器/鸭嘴枪口/绷带…),
        //   这些字全部来自 tools/gen_item_names.py 合并的外部表 + 本仓库 WeaponName。
        //   缺一个就是方框，所以按"物品名里实际出现的汉字"一次性补全。
        "之乐习以偿光冰剔勿升双合嘴垂学宵巨带年扩抽拇损握撞散汽沙消漠激焰球盾礼糕绷绿肤胜花蝎蟒补袋豆返途钻霜音鸭鹰"
        // ---- 2026-09-22 三补：箱子类型名 + 钥匙名 ----
        //   通用箱子识别带来的名字(储物柜/文件柜/工具箱/木箱/垃圾桶/密码箱/辐射箱/
        //   油桶/公文包/青铜门钥匙/金钥匙/银钥匙/破损钥匙/轮回钥匙/解密钥匙)。
        "他代任份值储其圾垃木柜桶残累纹辐铜银键附青"
        // ---- 2026-09-22 四补：贵重物品名字（金条/金币/观星仪/雪雕哨子）+ 开发者面板"父类链" ----
        "哨星雕父链"
        // ---- 2026-09-23 五补：商业钥匙（侦察兵/突击兵/特种兵密钥）+ 模型显示自查行 ----
        "兵南网"
        "先开启一种追踪类型解密逻辑算法自检通过结束悬浮窗运行狙击射手步枪使用单发参数该用户"
        "今列反吸呼坏宽尾幕弊得意扰挤末窄衰逐那见天好它差颤"
        "快捷开关基础瞄准锁定参数镜头灵敏度压枪与预判"
        "锁定触发开火开镜开火/开镜瞄准部位头部胸部动态锁定范围速度近点制动最大移动预判人机不锁倒地不锁自瞄圈关闭开启陀螺仪力度压枪圈大小"
        "高更稳强靠前稳定锁点到骨骼后停止左右修正只做微量跟随不动最快最强"
        "不开镜灵敏度红点灵敏度二倍镜灵敏度三倍镜灵敏度四倍镜灵敏度六倍镜灵敏度八倍镜灵敏度"
        "预判开关移动目标提前量自动压枪锁稳开火轻微向下压枪力度下压"
        "追踪设置追踪总开关开启后显示当前武器追踪圈统一控制单发枪爆炸猎弓和步枪追踪狙击枪和射手步枪爆炸猎弓追踪仅单发追踪概率单发追踪距离单发追踪范围突击步枪和轻机枪步枪追踪概率步枪追踪距离步枪追踪范围圈内有效"
        "遮挡目标不参与锁定"
        "追击炮雷达手持时在原生地图上显示圆形雷达雷达中心雷达半径雷达射程弹道初速重力加速度米秒"
        "通用同步开关筛选器选择项刷新率待米药装备武配件药品中血条样式分段胶囊"
        "驱动连接成功失败未连接请先刷游戏链接"
        "蜜獾汤姆逊野牛莫甘娜辛十字弩爆炸猎弓大砍刀撬棍镰刀平底锅震撼弹燃烧瓶手榴弹铝热弹"
        "三级头盔防弹衣背包全能医疗箱烟雾弹破片"
        "普通超级节庆载具暴君四圣坦克僚机复活空箱战斗无人机空投已落地下落中燃烧铝热秒玩家"
        "头甲包无有未知动作一二三四五六七金夜墨机威特先开生纳站立蹲下趴下行走奔跑跳跃爬行倒地开火开镜换弹拉栓切枪打药游泳坐车坐船跳伞翻墙挥拳掐雷自救"
        "耐久油量三轮摩托车小绵羊车摩托车蹦蹦敞篷跑车运动轿车轿车皮卡旅行车吉普快艇冲锋艇"
        "面包车两栖装甲车雪地越野车大脚车雪地摩托车滑翔机马波波车越野自行车布朗电动巴士大运霹雳车□贴"
        // Keep all Chinese literals used by the overlay in the startup atlas.
        "安按把靶版半本必避便辨才采测层查场称程充初穿传创次从达档的第顶丢独读短断堆方放服浮符负改感告格工公共固果汉黑横候化环缓恢会或基即集辑己计记加兼监减检建将交结截解进警径静就局据块来拦里例留录逻满慢没每免描命摸昵牌炮匹签区取确仍日容入扫闪尚剩实始世试是适首受竖数斯缩探体填听图拖完唯为文务析系现限霰享响写械心形须需许绪续悬旋循验要义影映硬由余域原源远约允再暂造责增占栈张找照这针诊整证直志重住转"
        "搬被币遍表并裁叉察承乘除础处串此错导道等低递掉端多额繁非各供构国含核护华获脊几际季继肩精颈旧矩跨了历联邻路码门排盆批偏频扑期齐千清求群绕如赛少身声事输顺溯算所索拓添厅腿万腕维误膝相象校序沿也异因引英于元侦阵址治致终周肘注柱专组");
    // Glyphs used by the native iOS pages, including new group/theme names.
    builder.AddText("·一三上不与个中主义了事二人仅仪伍位体使保倍倒先全八六关具军准出击分初判利制力动助包医半单压参发变只同名含启器囊四围图圈地型基外大头套子字定宝实宠密对射小就局展岛已帧常序度开式弓弹强径待心态急性总悬手投持控掩掷插收敌敏救数整料时明显景最机束条板枪柔样检概模止正步武段法浅浮海滤火灵炮炸点烟然爆物状狙猎率理用甲界略疗痛白皇盒盗目真瞄矢础示福离种秒移程稳空窗等策筛算管箭箱米类粉素紫红级纯线结绘绪置者肾背胶胸能腺自色范药蓝螺血行观解触设调贴资起超距踪载辅辑达过运近追退选透通速逻部配重量金锁镜闭闲间队陀降险雷雾面页项预题颜饮马骨骼黑（）");
    builder.BuildRanges(&out);
}

static ImVec2 TextSize(ImFont* font, float size, const char* text)
{
    return font->CalcTextSizeA(size, FLT_MAX, 0.0f, text);
}

static void DrawText(ImDrawList* dl, ImFont* font, float size, ImVec2 pos, ImU32 color, const char* text)
{
    dl->AddText(font, size, pos, color, text);
}

static void DrawTextCentered(ImDrawList* dl, ImFont* font, float size, ImVec2 p0, ImVec2 p1, ImU32 color, const char* text)
{
    const ImVec2 ts = TextSize(font, size, text);
    DrawText(dl, font, size, ImVec2(p0.x + (p1.x - p0.x - ts.x) * 0.5f,
                                    p0.y + (p1.y - p0.y - ts.y) * 0.5f), color, text);
}

static int CountEnabledDrawing(const UIState& st)
{
    int count = 0;
    for (int i = 0; i < kVisibleDrawingItemCount; ++i) {
        const int itemIndex = kVisibleDrawingFeatureIndices[i];
        count += (itemIndex == kStandaloneHorseDrawingItem
                      ? st.horseEnabled
                      : itemIndex == kStandaloneOffscreenDistanceItem
                            ? st.offscreenDistanceEnabled
                            : itemIndex == kStandaloneWeaponIconItem
                                  ? st.weaponIconEnabled
                                  : itemIndex == kStandaloneVehicleIconItem
                                        ? st.vehicleIconEnabled
                                        : itemIndex == kStandaloneRadarDrawingItem
                                              ? st.radarEnabled
                                              : st.feat[itemIndex])
                     ? 1
                     : 0;
    }
    return count;
}

static int CountEnabledLoot(const UIState& st)
{
    int count = kAlwaysOnSignalLootCategoryCount + 4; // 指挥官密钥+自救器+经典黑箱+密室钥匙固定开启
    for (int i = 0; i < kConfigurableLootItemCount; ++i)
        count += st.grid[kConfigurableLootCategoryIndices[i]] == 1 ? 1 : 0;
    return count;
}

static int CountEnabledConfigurableLoot(const UIState& st)
{
    int count = st.feat[DrawingAirDrop] ? 1 : 0;
    for (int i = 0; i < kConfigurableLootItemCount; ++i)
        count += st.grid[kConfigurableLootCategoryIndices[i]] == 1 ? 1 : 0;
    return count;
}

static bool HasActiveOverlay(const UIState& st)
{
    return st.feat[DrawingHuman] &&
        (CountEnabledDrawing(st) > 1 || st.lootEnabled || st.boxesEnabled || st.lootStatsEnabled);
}

static void DrawStatusDot(ImDrawList* dl, ImVec2 center, float radius, ImU32 color)
{
    dl->AddCircleFilled(center, radius, color);
}

static void DrawPowerIcon(ImDrawList* dl, ImVec2 center, float size, ImU32 color)
{
    dl->PathArcTo(center, size * 0.40f, -0.78f, 3.92f, 22);
    dl->PathStroke(color, 0, size * 0.10f);
    dl->AddLine(ImVec2(center.x, center.y - size * 0.48f),
                ImVec2(center.x, center.y - size * 0.02f), color, size * 0.10f);
}

static void DrawNavIcon(ImDrawList* dl, int index, ImVec2 center, float size, ImU32 color)
{
    const float w = ImMax(1.5f, size * 0.085f);
    if (index == 0) {
        // Home
        dl->AddLine(ImVec2(center.x - size * 0.40f, center.y - size * 0.02f),
                    ImVec2(center.x, center.y - size * 0.38f), color, w);
        dl->AddLine(ImVec2(center.x, center.y - size * 0.38f),
                    ImVec2(center.x + size * 0.40f, center.y - size * 0.02f), color, w);
        dl->AddRect(ImVec2(center.x - size * 0.30f, center.y - size * 0.04f),
                    ImVec2(center.x + size * 0.30f, center.y + size * 0.36f), color, size * 0.06f, 0, w);
    } else if (index == 1) {
        // Drawing layers
        const float cell = size * 0.27f;
        for (int y = 0; y < 2; ++y)
            for (int x = 0; x < 2; ++x) {
                const ImVec2 p(center.x + (x ? 0.06f : -0.34f) * size,
                               center.y + (y ? 0.06f : -0.34f) * size);
                dl->AddRect(p, ImVec2(p.x + cell, p.y + cell), color, size * 0.05f, 0, w);
            }
    } else if (index == 2) {
        // Aim reticle
        dl->AddCircle(center, size * 0.29f, color, 18, w);
        dl->AddCircleFilled(center, size * 0.07f, color);
        dl->AddLine(ImVec2(center.x - size * 0.46f, center.y), ImVec2(center.x - size * 0.20f, center.y), color, w);
        dl->AddLine(ImVec2(center.x + size * 0.20f, center.y), ImVec2(center.x + size * 0.46f, center.y), color, w);
        dl->AddLine(ImVec2(center.x, center.y - size * 0.46f), ImVec2(center.x, center.y - size * 0.20f), color, w);
        dl->AddLine(ImVec2(center.x, center.y + size * 0.20f), ImVec2(center.x, center.y + size * 0.46f), color, w);
    } else if (index == 3) {
        // Tracking radar
        dl->AddCircle(center, size * 0.41f, color, 22, w);
        dl->AddCircle(center, size * 0.19f, color, 18, ImMax(1.0f, w * 0.72f));
        dl->AddLine(center, ImVec2(center.x + size * 0.30f, center.y - size * 0.24f), color, w);
        dl->AddCircleFilled(ImVec2(center.x + size * 0.20f, center.y + size * 0.14f), size * 0.07f, color, 12);
    } else if (index == 4) {
        // Loot box
        const ImVec2 box0(center.x - size * 0.38f, center.y - size * 0.22f);
        const ImVec2 box1(center.x + size * 0.38f, center.y + size * 0.32f);
        dl->AddRect(box0, box1, color, size * 0.06f, 0, w);
        dl->AddLine(ImVec2(box0.x, center.y - size * 0.04f),
                    ImVec2(box1.x, center.y - size * 0.04f), color, w);
        dl->AddLine(ImVec2(center.x, box0.y), ImVec2(center.x, box1.y), color, w);
        dl->AddLine(ImVec2(box0.x + size * 0.06f, box0.y),
                    ImVec2(center.x, center.y - size * 0.42f), color, w);
        dl->AddLine(ImVec2(box1.x - size * 0.06f, box0.y),
                    ImVec2(center.x, center.y - size * 0.42f), color, w);
    } else if (index == 5) {
        // Appearance palette
        dl->AddCircle(center, size * 0.39f, color, 22, w);
        dl->AddCircleFilled(ImVec2(center.x - size * 0.16f, center.y - size * 0.13f), size * 0.07f, color, 12);
        dl->AddCircleFilled(ImVec2(center.x + size * 0.13f, center.y - size * 0.16f), size * 0.07f, color, 12);
        dl->AddCircleFilled(ImVec2(center.x - size * 0.18f, center.y + size * 0.13f), size * 0.07f, color, 12);
        dl->AddCircleFilled(ImVec2(center.x + size * 0.18f, center.y + size * 0.12f), size * 0.10f, color, 14);
    } else {
        // Settings sliders
        for (int i = -1; i <= 1; ++i) {
            const float y = center.y + i * size * 0.30f;
            dl->AddLine(ImVec2(center.x - size * 0.42f, y), ImVec2(center.x + size * 0.42f, y), color, w);
            const float knobX = center.x + (i == -1 ? -0.18f : (i == 0 ? 0.20f : -0.04f)) * size;
            dl->AddCircleFilled(ImVec2(knobX, y), size * 0.105f, color);
        }
    }
}


static float ComputeLayoutScale(ImVec2 screenSize, bool portrait, float screenCoverage)
{
    const float baseWidth = portrait ? 720.0f : 980.0f;
    const float totalHeight = portrait ? (930.0f + 34.0f + 42.0f)
                                       : (590.0f + 34.0f + 42.0f);
    const float widthScale = ImMax(screenSize.x * screenCoverage, 1.0f) / baseWidth;
    const float heightScale = ImMax(screenSize.y * screenCoverage, 1.0f) / totalHeight;
    return ImClamp(ImMin(widthScale, heightScale), 0.20f, 3.2f);
}


struct IslandLayout
{
    float scale;
    float top;
    float height;
    float centerY() const { return top + height * 0.5f; }
    float bottom() const { return top + height; }
};

// Shared by the island, its attached ray origins, and transient notices.
static IslandLayout ComputeIslandLayout(ImVec2 screenSize, float yOffset)
{
    const bool portrait = screenSize.y > screenSize.x * 1.08f;
    const float layoutScale = ComputeLayoutScale(screenSize, portrait, 0.66f);
    const float scale = layoutScale * kDynamicIslandScale;
    const float height = kDynamicIslandHeightUnits * scale;
    const float top = ImClamp((kDynamicIslandTopUnits + yOffset) * layoutScale,
                             6.0f, ImMax(6.0f, screenSize.y - height - 6.0f));
    return {scale, top, height};
}
