//
//  MFMenuUI.mm — 悬浮菜单（实现）
//
#import "MFMenuUI.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFSettings.h"

#include "imgui.h"

//
// ★ ObjC++ 硬约束：不能对 property 表达式取地址（&s.someProp 是编译错误）。
//   所以所有 ImGui 控件都走下面这组宏：
//     读进局部变量 → 传局部变量地址 → 有变更再写回属性。
//
#define MF_CHECK(label, prop)                           \
    do {                                                \
        bool _v = (s.prop);                             \
        if (ImGui::Checkbox(label, &_v)) s.prop = _v;   \
    } while (0)

#define MF_CHECK_SAME(label, prop)                      \
    do {                                                \
        bool _v = (s.prop);                             \
        if (ImGui::Checkbox(label, &_v)) s.prop = _v;   \
        ImGui::SameLine();                              \
    } while (0)

#define MF_SLIDE_F(label, prop, lo, hi, fmt)                          \
    do {                                                              \
        float _v = (float)(s.prop);                                   \
        ImGui::SetNextItemWidth(-1);                                  \
        if (ImGui::SliderFloat(label, &_v, lo, hi, fmt)) s.prop = _v; \
    } while (0)

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

    // 关掉总开关或手动隐藏 → 什么都不画，捕获区清空（全屏穿透）
    if (!gVisible || !s.masterEnabled) {
        overlay.captureRect = CGRectNull;
        return;
    }

    ImGuiIO &io = ImGui::GetIO();
    const ImVec2 screen = io.DisplaySize;
    const float W = 348.0f;
    const float H = MIN(520.0f, MAX(240.0f, screen.y - 120.0f));

    if (!_posInit) {
        _pos = ImVec2(24, 90);
        _posInit = YES;
    }
    ImGui::SetNextWindowSize(ImVec2(W, H), ImGuiCond_Always);
    ImGui::SetNextWindowPos(_pos, ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(_alpha);

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoScrollbar;
    if (!ImGui::Begin("##mfmenu", nullptr, flags)) {
        ImGui::End();
        overlay.captureRect = CGRectNull;
        return;
    }

    // 拖动后同步位置；主面板矩形交给 overlay 做命中判定
    _pos = ImGui::GetWindowPos();
    ImVec2 ws = ImGui::GetWindowSize();
    overlay.captureRect = CGRectMake(_pos.x, _pos.y, ws.x, ws.y);

    // ── 标题行 ──
    ImGui::TextColored(ImVec4(0.19f, 0.82f, 0.35f, 1.0f), "复刻版");
    ImGui::SameLine();
    ImGui::TextDisabled("| 悬浮菜单");
    ImGui::SameLine(ImGui::GetContentRegionAvail().x - 56);
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
    ImGui::SetNextItemWidth(-96);
    ImGui::SliderFloat("##alpha", &_alpha, 0.4f, 1.0f, "透明度 %.2f");
    ImGui::SameLine();
    if (ImGui::Button("保存配置")) [[MFSettings shared] save];

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
        int v = (int)s.minLootLevel;
        char fmt[32];
        if (v == 0) snprintf(fmt, sizeof(fmt), "不限制");
        else        snprintf(fmt, sizeof(fmt), "等级 >= %%d");
        ImGui::SetNextItemWidth(-1);
        if (ImGui::SliderInt("物资等级阈值", &v, 0, 6, fmt)) s.minLootLevel = v;
    }
    {   // 价值阈值
        int v = (int)s.minLootValue;
        char fmt[32];
        if (v == 0) snprintf(fmt, sizeof(fmt), "不限制");
        else        snprintf(fmt, sizeof(fmt), "价值 >= %%d");
        ImGui::SetNextItemWidth(-1);
        if (ImGui::SliderInt("物资价值阈值", &v, 0, 50000, fmt)) s.minLootValue = v;
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
    ImGui::TextDisabled("物资统计");
    ImGui::Separator();
    MF_CHECK("物资统计窗口", showLootStats);
    ImGui::TextDisabled("等级/价值阈值在主功能页");

    ImGui::Spacing();
    ImGui::TextDisabled("渲染");
    ImGui::Separator();
    {
        const char *rates[] = {"60", "90", "120"};
        int ri = s.refreshRate == 120 ? 2 : (s.refreshRate == 90 ? 1 : 0);
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("刷新率", &ri, rates, 3)) {
            s.refreshRate = (ri == 2) ? 120 : (ri == 1 ? 90 : 60);
            self.overlay.preferredFPS = s.refreshRate;
        }
    }
    {
        const char *bars[] = {"细线", "圆头", "分段"};
        int hb = (int)s.healthBarStyle;
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("血条样式", &hb, bars, 3)) s.healthBarStyle = hb;
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
