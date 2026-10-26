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
#ifdef MF_UI_TEST_HOOKS
extern "C" void MFRecordMenuTestItem(const char *, ImVec2, ImVec2);
#define HEIHUANG_UI_TEST_ITEM(name, origin, size) MFRecordMenuTestItem(name, origin, size)
#endif
#include "UIPort/MFUiCanvas.h"

static UIState gUI;
static BOOL    gInitDone = NO;
static BOOL    gLoadedFromSettings = NO;

/* 绘制层每帧上报的统计 */
static int  sReal = 0, sBot = 0, sLoot = 0, sObservers = 0;
static BOOL sCameraOK = NO;
static void (^sStatsChangeHandler)(int, int, int, BOOL) = nil;

static CGSize sLogicalScreen = CGSizeZero;
static CGPoint sIslandCenter = CGPointZero;
static BOOL sHasIslandCenter = NO;
static void (^sPresentationChangeHandler)(void) = nil;
static NSUInteger sSettingsRevision = 0;
static NSString *const kMFPanelAppearanceKey = @"MFMenuPanelAppearanceV1";

#pragma mark - 设置同步

static void MFPanelStoreToSettings(void) {
    if (!gUI.configDirty) return;
    gUI.configDirty = false;

    MFSettings *s = [MFSettings shared];
    s.masterEnabled = gUI.feat[DrawingHuman];
    s.drawEnabled   = gUI.feat[DrawingHuman];
    s.showBot        = gUI.feat[DrawingBot];
    s.showTeammates  = NO;
    s.showSkeleton   = gUI.feat[DrawingSkeleton];
    s.showTracer     = gUI.feat[DrawingRay];
    s.showHealth     = gUI.feat[DrawingHealth];
    s.showRadar      = gUI.radarEnabled;
    s.showFPS        = gUI.fpsEnabled;
    s.showName       = gUI.feat[DrawingName];
    s.showTeam       = gUI.feat[DrawingTeam];
    s.showHeld       = gUI.feat[DrawingWeapon];
    s.showDistance   = gUI.feat[DrawingDistance];
    s.showArmor      = gUI.feat[DrawingEquipment];
    s.backEnemyEnabled = gUI.feat[DrawingOffscreen];
    s.showLoot       = gUI.lootEnabled;
    s.showBox        = gUI.boxesEnabled;
    s.showLootName   = gUI.lootNamesEnabled;
    s.showLootStats  = gUI.lootStatsEnabled;
    s.lootStatsXRatio = gUI.lootStatsXRatio;
    s.lootStatsYRatio = gUI.lootStatsYRatio;
    s.minLootLevel   = (NSInteger)lroundf(gUI.minLootLevel);
    s.minLootValue   = (NSInteger)lroundf(gUI.minLootValue);
    s.lootDrawDistance = gUI.lootDistance;
    s.boxDrawDistance = gUI.boxDistance;
    s.skeletonDistance = gUI.skeletonDistance;
    s.backEnemyDistance = gUI.backEnemyDistance;
    s.skeletonThickness = gUI.boneLineWidth;
    s.fontPerson     = 13.0f * gUI.espFontScale;
    s.fontInfo       = 13.0f * gUI.espFontScale;
    s.fontArmor      = 12.0f * gUI.espFontScale;
    s.fontBox        = 12.0f * gUI.lootFontScale;
    s.healthBarStyle = gUI.healthBarStyle;
    [s setColor:[UIColor colorWithRed:gUI.humanSkeletonColor.x
                               green:gUI.humanSkeletonColor.y
                                blue:gUI.humanSkeletonColor.z
                               alpha:gUI.humanSkeletonColor.w]
           forSlot:MFColorSlotSkeleton];
    [s setColor:[UIColor colorWithRed:gUI.botSkeletonColor.x
                               green:gUI.botSkeletonColor.y
                                blue:gUI.botSkeletonColor.z
                               alpha:gUI.botSkeletonColor.w]
           forSlot:MFColorSlotBotSkeleton];
    s.captureProtectionEnabled = gUI.excludeFromRecording;
    // Apply settings immediately, but persist only after the gesture settles.
    // This timer also fires when the panel has been minimized and rendering is
    // paused; no plist write belongs in the per-frame rendering path.
    const NSUInteger revision = ++sSettingsRevision;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (revision != sSettingsRevision) return;
        [s save];
        [[NSUserDefaults standardUserDefaults] setObject:@{
            @"scale": @(gUI.uiScale), @"theme": @(gUI.theme),
            @"alpha": @(gUI.bgAlpha), @"accent": @(gUI.accentHue)
        } forKey:kMFPanelAppearanceKey];
    });
}

static void MFPanelLoadFromSettings(void) {
    if (gLoadedFromSettings) return;
    gLoadedFromSettings = YES;

    MFSettings *s = [MFSettings shared];
    gUI.feat[DrawingHuman]      = s.masterEnabled && s.drawEnabled;
    gUI.feat[DrawingBot]        = s.showBot;
    gUI.showTeammates           = false;
    gUI.feat[DrawingSkeleton]   = s.showSkeleton;
    gUI.feat[DrawingRay]        = s.showTracer;
    gUI.feat[DrawingHealth]     = s.showHealth;
    gUI.radarEnabled            = s.showRadar;
    gUI.fpsEnabled              = s.showFPS;
    gUI.feat[DrawingName]       = s.showName;
    gUI.feat[DrawingTeam]       = s.showTeam;
    gUI.feat[DrawingWeapon]     = s.showHeld;
    gUI.feat[DrawingDistance]   = s.showDistance;
    gUI.feat[DrawingEquipment]  = s.showArmor;
    gUI.feat[DrawingOffscreen]  = s.backEnemyEnabled;
    gUI.lootEnabled            = s.showLoot;
    gUI.boxesEnabled           = s.showBox;
    gUI.lootNamesEnabled       = s.showLootName;
    gUI.lootStatsEnabled       = s.showLootStats;
    gUI.lootStatsXRatio        = s.lootStatsXRatio;
    gUI.lootStatsYRatio        = s.lootStatsYRatio;
    gUI.minLootLevel           = (float)s.minLootLevel;
    gUI.minLootValue           = (float)s.minLootValue;
    gUI.lootDistance           = s.lootDrawDistance;
    gUI.boxDistance            = s.boxDrawDistance;
    gUI.skeletonDistance       = s.skeletonDistance;
    gUI.backEnemyDistance      = s.backEnemyDistance;
    gUI.boneLineWidth           = s.skeletonThickness > 0 ? s.skeletonThickness : 1.0f;
    gUI.espFontScale            = ImClamp(s.fontPerson / 13.0f,.85f,1.5f);
    gUI.lootFontScale           = ImClamp(s.fontBox / 12.0f,.85f,1.5f);
    gUI.healthBarStyle          = (int)s.healthBarStyle;
    CGFloat r=1,g=1,b=1,a=1;
    [[s colorForSlot:MFColorSlotSkeleton] getRed:&r green:&g blue:&b alpha:&a];
    gUI.humanSkeletonColor      = ImVec4((float)r,(float)g,(float)b,(float)a);
    [[s colorForSlot:MFColorSlotBotSkeleton] getRed:&r green:&g blue:&b alpha:&a];
    gUI.botSkeletonColor        = ImVec4((float)r,(float)g,(float)b,(float)a);
    gUI.excludeFromRecording    = s.captureProtectionEnabled;
    NSDictionary *appearance = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kMFPanelAppearanceKey];
    if ([appearance[@"scale"] isKindOfClass:[NSNumber class]]) {
        const float scale = [appearance[@"scale"] floatValue];
        if (std::isfinite(scale)) gUI.uiScale = ImClamp(scale,kPanelScaleMinimum,kPanelScaleMaximum);
    }
    if ([appearance[@"theme"] isKindOfClass:[NSNumber class]])
        gUI.theme = ImClamp([appearance[@"theme"] intValue],0,3);
    if ([appearance[@"alpha"] isKindOfClass:[NSNumber class]]) {
        const float alpha = [appearance[@"alpha"] floatValue];
        // V1 shipped .96 as the default; migrate that default to a solid panel.
        if (std::isfinite(alpha)) gUI.bgAlpha = std::fabs(alpha-.96f)<.0001f ?
            1.0f : ImClamp(alpha,.85f,1.0f);
    }
    if ([appearance[@"accent"] isKindOfClass:[NSNumber class]]) {
        const float accent = [appearance[@"accent"] floatValue];
        if (std::isfinite(accent)) gUI.accentHue = ImClamp(accent,0.0f,1.0f);
    }
    gUI.uiScaleVisual = gUI.uiScale;
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
    real = cameraOK ? MAX(real, 0) : 0;
    bot = cameraOK ? MAX(bot, 0) : 0;
    loot = cameraOK ? MAX(loot, 0) : 0;
    const BOOL changed = sReal != real || sBot != bot || sLoot != loot || sCameraOK != cameraOK;
    sReal = real; sBot = bot; sLoot = loot; sCameraOK = cameraOK; sObservers = observers;
    if (changed && sStatsChangeHandler) sStatsChangeHandler(real, bot, loot, cameraOK);
}

void MFMenuPanelSetStatsChangeHandler(void (^handler)(int, int, int, BOOL)) {
    sStatsChangeHandler = [handler copy];
    if (sStatsChangeHandler) sStatsChangeHandler(sReal, sBot, sLoot, sCameraOK);
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
