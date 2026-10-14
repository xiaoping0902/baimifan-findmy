//
//  MFDrawingLayer.mm — 透明绘制层（实现）
//
#import "MFDrawingLayer.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFGameReader.h"
#import "../Game/MFSettings.h"
#import "../Game/Offsets.h"

#include "imgui.h"

static BOOL gDrawEnabled = YES;

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

@implementation MFDrawingLayer {
    MFGameReader *_reader;
    NSUInteger _entCount;
    NSUInteger _lootCount;
    BOOL _camOK;
}

+ (void)setEnabled:(BOOL)enabled { gDrawEnabled = enabled; }
+ (BOOL)enabled { return gDrawEnabled; }

- (instancetype)init {
    if ((self = [super init])) {
        _reader = [MFGameReader shared];
    }
    return self;
}

- (NSUInteger)lastEntityCount { return _entCount; }
- (NSUInteger)lastLootCount { return _lootCount; }
- (BOOL)lastCameraOK { return _camOK; }

#pragma mark - 每帧

- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay {
    _entCount = 0;
    _lootCount = 0;
    _camOK = NO;

    MFSettings *st = [MFSettings shared];
    if (!gDrawEnabled || !st.masterEnabled || !st.drawEnabled) return;
    if (!self.reader.ready) return;

    const CGSize size = overlay.bounds.size;
    if (size.width < 1 || size.height < 1) return;

    NSDictionary *frame = [self.reader readFrameWithSize:size];
    _camOK = [frame[@"cameraOK"] boolValue];
    if (!_camOK) return;

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

    const ImVec2 screen((float)size.width, (float)size.height);

    // ── 人/盒子 ──
    for (MFEntity *e in ents) {
        if (!e.isVisible) continue;
        [self drawEntity:e drawList:dl settings:st screen:screen camera:cam];
    }

    // ── 物资 ──
    if (st.showLoot || st.showBox) {
        for (MFEntity *e in loot) {
            if (!e.isVisible) continue;
            [self drawLoot:e drawList:dl settings:st screen:screen];
        }
    }

    // ── 物资统计窗（可选）──
    if (st.showLootStats) [self drawStats:st loot:loot];
}

#pragma mark - 人 / 盒子

- (void)drawEntity:(MFEntity *)e drawList:(ImDrawList *)dl
          settings:(MFSettings *)st screen:(ImVec2)screen camera:(MFCamera)cam {
    // 盒子尺寸：按距离缩放。公式是常规做法，真机可调
    float h = 2200.0f / MAX(e.distanceMeters, 1.0f);   // 世界单位（厘米）→ 屏幕
    h = MIN(MAX(h, 8.0f), screen.y * 0.6f);
    float w = h * 0.45f;
    ImVec2 p1(e.screen.x - w * 0.5f, e.screen.y - h);
    ImVec2 p2(e.screen.x + w * 0.5f, e.screen.y);

    ImU32 boxCol = MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.85f);

    // 框
    if (st.showHealth || st.showName || st.showArmor) {
        dl->AddRect(p1, p2, boxCol, 0.0f, 0, 1.5f);
    }

    // 血条（左侧竖条）
    if (st.showHealth) {
        float bw = MAX(2.0f, w * 0.12f);
        ImVec2 b1(p1.x - bw - 2.0f, p1.y);
        ImVec2 b2(p1.x - 2.0f, p2.y);
        dl->AddRectFilled(b1, b2, IM_COL32(0, 0, 0, 140), 1.0f);
        // 血量数值未恢复来源 → 先画满格占位（真机校准后接实体字段）
        dl->AddRectFilled(b1, b2, MFU32([UIColor systemGreenColor], 0.9f), 1.0f);
    }

    // 名字
    if (st.showName) {
        const char *name = e.name.length ? e.name.UTF8String : "敌人";
        ImVec2 ts = ImGui::CalcTextSize(name);
        dl->AddText(ImVec2(e.screen.x - ts.x * 0.5f, p1.y - ts.y - 2.0f), boxCol, name);
    }

    // 距离
    if (st.showDistance) {
        char buf[32];
        snprintf(buf, sizeof(buf), "[%.0fm]", e.distanceMeters);
        ImVec2 ts = ImGui::CalcTextSize(buf);
        dl->AddText(ImVec2(e.screen.x - ts.x * 0.5f, p2.y + 1.0f), boxCol, buf);
    }

    // 头甲
    if (st.showArmor) {
        ImVec2 ts = ImGui::CalcTextSize("头甲");
        dl->AddText(ImVec2(p2.x + 3.0f, p1.y), MFU32([st colorForSlot:MFColorSlotArmor]), "头甲");
        (void)ts;
    }

    // 射线：从屏幕底部中点到目标
    if (st.showTracer) {
        dl->AddLine(ImVec2(screen.x * 0.5f, screen.y),
                    ImVec2(e.screen.x, e.screen.y),
                    MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.6f), 1.5f);
    }

    // 骨骼（无拓扑数据时用简化骨架：头-肩-胯）
    if (st.showSkeleton) {
        [self drawSkeleton:e drawList:dl settings:st camera:cam];
    }
}

/// 简化骨架。
/// ⚠️ 分析明确标注「骨骼连线拓扑 + 骨骼矩阵来源」是【未证】项，
///    这里用「头-肩-胯」三点近似，真机拿到真实骨骼数组后替换本函数即可。
- (void)drawSkeleton:(MFEntity *)e drawList:(ImDrawList *)dl
            settings:(MFSettings *)st camera:(MFCamera)cam {
    float scale = 2200.0f / MAX(e.distanceMeters, 1.0f);
    ImU32 col = MFU32([st colorForSlot:MFColorSlotSkeleton], 0.9f);
    float th = MAX(1.0f, st.skeletonThickness);

    ImVec2 head(e.screen.x, e.screen.y - scale);
    ImVec2 neck(e.screen.x, e.screen.y - scale * 0.82f);
    ImVec2 hip (e.screen.x, e.screen.y - scale * 0.45f);
    ImVec2 lShoulder(e.screen.x - scale * 0.22f, e.screen.y - scale * 0.75f);
    ImVec2 rShoulder(e.screen.x + scale * 0.22f, e.screen.y - scale * 0.75f);
    ImVec2 lFoot(e.screen.x - scale * 0.14f, e.screen.y);
    ImVec2 rFoot(e.screen.x + scale * 0.14f, e.screen.y);

    dl->AddLine(head, neck, col, th);
    dl->AddLine(lShoulder, rShoulder, col, th);
    dl->AddLine(neck, hip, col, th);
    dl->AddLine(hip, lFoot, col, th);
    dl->AddLine(hip, rFoot, col, th);
    dl->AddLine(lShoulder, lFoot, col, th * 0.6f);
    dl->AddLine(rShoulder, rFoot, col, th * 0.6f);
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
    if (st.showLootName) {
        NSString *name = e.name.length ? e.name : @"物资";
        NSString *label = [NSString stringWithFormat:@"%@\n等级[%d]\n价值[%d]\n[%.1fm]",
                           name, e.level, e.value, e.distanceMeters];
        // 首行居中、后续左对齐 —— 用多行文本一次性画
        ImVec2 ts = ImGui::CalcTextSize(label.UTF8String);
        dl->AddText(ImVec2(e.screen.x - ts.x * 0.5f, e.screen.y - ts.y),
                    c, label.UTF8String);
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
