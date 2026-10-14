//
//  MFMenuUI.mm — 悬浮菜单（实现）
//
#import "MFMenuUI.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFSettings.h"

#include "imgui.h"

/// ImGui 不认 UIColor，转 ImVec4
static ImVec4 MFV4(UIColor *c, float alphaScale = 1.0f) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { r = g = b = 1; a = 1; }
    return ImVec4((float)r, (float)g, (float)b, (float)a * alphaScale);
}
static bool MFUIColorEdit(const char *label, UIColor **io, MFColorSlot slot) {
    UIColor *c = *io;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [c getRed:&r green:&g blue:&b alpha:&a];
    float col[4] = {(float)r, (float)g, (float)b, (float)a};
    if (ImGui::ColorEdit4(label, col,
                          ImGuiColorEditFlags_NoInputs | ImGuiColorEditFlags_NoLabel |
                          ImGuiColorEditFlags_AlphaBar)) {
        UIColor *nc = [UIColor colorWithRed:col[0] green:col[1] blue:col[2] alpha:col[3]];
        [[MFSettings shared] setColor:nc forSlot:slot];
        *io = nc;
        return true;
    }
    return false;
}

@implementation MFMenuUI {
    int _tab;
    ImVec2 _pos;
    BOOL _posInit;
    float _alpha;
}

static BOOL gVisible = YES;

+ (void)setGlobalVisible:(BOOL)visible { gVisible = visible; }
+ (BOOL)globalVisible { return gVisible; }

- (instancetype)init {
    if ((self = [super init])) {
        _tab = 0;
        _posInit = NO;
        _alpha = 0.96f;
        _pos = ImVec2(24, 90);
    }
    return self;
}

#pragma mark - MFOverlayViewDelegate

- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay {
    MFSettings *s = [MFSettings shared];

    // 未开启总开关 → 什么都不画，捕获区清空（全屏穿透）
    if (!gVisible || !s.masterEnabled) {
        overlay.captureRect = CGRectNull;
        return;
    }

    ImGuiIO &io = ImGui::GetIO();
    const ImVec2 screen = io.DisplaySize;
    const float W = 348.0f;
    const float H = MIN(520.0f, screen.y - 120.0f);

    ImGui::SetNextWindowSize(ImVec2(W, H), ImGuiCond_Always);
    if (!_posInit) {
        _pos = ImVec2(24, 90);
        _posInit = YES;
    }
    ImGui::SetNextWindowPos(_pos, ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(_alpha);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoScrollbar;
    if (!ImGui::Begin("##mfmenu", nullptr, flags)) {
        ImGui::End();
        overlay.captureRect = CGRectNull;
        return;
    }

    // 拖动后同步位置（ImGui 内部会改窗口位置）
    _pos = ImGui::GetWindowPos();

    // 主面板矩形 → 交给 overlay 做命中判定
    ImVec2 wp = ImGui::GetWindowPos();
    ImVec2 ws = ImGui::GetWindowSize();
    overlay.captureRect = CGRectMake(wp.x, wp.y, ws.x, ws.y);

    // ── 标题行 ──
    ImGui::TextColored(ImVec4(0.19f, 0.82f, 0.35f, 1.0f), "复刻版");
    ImGui::SameLine();
    ImGui::TextDisabled("| 悬浮菜单");
    ImGui::SameLine(ImGui::GetContentRegionAvail().x - 60);
    if (ImGui::SmallButton("隐藏")) gVisible = NO;
    ImGui::Separator();

    // ── 页签 ──
    if (ImGui::BeginTabBar("##tabs", ImGuiTabBarFlags_NoTooltip)) {
        if (ImGui::BeginTabItem("主功能")) { _tab = 0; [self pageMain:s]; ImGui::EndTabItem(); }
        if (ImGui::BeginTabItem("外观"))   { _tab = 1; [self pageAppearance:s]; ImGui::EndTabItem(); }
        if (ImGui::BeginTabItem("其他"))   { _tab = 2; [self pageOther:s]; ImGui::EndTabItem(); }
        ImGui::EndTabBar();
    }

    // ── 底部：透明度 + 保存 ──
    ImGui::Separator();
    ImGui::SetNextItemWidth(-90);
    ImGui::SliderFloat("##alpha", &_alpha, 0.4f, 1.0f, "透明度 %.2f");
    ImGui::SameLine();
    if (ImGui::Button("保存配置")) [[MFSettings shared] save];

    ImGui::End();
}

#pragma mark - 主功能页

- (void)pageMain:(MFSettings *)s {
    ImGui::Spacing();
    ImGui::Checkbox("总开关", &s.masterEnabled);
    ImGui::SameLine();
    ImGui::Checkbox("启用绘制", &s.drawEnabled);

    ImGui::Spacing();
    ImGui::TextDisabled("绘制开关");
    ImGui::Separator();
    ImGui::Checkbox("人机显示", &s.showBot);
    ImGui::Checkbox("名字", &s.showName);
    ImGui::Checkbox("头甲", &s.showArmor);
    ImGui::Checkbox("血量", &s.showHealth);
    ImGui::Checkbox("距离", &s.showDistance);
    ImGui::SameLine();
    ImGui::Checkbox("队伍", &s.showTeam);
    ImGui::Checkbox("射线", &s.showTracer);
    ImGui::SameLine();
    ImGui::Checkbox("手持", &s.showHeld);
    ImGui::Checkbox("骨骼", &s.showSkeleton);

    ImGui::Spacing();
    ImGui::TextDisabled("物资与盒子");
    ImGui::Separator();
    ImGui::Checkbox("物资", &s.showLoot);
    ImGui::SameLine();
    ImGui::Checkbox("盒子", &s.showBox);
    ImGui::Checkbox("物资名字", &s.showLootName);
    ImGui::SameLine();
    ImGui::Checkbox("统计窗口", &s.showLootStats);

    int lvl = (int)s.minLootLevel;
    int val = (int)s.minLootValue;
    ImGui::SetNextItemWidth(-1);
    if (ImGui::SliderInt("物资等级阈值", &lvl, 0, 6, lvl == 0 ? "不限制" : "等级 >= %d")) s.minLootLevel = lvl;
    ImGui::SetNextItemWidth(-1);
    if (ImGui::SliderInt("物资价值阈值", &val, 0, 50000, val == 0 ? "不限制" : "价值 >= %d")) s.minLootValue = val;

    ImGui::Spacing();
    ImGui::TextDisabled("绘制范围");
    ImGui::Separator();
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("盒子距离", &s.boxDrawDistance, 10.0f, 500.0f, "%.0f 米");
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("物资距离", &s.lootDrawDistance, 10.0f, 500.0f, "%.0f 米");
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("骨骼距离", &s.skeletonDistance, 10.0f, 300.0f, "%.0f 米");
    ImGui::TextDisabled("骨骼距离越低越流畅");

    ImGui::Spacing();
    ImGui::TextDisabled("背敌提示");
    ImGui::Separator();
    ImGui::Checkbox("背敌", &s.backEnemyEnabled);
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("背敌半径", &s.backEnemyRadius, 10.0f, 300.0f, "%.0f px");
    const char *styles[] = {"圆形", "箭头", "圆环"};
    int st = (int)s.backEnemyStyle;
    ImGui::SetNextItemWidth(-1);
    if (ImGui::Combo("背敌样式", &st, styles, 3)) s.backEnemyStyle = (MFBackEnemyStyle)st;
}

#pragma mark - 外观页

- (void)pageAppearance:(MFSettings *)s {
    ImGui::Spacing();
    ImGui::TextDisabled("字号");
    ImGui::Separator();
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("人物字号", &s.fontPerson, 8.0f, 28.0f, "%.0f");
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("盒子字号", &s.fontBox, 8.0f, 28.0f, "%.0f");
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("信息字号", &s.fontInfo, 8.0f, 28.0f, "%.0f");
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("头甲字号", &s.fontArmor, 8.0f, 28.0f, "%.0f");
    ImGui::SetNextItemWidth(-1);
    ImGui::SliderFloat("骨骼粗细", &s.skeletonThickness, 0.5f, 6.0f, "%.1f");

    ImGui::Spacing();
    ImGui::TextDisabled("颜色");
    ImGui::Separator();

    struct { const char *label; MFColorSlot slot; UIColor *c; } rows[] = {
        { "人物信息",   MFColorSlotPersonInfo, nil },
        { "0-2级物资",  MFColorSlotLootLow,    nil },
        { "3级物资",    MFColorSlotLoot3,      nil },
        { "4级物资",    MFColorSlotLoot4,      nil },
        { "5级物资",    MFColorSlotLoot5,      nil },
        { "6级物资",    MFColorSlotLoot6,      nil },
        { "队伍",       MFColorSlotTeam,       nil },
        { "头甲",       MFColorSlotArmor,      nil },
        { "真人骨骼",   MFColorSlotSkeleton,   nil },
        { "背敌",       MFColorSlotBackEnemy,  nil },
    };
    for (auto &r : rows) {
        r.c = [s colorForSlot:r.slot];
        ImGui::Text("%s", r.label);
        ImGui::SameLine(150);
        if (MFUIColorEdit(r.label, &r.c, r.slot)) [s save];
    }
}

#pragma mark - 其他页

- (void)pageOther:(MFSettings *)s {
    ImGui::Spacing();
    ImGui::TextDisabled("物资统计");
    ImGui::Separator();
    ImGui::Checkbox("物资统计窗口", &s.showLootStats);
    ImGui::TextDisabled("等级/价值阈值在主功能页");

    ImGui::Spacing();
    ImGui::TextDisabled("渲染");
    ImGui::Separator();
    const char *rates[] = {"60", "90", "120"};
    int ri = s.refreshRate == 120 ? 2 : (s.refreshRate == 90 ? 1 : 0);
    ImGui::SetNextItemWidth(-1);
    if (ImGui::Combo("刷新率", &ri, rates, 3)) {
        s.refreshRate = (ri == 2) ? 120 : (ri == 1 ? 90 : 60);
        self.overlay.preferredFPS = s.refreshRate;
    }
    const char *bars[] = {"细线", "圆头", "分段"};
    int hb = (int)s.healthBarStyle;
    ImGui::SetNextItemWidth(-1);
    if (ImGui::Combo("血条样式", &hb, bars, 3)) s.healthBarStyle = hb;
    ImGui::Checkbox("平滑绘制", &s.smoothAim);

    ImGui::Spacing();
    ImGui::TextDisabled("模式");
    ImGui::Separator();
    ImGui::Checkbox("观战模式", &s.spectatorMode);
    ImGui::SameLine();
    ImGui::Checkbox("直播模式", &s.liveMode);
    ImGui::TextDisabled("直播模式对应原版 DrawingView._isLiveModeEnabled");

    ImGui::Spacing();
    ImGui::TextDisabled("目标");
    ImGui::Separator();
    ImGui::TextWrapped("当前目标：三角洲行动 com.tencent.tmgp.dfm");
    ImGui::TextDisabled("偏移表见 Game/Offsets.h（M4 真机校准）");
}

@end
