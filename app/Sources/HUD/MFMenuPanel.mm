//
//  MFMenuPanel.mm — 小玉原版面板的接入实现
//
//  设计要点：
//    · UIState 是唯一的界面状态，页面代码（ios_pages.h）只读它
//    · 与 MFSettings 双向：首帧从设置灌入，用户动了就写回并落盘（去抖 0.8s）
//    · 触摸命中：展开时报面板窗口矩形，收起时报灵动岛矩形，其余区域穿透到游戏
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

static __weak MFOverlayView *sOverlay = nil;

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
    [s save];
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
    /* [M5.186] 启动即展开面板（原版行为），点灵动岛可收起 */
    gUI.expanded     = true;
    gUI.anim         = 1.0f;
    gUI.tab          = 0;
    /* [M5.185] 默认放大到 1.15（上限 1.212）—— 原来的 1.0 在 iPad 上偏小 */
    gUI.uiScale      = 1.15f;
    gUI.uiScaleVisual= 1.15f;
    /* 灵动岛默认往下压 40，不再贴着状态栏；外观页滑杆可再调（0~600） */
    gUI.islandYOffset= 40.0f;
    gUI.islandAlpha  = 1.0f;
    gUI.panelCenterXRatio = 0.5f;
    gUI.panelCenterYRatio = 0.5f;
    MFPanelLoadFromSettings();
}

#pragma mark - 对外接口

void MFMenuPanelSetExpanded(BOOL expanded) { MFPanelInitOnce(); gUI.expanded = expanded ? true : false; }
BOOL MFMenuPanelExpanded(void)             { MFPanelInitOnce(); return gUI.expanded ? YES : NO; }

void MFMenuPanelReportStats(int real, int bot, int loot, BOOL cameraOK, int observers) {
    sReal = real; sBot = bot; sLoot = loot; sCameraOK = cameraOK; sObservers = observers;
}

ImVec2 MFMenuPanelIslandCenter(ImVec2 screen) {
    MFPanelInitOnce();
    const IslandLayout layout = ComputeIslandLayout(screen, gUI.islandYOffset);
    return ImVec2(screen.x * 0.5f, layout.top + layout.height * 0.5f);
}

void MFMenuPanelRender(MFOverlayView *overlay, ImVec2 screen) {
    MFPanelInitOnce();
    sOverlay = overlay;

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

    /* ② 页面里的开关改完 → 写回设置 */
    MFPanelStoreToSettings();

    /* ③ 画：外框 + 分页 + 当前页；收起态只画灵动岛
     * RenderUI 在 ui.h 里是【全局函数】（不在 ios 命名空间内）
     *
     * [M5.186] 前三帧打点：万一又死在渲染里，hud.log 会明确停在"开始"还是"结束"。
     */
    static int sFrameLog = 0;
    if (sFrameLog < 3) {
        sFrameLog++;
        MFHUDLogLine(@"[面板] 第%d帧 开始 %.0fx%.0f scale=%.2f anim=%.2f font=%p",
                     sFrameLog, screen.x, screen.y, gUI.uiScale, gUI.anim, (void *)font);
    }
    RenderUI(gUI, screen, font, (ImTextureID)0, nullptr, 0);
    if (sFrameLog <= 3) {
        MFHUDLogLine(@"[面板] 第%d帧 结束", sFrameLog);
    }

    /* ④ 触摸命中：展开报面板矩形，收起报灵动岛矩形
     * ★ [M5.190] 关键是 captureRect ★
     * MFOverlayView 的命中判定是「上报矩形 ∩ captureRect」——
     * 老代码在 buildPanel 里设它，我换掉之后没人设，一直保持 CGRectNull，
     * 交集永远为空 → 面板怎么点都没反应。这里补上。
     */
    if (gUI.anim > 0.01f) {
        ImGuiWindow *w = ImGui::FindWindowByName("##ios_panel");
        if (w != NULL) {
            const CGRect r = CGRectMake(w->Pos.x, w->Pos.y, w->Size.x, w->Size.y);
            [overlay addInteractiveRect:r];
            overlay.captureRect = r;
        }
    } else {
        const IslandLayout layout = ComputeIslandLayout(screen, gUI.islandYOffset);
        const float islW = 108.0f * layout.scale;
        const CGRect r = CGRectMake((screen.x - islW) * 0.5f, layout.top, islW, layout.height);
        [overlay addInteractiveRect:r];
        overlay.captureRect = r;
    }
}
