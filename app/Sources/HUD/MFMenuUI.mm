//
//  MFMenuUI.mm — 悬浮菜单（实现）
//
//  ★ 这个文件承担两件事 ★
//
//  ① 画菜单（ImGui 即时模式）
//  ② 每帧把「真正可交互的控件矩形」上报给 MFOverlayView
//     —— 这是「面板空白区穿透」的数据来源。没上报的像素不接受系统命中，
//        触摸会直接落到下层 App（游戏）。
//
#import "MFMenuUI.h"
#import "MFHUDControl.h"
#import "MFHUDLog.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFSettings.h"

#include "imgui.h"

//
// ★ ObjC++ 硬约束：不能对 property 表达式取地址（&s.someProp 是编译错误）。
//   所以所有 ImGui 控件都走下面这组宏：
//     读进局部变量 → 传局部变量地址 → 有变更再写回属性。
//
static __weak MFOverlayView *sRectTarget = nil;

/// 上报一个矩形（视图坐标）——只有落在上报矩形里的点才被菜单接住。
static void MFTrackRect(CGRect rect) {
    MFOverlayView *overlay = sRectTarget;
    if (!overlay) return;
    [overlay addInteractiveRect:rect];
}

/// 上报「刚刚构建完的那个 ImGui item」的矩形。
static void MFTrackLastItem(void) {
    MFOverlayView *overlay = sRectTarget;
    if (!overlay) return;
    ImVec2 a = ImGui::GetItemRectMin();
    ImVec2 b = ImGui::GetItemRectMax();
    [overlay addInteractiveRect:CGRectMake(a.x, a.y, b.x - a.x, b.y - a.y)];
}

#define MF_CHECK(label, prop)                           \
    do {                                                \
        bool _v = (s.prop);                             \
        if (ImGui::Checkbox(label, &_v)) s.prop = _v;   \
        MFTrackLastItem();                              \
    } while (0)

#define MF_CHECK_SAME(label, prop)                      \
    do {                                                \
        bool _v = (s.prop);                             \
        if (ImGui::Checkbox(label, &_v)) s.prop = _v;   \
        MFTrackLastItem();                              \
        ImGui::SameLine();                              \
    } while (0)

#define MF_SLIDE_F(label, prop, lo, hi, fmt)                          \
    do {                                                              \
        float _v = (float)(s.prop);                                   \
        ImGui::SetNextItemWidth(-1);                                  \
        if (ImGui::SliderFloat(label, &_v, lo, hi, fmt)) s.prop = _v; \
        MFTrackLastItem();                                            \
    } while (0)

#define MF_SLIDE_I(label, prop, lo, hi, fmt)                          \
    do {                                                              \
        int _v = (int)(s.prop);                                       \
        ImGui::SetNextItemWidth(-1);                                  \
        if (ImGui::SliderInt(label, &_v, lo, hi, fmt)) s.prop = _v;   \
        MFTrackLastItem();                                            \
    } while (0)

static bool MFUIColorEdit(const char *label, UIColor **io, MFColorSlot slot) {
    UIColor *c = *io;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [c getRed:&r green:&g blue:&b alpha:&a];
    float col[4] = {(float)r, (float)g, (float)b, (float)a};
    bool changed = ImGui::ColorEdit4(label, col,
                          ImGuiColorEditFlags_NoInputs | ImGuiColorEditFlags_NoLabel |
                          ImGuiColorEditFlags_AlphaBar);
    MFTrackLastItem();
    if (changed) {
        UIColor *nc = [UIColor colorWithRed:col[0] green:col[1] blue:col[2] alpha:col[3]];
        [[MFSettings shared] setColor:nc forSlot:slot];
        *io = nc;
        return true;
    }
    return false;
}

@implementation MFMenuUI {
    int _tab;
    float _alpha;
}

static BOOL gVisible = YES;
static BOOL gCollapsed = NO;
static BOOL gFullPassthrough = NO;
static void (^gFrameRateApplier)(NSInteger fps) = nil;

/// 收起态的圆球直径（点）
static const float kMFMenuBallSize = 56.0f;

+ (void)setGlobalVisible:(BOOL)visible { gVisible = visible; }
+ (BOOL)globalVisible { return gVisible; }

+ (BOOL)collapsed { return gCollapsed; }
+ (void)setCollapsed:(BOOL)collapsed { gCollapsed = collapsed; }

+ (BOOL)fullPassthrough { return gFullPassthrough; }
+ (void)setFullPassthrough:(BOOL)passthrough { gFullPassthrough = passthrough; }

+ (void)setFrameRateApplier:(void (^_Nullable)(NSInteger))applier { gFrameRateApplier = applier; }

- (instancetype)init {
    if ((self = [super init])) {
        _tab = 0;
        _alpha = 0.96f;
    }
    return self;
}

#pragma mark - MFOverlayViewDelegate

- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay {
    MFSettings *s = [MFSettings shared];

    // 整面板穿透是运行时开关，每帧同步一次即可（setter 内部有变化判断）。
    overlay.passthroughAll = gFullPassthrough;

    sRectTarget = nil;
    [overlay beginInteractiveRects];

    if (!gVisible) {
        [overlay endInteractiveRects];
        overlay.captureRect = CGRectNull;
        overlay.headerDragRect = CGRectNull;
        return;
    }

    sRectTarget = overlay;
    ImGuiIO &io = ImGui::GetIO();
    const ImVec2 screen = io.DisplaySize;

    if (gCollapsed) {
        [self buildBallOnOverlay:overlay screen:screen];
    } else {
        [self buildPanelForSettings:s overlay:overlay screen:screen];
    }

    [overlay endInteractiveRects];
    sRectTarget = nil;
}

#pragma mark - 收起态：小圆球

- (void)buildBallOnOverlay:(MFOverlayView *)overlay screen:(ImVec2)screen {
    const float ball = kMFMenuBallSize;

    ImGui::SetNextWindowSize(ImVec2(ball, ball), ImGuiCond_Always);
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, ball * 0.5f);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoScrollbar |
                             ImGuiWindowFlags_NoScrollWithMouse |
                             ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoCollapse;
    if (!ImGui::Begin("##mfball", nullptr, flags)) {
        ImGui::End();
        ImGui::PopStyleVar(2);
        overlay.captureRect = CGRectNull;
        overlay.headerDragRect = CGRectNull;
        return;
    }

    const ImVec2 origin = ImGui::GetCursorScreenPos();
    const ImVec2 center(origin.x + ball * 0.5f, origin.y + ball * 0.5f);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    dl->AddCircleFilled(center, ball * 0.5f - 2.0f, IM_COL32(22, 24, 28, 242), 40);
    dl->AddCircle(center, ball * 0.5f - 3.0f, IM_COL32(48, 209, 88, 255), 40, 2.5f);
    {
        const char *glyph = "米";
        ImVec2 ts = ImGui::CalcTextSize(glyph);
        dl->AddText(ImVec2(center.x - ts.x * 0.5f, center.y - ts.y * 0.5f),
                    IM_COL32(255, 255, 255, 238), glyph);
    }

    // 整球就是按钮：抬指时仍在球上才算「点开」——
    // 用 down 触发的话，展开后那根手指的抬起会砸在刚出现的面板控件上。
    ImGui::InvisibleButton("##mfexpand", ImVec2(ball, ball));
    MFTrackLastItem();
    if (ImGui::IsItemDeactivated() && ImGui::IsItemHovered()) {
        gCollapsed = NO;
        MFHUDLogLine(@"菜单展开");
        [overlay requestRedraw];
    }

    ImGui::End();
    ImGui::PopStyleVar(2);

    overlay.captureRect = CGRectMake(0, 0, ball, ball);
    // 整球都能拖 —— 收起态下用户靠它把小窗挪出关键区域。
    overlay.headerDragRect = CGRectMake(0, 0, ball, ball);
}

#pragma mark - 展开态：面板

- (void)buildPanelForSettings:(MFSettings *)s overlay:(MFOverlayView *)overlay screen:(ImVec2)screen {
    ImGui::SetNextWindowSize(screen, ImGuiCond_Always);
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(_alpha);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoTitleBar;
    if (!ImGui::Begin("##mfmenu", nullptr, flags)) {
        ImGui::End();
        overlay.captureRect = CGRectNull;
        overlay.headerDragRect = CGRectNull;
        return;
    }

    const ImVec2 pos = ImGui::GetWindowPos();
    const ImVec2 ws = ImGui::GetWindowSize();
    overlay.captureRect = CGRectMake(pos.x, pos.y, ws.x, ws.y);

    // ── 标题行 ──
    ImGui::TextColored(ImVec4(0.19f, 0.82f, 0.35f, 1.0f), "复刻版");
    ImGui::SameLine();
    ImGui::TextDisabled("| 悬浮菜单");
    ImGui::SameLine(ImGui::GetContentRegionAvail().x - 140);

    if (ImGui::SmallButton("收起")) {
        gCollapsed = YES;
        MFHUDLogLine(@"菜单收起为小圆球（点球体可再展开）");
        [overlay requestRedraw];
    }
    const ImVec2 collapseMin = ImGui::GetItemRectMin();
    const ImVec2 collapseMax = ImGui::GetItemRectMax();
    MFTrackLastItem();

    ImGui::SameLine();
    if (ImGui::SmallButton("退出")) {
        // 让 HUD 进程自己结束自己 —— 不需要跨 uid 的信号权限。
        MFHUDLogLine(@"菜单里点了「退出」，请求关闭悬浮窗");
        [MFHUDControl requestExit];
    }
    MFTrackLastItem();
    ImGui::Separator();

    /*
     * 标题拖动区。
     *
     * ★ 原来写成 CGRectMake(0, 0, hideMin.x - 4, hideMax.y + 4)：
     *   一旦那行被挤到可视区之外，hideMax.y 就是负数 —— 产生
     *   {{0,0},{248,-316}} 这种负高度矩形，拖动判定直接失效。
     *   这里把高度夹在 [0, 面板高] 内，并把右边界停在「收起」按钮左侧，
     *   免得拖动手势把按钮点击吃掉。
     */
    {
        CGFloat dragW = MAX(0.0f, collapseMin.x - 8.0f);
        CGFloat dragH = MIN(MAX(collapseMax.y + 6.0f, 0.0f), ws.y);
        overlay.headerDragRect = CGRectMake(0, 0, dragW, dragH);
    }

    // ── 页签 ──
    // 只上报 tab bar 整行（精确到每个 tab 的矩形在即时模式下不可靠；
    // 而 tab 行本身很短，多算一点都不影响穿透体验）。
    const ImVec2 barTop = ImGui::GetCursorScreenPos();
    if (ImGui::BeginTabBar("##tabs", ImGuiTabBarFlags_NoTooltip)) {
        if (ImGui::BeginTabItem("主功能")) { _tab = 0; [self pageMain:s]; ImGui::EndTabItem(); }
        if (ImGui::BeginTabItem("外观"))   { _tab = 1; [self pageAppearance:s]; ImGui::EndTabItem(); }
        if (ImGui::BeginTabItem("其他"))   { _tab = 2; [self pageOther:s]; ImGui::EndTabItem(); }
        ImGui::EndTabBar();
    }
    {
        const ImVec2 barBottom = ImGui::GetCursorScreenPos();
        CGFloat h = MAX(0.0f, barBottom.y - barTop.y);
        if (h > 0.0f) MFTrackRect(CGRectMake(0, barTop.y, screen.x, h));
    }

    // ── 底部：透明度 + 保存 ──
    ImGui::Separator();
    ImGui::SetNextItemWidth(-96);
    ImGui::SliderFloat("##alpha", &_alpha, 0.4f, 1.0f, "透明度 %.2f");
    MFTrackLastItem();
    ImGui::SameLine();
    if (ImGui::Button("保存配置")) [[MFSettings shared] save];
    MFTrackLastItem();

    ImGui::End();
}

#pragma mark - 主功能页

- (void)pageMain:(MFSettings *)s {
    ImGui::Spacing();
    MF_CHECK_SAME("总开关", masterEnabled);
    MF_CHECK("启用绘制", drawEnabled);

    ImGui::Spacing();
    ImGui::TextDisabled("绘制开关");
    ImGui::Separator();
    MF_CHECK("人机显示", showBot);
    MF_CHECK("名字", showName);
    MF_CHECK("头甲", showArmor);
    MF_CHECK("血量", showHealth);
    MF_CHECK("距离", showDistance);
    ImGui::SameLine();
    MF_CHECK("队伍", showTeam);
    MF_CHECK("射线", showTracer);
    ImGui::SameLine();
    MF_CHECK("手持", showHeld);
    MF_CHECK("骨骼", showSkeleton);

    ImGui::Spacing();
    ImGui::TextDisabled("物资与盒子");
    ImGui::Separator();
    MF_CHECK_SAME("物资", showLoot);
    MF_CHECK("盒子", showBox);
    MF_CHECK_SAME("物资名字", showLootName);
    MF_CHECK("统计窗口", showLootStats);

    {   // 等级阈值：0 显示「不限制」
        char fmt[32];
        if (s.minLootLevel == 0) snprintf(fmt, sizeof(fmt), "不限制");
        else                     snprintf(fmt, sizeof(fmt), "等级 >= %%d");
        MF_SLIDE_I("物资等级阈值", minLootLevel, 0, 6, fmt);
    }
    {   // 价值阈值
        char fmt[32];
        if (s.minLootValue == 0) snprintf(fmt, sizeof(fmt), "不限制");
        else                     snprintf(fmt, sizeof(fmt), "价值 >= %%d");
        MF_SLIDE_I("物资价值阈值", minLootValue, 0, 50000, fmt);
    }

    ImGui::Spacing();
    ImGui::TextDisabled("绘制范围");
    ImGui::Separator();
    MF_SLIDE_F("盒子距离", boxDrawDistance, 10.0f, 500.0f, "%.0f 米");
    MF_SLIDE_F("物资距离", lootDrawDistance, 10.0f, 500.0f, "%.0f 米");
    MF_SLIDE_F("骨骼距离", skeletonDistance, 10.0f, 300.0f, "%.0f 米");
    ImGui::TextDisabled("骨骼距离越低越流畅");

    ImGui::Spacing();
    ImGui::TextDisabled("背敌提示");
    ImGui::Separator();
    MF_CHECK("背敌", backEnemyEnabled);
    MF_SLIDE_F("背敌半径", backEnemyRadius, 10.0f, 300.0f, "%.0f px");
    {
        const char *styles[] = {"圆形", "箭头", "圆环"};
        int st = (int)s.backEnemyStyle;
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("背敌样式", &st, styles, 3)) s.backEnemyStyle = (MFBackEnemyStyle)st;
        MFTrackLastItem();
    }
}

#pragma mark - 外观页

- (void)pageAppearance:(MFSettings *)s {
    ImGui::Spacing();
    ImGui::TextDisabled("字号");
    ImGui::Separator();
    MF_SLIDE_F("人物字号", fontPerson, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("盒子字号", fontBox, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("信息字号", fontInfo, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("头甲字号", fontArmor, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("骨骼粗细", skeletonThickness, 0.5f, 6.0f, "%.1f");

    ImGui::Spacing();
    ImGui::TextDisabled("颜色");
    ImGui::Separator();

    struct Row { const char *label; MFColorSlot slot; };
    static const Row rows[] = {
        { "人物信息",   MFColorSlotPersonInfo },
        { "0-2级物资",  MFColorSlotLootLow    },
        { "3级物资",    MFColorSlotLoot3      },
        { "4级物资",    MFColorSlotLoot4      },
        { "5级物资",    MFColorSlotLoot5      },
        { "6级物资",    MFColorSlotLoot6      },
        { "队伍",       MFColorSlotTeam       },
        { "头甲",       MFColorSlotArmor      },
        { "真人骨骼",   MFColorSlotSkeleton   },
        { "背敌",       MFColorSlotBackEnemy  },
    };
    for (const Row &r : rows) {
        ImGui::Text("%s", r.label);
        ImGui::SameLine(150);
        UIColor *c = [s colorForSlot:r.slot];
        if (MFUIColorEdit(r.label, &c, r.slot)) [s save];
    }
}

#pragma mark - 其他页

- (void)pageOther:(MFSettings *)s {
    ImGui::Spacing();
    ImGui::TextDisabled("穿透与窗口");
    ImGui::Separator();
    {
        bool v = gFullPassthrough;
        if (ImGui::Checkbox("整面板穿透", &v)) {
            gFullPassthrough = v;
            MFHUDLogLine(@"整面板穿透 = %d（菜单仍可用 BKS 输入操作）", (int)v);
        }
        MFTrackLastItem();
        ImGui::TextDisabled("菜单空白处本来就不吃触摸；");
        ImGui::TextDisabled("打开这个连按钮也一起穿透给下层。");
        ImGui::TextDisabled("点「收起」可以缩成小圆球。");
    }

    ImGui::Spacing();
    ImGui::TextDisabled("物资统计");
    ImGui::Separator();
    MF_CHECK("物资统计窗口", showLootStats);
    ImGui::TextDisabled("等级/价值阈值在主功能页");

    ImGui::Spacing();
    ImGui::TextDisabled("渲染");
    ImGui::Separator();
    {
        const char *rates[] = {"30", "45", "60", "90", "120"};
        const int rateValues[] = {30, 45, 60, 90, 120};
        int ri = 2;
        for (int i = 0; i < 5; i++) if (s.refreshRate >= rateValues[i]) ri = i;
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("刷新率", &ri, rates, 5)) {
            s.refreshRate = rateValues[ri];
            // ★ 同时应用到菜单层与绘制层：之前只改了菜单层，
            //   真正吃性能的全屏绘制层一直是固定 60。
            if (gFrameRateApplier) gFrameRateApplier(s.refreshRate);
            else self.overlay.preferredFPS = s.refreshRate;
        }
        MFTrackLastItem();
        ImGui::TextDisabled("菜单空闲时会自动降到 12 帧");
    }
    {
        const char *bars[] = {"细线", "圆头", "分段"};
        int hb = (int)s.healthBarStyle;
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("血条样式", &hb, bars, 3)) s.healthBarStyle = hb;
        MFTrackLastItem();
    }
    MF_CHECK("平滑绘制", smoothAim);

    ImGui::Spacing();
    ImGui::TextDisabled("自检");
    ImGui::Separator();
    MF_CHECK("渲染自检", renderSelfTest);
    ImGui::TextDisabled("打开后会画 4 个合成框 + 4 个物资标签");
    ImGui::TextDisabled("用于在偏移校准之前验证渲染链");

    ImGui::Spacing();
    ImGui::TextDisabled("模式");
    ImGui::Separator();
    MF_CHECK_SAME("观战模式", spectatorMode);
    MF_CHECK("直播模式", liveMode);
    ImGui::TextDisabled("直播模式对应原版 DrawingView._isLiveModeEnabled");

    ImGui::Spacing();
    ImGui::TextDisabled("目标");
    ImGui::Separator();
    ImGui::TextWrapped("当前目标：三角洲行动 com.tencent.tmgp.dfm");
    ImGui::TextDisabled("偏移表见 Game/Offsets.h（M4 真机校准）");
}

@end
