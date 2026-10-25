//
//  MFGameReader.mm — 游戏数据读取（实现）
//
#import "MFGameReader.h"
#import "Offsets.h"
#import "MFSettings.h"
#import "MFUEOffsets.h"      /* [M5.155] gMFUELocalPawn / gMFUELocalTeam */
#import "../Read/MFReadBackend.h"
#import <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <string.h>

// libproc.h is not available in the iOS SDK. The symbol is provided by libSystem.
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static NSString *const kMFReaderBasesKey = @"mf.game.reader.absoluteBases.v1";

/// A PID/path alone cannot distinguish a restarted copy of the same game.
/// Refuse persistence when its start time cannot be established as well.
static NSDictionary *MFReaderProcessIdentity(mach_port_t task) {
    int pid = 0;
    if (task == MACH_PORT_NULL || pid_for_task(task, &pid) != KERN_SUCCESS || pid <= 0) return nil;

    char path[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    path[sizeof(path) - 1] = '\0';
    NSString *executable = [NSString stringWithUTF8String:path];
    if (!executable.length) return nil;

    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info = {0};
    size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length != sizeof(info) ||
        info.kp_proc.p_pid != pid || info.kp_proc.p_starttime.tv_sec <= 0 ||
        info.kp_proc.p_starttime.tv_usec < 0 || info.kp_proc.p_starttime.tv_usec >= 1000000) return nil;

    // If the task died during the path/sysctl queries, do not publish an
    // identity possibly obtained from a newly reused PID.
    int confirmedPID = 0;
    if (pid_for_task(task, &confirmedPID) != KERN_SUCCESS || confirmedPID != pid) return nil;
    return @{@"pid": @(pid), @"path": executable,
             @"startTimeSec": @((int64_t)info.kp_proc.p_starttime.tv_sec),
             @"startTimeUSec": @((int64_t)info.kp_proc.p_starttime.tv_usec)};
}

static BOOL MFReaderIsUnsignedInteger(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    const char *type = [value objCType];
    if (!type || !strchr("cCsSiIlLqQ", type[0])) return NO;
    if (strchr("csilq", type[0]) && [value longLongValue] < 0) return NO;
    return YES;
}

@interface MFGameReader ()
- (void)clearBasesWithStatus:(NSString *)status;
@end

@implementation MFEntity
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ (%.0f,%.0f,%.0f) %.1fm → (%.0f,%.0f)%@>",
            self.isLoot ? @"物资" : (self.isBox ? @"盒子" : @"人"),
            self.worldX, self.worldY, self.worldZ, self.distanceMeters,
            self.screen.x, self.screen.y,
            self.isVisible ? @"" : @" [不可见]"];
}
@end

@implementation MFGameReader {
    NSString *_baseCalibrationStatus;
}

+ (instancetype)shared {
    static MFGameReader *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFGameReader alloc] init]; });
    return s;
}

- (void)setTargetTaskPort:(uint32_t)port {
    @synchronized (self) {
        if (_targetTaskPort != port)
            [self clearBasesWithStatus:@"未校准（目标已切换，旧绝对地址已清空）"];
        _targetTaskPort = port;
        [MFReadBackend shared].targetTaskPort = port;
    }
}

- (BOOL)ready {
    return self.targetTaskPort != MACH_PORT_NULL && [MFReadBackend shared].gateOpen;
}

#pragma mark - 当前进程实例的基址快照

- (void)clearBasesWithStatus:(NSString *)status {
    self.rootObjectBase = 0;
    self.entityArrayBase = 0;
    self.lootArrayBase = 0;
    _baseCalibrationStatus = [status copy];
}

- (void)loadBasesFromDefaults {
    @synchronized (self) {
        [self clearBasesWithStatus:@"未校准（没有当前进程实例的基址快照）"];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults synchronize];
        id value = [defaults objectForKey:kMFReaderBasesKey];
        NSDictionary *identity = MFReaderProcessIdentity(self.targetTaskPort);
        if (!identity) {
            [defaults removeObjectForKey:kMFReaderBasesKey];
            _baseCalibrationStatus = @"未校准（目标 PID、路径或启动时间无法确认）";
            return;
        }
        if (!value) return;
        if (![value isKindOfClass:NSDictionary.class]) {
            [defaults removeObjectForKey:kMFReaderBasesKey];
            _baseCalibrationStatus = @"未校准（基址快照格式无效）";
            return;
        }
        NSDictionary *snapshot = value;
        if (![snapshot[@"version"] isEqual:@1] ||
            ![snapshot[@"identity"] isKindOfClass:NSDictionary.class] ||
            ![snapshot[@"identity"] isEqual:identity] ||
            !MFReaderIsUnsignedInteger(snapshot[@"rootObjectBase"]) ||
            !MFReaderIsUnsignedInteger(snapshot[@"entityArrayBase"]) ||
            !MFReaderIsUnsignedInteger(snapshot[@"lootArrayBase"])) {
            [defaults removeObjectForKey:kMFReaderBasesKey];
            _baseCalibrationStatus = @"未校准（旧快照身份不匹配或字段无效）";
            return;
        }
        self.rootObjectBase = [snapshot[@"rootObjectBase"] unsignedLongLongValue];
        self.entityArrayBase = [snapshot[@"entityArrayBase"] unsignedLongLongValue];
        self.lootArrayBase = [snapshot[@"lootArrayBase"] unsignedLongLongValue];
        _baseCalibrationStatus = @"已恢复（仅限同一目标进程实例，字段仍需真机校准）";
    }
}

- (void)saveBasesToDefaults {
    @synchronized (self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *identity = MFReaderProcessIdentity(self.targetTaskPort);
        if (!identity) {
            [self clearBasesWithStatus:@"未校准（缺少进程实例身份，已丢弃绝对地址）"];
            [defaults removeObjectForKey:kMFReaderBasesKey];
            [defaults synchronize];
            return;
        }
        if (!(self.rootObjectBase || self.entityArrayBase || self.lootArrayBase)) {
            [defaults removeObjectForKey:kMFReaderBasesKey];
            _baseCalibrationStatus = @"未校准（三个基址均为 0）";
        } else {
            [defaults setObject:@{@"version": @1, @"identity": identity,
                @"rootObjectBase": @(self.rootObjectBase),
                @"entityArrayBase": @(self.entityArrayBase),
                @"lootArrayBase": @(self.lootArrayBase)} forKey:kMFReaderBasesKey];
            _baseCalibrationStatus = @"已保存（仅限当前目标进程实例）";
        }
        if (![defaults synchronize]) _baseCalibrationStatus = @"基址快照保存失败";
    }
}

- (NSString *)calibrationSummary {
    @synchronized (self) {
        NSString *state = _baseCalibrationStatus ?: @"未校准（尚未加载或保存进程实例快照）";
        return [NSString stringWithFormat:@"%@\nroot=0x%llx ent=0x%llx loot=0x%llx", state,
            (unsigned long long)self.rootObjectBase,
            (unsigned long long)self.entityArrayBase,
            (unsigned long long)self.lootArrayBase];
    }
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
                continue;        /* [M5.155] 坐标读不到就不产出实体（以前会画一个空气框） */
            }
            e.worldX = pos[0]; e.worldY = pos[1]; e.worldZ = pos[2];

            /* ══════════ [M5.155] 角色判据 + 全部属性（frida 真机验证）══════════
             *   +0x3D0 Mesh → Mesh+0x750 骨骼数组（Num≥20 才算人）
             *   +0x390 PlayerState（空 = 人机）   +0xDC8 死亡   PS+0x4C0 bit0 观战
             *   +0x10C0 → +0x108 队伍            +0x24E0 → +0x1D8 装备槽
             *   +0x1020 → 0x4D8/0x588 → +0x838 武器
             */
            {
                if (item == gMFUELocalPawn) continue;

                uint64_t mesh = 0, boneData = 0;
                int32_t boneNum = 0;
                if (![rb readU64:item + 0x3D0 out:&mesh] || !mesh) continue;
                if (![rb readU64:mesh + 0x750 out:&boneData] || !boneData) continue;
                if (![rb readRemote:mesh + 0x750 + 8 into:&boneNum size:4]) continue;
                if (boneNum < 20) continue;

                uint8_t deadFlag = 0;
                if ([rb readRemote:item + 0xDC8 into:&deadFlag size:1] && deadFlag != 0) continue;

                uint64_t ps = 0;
                BOOL havePS = ([rb readU64:item + 0x390 out:&ps] && ps != 0);
                if (havePS) {
                    uint8_t inactive = 0;
                    if ([rb readRemote:ps + 0x4C0 into:&inactive size:1] && (inactive & 1)) continue;
                }

                uint32_t teamVal = 0;
                uint64_t tc = 0;
                if ([rb readU64:item + 0x10C0 out:&tc] && tc) {
                    [rb readRemote:tc + 0x108 into:&teamVal size:4];
                }
                e.teamId = (int)teamVal;
                e.isBot = havePS ? NO : YES;
                if (gMFUELocalTeam != 0 && teamVal == gMFUELocalTeam && havePS &&
                    ![MFSettings shared].showTeammates) {
                    continue;
                }
                if (havePS) {
                    uint64_t uinVal = 0;
                    if ([rb readU64:ps + 0x490 out:&uinVal]) e.uin = uinVal;
                }

                uint64_t ec = 0, slots = 0;
                if ([rb readU64:item + 0x24E0 out:&ec] && ec &&
                    [rb readU64:ec + 0x1D8 out:&slots] && slots) {
                    uint8_t rawSlots[10 * 0x30];
                    size_t got = [rb readRemotePartial:slots into:rawSlots size:sizeof(rawSlots)];
                    if (got >= 0x30) {
                        size_t nSlot = got / 0x30;
                        for (size_t s2 = 0; s2 < nSlot; s2++) {
                            uint64_t itemId = 0;
                            memcpy(&itemId, rawSlots + s2 * 0x30, 8);
                            if (itemId < 10000001ULL || itemId > 0x4A87F317FULL) continue;
                            if (!e.equipRawID) e.equipRawID = itemId;
                            char dec[24] = {0};
                            int len = snprintf(dec, sizeof(dec), "%llu",
                                               (unsigned long long)itemId);
                            if (len < 8) continue;
                            int typeCode = (dec[1] - '0') * 100 + (dec[2] - '0') * 10 +
                                           (dec[3] - '0');
                            int lv = dec[7] - '0';
                            if (lv < 1 || lv > 6) continue;
                            switch (typeCode) {
                                case 101: e.helmetLevel = lv;   e.equipKnown = YES; break;
                                case 105: e.armorLevel = lv;    e.armorKnown = YES;
                                          e.equipKnown = YES; break;
                                case 108: e.backpackLevel = lv; e.equipKnown = YES; break;
                                default: break;
                            }
                        }
                    }
                }

                uint64_t combat = 0;
                if ([rb readU64:item + 0x1020 out:&combat] && combat) {
                    uint64_t wpn = 0;
                    if (![rb readU64:combat + 0x4D8 out:&wpn] || !wpn) {
                        [rb readU64:combat + 0x588 out:&wpn];
                    }
                    if (wpn) {
                        uint64_t wid = 0;
                        if ([rb readU64:wpn + 0x838 out:&wid] && wid > 0) {
                            char dec[24] = {0};
                            int len = snprintf(dec, sizeof(dec), "%llu",
                                               (unsigned long long)wid);
                            if (len >= 4) {
                                e.weaponId = (dec[1] - '0') * 100 + (dec[2] - '0') * 10 +
                                             (dec[3] - '0');
                            }
                        }
                    }
                }
            }

            // ③ 投影
            float cam[3] = {camera.x, camera.y, camera.z};
            e.distanceMeters = [MFProjection distanceMetersFrom:pos to:cam];
            e.screen = [[MFProjection shared] projectTarget:pos camera:camera screen:screen];
            e.isVisible = e.screen.valid;

            /* ── [M5.2] 方位角 + 前后判定 ──
             * 使用已读取的坐标差 + 相机 yaw，不需要额外人物属性偏移。
             * 仍依赖正确校准的相机和实体坐标链。
             *   带符号：负 = 左 / 正 = 右 / 0 = 正前 / ±180 = 正后
             */
            {
                float dx = pos[0] - camera.x;
                float dy = pos[1] - camera.y;
                float targetYaw = atan2f(dy, dx) / kMF_Deg2Rad;   // 度
                float d = targetYaw - camera.yaw;
                while (d >  180.0f) d -= 360.0f;
                while (d < -180.0f) d += 360.0f;
                e.bearingDeg = d;                                  // 保留符号
                e.isBehind = (fabsf(d) > kMFBehindAngleDeg);
            }

            /* ── [M5.2] 人物属性（偏移全为 0 时自动跳过，不会画错）── */
            [self readHumanFields:e reader:rb profile:off.current];

            /*
             * ★ [M5.141] 贴身过滤：自己永远在相机底下。
             *
             * 前面按 actor == Pawn 跳过自己，但 Pawn 指针读失败时（或引擎换了一具
             * 代理身体）那条就不生效，于是屏幕上给自己画框、脚下还留一条"残留骨骼"。
             * 实体离相机不到 1.2m 的，无论指针怎么指都不可能是别人。
             */
            if (e.distanceMeters >= 0.0f && e.distanceMeters < 2.0f) {
                continue;
            }

            [out addObject:e];
        }
    }
    return out;
}

/// 读人物属性。所有偏移为 0 时直接返回 —— 保持「未校准不画错」的约束。
- (void)readHumanFields:(MFEntity *)e reader:(MFReadBackend *)rb
                profile:(MFGameProfile *)p {
    e.isBot      = NO;
    e.teamId     = 0;
    e.weaponId   = 0;
    e.health     = -1;          // -1 = 未知 → 绘制层按满格处理
    e.armorLevel = 0;
    e.armorKnown = NO;

    if (!p) return;

    if (p.entityIsBotOffset) {
        int v = [rb readInt32:e.address + p.entityIsBotOffset];
        e.isBot = (v != 0);
    }
    if (p.entityTeamOffset) {
        int v = [rb readInt32:e.address + p.entityTeamOffset];
        if (v >= 0 && v < 64) e.teamId = v;      // 明显越界就当中断读失败
    }
    if (p.entityWeaponOffset) {
        int v = [rb readInt32:e.address + p.entityWeaponOffset];
        if (v >= 0 && v < 4096) e.weaponId = v;
    }
    if (p.entityHealthOffset) {
        int v = [rb readInt32:e.address + p.entityHealthOffset];
        if (v >= kMFHealthMin && v <= kMFHealthMax) e.health = v;
    }
    if (p.entityArmorOffset) {
        int v = [rb readInt32:e.address + p.entityArmorOffset];
        if (v >= 0 && v <= 10) { e.armorLevel = v; e.armorKnown = YES; }
    }
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
    [s appendFormat:@"基址校准：%@\n\n", self.calibrationSummary];
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
