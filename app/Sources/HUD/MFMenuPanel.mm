//
//  MFMenuPanel.mm — 小玉原版面板的接入实现
//
//  设计要点：
//    · UIState 是唯一的界面状态，页面代码（ios_pages.h）只读它
//    · 与 MFSettings 双向：首帧从设置灌入，用户动了就写回并落盘（去抖 0.8s）
//    · 触摸命中：上报面板本地矩形，灵动岛由独立 UIKit 窗口接收触摸
//
#import "MFMenuPanel.h"
#import "MFMenuUI.h"
#import "MFHUDLog.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFSettings.h"

/* ★ 这一行把小玉的整套 UI 编进来（只有这一个 TU 编译它，避免重复符号） */
#include "UIPort/MFUiCanvas.h"

static UIState gUI;
static BOOL    gInitDone = NO;
static BOOL    gLoadedFromSettings = NO;

/* 绘制层每帧上报的统计 */
static int  sReal = 0, sBot = 0, sLoot = 0, sObservers = 0;
static BOOL sCameraOK = NO;

static CGSize sLogicalScreen = CGSizeZero;
static CGPoint sIslandCenter = CGPointZero;
static BOOL sHasIslandCenter = NO;
static void (^sPresentationChangeHandler)(void) = nil;
static NSUInteger sSettingsRevision = 0;

#pragma mark - 设置同步

static void MFPanelStoreToSettings(void) {
    if (!gUI.configDirty) return;
    gUI.configDirty = false;

    MFSettings *s = [MFSettings shared];
    s.showBot        = gUI.feat[DrawingBot];
    s.showSkeleton   = gUI.feat[DrawingSkeleton];
    s.showTracer     = gUI.feat[DrawingRay];
    s.showHealth     = gUI.feat[DrawingHealth];
    s.showName       = gUI.feat[DrawingName];
    s.showTeam       = gUI.feat[DrawingTeam];
    s.showHeld       = gUI.feat[DrawingWeapon];
    s.showDistance   = gUI.feat[DrawingDistance];
    s.showArmor      = gUI.feat[DrawingEquipment];
    s.backEnemyEnabled = gUI.feat[DrawingOffscreen];
    s.skeletonThickness = gUI.boneLineWidth;
    s.fontPerson     = 13.0f * gUI.espFontScale;
    s.fontInfo       = 13.0f * gUI.espFontScale;
    s.captureProtectionEnabled = gUI.excludeFromRecording;
    // Apply settings immediately, but persist only after the gesture settles.
    // This timer also fires when the panel has been minimized and rendering is
    // paused; no plist write belongs in the per-frame rendering path.
    const NSUInteger revision = ++sSettingsRevision;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (revision == sSettingsRevision) [s save];
    });
}

static void MFPanelLoadFromSettings(void) {
    if (gLoadedFromSettings) return;
    gLoadedFromSettings = YES;

    MFSettings *s = [MFSettings shared];
    gUI.feat[DrawingHuman]      = true;
    gUI.feat[DrawingBot]        = s.showBot;
    gUI.feat[DrawingSkeleton]   = s.showSkeleton;
    gUI.feat[DrawingRay]        = s.showTracer;
    gUI.feat[DrawingHealth]     = s.showHealth;
    gUI.feat[DrawingName]       = s.showName;
    gUI.feat[DrawingTeam]       = s.showTeam;
    gUI.feat[DrawingWeapon]     = s.showHeld;
    gUI.feat[DrawingDistance]   = s.showDistance;
    gUI.feat[DrawingEquipment]  = s.showArmor;
    gUI.feat[DrawingOffscreen]  = s.backEnemyEnabled;
    gUI.boneLineWidth           = s.skeletonThickness > 0 ? s.skeletonThickness : 1.0f;
    gUI.espFontScale            = 1.0f;
    gUI.excludeFromRecording    = s.captureProtectionEnabled;
    gUI.configDirty             = false;
}

static void MFPanelInitOnce(void) {
    if (gInitDone) return;
    gInitDone = YES;
    /* 首次启动展开；窗口的显隐与原生灵动岛由宿主管理。 */
    gUI.expanded     = true;
    gUI.anim         = 1.0f;
    gUI.tab          = 0;
    /* [M5.185] 默认放大到 1.15（上限 1.212）—— 原来的 1.0 在 iPad 上偏小 */
    gUI.uiScale      = 1.15f;
    gUI.uiScaleVisual= 1.15f;
    /* 保留导入面板的外观状态；原生灵动岛位置由宿主发布。 */
    gUI.islandYOffset= 40.0f;
    gUI.islandAlpha  = 1.0f;
    gUI.panelCenterXRatio = 0.5f;
    gUI.panelCenterYRatio = 0.5f;
    MFPanelLoadFromSettings();
}

#pragma mark - 对外接口

void MFMenuPanelSetExpanded(BOOL expanded) { MFPanelInitOnce(); gUI.expanded = expanded ? true : false; }
BOOL MFMenuPanelExpanded(void)             { MFPanelInitOnce(); return gUI.expanded ? YES : NO; }
BOOL MFMenuPanelConsumeExitRequest(void) {
    MFPanelInitOnce();
    const BOOL requested = gUI.wantExit ? YES : NO;
    gUI.wantExit = false;
    return requested;
}

CGSize MFMenuPanelPreferredSize(CGSize logicalScreen) {
    MFPanelInitOnce();
    if (!std::isfinite(logicalScreen.width) || !std::isfinite(logicalScreen.height) ||
        logicalScreen.width <= 1.0 || logicalScreen.height <= 1.0) return CGSizeZero;
    sLogicalScreen = logicalScreen;
    const UIPanelLayout layout = ComputePanelLayout(
        ImVec2((float)logicalScreen.width, (float)logicalScreen.height), gUI.uiScale);
    return CGSizeMake(layout.size.x, layout.size.y);
}

void MFMenuPanelSetPresentationChangeHandler(void (^handler)(void)) {
    sPresentationChangeHandler = [handler copy];
}

void MFMenuPanelSetIslandCenter(CGPoint center) {
    if (!std::isfinite(center.x) || !std::isfinite(center.y)) return;
    sIslandCenter = center;
    sHasIslandCenter = YES;
}

void MFMenuPanelReportStats(int real, int bot, int loot, BOOL cameraOK, int observers) {
    sReal = real; sBot = bot; sLoot = loot; sCameraOK = cameraOK; sObservers = observers;
}

ImVec2 MFMenuPanelIslandCenter(ImVec2 screen) {
    if (sHasIslandCenter) return ImVec2((float)sIslandCenter.x, (float)sIslandCenter.y);
    return ImVec2(screen.x * 0.5f, 12.0f + 34.0f * 0.5f);
}

void MFMenuPanelRender(MFOverlayView *overlay, ImVec2 screen) {
    MFPanelInitOnce();

    ImFont *font = ImGui::GetFont();
    if (font == NULL || screen.x <= 1.0f || screen.y <= 1.0f) return;

    /* ① 统计 → 灵动岛徽标（真人 / 人机 / 观战者） */
    gUI.realCount     = sReal;
    gUI.botCount      = sBot;
    gUI.lootCount     = sLoot;
    gUI.cameraValid   = sCameraOK ? true : false;
    gUI.observerCount = sObservers;
    gUI.renderFps     = ImGui::GetIO().Framerate;
    gUI.time          = (float)ImGui::GetTime();

    /* The native host owns positioning, expansion and the independent island.
     * Render only local panel content, using the full-screen layout once. */
    CGSize logicalScreen = sLogicalScreen;
    if (logicalScreen.width <= 1.0 || logicalScreen.height <= 1.0)
        logicalScreen = overlay.window.screen.bounds.size;
    if (logicalScreen.width <= 1.0 || logicalScreen.height <= 1.0)
        logicalScreen = CGSizeMake(screen.x, screen.y);
    const UIPanelLayout layout = ComputePanelLayout(
        ImVec2((float)logicalScreen.width, (float)logicalScreen.height), gUI.uiScale);
    const float previousScale = gUI.uiScale;

    // Keep both diagnostics inside the same first-three-frames condition.
    static int sFrameLog = 0;
    const BOOL logFrame = sFrameLog < 3;
    if (logFrame) {
        sFrameLog++;
        MFHUDLogLine(@"[面板] 第%d帧 开始 %.0fx%.0f scale=%.2f anim=%.2f font=%p",
                     sFrameLog, screen.x, screen.y, gUI.uiScale, gUI.anim, (void *)font);
    }
    RenderUI(gUI, screen, font, (ImTextureID)0, nullptr, 0, &layout);
    if (logFrame) {
        MFHUDLogLine(@"[面板] 第%d帧 结束", sFrameLog);
    }

    MFPanelStoreToSettings();
    if (gUI.animationActive) [overlay requestRedraw];

    const float scale = ImMin(screen.x / layout.baseWidth, screen.y / layout.baseHeight);
    const CGRect panelRect = CGRectMake(0, 0, layout.baseWidth * scale,
                                       layout.baseHeight * scale);
    [overlay addInteractiveRect:panelRect];
    overlay.captureRect = panelRect;
    overlay.headerDragRect = CGRectMake(0, 0, (layout.baseWidth - 214.0f) * scale,
                                        60.0f * scale);

    // Do this after publishing this frame's geometry.  The host can resize
    // synchronously, while the next frame fits its new viewport exactly once.
    if (std::fabs(previousScale - gUI.uiScale) > .00001f && sPresentationChangeHandler)
        sPresentationChangeHandler();
}
