//
//  MFGameReader.mm — 游戏数据读取（实现）
//
#import "MFGameReader.h"
#import "Offsets.h"
#import "MFSettings.h"
#import "../Read/MFReadBackend.h"

@implementation MFEntity
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ (%.0f,%.0f,%.0f) %.1fm → (%.0f,%.0f)%@>",
            self.isLoot ? @"物资" : (self.isBox ? @"盒子" : @"人"),
            self.worldX, self.worldY, self.worldZ, self.distanceMeters,
            self.screen.x, self.screen.y,
            self.isVisible ? @"" : @" [不可见]"];
}
@end

@implementation MFGameReader

+ (instancetype)shared {
    static MFGameReader *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFGameReader alloc] init]; });
    return s;
}

- (void)setTargetTaskPort:(uint32_t)port {
    _targetTaskPort = port;
    [MFReadBackend shared].targetTaskPort = port;
}

- (BOOL)ready {
    return self.targetTaskPort != MACH_PORT_NULL && [MFReadBackend shared].gateOpen;
}

#pragma mark - ① 相机

- (BOOL)readCamera:(MFCamera *)out {
    if (!self.ready) return NO;
    MFOffsets *off = [MFOffsets shared];
    MFReadBackend *rb = [MFReadBackend shared];

    // 相机对象基址（原实现存在全局 0x100FF6610，复刻版按档案里的偏移直接走对象链）
    // ★ 审查修正 F4：这里走的是【指针链根 rootObjectBase】，与实体数组起始是两个字段
    uint64_t base = [rb followChain:self.rootObjectBase
                            offsets:off.current.rootChain];
    if (!base) return NO;

    uint64_t camObjPtr = base + off.current.cameraPtrOffset;
    uint64_t camObj = [rb readU64:camObjPtr];
    if (!camObj) return NO;

    MFCamera c = {0};
    // 已证：相机结构体 +0x10/+0x14/+0x18 = XYZ
    if (![rb readRemote:camObj + kMFCamera_X into:&c.x size:4]) return NO;
    if (![rb readRemote:camObj + kMFCamera_Y into:&c.y size:4]) return NO;
    if (![rb readRemote:camObj + kMFCamera_Z into:&c.z size:4]) return NO;
    // +0x20/+0x24/+0x28 = 俯仰/偏航/横滚
    [rb readRemote:camObj + kMFCamera_Pitch into:&c.pitch size:4];
    [rb readRemote:camObj + kMFCamera_Yaw   into:&c.yaw   size:4];
    [rb readRemote:camObj + kMFCamera_Roll  into:&c.roll  size:4];
    // +0x2C = FOV
    [rb readRemote:camObj + kMFCamera_FOV   into:&c.fov   size:4];

    if (out) *out = c;
    return YES;
}

/// 实体数组起始地址
/// ★ 审查修正 F4：原来共用 entityListBase，与相机路的语义冲突（同一值当两个东西用）
- (uint64_t)resolveEntityListBase {
    return self.entityArrayBase;
}

#pragma mark - ②③ 实体

- (NSArray<MFEntity *> *)readEntitiesWithCamera:(MFCamera)camera screen:(MFScreen)screen {
    NSMutableArray<MFEntity *> *out = [NSMutableArray array];
    if (!self.ready) return out;

    MFOffsets *off = [MFOffsets shared];
    MFReadBackend *rb = [MFReadBackend shared];

    uint64_t base = [self resolveEntityListBase];
    if (!base) return out;

    // 已证：实体数量在 +0xE68
    int count = [rb readInt32:base + off.current.entityCountOffset];
    if (count <= 0 || count > 4096) return out;      // 防越界

    for (int i = 0; i < count; i++) {
        @autoreleasepool {
            uint64_t itemPtrAddr = base + 0x8 * (uint64_t)i;   // 指针数组，真机校准
            uint64_t item = [rb readU64:itemPtrAddr];
            if (!item) continue;

            MFEntity *e = [[MFEntity alloc] init];
            e.address = item;

            // 已证：坐标在 +0x220（3 float）
            float pos[3] = {0};
            if (![rb readFloat3:item + off.current.entityPositionOffset out:pos]) {
                [out addObject:e];                       // 保留但标不可见（对齐原实现：读失败不跳过解析）
                continue;
            }
            e.worldX = pos[0]; e.worldY = pos[1]; e.worldZ = pos[2];

            // ③ 投影
            float cam[3] = {camera.x, camera.y, camera.z};
            e.distanceMeters = [MFProjection distanceMetersFrom:pos to:cam];
            e.screen = [[MFProjection shared] projectTarget:pos camera:camera screen:screen];
            e.isVisible = e.screen.valid;

            [out addObject:e];
        }
    }
    return out;
}

#pragma mark - ④ 物资

- (NSArray<MFEntity *> *)readLootWithCamera:(MFCamera)camera screen:(MFScreen)screen {
    NSMutableArray<MFEntity *> *out = [NSMutableArray array];
    if (!self.ready) return out;

    MFOffsets *off = [MFOffsets shared];
    MFReadBackend *rb = [MFReadBackend shared];

    uint64_t base = self.lootArrayBase;
    if (!base) return out;

    int count = [rb readInt32:base + off.current.entityCountOffset];
    if (count <= 0 || count > 4096) return out;

    MFSettings *st = [MFSettings shared];

    for (int i = 0; i < count; i++) {
        @autoreleasepool {
            uint64_t item = [rb readU64:base + 0x8 * (uint64_t)i];
            if (!item) continue;

            MFEntity *e = [[MFEntity alloc] init];
            e.address = item;
            e.isLoot = YES;

            // 价值：4 字节。读失败 / 长度为 4 但不为 0 → 跳过（对齐原实现）
            int32_t value = 0;
            if (off.current.lootValueOffset &&
                ![rb readRemote:item + off.current.lootValueOffset into:&value size:4]) {
                continue;
            }
            if (value == 0) continue;                 // 原实现：价值为 0 直接跳过
            e.value = value;

            // 等级：4 字节。读失败 → 置 0（不跳过，进默认颜色分支）
            int32_t level = 0;
            if (off.current.lootLevelOffset) {
                [rb readRemote:item + off.current.lootLevelOffset into:&level size:4];
            }
            e.level = level;

            float pos[3] = {0};
            if (![rb readFloat3:item + off.current.entityPositionOffset out:pos]) {
                continue;
            }
            e.worldX = pos[0]; e.worldY = pos[1]; e.worldZ = pos[2];

            float cam[3] = {camera.x, camera.y, camera.z};
            e.distanceMeters = [MFProjection distanceMetersFrom:pos to:cam];
            e.screen = [[MFProjection shared] projectTarget:pos camera:camera screen:screen];
            e.isVisible = e.screen.valid;

            // 距离过滤（已证：受另一个模式 flag 影响）
            if (e.distanceMeters > st.lootDrawDistance) continue;

            [out addObject:e];
        }
    }
    return out;
}

#pragma mark - 一次性

- (NSDictionary *)readFrameWithSize:(CGSize)size {
    MFCamera cam = {0};
    BOOL ok = [self readCamera:&cam];
    MFScreen sc = [MFProjection screenWithSize:size fov:cam.fov];

    NSArray<MFEntity *> *ents = ok ? [self readEntitiesWithCamera:cam screen:sc] : @[];
    NSArray<MFEntity *> *loot = ok ? [self readLootWithCamera:cam screen:sc] : @[];

    return @{
        @"cameraOK": @(ok),
        @"camera": @{ @"x": @(cam.x), @"y": @(cam.y), @"z": @(cam.z),
                      @"pitch": @(cam.pitch), @"yaw": @(cam.yaw),
                      @"roll": @(cam.roll), @"fov": @(cam.fov) },
        @"entities": ents,
        @"loot": loot,
        @"stats": [[MFReadBackend shared] statsText],
    };
}

#pragma mark - 诊断

- (NSString *)diagnosticReport {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"门条件：%@\n", self.ready ? @"已就绪" : @"未就绪"];
    [s appendFormat:@"目标端口：0x%x\n", self.targetTaskPort];
    [s appendFormat:@"%@\n\n", [[MFReadBackend shared] statsText]];
    [s appendString:[[MFOffsets shared] summary]];
    [s appendFormat:@"\n\n%@", [[MFProjection shared] conventionText]];

    MFCamera cam = {0};
    if ([self readCamera:&cam]) {
        [s appendFormat:@"\n\n相机读数：\n  位置 (%.1f, %.1f, %.1f)\n  角度 (俯仰 %.1f / 偏航 %.1f / 横滚 %.1f)\n  FOV %.1f",
         cam.x, cam.y, cam.z, cam.pitch, cam.yaw, cam.roll, cam.fov];
    } else {
        [s appendString:@"\n\n相机读数：× 失败（地址链未校准时正常）"];
    }
    return s;
}

@end
