//
//  MFGameReader.mm — 游戏数据读取（实现）
//
#import "MFGameReader.h"
#import "Offsets.h"
#import "MFSettings.h"
#import "MFUEOffsets.h"      /* [M5.155] gMFUELocalPawn / gMFUELocalTeam */
#include "MFUEHealth.h"
#include "MFUECameraValidation.h"
#include "MFUEPlayerDataObjC.h"
#include "MFUEActorState.h"
#import "MFItemNames.h"      /* [M5.159] 物品 ID → 中文名 */
#import "../Read/MFReadBackend.h"
#import "../HUD/MFHUDLog.h"     /* [M5.212] 帧预算截断要写一条限流日志 */
#import <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <string.h>

// libproc.h is not available in the iOS SDK. The symbol is provided by libSystem.
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static NSString *const kMFReaderBasesKey = @"mf.game.reader.absoluteBases.v1";

/// A PID/path alone cannot distinguish a restarted copy of the same game.
/// Refuse persistence when its start time cannot be established as well.
///
/// [M5.207] 改为按 **pid** 取身份，不再要求 task port：端口已经从读取链上退场，
/// 而 pid + 可执行路径 + 启动时间三者合起来才能确认"同一个进程实例"。
static NSDictionary *MFReaderProcessIdentityForPid(int pid) {
    if (pid <= 0) return nil;

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

    // Re-read the pid after the path/sysctl queries: if it vanished in between,
    // the pid may already have been reused, so no identity is published.
    char confirmPath[4096] = {0};
    if (proc_pidpath(pid, confirmPath, sizeof(confirmPath)) <= 0) return nil;
    if (strcmp(confirmPath, path) != 0) return nil;
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
- (instancetype)init {
    if ((self = [super init])) {
        _health = -1;
        _maxHealth = 0;
        _yawDeg = NAN;
        _helmetHP = _helmetMaxHP = _armorHP = _armorMaxHP = NAN;
    }
    return self;
}
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
    /* [M5.212] 帧内读取预算被截断的次数（限流日志用，避免每帧刷屏） */
    unsigned _entityBudgetCuts;
    unsigned _lootBudgetCuts;
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
    /*
     * [M5.207] 就绪判据改成只看 KFD 门。
     *
     * 原来是 targetTaskPort != NULL && gateOpen，而端口已经恒为 0 ——
     * 继续用那个判据会让 ready 永远为 NO，绘制层直接判死。
     * 现在的真实条件只有一个：pmap 根表已就位（attachKFDPid 成功）。
     */
    return [MFReadBackend shared].gateOpen;
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
        NSDictionary *identity = MFReaderProcessIdentityForPid([MFReadBackend shared].kfdPid);
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
        NSDictionary *identity = MFReaderProcessIdentityForPid([MFReadBackend shared].kfdPid);
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
    if (![rb readRemote:camObj + kMFCamera_Pitch into:&c.pitch size:4]) return NO;
    if (![rb readRemote:camObj + kMFCamera_Yaw   into:&c.yaw   size:4]) return NO;
    if (![rb readRemote:camObj + kMFCamera_Roll  into:&c.roll  size:4]) return NO;
    // +0x2C = FOV
    if (![rb readRemote:camObj + kMFCamera_FOV   into:&c.fov   size:4]) return NO;
    if (!MFUECameraValidation::NormalizeAndValidate(c, kMFUE_POV_FovMin, kMFUE_POV_FovMax)) return NO;

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

    /*
     * [M5.209] 连续读空就熔断。
     *
     * 正常的局里，"整段指针全是无效值"撑不到几十个；一旦连续这么多次读不出东西，
     * 基本可以断定这个基址已经失效（典型场景：换局了但没被识别）。
     * 继续跑满 count 次只会把渲染线程按在几千次无效内核读上 —— 那正是卡死。
     */
    /*
     * [M5.212] 帧内时间预算。
     *
     * CADisplayLink 和绘制都在主线程，所以"实体读得太多"不是掉帧问题，
     * 是直接卡住 UI 的问题。目标多的局（几十上百人）里，一个人一次坐标读
     * 就是一次内核读，累计起来能把一帧拖到几十毫秒。
     *
     * 给 5ms 预算：超了就停，下一帧从头发继续。宁可这一帧少画几个，
     * 也不让主线程被按死 —— 用户看到的是"框偶尔少一个"，不是"整个 HUD 卡住"。
     */
    const CFTimeInterval entityBudgetEnd = CFAbsoluteTimeGetCurrent() + 0.005;
    int consecutiveMisses = 0;
    for (int i = 0; i < count; i++) {
        if ((i & 7) == 0 && CFAbsoluteTimeGetCurrent() > entityBudgetEnd) {
            if (_entityBudgetCuts < 5) {
                _entityBudgetCuts++;
                MFHUDLogLine(@"实体读取触顶 5ms 预算：已读 %d/%d（第 %u 次，后续不再刷日志）",
                             i, count, _entityBudgetCuts);
            }
            break;
        }
        @autoreleasepool {
            uint64_t itemPtrAddr = base + 0x8 * (uint64_t)i;   // 指针数组，真机校准
            uint64_t item = [rb readU64:itemPtrAddr];
            if (!item) { if (++consecutiveMisses > 64) break; continue; }

            MFEntity *e = [[MFEntity alloc] init];
            e.address = item;

            // 已证：坐标在 +0x220（3 float）
            float pos[3] = {0};
            if (![rb readFloat3:item + off.current.entityPositionOffset out:pos]) {
                /* [M5.155] 坐标读不到就不产出实体（以前会画一个空气框） */
                if (++consecutiveMisses > 64) break;
                continue;
            }
            consecutiveMisses = 0;
            e.worldX = pos[0]; e.worldY = pos[1]; e.worldZ = pos[2];

            /*
             * ══════════ [M5.164] 分层读取：位置每帧，属性每秒 ══════════
             *
             * 相机和坐标每帧读取，队伍/装备/武器按 Actor 缓存约 1 秒。
             * 血量使用单独的 15 Hz 缓存，避免受伤状态延迟一秒以上。
             * 静态资料不再每帧重复读取，血量也不会被一秒缓存锁住。
             */
            {
                if (item == gMFUELocalPawn) continue;

                /* ① 每帧只做一件事：读坐标（12 字节） */
                float posNow[3] = {0};
                if (![rb readFloat3:item + off.current.entityPositionOffset out:posNow]) {
                    continue;
                }
                if (!isfinite(posNow[0]) || !isfinite(posNow[1]) || !isfinite(posNow[2])) {
                    continue;
                }
                if (posNow[0] == 0.0f && posNow[1] == 0.0f && posNow[2] == 0.0f) continue;

                /* ② 属性：按 Actor 缓存 1 秒 */
                static NSMutableDictionary<NSNumber *, NSDictionary *> *attrCache = nil;
                static dispatch_once_t attrOnce;
                dispatch_once(&attrOnce, ^{ attrCache = [NSMutableDictionary dictionary]; });

                NSDictionary *attr = nil;
                /* TTL 按地址错开 1.0~1.5 秒：避免所有角色在同一帧一起刷新造成顿挫 */
                const double ttl = 1.0 + (double)(item & 0x3F) / 128.0;
                @synchronized (attrCache) { attr = attrCache[@(item)]; }
                BOOL fresh = attr &&
                    (CFAbsoluteTimeGetCurrent() - [attr[@"t"] doubleValue]) < ttl;

                if (!fresh) {
                    NSMutableDictionary *a = [NSMutableDictionary dictionary];

                    uint64_t mesh = 0, boneData = 0;
                    int32_t boneNum = 0;
                    BOOL isChar = NO;
                    if ([rb readU64:item + 0x3D0 out:&mesh] && mesh &&
                        [rb readU64:mesh + 0x750 out:&boneData] && boneData &&
                        [rb readRemote:mesh + 0x750 + 8 into:&boneNum size:4] &&
                        boneNum >= 20) {
                        isChar = YES;
                    }
                    /* 同一个 Mesh 就是自己 */
                    if (isChar && gMFUELocalMesh != 0 && mesh == gMFUELocalMesh) isChar = NO;

                    if (isChar && MFIsUEFullyDead(rb, item)) {
                        isChar = NO;
                    }

                    uint64_t ps = 0;
                    BOOL havePS = NO;
                    if (isChar) {
                        havePS = ([rb readU64:item + 0x390 out:&ps] && ps != 0);
                        if (havePS && MFUEActorState::IsSpectatorOrInactive(ps,
                            [rb](uint64_t address, void *out, size_t size) {
                                return (bool)[rb readRemote:address into:out size:size];
                            })) isChar = NO;
                    }

                    uint32_t teamVal = 0;
                    uint64_t tc = 0;
                    if (isChar && [rb readU64:item + 0x10C0 out:&tc] && tc) {
                        [rb readRemote:tc + 0x108 into:&teamVal size:4];
                    }
                    /* 同队目标不进入绘制实体列表。 */
                    if (isChar && gMFUELocalTeam != 0 && teamVal == gMFUELocalTeam) {
                        isChar = NO;
                    }

                    a[@"char"] = @(isChar);
                    a[@"team"] = @(teamVal);
                    a[@"bot"]  = @(isChar&&MFIsUEBot(rb,item));

                    if (isChar) {
                        uint64_t uinVal = 0;
                        if (havePS && [rb readU64:ps + kMFUE_PlayerState_UIN out:&uinVal]) a[@"uin"] = @(uinVal);
                        NSString *name = havePS ? MFReadUEPlayerName(rb, ps) : nil;
                        if (name.length) a[@"name"] = name;
                        MFFillUEHeroAttributes(rb, item, a);
                        MFFillUENPCAttributes(rb, item, [a[@"bot"] boolValue], name, a);

                        /* 手持 */
                        uint64_t combat = 0;
                        if ([rb readU64:item + 0x1020 out:&combat] && combat) {
                            uint64_t wpn = 0;
                            if (![rb readU64:combat + 0x4D8 out:&wpn] || !wpn) {
                                [rb readU64:combat + 0x588 out:&wpn];
                            }
                            if (wpn) {
                                const uint64_t wid = MFHeldWeapons::ReadID(wpn + 0x838, [rb](uint64_t address, void *out, size_t size) {
                                    return (bool)[rb readRemote:address into:out size:size];
                                });
                                if (wid > 0) {
                                    a[@"wid"] = @(wid);
                                }
                            }
                        }

                        MFFillUEEquipmentAttributes(rb, item, a);
                    }

                    a[@"t"] = @(CFAbsoluteTimeGetCurrent());
                    @synchronized (attrCache) {
                        attrCache[@(item)] = a;
                        if (attrCache.count > 1024) [attrCache removeAllObjects];
                    }
                    attr = a;
                }

                if (![attr[@"char"] boolValue]) continue;

                e.worldX = posNow[0]; e.worldY = posNow[1]; e.worldZ = posNow[2];
                MFApplyUEHeading(e, rb, 0x180);
                e.teamId = [attr[@"team"] intValue];
                e.isBot = [attr[@"bot"] boolValue];
                e.uin = [attr[@"uin"] unsignedLongLongValue];
                static NSMutableDictionary<NSNumber *, NSDictionary *> *healthCache;
                static dispatch_once_t healthOnce;
                dispatch_once(&healthOnce, ^{ healthCache = [NSMutableDictionary dictionary]; });
                const double healthNow = CFAbsoluteTimeGetCurrent();
                NSDictionary *health;
                @synchronized (healthCache) { health = healthCache[@(item)]; }
                if (!health || healthNow - [health[@"t"] doubleValue] >= 1.0 / 15.0) {
                    const auto hp = MFUEHealth::Read(item, [&](uint64_t address, void *out, size_t size) {
                        return (bool)[rb readRemote:address into:out size:size];
                    });
                    health = @{@"t": @(healthNow), @"hp": @(hp.current), @"max": @(hp.maximum)};
                    @synchronized (healthCache) {
                        if (healthCache.count > 1024) [healthCache removeAllObjects];
                        healthCache[@(item)] = health;
                    }
                }
                e.health = [health[@"hp"] floatValue];
                e.maxHealth = [health[@"max"] floatValue];
                e.weaponRawID = [attr[@"wid"] unsignedLongLongValue];
                if (e.weaponRawID) {
                    e.weaponId = (int)((e.weaponRawID / 10000000ULL) % 1000ULL);
                }
                e.name = attr[@"name"];
                MFApplyUEHeroAttributes(e, attr);
                MFApplyUENPCAttributes(e, attr);
                MFApplyUEEquipmentAttributes(e, attr);
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
                float d = MFUECameraValidation::NormalizeDegrees(targetYaw - camera.yaw);
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
    // A zero legacy offset leaves the already decoded SDK value intact.
    if (!p) return;

    if (p.entityIsBotOffset) {
        int v = [rb readInt32:e.address + p.entityIsBotOffset];
        e.isBot = MFHeroNames::UsesBotHUD(v != 0, e.expertID);
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
        int32_t v = -1;
        e.health = -1; e.maxHealth = 0;
        if ([rb readRemote:e.address + p.entityHealthOffset into:&v size:sizeof(v)] &&
            v >= kMFHealthMin && v <= kMFHealthMax) {
            e.health = v;
            e.maxHealth = kMFHealthMax; // Calibrated legacy profile explicitly uses a 0..100 scale.
        }
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

    /* [M5.209] 与实体循环同样的熔断：基址失效时不要跑满 count 次无效读 */
    /* [M5.212] 物资也给一份小预算：地面物品多的时候不能把主线程吃光 */
    const CFTimeInterval lootBudgetEnd = CFAbsoluteTimeGetCurrent() + 0.0015;
    int consecutiveMisses = 0;
    for (int i = 0; i < count; i++) {
        if ((i & 7) == 0 && CFAbsoluteTimeGetCurrent() > lootBudgetEnd) {
            if (_lootBudgetCuts < 3) {
                _lootBudgetCuts++;
                MFHUDLogLine(@"物资读取触顶 1.5ms 预算：已读 %d/%d（第 %u 次）",
                             i, count, _lootBudgetCuts);
            }
            break;
        }
        @autoreleasepool {
            uint64_t item = [rb readU64:base + 0x8 * (uint64_t)i];
            if (!item) { if (++consecutiveMisses > 64) break; continue; }

            MFEntity *e = [[MFEntity alloc] init];
            e.address = item;
            e.isLoot = YES;

            // 价值：4 字节。读失败 / 长度为 4 但不为 0 → 跳过（对齐原实现）
            int32_t value = 0;
            if (off.current.lootValueOffset &&
                ![rb readRemote:item + off.current.lootValueOffset into:&value size:4]) {
                if (++consecutiveMisses > 64) break;
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
                if (++consecutiveMisses > 64) break;
                continue;
            }
            consecutiveMisses = 0;
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

#pragma mark - 对局切换

/*
 * [M5.209] 判断是否换到了下一局，并把过期的绝对基址作废。
 *
 * 为什么必须有这一步：
 *   现在的缓存隔离是按「进程实例」算的（pid | 路径 | 启动时间）。换局时
 *   进程没变、启动时间没变，令牌就不变，于是 rootObjectBase / entityArrayBase /
 *   lootArrayBase 这些绝对地址仍然被当成有效 —— 但它们指向的 UWorld / ULevel /
 *   Actors 已经被游戏整套换掉了。
 *
 *   后果不是"读不到"这么温和：
 *     · readCamera 可能从旧地址凑出一组看似合法的相机数值 → cameraOK = YES
 *     · 绘制层因此不会回退到自动 UE4 链，直接用了失效的实体数组
 *     · 实体循环把旧数组当指针数组逐个解引用，几千次无效内核读 → 卡顿甚至卡死
 *   表现出来正是「打完一局进下一局，画面没了、HUD 也卡住」。
 *
 * 判据用 GWorld 静态槽读出的世界指针：换局必换 UWorld，而 libBase 不变，
 * 所以这个槽是干净的换局信号。非法值（0 / 窗口外）由 noteWorldPointer 忽略，
 * 加载动画期间的瞬时 0 不会误判。
 */
- (BOOL)refreshMatchEpoch {
    MFReadBackend *rb = [MFReadBackend shared];
    MFUEReader *ue = [MFUEReader shared];
    const uint64_t lib = ue.libBase;
    if (lib == 0) return NO;

    // GWorld 静态槽：libBase + gworldStaticOffset（与 MFUEReader.resolve 同一来源）
    const uint64_t world = [rb readU64:lib + ue.profile.gworldStaticOffset];
    const uint64_t before = rb.matchEpoch;
    [rb noteWorldPointer:world];
    if (rb.matchEpoch == before) return NO;

    [self clearBasesWithStatus:@"局已切换（世界指针变化，旧绝对基址作废；自动链会重新解析）"];
    return YES;
}

#pragma mark - 一次性

- (NSDictionary *)readFrameWithSize:(CGSize)size {
    const BOOL matchChanged = [self refreshMatchEpoch];
    MFCamera cam = {0};
    BOOL ok = [self readCamera:&cam];
    MFScreen sc = [MFProjection screenWithSize:size fov:cam.fov];

    NSArray<MFEntity *> *ents = ok ? [self readEntitiesWithCamera:cam screen:sc] : @[];
    NSArray<MFEntity *> *loot = ok ? [self readLootWithCamera:cam screen:sc] : @[];

    return @{
        @"cameraOK": @(ok),
        @"matchChanged": @(matchChanged),
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
