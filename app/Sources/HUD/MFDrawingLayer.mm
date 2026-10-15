//
//  MFDrawingLayer.mm — 透明绘制层（实现）
//
#import "MFDrawingLayer.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFGameReader.h"
#import "../Game/MFSettings.h"
#import "../Game/Offsets.h"

#import <QuartzCore/QuartzCore.h>      // CACurrentMediaTime（自检动画）

#include "imgui.h"

static BOOL gDrawEnabled = YES;

@interface MFDrawingLayer ()
@property (nonatomic, strong) MFGameReader *reader;
/// 这一帧有没有真正画出东西（决定绘制层是全速还是低频空转）
- (void)noteDrawingActivity:(BOOL)active;
- (void)drawBackEnemies:(NSArray<MFEntity *> *)ents
               drawList:(ImDrawList *)dl
               settings:(MFSettings *)st
                 screen:(ImVec2)screen;
- (void)drawSkeleton:(MFEntity *)e drawList:(ImDrawList *)dl
            settings:(MFSettings *)st camera:(MFCamera)cam at:(ImVec2)pt;
- (ImVec2)smoothPoint:(ImVec2)raw address:(uint64_t)addr settings:(MFSettings *)st;
@end

/// UIKit 颜色 → ImU32（ImGui 的 ABGR 打包格式）
static ImU32 MFU32(UIColor *c, float alphaScale = 1.0f) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { r = g = b = 1; a = 1; }
    a *= alphaScale;
    return IM_COL32((int)(r * 255), (int)(g * 255), (int)(b * 255), (int)(a * 255));
}

static ImU32 MFU32A(UIColor *c, int alpha) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { r = g = b = 1; }
    return IM_COL32((int)(r * 255), (int)(g * 255), (int)(b * 255), alpha);
}

/* ── 字号支持（[M5.2] 接线）─────────────────────────────────────
 * DrawList 的 AddText 有一个带 (font, size) 的重载 —— 用它就能逐条文本设字号，
 * 不用 PushFont/PopFont，也不会影响 ImGui 的窗口字体栈。
 * CalcTextSize 不接受字号，所以按 GetFontSize() 等比缩放算宽度。
 */
static float MFTextK(float size) {
    float base = ImGui::GetFontSize();
    return (base > 0.5f) ? (size / base) : 1.0f;
}
static ImVec2 MFTextSize(const char *s, float size) {
    ImVec2 t = ImGui::CalcTextSize(s);
    float k = MFTextK(size);
    return ImVec2(t.x * k, t.y * k);
}
static void MFText(ImDrawList *dl, float size, ImVec2 pos, ImU32 col, const char *s) {
    dl->AddText(ImGui::GetFont(), MAX(8.0f, size), pos, col, s);
}

@implementation MFDrawingLayer {
    MFGameReader *_reader;
    NSUInteger _entCount;
    NSUInteger _lootCount;
    BOOL _camOK;

    /* ── 平滑绘制缓存（[M5.2]）──
     * key = 实体地址，value = 上一帧的屏幕坐标（CGPoint —— NSValue 原生支持）。
     * 打开「平滑绘制」时，新坐标按 lerp 追上去，视觉上不会一格一格跳。
     * 只在 smoothAim 打开时使用；关掉时直接清空，避免残留旧位置。
     */
    NSMutableDictionary<NSNumber *, NSValue *> *_smoothCache;

    /* ── 背敌计数（[M5.2]）── 供底部状态条显示 */
    NSUInteger _backEnemyCount;
}

+ (void)setEnabled:(BOOL)enabled { gDrawEnabled = enabled; }
+ (BOOL)enabled { return gDrawEnabled; }

- (instancetype)init {
    if ((self = [super init])) {
        _reader = [MFGameReader shared];
        _smoothCache = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 平滑坐标（[M5.2]）

/// 打开时：新坐标向旧坐标插值追上去；关闭时：直接用新坐标并清缓存
- (ImVec2)smoothPoint:(ImVec2)raw address:(uint64_t)addr settings:(MFSettings *)st {
    if (!st.smoothAim) {
        if (_smoothCache.count) [_smoothCache removeAllObjects];
        return raw;
    }
    NSNumber *key = @(addr);
    NSValue *old = _smoothCache[key];
    ImVec2 out = raw;
    if (old) {
        CGPoint o = old.CGPointValue;
        const float k = 0.45f;              // 追赶系数：越大越跟手，越小越平滑
        out.x = (float)o.x + (raw.x - (float)o.x) * k;
        out.y = (float)o.y + (raw.y - (float)o.y) * k;
    }
    _smoothCache[key] = [NSValue valueWithCGPoint:CGPointMake(out.x, out.y)];
    return out;
}

- (NSUInteger)lastEntityCount { return _entCount; }
- (NSUInteger)lastLootCount { return _lootCount; }
- (BOOL)lastCameraOK { return _camOK; }

#pragma mark - 每帧

/*
 * [M5.66] 绘制层的「有没有内容」反馈。
 *
 * 绘制层是全屏 2048×2732 的 Metal surface —— 每帧 clear + present 都要
 * 真金白银的显存带宽。可它经常无事可做：总开关关着、还没绑定目标进程、
 * 相机读不到、屏幕上没有敌人也没有物资。
 *
 * 这种时候把 overlay 的空闲帧率压到 20，有内容时立刻恢复满帧。
 * 菜单层用的是同一套机制（交互满帧、空闲 12）。
 */
- (void)noteDrawingActivity:(BOOL)active {
    MFOverlayView *overlay = self.overlay;
    if (!overlay) return;
    NSInteger want = active ? 0 : 20;      // 0 = 不降频，直接用满帧率
    if (overlay.idleFPS != want) {
        overlay.idleFPS = want;
        NSLog(@"[MF][Draw] 绘制层空闲帧率 → %ld（%s）", (long)want, active ? "有内容" : "无内容");
    }
}

- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay {
    _entCount = 0;
    _lootCount = 0;
    _camOK = NO;

    MFSettings *st = [MFSettings shared];
    if (!gDrawEnabled || !st.masterEnabled || !st.drawEnabled) { [self noteDrawingActivity:NO]; return; }

    const CGSize size = overlay.bounds.size;
    if (size.width < 1 || size.height < 1) { [self noteDrawingActivity:NO]; return; }

    // ── 渲染自检：不碰游戏内存，纯合成数据 ──
    //   用途：在偏移校准之前，独立验证 ImGui → Metal → 透明层 → 投影 这条链。
    if (st.renderSelfTest) {
        [self runSelfTest:st overlay:overlay];
        [self noteDrawingActivity:YES];
        return;
    }

    if (!self.reader.ready) { [self noteDrawingActivity:NO]; return; }

    NSDictionary *frame = [self.reader readFrameWithSize:size];
    _camOK = [frame[@"cameraOK"] boolValue];
    if (!_camOK) { [self noteDrawingActivity:NO]; return; }

    MFCamera cam = {0};
    NSDictionary *cd = frame[@"camera"];
    cam.x     = [cd[@"x"] floatValue];
    cam.y     = [cd[@"y"] floatValue];
    cam.z     = [cd[@"z"] floatValue];
    cam.pitch = [cd[@"pitch"] floatValue];
    cam.yaw   = [cd[@"yaw"] floatValue];
    cam.roll  = [cd[@"roll"] floatValue];
    cam.fov   = [cd[@"fov"] floatValue];

    NSArray<MFEntity *> *ents = frame[@"entities"];
    NSArray<MFEntity *> *loot = frame[@"loot"];
    _entCount = ents.count;
    _lootCount = loot.count;

    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    if (!dl) return;

    const int initialVertices = dl->VtxBuffer.Size;
    const ImVec2 screen((float)size.width, (float)size.height);

    // ── 人/盒子 ──
    for (MFEntity *e in ents) {
        if (!e.isVisible) continue;
        [self drawEntity:e drawList:dl settings:st screen:screen camera:cam];
    }

    /* ── [M5.2] 背敌提示 ──
     * 放在实体循环【之后】画，确保它盖在框上面。
     * 它用 bearingDeg（只由坐标 + 相机 yaw 算得）判定，不依赖游戏字段，
     * 所以偏移未校准也能工作。
     */
    [self drawBackEnemies:ents drawList:dl settings:st screen:screen];

    // ── 物资 ──
    if (st.showLoot || st.showBox) {
        for (MFEntity *e in loot) {
            if (!e.isVisible) continue;
            [self drawLoot:e drawList:dl settings:st screen:screen];
        }
    }

    // ── 物资统计窗（可选）──
    if (st.showLootStats) [self drawStats:st loot:loot];

    // Base activity on generated content after visibility/settings filters.
    [self noteDrawingActivity:(dl->VtxBuffer.Size > initialVertices || st.showLootStats)];
}

#pragma mark - 人 / 盒子

- (void)drawEntity:(MFEntity *)e drawList:(ImDrawList *)dl
          settings:(MFSettings *)st screen:(ImVec2)screen camera:(MFCamera)cam {
    /* ── [M5.2] 人机过滤 ──
     * isBot 来自实体字段；未校准时恒 NO —— 所以「人机显示」关掉【不会】把所有人都隐藏，
     * 只会隐藏真的判定为人机的那些。这是「未校准不画错」的关键。
     */
    if (e.isBot && !st.showBot) return;

    /* ── [M5.2] 平滑坐标 ── */
    ImVec2 pt = [self smoothPoint:ImVec2(e.screen.x, e.screen.y)
                          address:e.address settings:st];

    // 盒子尺寸：按距离缩放
    float h = 2200.0f / MAX(e.distanceMeters, 1.0f);
    h = MIN(MAX(h, 8.0f), screen.y * 0.6f);
    float w = h * 0.45f;
    ImVec2 p1(pt.x - w * 0.5f, pt.y - h);
    ImVec2 p2(pt.x + w * 0.5f, pt.y);

    /* ── 主色：人机用「队伍色」提示、真人用「人物信息色」──
     * 队伍颜色槽 [M5.2] 接线：编队模式下用队员色，未校准时 teamId=0 → 走人物信息色。
     */
    BOOL useTeamColor = st.showTeam && e.teamId != 0;
    ImU32 boxCol = useTeamColor
        ? MFU32([st colorForSlot:MFColorSlotTeam], 0.9f)
        : MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.85f);

    // 框
    dl->AddRect(p1, p2, boxCol, 0.0f, 0, 1.5f);

    /* ── 血条（[M5.2] 接线：三种样式 + 真实血量）──
     * health < 0 = 未校准 → 按满格画（保持原占位行为，不显示假数据）
     */
    if (st.showHealth) {
        float ratio = (e.health >= kMFHealthMin && e.health <= kMFHealthMax)
                    ? (e.health / 100.0f) : 1.0f;
        ImU32 hpCol = MFU32(ratio > 0.5f ? [UIColor systemGreenColor]
                                         : [UIColor systemRedColor], 0.92f);

        switch (st.healthBarStyle) {
            case 0: {   /* 细线：贴在框底的一根 2px 线 */
                ImVec2 b1(p1.x, p2.y + 1.0f), b2(p2.x, p2.y + 3.0f);
                dl->AddRectFilled(b1, b2, IM_COL32(0, 0, 0, 150));
                dl->AddRectFilled(b1, ImVec2(b1.x + (b2.x - b1.x) * ratio, b2.y), hpCol);
                break;
            }
            case 1: {   /* 圆头：左侧竖条 + 圆角 */
                float bw = MAX(3.0f, w * 0.13f);
                ImVec2 b1(p1.x - bw - 3.0f, p1.y), b2(p1.x - 3.0f, p2.y);
                dl->AddRectFilled(b1, b2, IM_COL32(0, 0, 0, 150), bw * 0.5f);
                ImVec2 f2(b2.x, b1.y + (b2.y - b1.y) * ratio);
                dl->AddRectFilled(ImVec2(b1.x, f2.y), f2, hpCol, bw * 0.5f);
                break;
            }
            default: {  /* 分段：6 格，一格一格的 */
                const int segs = 6;
                float bw = MAX(3.0f, w * 0.13f);
                float gap = 1.5f;
                float totalH = p2.y - p1.y;
                float segH = (totalH - gap * (segs - 1)) / segs;
                float x1 = p1.x - bw - 3.0f, x2 = p1.x - 3.0f;
                dl->AddRectFilled(ImVec2(x1, p1.y), ImVec2(x2, p2.y),
                                  IM_COL32(0, 0, 0, 150), 1.0f);
                for (int i = 0; i < segs; i++) {
                    // 从下往上填：血量越低，顶部格越少
                    float segTop = p2.y - (i + 1) * segH - i * gap;
                    float fillTop = segTop + segH * (1.0f - MIN(1.0f, MAX(0.0f, ratio * segs - i)));
                    if (ratio * segs <= i) continue;
                    dl->AddRectFilled(ImVec2(x1 + 1, fillTop), ImVec2(x2 - 1, segTop + segH),
                                      hpCol, 1.0f);
                }
                break;
            }
        }
    }

    /* ── 名字（[M5.2] 用 fontPerson 字号）── */
    if (st.showName) {
        const char *name = e.name.length ? e.name.UTF8String
                          : (e.isBot ? "人机" : "敌人");
        ImVec2 ts = MFTextSize(name, st.fontPerson);
        MFText(dl, st.fontPerson,
               ImVec2(pt.x - ts.x * 0.5f, p1.y - ts.y - 2.0f), boxCol, name);
    }

    /* ── 距离（[M5.2] 用 fontInfo 字号）── */
    if (st.showDistance) {
        char buf[32];
        snprintf(buf, sizeof(buf), "[%.0fm]", e.distanceMeters);
        ImVec2 ts = MFTextSize(buf, st.fontInfo);
        MFText(dl, st.fontInfo, ImVec2(pt.x - ts.x * 0.5f, p2.y + 2.0f), boxCol, buf);
    }

    /* ── 头甲（[M5.2] 用 fontArmor 字号 + Armor 颜色 + 真实等级）── */
    if (st.showArmor) {
        char buf[24];
        if (e.armorKnown) {
            snprintf(buf, sizeof(buf), "%d", e.armorLevel);
        } else {
            snprintf(buf, sizeof(buf), "甲");
        }
        MFText(dl, st.fontArmor, ImVec2(p2.x + 4.0f, p1.y),
               MFU32([st colorForSlot:MFColorSlotArmor]), buf);
    }

    /* ── 队伍（[M5.2] 接线：显示队伍编号）── */
    if (st.showTeam && e.teamId != 0) {
        char buf[16];
        snprintf(buf, sizeof(buf), "T%d", e.teamId);
        MFText(dl, st.fontInfo, ImVec2(p1.x - 26.0f, p1.y),
               MFU32([st colorForSlot:MFColorSlotTeam]), buf);
    }

    /* ── 手持（[M5.2] 接线：显示武器编号）── */
    if (st.showHeld) {
        char buf[24];
        if (e.weaponId != 0) snprintf(buf, sizeof(buf), "W%d", e.weaponId);
        else                 snprintf(buf, sizeof(buf), "持");
        MFText(dl, st.fontInfo, ImVec2(p2.x + 4.0f, p2.y - st.fontInfo),
               MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.85f), buf);
    }

    /* ── 射线 ── */
    if (st.showTracer) {
        dl->AddLine(ImVec2(screen.x * 0.5f, screen.y), ImVec2(pt.x, pt.y),
                    MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.6f), 1.5f);
    }

    /* ── 骨骼（[M5.2] 接线：受 skeletonDistance 限制）── */
    if (st.showSkeleton && e.distanceMeters <= st.skeletonDistance) {
        [self drawSkeleton:e drawList:dl settings:st camera:cam at:pt];
    }
}

/// 简化骨架。
/// ⚠️ 分析明确标注「骨骼连线拓扑 + 骨骼矩阵来源」是【未证】项，
///    这里用「头-肩-胯」三点近似，真机拿到真实骨骼数组后替换本函数即可。
- (void)drawSkeleton:(MFEntity *)e drawList:(ImDrawList *)dl
            settings:(MFSettings *)st camera:(MFCamera)cam at:(ImVec2)pt {
    float scale = 2200.0f / MAX(e.distanceMeters, 1.0f);
    ImU32 col = MFU32([st colorForSlot:MFColorSlotSkeleton], 0.9f);
    float th = MAX(1.0f, st.skeletonThickness);

    ImVec2 head(pt.x, pt.y - scale);
    ImVec2 neck(pt.x, pt.y - scale * 0.82f);
    ImVec2 hip (pt.x, pt.y - scale * 0.45f);
    ImVec2 lShoulder(pt.x - scale * 0.22f, pt.y - scale * 0.75f);
    ImVec2 rShoulder(pt.x + scale * 0.22f, pt.y - scale * 0.75f);
    ImVec2 lFoot(pt.x - scale * 0.14f, pt.y);
    ImVec2 rFoot(pt.x + scale * 0.14f, pt.y);

    dl->AddLine(head, neck, col, th);
    dl->AddLine(lShoulder, rShoulder, col, th);
    dl->AddLine(neck, hip, col, th);
    dl->AddLine(hip, lFoot, col, th);
    dl->AddLine(hip, rFoot, col, th);
    dl->AddLine(lShoulder, lFoot, col, th * 0.6f);
    dl->AddLine(rShoulder, rFoot, col, th * 0.6f);
}

#pragma mark - 背敌提示（[M5.2] 新增，原版有我们之前没实现）

/*
 * 画法：在屏幕中心画一个半径 = backEnemyRadius(px) 的环，
 *       背后有敌人时，在对应方位角上打一个标记。
 *
 * 为什么用「屏幕中心 + 方位角」而不是直接画在敌人位置：
 *   背后的敌人在屏幕上是【投影不出来的】（在相机后面），
 *   所以必须用方位角映射到屏幕边缘的位置来表示方向 —— 这正是原版「背敌提示」的用途。
 *
 * 方位角来自 MFGameReader 的 bearingDeg，只由坐标 + 相机 yaw 算得，
 * 【不依赖任何游戏字段】—— 所以校准之前就能工作。
 */
- (void)drawBackEnemies:(NSArray<MFEntity *> *)ents
               drawList:(ImDrawList *)dl
               settings:(MFSettings *)st
                 screen:(ImVec2)screen {
    if (!st.backEnemyEnabled) return;

    ImU32 col = MFU32([st colorForSlot:MFColorSlotBackEnemy], 0.95f);
    ImVec2 c(screen.x * 0.5f, screen.y * 0.5f);
    float R = MAX(40.0f, st.backEnemyRadius);     // 单位 px（对齐原版）

    int n = 0;
    for (MFEntity *e in ents) {
        if (!e.isBehind) continue;
        if (e.isBot && !st.showBot) continue;
        n++;

        /* bearingDeg: 0=前 负=左 正=右 ±180=后
         * 映射到屏幕角度：-90°(左) → 左半屏；+90°(右) → 右半屏；180 → 正下
         * 用「从上方开始顺时针」的屏坐标约定：
         *   screenAngle = bearing - 90   （bearing=-90 → -180 左；+90 → 0 右；180 → 90 下）
         */
        float rad = (e.bearingDeg - 90.0f) * kMF_Deg2Rad;
        ImVec2 p(c.x + cosf(rad) * R, c.y + sinf(rad) * R);

        switch (st.backEnemyStyle) {
            case MFBackEnemyStyleCircle:      /* 圆形：实心点 + 距离 */
                dl->AddCircleFilled(p, 5.0f, col, 12);
                break;
            case MFBackEnemyStyleArrow: {     /* 箭头：从环上指向外侧 */
                ImVec2 dir(cosf(rad), sinf(rad));
                ImVec2 tip(p.x + dir.x * 11.0f, p.y + dir.y * 11.0f);
                ImVec2 l(p.x - dir.y * 6.0f, p.y + dir.x * 6.0f);
                ImVec2 r(p.x + dir.y * 6.0f, p.y - dir.x * 6.0f);
                dl->AddTriangleFilled(tip, l, r, col);
                break;
            }
            default:                          /* 圆环：空心圈 */
                dl->AddCircle(p, 7.0f, col, 16, 2.0f);
                break;
        }

        // 距离数字（背敌也要知道多远）
        char buf[24];
        snprintf(buf, sizeof(buf), "%.0fm", e.distanceMeters);
        ImVec2 ts = MFTextSize(buf, st.fontInfo * 0.85f);
        MFText(dl, st.fontInfo * 0.85f,
               ImVec2(p.x - ts.x * 0.5f, p.y + 9.0f), col, buf);
    }

    /* 有背敌时把环也画出来（没背敌就不画，免得挡视野）*/
    if (n > 0 && st.backEnemyStyle != MFBackEnemyStyleCircle) {
        dl->AddCircle(c, R, MFU32([st colorForSlot:MFColorSlotBackEnemy], 0.30f), 48, 1.0f);
    }
    _backEnemyCount = n;
}

#pragma mark - 物资

- (void)drawLoot:(MFEntity *)e drawList:(ImDrawList *)dl
        settings:(MFSettings *)st screen:(ImVec2)screen {
    // ① 数值过滤（对齐分析已证的业务行为）
    if (st.minLootValue != 0 && e.value > 0 && e.value < st.minLootValue) return;
    if (st.minLootLevel != 0 && e.level > 0 && e.level < st.minLootLevel) return;
    if (e.distanceMeters > st.lootDrawDistance) return;

    // ② 颜色（已证：等级 3/4/5/6 各自色；非 3–6 且价值【严格大于】9999 → 用 3 级色强调）
    UIColor *col;
    if (e.level >= kMFLootLevelMin && e.level <= kMFLootLevelMax) {
        static const MFColorSlot slots[4] = {
            MFColorSlotLoot3, MFColorSlotLoot4, MFColorSlotLoot5, MFColorSlotLoot6
        };
        col = [st colorForSlot:slots[e.level - kMFLootLevelMin]];
    } else if (e.value > kMFLootValueHighlight) {
        col = [st colorForSlot:MFColorSlotLoot3];      // 强调
    } else {
        col = [st colorForSlot:MFColorSlotLootLow];    // 0–2 级色
    }

    ImU32 c = MFU32(col, 0.95f);

    // ③ 标签（已证格式串：%s\n等级[%d]\n价值[%d]\n[%.1fm]）
    //    [M5.2] 接线：用「盒子字号」fontBox
    if (st.showLootName) {
        NSString *name = e.name.length ? e.name : @"物资";
        NSString *label = [NSString stringWithFormat:@"%@\n等级[%d]\n价值[%d]\n[%.1fm]",
                           name, e.level, e.value, e.distanceMeters];
        const char *txt = label.UTF8String;
        ImVec2 ts = MFTextSize(txt, st.fontBox);
        MFText(dl, st.fontBox,
               ImVec2(e.screen.x - ts.x * 0.5f, e.screen.y - ts.y), c, txt);
    } else if (st.showLoot) {
        dl->AddCircle(ImVec2(e.screen.x, e.screen.y), 4.0f, c, 12, 1.5f);
    }

    // ④ 盒子（独立的绘制距离）
    if (st.showBox && e.isBox && e.distanceMeters <= st.boxDrawDistance) {
        float s = MIN(60.0f, 800.0f / MAX(e.distanceMeters, 1.0f));
        dl->AddRect(ImVec2(e.screen.x - s, e.screen.y - s),
                    ImVec2(e.screen.x + s, e.screen.y + s),
                    c, 3.0f, 0, 1.5f);
    }
}

#pragma mark - 统计窗

- (void)drawStats:(MFSettings *)st loot:(NSArray<MFEntity *> *)loot {
    // 已证：程序里有独立的「物资统计窗口」，等级/价值分组展示
    static BOOL open = YES;
    ImGui::SetNextWindowSize(ImVec2(220, 160), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(24, 120), ImGuiCond_FirstUseEver);
    if (ImGui::Begin("物资统计", &open,
                     ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                     ImGuiWindowFlags_AlwaysAutoResize)) {
        NSUInteger byLevel[7] = {0};
        long long totalValue = 0;
        for (MFEntity *e in loot) {
            int lv = (e.level >= 0 && e.level <= 6) ? e.level : 0;
            byLevel[lv]++;
            totalValue += e.value;
        }
        ImGui::Text("共 %lu 件", (unsigned long)loot.count);
        ImGui::Separator();
        for (int lv = 6; lv >= 3; lv--) {
            if (byLevel[lv] == 0) continue;
            ImGui::TextColored(ImVec4(0.98f, 0.82f, 0.30f, 1.0f),
                               "%d 级：%lu", lv, (unsigned long)byLevel[lv]);
        }
        if (byLevel[0]) ImGui::TextDisabled("其他：%lu", (unsigned long)byLevel[0]);
        ImGui::Separator();
        ImGui::Text("总价值：%lld", totalValue);
        // ImGui 的格式化不认 %@，必须转成 UTF-8 C 串
        ImGui::TextDisabled("%s", [[MFOffsets shared] summary].UTF8String);
    }
    ImGui::End();
}

#pragma mark - 渲染自检

/// 合成数据渲染。不读任何游戏内存。
///
/// 相机约定（来自 Game/MFProjection.h）：
///   前向 F = (cosP·cosY, cosP·sinY, sinP)  → P=Y=0 时 F=(1,0,0)，即朝 +X 看
///   右向 R = (-sinY, cosY, 0)              → y>0 在屏幕右侧
///   上向 U = (-sinP·cosY, -sinP·sinY, cosP) → z>0 在屏幕上方
- (void)runSelfTest:(MFSettings *)st overlay:(MFOverlayView *)overlay {
    const CGSize size = overlay.bounds.size;
    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    if (!dl) return;

    const float t = (float)(fmod(CACurrentMediaTime(), 6.0));   // 0–6 秒循环
    const float bob = sinf(t * 1.6f) * 60.0f;                   // 目标上下浮动

    MFCamera cam = (MFCamera){0};
    cam.fov = 90.0f;

    MFScreen sc = [MFProjection screenWithSize:size fov:cam.fov];

    // 场景：4 个「人」（不同距离/横向）+ 4 个「物资」（不同等级/价值）
    struct Item { float x, y, z; int level, value; BOOL isLoot; const char *name; };
    static const struct Item kItems[] = {
        {  300,   0,  0, 0,     0, NO,  "近距目标" },
        {  600, 120, 20, 0,     0, NO,  "中距目标" },
        { 1000, -160, 0, 0,     0, NO,  "远距目标" },
        {  800,   0, -60, 0,    0, NO,  "低位目标" },
        {  450,  260, 0, 3,   500, YES, "3级物资" },
        {  450, -260, 0, 4,  4000, YES, "4级物资" },
        {  700,  200, 0, 5, 20000, YES, "5级物资" },
        {  700, -200, 0, 6, 99999, YES, "6级物资" },
    };

    for (size_t i = 0; i < sizeof(kItems) / sizeof(kItems[0]); i++) {
        const struct Item *it = &kItems[i];
        float world[3] = { it->x, it->y, it->z + bob };

        MFPoint2D p = [[MFProjection shared] projectTarget:world camera:cam screen:sc];
        if (!p.valid) continue;

        MFEntity *e = [[MFEntity alloc] init];
        e.screen = p;
        e.isVisible = YES;
        e.worldX = world[0]; e.worldY = world[1]; e.worldZ = world[2];

        float camPos[3] = { cam.x, cam.y, cam.z };
        e.distanceMeters = [MFProjection distanceMetersFrom:world to:camPos];
        e.name = [NSString stringWithUTF8String:it->name];

        if (it->isLoot) {
            e.isLoot = YES;
            e.level = it->level;
            e.value = it->value;
            [self drawLoot:e drawList:dl settings:st screen:ImVec2((float)size.width, (float)size.height)];
        } else {
            [self drawEntity:e drawList:dl settings:st
                       screen:ImVec2((float)size.width, (float)size.height) camera:cam];
        }
    }

    // 顶部提示条
    ImGui::SetNextWindowPos(ImVec2(20, 20), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.9f);
    if (ImGui::Begin("##selftest", nullptr,
                     ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                     ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoInputs)) {
        ImGui::TextColored(ImVec4(0.19f, 0.82f, 0.35f, 1.0f), "渲染自检模式");
        ImGui::Separator();
        ImGui::Text("画面尺寸  %.0f × %.0f", size.width, size.height);
        ImGui::Text("帧         %.1f s", t);
        ImGui::Text("看到的框        4 个（随距离缩放）");
        ImGui::Text("看到的物资标签  4 个（3/4/5/6 级各自色）");
        ImGui::TextDisabled("这条链通了 = ImGui/Metal/透明层/投影 全正常");
        ImGui::TextDisabled("关掉「渲染自检」才会回到读游戏内存的模式");
    }
    ImGui::End();
}

#pragma mark - 诊断

- (NSString *)dumpFrameWithSize:(CGSize)size {
    NSDictionary *frame = [self.reader readFrameWithSize:size];
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"相机：%@\n", [frame[@"cameraOK"] boolValue] ? @"✓" : @"✗"];
    NSDictionary *cd = frame[@"camera"];
    if (cd) {
        [s appendFormat:@"  位置 (%.1f, %.1f, %.1f)\n  角度 (%.1f, %.1f, %.1f)  FOV %.1f\n",
         [cd[@"x"] floatValue], [cd[@"y"] floatValue], [cd[@"z"] floatValue],
         [cd[@"pitch"] floatValue], [cd[@"yaw"] floatValue], [cd[@"roll"] floatValue],
         [cd[@"fov"] floatValue]];
    }
    [s appendFormat:@"实体：%lu\n物资：%lu\n", (unsigned long)[frame[@"entities"] count],
     (unsigned long)[frame[@"loot"] count]];
    [s appendFormat:@"\n%@\n", frame[@"stats"] ?: @""];
    [s appendString:[[MFGameReader shared] diagnosticReport]];
    return s;
}

@end
