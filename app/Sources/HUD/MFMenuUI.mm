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
#include "imgui_internal.h"

//
// ★ ObjC++ 硬约束：不能对 property 表达式取地址（&s.someProp 是编译错误）。
//   所以所有 ImGui 控件都走下面这组宏：
//     读进局部变量 → 传局部变量地址 → 有变更再写回属性。
//
static __weak MFOverlayView *sRectTarget = nil;

// Clip against the current ImGui window, including its scrolling viewport.
// Offscreen items must never become invisible touch targets.
static void MFTrackRect(CGRect rect) {
    MFOverlayView *overlay = sRectTarget;
    if (!overlay || rect.size.width <= 0 || rect.size.height <= 0) return;
    ImGuiWindow *window = ImGui::GetCurrentWindowRead();
    const ImRect &clip = window->ClipRect;
    CGRect clipped = CGRectIntersection(rect, CGRectMake(clip.Min.x, clip.Min.y,
                                      clip.GetWidth(), clip.GetHeight()));
    if (!CGRectIsNull(clipped) && !CGRectIsEmpty(clipped)) [overlay addInteractiveRect:clipped];
}
static void MFTrackLastItem(void) {
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    MFTrackRect(CGRectMake(a.x, a.y, b.x - a.x, b.y - a.y));
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
        ImGui::TextUnformatted(label);                               \
        ImGui::SetNextItemWidth(-1);                                  \
        if (ImGui::SliderFloat("##" label, &_v, lo, hi, fmt)) s.prop = _v; \
        MFTrackLastItem();                                            \
    } while (0)

#define MF_SLIDE_I(label, prop, lo, hi, fmt)                          \
    do {                                                              \
        int _v = (int)(s.prop);                                       \
        ImGui::TextUnformatted(label);                               \
        ImGui::SetNextItemWidth(-1);                                  \
        if (ImGui::SliderInt("##" label, &_v, lo, hi, fmt)) s.prop = _v;   \
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
static void (^gCollapseChangeHandler)(BOOL) = nil;
static void (^gFrameRateApplier)(NSInteger fps) = nil;

/// 收起态的圆球直径（点）
static const float kMFMenuBallSize = 56.0f;

+ (void)setGlobalVisible:(BOOL)visible { gVisible = visible; }
+ (BOOL)globalVisible { return gVisible; }

+ (BOOL)collapsed { return gCollapsed; }
+ (void)setCollapsed:(BOOL)collapsed {
    if (gCollapsed == collapsed) return;
    gCollapsed = collapsed;
    if (gCollapseChangeHandler) gCollapseChangeHandler(collapsed);
}
+ (void)setCollapseChangeHandler:(void (^)(BOOL))handler { gCollapseChangeHandler = [handler copy]; }

// Legacy callers requesting full passthrough now collapse the real window.
+ (BOOL)fullPassthrough { return gCollapsed; }
+ (void)setFullPassthrough:(BOOL)passthrough { [self setCollapsed:passthrough]; }

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

    overlay.passthroughAll = NO;

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

    // Popups own their visible surface, including color pickers and combo
    // lists whose children do not pass through the menu's tracking helpers.
    ImGuiContext *current = ImGui::GetCurrentContext();
    for (ImGuiWindow *window : current->Windows) {
        if (!window->Active || !(window->Flags & ImGuiWindowFlags_Popup)) continue;
        const ImRect &r = window->OuterRectClipped;
        [overlay addInteractiveRect:CGRectMake(r.Min.x, r.Min.y, r.GetWidth(), r.GetHeight())];
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
    bool expand = ImGui::InvisibleButton("##mfexpand", ImVec2(ball, ball));
    MFTrackLastItem();
    if (expand) {
        [MFMenuUI setCollapsed:NO];
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
        ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar |
        ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse;
    if (!ImGui::Begin("##mfmenu", nullptr, flags)) {
        ImGui::End(); overlay.captureRect = CGRectNull; overlay.headerDragRect = CGRectNull; return;
    }
    overlay.captureRect = CGRectMake(0, 0, screen.x, screen.y);
    const float left = ImGui::GetCursorPosX();
    const float headerY = ImGui::GetCursorPosY();
    const float right = screen.x - ImGui::GetStyle().WindowPadding.x;
    ImGui::TextColored(ImVec4(0.19f, 0.82f, 0.35f, 1), "白米饭 · 悬浮窗");
    ImGui::SetCursorPos(ImVec2(right - 136, headerY));
    bool collapse = ImGui::Button("收起", ImVec2(64, 32)); MFTrackLastItem();
    ImGui::SameLine(0, 8);
    if (ImGui::Button("退出", ImVec2(64, 32))) [MFHUDControl requestExit];
    MFTrackLastItem();
    overlay.headerDragRect = CGRectMake(left, headerY, MAX(0.0f, right - 144 - left), 32);
    ImGui::SetCursorPosY(headerY + 40);
    ImGui::Separator();

    // Fixed tabs; only the page below scrolls. Header and exit stay reachable.
    const char *tabs[] = {"主功能", "外观", "其他"};
    float tabWidth = (ImGui::GetContentRegionAvail().x - 16) / 3;
    for (int i = 0; i < 3; i++) {
        if (i) ImGui::SameLine(0, 8);
        bool selected = _tab == i;
        if (selected) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.04f, 0.52f, 1, 1));
        if (ImGui::Button(tabs[i], ImVec2(tabWidth, 34))) _tab = i;
        MFTrackLastItem();
        if (selected) ImGui::PopStyleColor();
    }
    float footerHeight = ImGui::GetFrameHeight() + ImGui::GetStyle().ItemSpacing.y + 8;
    float pageHeight = MAX(64.0f, ImGui::GetContentRegionAvail().y - footerHeight);
    char pageID[32]; snprintf(pageID, sizeof(pageID), "##settings-%d", _tab);
    if (ImGui::BeginChild(pageID, ImVec2(0, pageHeight), ImGuiChildFlags_None,
                          ImGuiWindowFlags_NoSavedSettings)) {
        if (_tab == 0) [self pageMain:s];
        else if (_tab == 1) [self pageAppearance:s];
        else [self pageOther:s];
        ImGuiWindow *child = ImGui::GetCurrentWindowRead();
        if (child->ScrollbarY) {
            ImRect r = ImGui::GetWindowScrollbarRect(child, ImGuiAxis_Y);
            // Scrollbars lie outside the content ClipRect; clip to their child.
            CGRect scroll = CGRectMake(r.Min.x, r.Min.y, r.GetWidth(), r.GetHeight());
            CGRect outer = CGRectMake(child->Pos.x, child->Pos.y, child->Size.x, child->Size.y);
            [overlay addInteractiveRect:CGRectIntersection(scroll, outer)];
        }
    }
    ImGui::EndChild();
    ImGui::Separator();
    ImGui::SetNextItemWidth(MAX(60.0f, ImGui::GetContentRegionAvail().x - 104));
    ImGui::SliderFloat("##alpha", &_alpha, 0.4f, 1.0f, "透明度 %.2f"); MFTrackLastItem();
    ImGui::SameLine();
    if (ImGui::Button("保存配置")) [s save]; MFTrackLastItem();
    ImGui::End();
    if (collapse) {
        [MFMenuUI setCollapsed:YES];
        MFHUDLogLine(@"菜单收起：下一帧将原生窗口缩至 56×56");
        [overlay requestRedraw];
    }
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
        ImGui::TextUnformatted("背敌样式");
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("##背敌样式", &st, styles, 3)) s.backEnemyStyle = (MFBackEnemyStyle)st;
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
        MFUIColorEdit(r.label, &c, r.slot);
    }
}

#pragma mark - 其他页

- (void)pageOther:(MFSettings *)s {
    ImGui::Spacing();
    ImGui::TextDisabled("穿透与窗口");
    ImGui::Separator();
    ImGui::TextWrapped("拖动标题移动窗口；收起后仅保留小圆球，点球展开。");
    ImGui::TextWrapped("点击菜单和悬浮球时，下层 App 也会同时响应。");
    ImGui::TextDisabled("滑条和拖动也会传给下层");
    ImGui::TextDisabled("拖动右侧滚动条浏览设置");

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
        ImGui::TextUnformatted("刷新率请求");
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("##刷新率", &ri, rates, 5)) {
            s.refreshRate = rateValues[ri];
            // ★ 同时应用到菜单层与绘制层：之前只改了菜单层，
            //   真正吃性能的全屏绘制层一直是固定 60。
            if (gFrameRateApplier) gFrameRateApplier(s.refreshRate);
            else self.overlay.preferredFPS = s.refreshRate;
        }
        MFTrackLastItem();
        ImGui::TextDisabled("屏幕上限 %ld Hz / 当前请求 %ld fps",
            (long)self.overlay.maximumFPS, (long)self.overlay.effectiveFPS);
        ImGui::TextDisabled("实测绘制：菜单 %.0f / 绘制层 %.0f fps",
            self.overlay.renderedFPS, self.drawingOverlay.renderedFPS);
        ImGui::TextDisabled("菜单空闲时会自动降到 12 帧");
        ImGui::TextWrapped("高刷受系统电量、温度和负载影响，实测值为本工具的绘制帧率。");
    }
    {
        const char *bars[] = {"细线", "圆头", "分段"};
        int hb = (int)s.healthBarStyle;
        ImGui::TextUnformatted("血条样式");
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("##血条样式", &hb, bars, 3)) s.healthBarStyle = hb;
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
    ImGui::TextWrapped("截图与录屏隐藏：菜单、悬浮球、绘制内容全部开启。");
    ImGui::TextDisabled("观战 / 直播模式：功能尚未接入");

    ImGui::Spacing();
    ImGui::TextDisabled("目标");
    ImGui::Separator();
    ImGui::TextWrapped("当前目标：三角洲行动 com.tencent.tmgp.dfm");
    ImGui::TextDisabled("游戏数据和偏移仍需单独验证");
}

@end
