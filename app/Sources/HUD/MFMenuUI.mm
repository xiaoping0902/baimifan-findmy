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
#import "MFMenuPanel.h"
#import "MFHUDControl.h"
#import "MFHUDLog.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFSettings.h"
#import <QuartzCore/QuartzCore.h>

#include "imgui.h"
#include "imgui_internal.h"
#include <atomic>

//
// ★ ObjC++ 硬约束：不能对 property 表达式取地址（&s.someProp 是编译错误）。
//   所以所有 ImGui 控件都走下面这组宏：
//     读进局部变量 → 传局部变量地址 → 有变更再写回属性。
//
static __weak MFOverlayView *sRectTarget = nil;
static std::atomic<uint64_t> gSettingsRevision{0};
static std::atomic<bool> gSettingsDirty{false};

// Persist menu edits after a short idle period so a quick run of slider or
// switch changes results in one plist write rather than one write per frame.
static void MFMarkSettingsDirty(MFSettings *settings) {
    gSettingsDirty.store(true, std::memory_order_release);
    const uint64_t revision = gSettingsRevision.fetch_add(1, std::memory_order_acq_rel) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gSettingsRevision.load(std::memory_order_acquire) != revision) return;
        const BOOL saved = [settings save];
        if (gSettingsRevision.load(std::memory_order_acquire) == revision)
            gSettingsDirty.store(!saved, std::memory_order_release);
    });
}

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

static bool MFSettingSwitch(const char *label, bool enabled, const char *detail = nullptr) {
    ImGui::PushID(label);
    const float width = ImGui::GetContentRegionAvail().x;
    const float height = detail ? 62.0f : 52.0f;
    const ImVec2 origin = ImGui::GetCursorScreenPos();
    const bool pressed = ImGui::InvisibleButton("##row", ImVec2(width, height));
    const bool hovered = ImGui::IsItemHovered();
    MFTrackLastItem();

    ImDrawList *draw = ImGui::GetWindowDrawList();
    if (hovered) {
        draw->AddRectFilled(origin, ImVec2(origin.x + width, origin.y + height),
                            ImGui::GetColorU32(ImGuiCol_FrameBgHovered), 8.0f);
    }

    const float labelY = detail ? origin.y + 8.0f : origin.y + (height - ImGui::GetTextLineHeight()) * 0.5f;
    draw->AddText(ImVec2(origin.x + 3.0f, labelY), ImGui::GetColorU32(ImGuiCol_Text), label);
    if (detail) {
        draw->AddText(ImVec2(origin.x + 3.0f, origin.y + 32.0f),
                      ImGui::GetColorU32(ImGuiCol_TextDisabled), detail);
    }

    const float trackW = 44.0f;
    const float trackH = 26.0f;
    const ImVec2 trackMin(origin.x + width - trackW - 4.0f,
                          origin.y + (height - trackH) * 0.5f);
    const ImVec2 trackMax(trackMin.x + trackW, trackMin.y + trackH);
    const ImU32 trackColor = enabled ? IM_COL32(10, 132, 255, 255)
                                     : IM_COL32(211, 211, 216, 255);
    draw->AddRectFilled(trackMin, trackMax, trackColor, trackH * 0.5f);
    const float knobRadius = 10.0f;
    const float knobX = enabled ? trackMax.x - trackH * 0.5f : trackMin.x + trackH * 0.5f;
    const ImVec2 knob(knobX, trackMin.y + trackH * 0.5f);
    draw->AddCircleFilled(knob, knobRadius, IM_COL32(255, 255, 255, 255), 20);
    draw->AddLine(ImVec2(origin.x + 3.0f, origin.y + height),
                  ImVec2(origin.x + width - 3.0f, origin.y + height),
                  ImGui::GetColorU32(ImGuiCol_Separator), 1.0f);
    ImGui::PopID();
    return pressed;
}

static void MFBeginCard(const char *id, const char *title, const char *detail = nullptr) {
    ImGui::Spacing();
    ImGui::PushID(id);
    ImGui::BeginChild("##card", ImVec2(0, 0),
                      ImGuiChildFlags_AutoResizeY | ImGuiChildFlags_Borders,
                      ImGuiWindowFlags_NoSavedSettings);
    ImGui::Text("%s", title);
    if (detail) ImGui::TextDisabled("%s", detail);
    ImGui::Spacing();
}

static void MFEndCard(void) {
    ImGui::EndChild();
    ImGui::PopID();
}

#define MF_SWITCH(label, prop)                                     \
    do {                                                            \
        if (MFSettingSwitch(label, s.prop)) {                       \
            s.prop = !s.prop;                                       \
            MFMarkSettingsDirty(s);                                 \
        }                                                           \
    } while (0)

#define MF_SLIDE_F(label, prop, lo, hi, fmt)                          \
    do {                                                              \
        float _v = (float)(s.prop);                                   \
        ImGui::TextUnformatted(label);                               \
        ImGui::SetNextItemWidth(-1);                                  \
        if (ImGui::SliderFloat("##" label, &_v, lo, hi, fmt)) { s.prop = _v; MFMarkSettingsDirty(s); } \
        MFTrackLastItem();                                            \
    } while (0)

#define MF_SLIDE_I(label, prop, lo, hi, fmt)                          \
    do {                                                              \
        int _v = (int)(s.prop);                                       \
        ImGui::TextUnformatted(label);                               \
        ImGui::SetNextItemWidth(-1);                                  \
        if (ImGui::SliderInt("##" label, &_v, lo, hi, fmt)) { s.prop = _v; MFMarkSettingsDirty(s); } \
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
        MFMarkSettingsDirty([MFSettings shared]);
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
static void (^gCaptureProtectionApplier)(BOOL enabled) = nil;

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
+ (void)setCaptureProtectionApplier:(void (^_Nullable)(BOOL))applier {
    gCaptureProtectionApplier = [applier copy];
}

- (instancetype)init {
    if ((self = [super init])) {
        _tab = 0;
        _alpha = 0.96f;
    }
    return self;
}

#pragma mark - MFOverlayViewDelegate

- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay {
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

    /*
     * ★ [M5.183] 换成小玉原版面板 ★
     * 布局、分页、开关、滑块、颜色、缩放、灵动岛全部来自 UIPort/（原样搬运），
     * 不再用这个文件里那套简化菜单。
     */
    MFMenuPanelSetExpanded(!gCollapsed);
    MFMenuPanelRender(overlay, screen);
    /* 点灵动岛会自己展开/收起 —— 把状态同步回来，下一帧才不会被覆盖 */
    {
        const BOOL want = MFMenuPanelExpanded();
        if (gCollapsed == want) gCollapsed = !want;
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
    ImGui::SetCursorPos(ImVec2(left, headerY + 2.0f));
    ImGui::TextColored(ImVec4(0.04f, 0.43f, 0.88f, 1), "小玉");
    ImGui::SameLine(0, 7);
    ImGui::TextDisabled("HUD 设置");
    ImGui::SetCursorPos(ImVec2(right - 126, headerY));
    bool collapse = ImGui::Button("收起", ImVec2(58, 32)); MFTrackLastItem();
    ImGui::SameLine(0, 6);
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(1.0f, 0.92f, 0.92f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 0.84f, 0.84f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.75f, 0.13f, 0.13f, 1.0f));
    if (ImGui::Button("退出", ImVec2(56, 32))) [MFHUDControl requestExit];
    ImGui::PopStyleColor(3);
    MFTrackLastItem();
    overlay.headerDragRect = CGRectMake(left, headerY, MAX(0.0f, right - 132 - left), 36);
    ImGui::SetCursorPosY(headerY + 40);
    ImGui::Separator();

    // Fixed tabs; only the page below scrolls. Header and exit stay reachable.
    const char *tabs[] = {"主功能", "外观", "其他"};
    const float tabWidth = (ImGui::GetContentRegionAvail().x - 12.0f) / 3.0f;
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 10.0f);
    for (int i = 0; i < 3; i++) {
        if (i) ImGui::SameLine(0, 6);
        bool selected = _tab == i;
        if (selected) {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.04f, 0.43f, 0.88f, 1));
            ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.08f, 0.50f, 0.96f, 1));
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1, 1, 1, 1));
        } else {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.91f, 0.93f, 0.96f, 1));
            ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.85f, 0.89f, 0.94f, 1));
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.31f, 0.34f, 0.39f, 1));
        }
        if (ImGui::Button(tabs[i], ImVec2(tabWidth, 38))) _tab = i;
        MFTrackLastItem();
        ImGui::PopStyleColor(3);
    }
    ImGui::PopStyleVar();
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
    ImGui::TextDisabled("面板透明度");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(MAX(64.0f, ImGui::GetContentRegionAvail().x - 112.0f));
    ImGui::SliderFloat("##alpha", &_alpha, 0.4f, 1.0f, "%.0f%%");
    MFTrackLastItem();
    ImGui::SameLine();
    if (gSettingsDirty.load(std::memory_order_acquire))
        ImGui::TextDisabled("保存中");
    else
        ImGui::TextColored(ImVec4(0.16f, 0.55f, 0.25f, 1.0f), "已保存");
    ImGui::End();
    if (collapse) {
        [MFMenuUI setCollapsed:YES];
        MFHUDLogLine(@"菜单收起：下一帧将原生窗口缩至 56×56");
        [overlay requestRedraw];
    }
}

#pragma mark - 主功能页

- (void)pageMain:(MFSettings *)s {
    MFBeginCard("overview", "悬浮绘制", "关闭任一总开关都会暂停整层 HUD");
    MF_SWITCH("总开关", masterEnabled);
    MF_SWITCH("启用绘制", drawEnabled);
    MFEndCard();

    MFBeginCard("players", "对局信息", "每项开关都会即时作用于人物标记");
    MF_SWITCH("人机显示", showBot);
    MF_SWITCH("队友", showTeammates);
    MF_SWITCH("名字", showName);
    MF_SWITCH("头甲", showArmor);
    MF_SWITCH("血量", showHealth);
    MF_SWITCH("距离", showDistance);
    MF_SWITCH("队伍", showTeam);
    MF_SWITCH("射线", showTracer);
    MF_SWITCH("手持", showHeld);
    MF_SWITCH("骨骼", showSkeleton);
    MFEndCard();

    MFBeginCard("loot", "物资与盒子", "关闭物资后隐藏物资；盒子可单独控制");
    MF_SWITCH("物资", showLoot);
    MF_SWITCH("物资详情", showLootName);
    MF_SWITCH("盒子", showBox);
    MF_SWITCH("物资统计", showLootStats);

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
    MFEndCard();

    MFBeginCard("range", "绘制距离", "范围越大，读取和渲染的实体越多");
    MF_SLIDE_F("盒子距离", boxDrawDistance, 10.0f, 500.0f, "%.0f 米");
    MF_SLIDE_F("物资距离", lootDrawDistance, 10.0f, 500.0f, "%.0f 米");
    MF_SLIDE_F("骨骼距离", skeletonDistance, 10.0f, 300.0f, "%.0f 米");
    MFEndCard();

    MFBeginCard("back-enemy", "背敌提示", "标记处于屏幕后方的目标方向");
    MF_SWITCH("背敌", backEnemyEnabled);
    MF_SLIDE_F("背敌半径", backEnemyRadius, 10.0f, 300.0f, "%.0f px");
    MF_SLIDE_F("背敌距离", backEnemyDistance, 10.0f, 300.0f, "%.0f 米");
    {
        const char *styles[] = {"圆形", "箭头", "圆环"};
        int st = (int)s.backEnemyStyle;
        ImGui::TextUnformatted("背敌样式");
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("##背敌样式", &st, styles, 3)) {
            s.backEnemyStyle = (MFBackEnemyStyle)st;
            MFMarkSettingsDirty(s);
        }
        MFTrackLastItem();
    }
    MFEndCard();
}

#pragma mark - 外观页

- (void)pageAppearance:(MFSettings *)s {
    MFBeginCard("type", "文字与线条", "调整屏幕标记的大小和清晰度");
    MF_SLIDE_F("人物字号", fontPerson, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("盒子字号", fontBox, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("信息字号", fontInfo, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("头甲字号", fontArmor, 8.0f, 28.0f, "%.0f");
    MF_SLIDE_F("骨骼粗细", skeletonThickness, 0.5f, 6.0f, "%.1f");
    MFEndCard();

    MFBeginCard("colors", "颜色", "点按色块可选择颜色和透明度");

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
    MFEndCard();
}

#pragma mark - 其他页

- (void)pageOther:(MFSettings *)s {
    MFBeginCard("window", "窗口与触控", "面板空白处会穿透到下层 App");
    ImGui::TextWrapped("拖动标题移动窗口；收起后仅保留小圆球，点球展开。");
    ImGui::TextWrapped("点右上角“收起”可操作下层 App。");
    MFEndCard();

    MFBeginCard("render", "渲染", "菜单和绘制层会同时应用刷新率");
    {
        const char *rates[] = {"30", "45", "60", "90", "120"};
        const int rateValues[] = {30, 45, 60, 90, 120};
        int ri = 2;
        for (int i = 0; i < 5; i++) if (s.refreshRate >= rateValues[i]) ri = i;
        ImGui::TextUnformatted("刷新率请求");
        ImGui::SetNextItemWidth(-1);
        if (ImGui::Combo("##刷新率", &ri, rates, 5)) {
            s.refreshRate = rateValues[ri];
            MFMarkSettingsDirty(s);
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
        if (ImGui::Combo("##血条样式", &hb, bars, 3)) {
            s.healthBarStyle = hb;
            MFMarkSettingsDirty(s);
        }
        MFTrackLastItem();
    }
    MF_SWITCH("平滑绘制", smoothAim);
    MFEndCard();

    MFBeginCard("diagnostics", "自检", "打开后用合成内容验证绘制链");
    MF_SWITCH("渲染自检", renderSelfTest);
    ImGui::TextDisabled("用于在偏移校准之前验证渲染链");
    MFEndCard();

    MFBeginCard("availability", "功能状态");
    /*
     * ★ [M5.134] 防录屏开关已停用。
     *
     * 真机后果：点一下就会让整个悬浮窗卡死（点不动、退不出），只能重启设备。
     * 原因在 MFHUDCaptureShieldView：切换时在主线程同步 layoutIfNeeded，并把
     * 内容视图重新挂到 secureTextEntry 的安全画布上 —— 我们的窗口是托管给
     * SpringBoard 的远程上下文，这一步会等渲染服务器，直接死锁。
     *
     * 修好之前先把它关掉：宁可少一个功能，也不能让用户每次都得重启。
     */
    bool captureProtection = s.captureProtectionEnabled;
    ImGui::BeginDisabled();
    ImGui::Checkbox("防录屏（已停用，会导致卡死）", &captureProtection);
    ImGui::EndDisabled();
    MFTrackLastItem();
    ImGui::TextWrapped("已停用：该开关在主线程重挂安全画布会死锁。等重写后再开放。");
    ImGui::TextDisabled("观战 / 直播模式：功能尚未接入");
    MFEndCard();

}

@end
