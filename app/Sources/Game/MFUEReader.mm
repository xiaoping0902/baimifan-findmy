#import "MFUEReader.h"
#import "Offsets.h"                       /* kMF_Deg2Rad / kMFBehindAngleDeg 等常量在这 */
#import "../Read/MFReadBackend.h"
#include <math.h>
#include <stdlib.h>    /* calloc / free —— 宽松读要清零 */
#include <string.h>    /* memcpy —— 装备槽解析 */
#include <stdio.h>     /* snprintf —— 物品 ID 十进制解码 */

@implementation MFUEResolveResult
- (instancetype)init {
    if ((self = [super init])) { _trace = [NSMutableArray array]; }
    return self;
}
@end

static NSString *gUEReport = nil;

@implementation MFUEReader

+ (instancetype)shared {
    static MFUEReader *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[MFUEReader alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _profile = [MFUEProfile loadFromDefaults];
    }
    return self;
}

+ (NSString *)lastReport { return gUEReport ?: @"（还没有执行过 UE4 链解析）"; }

#pragma mark - 链解析

- (MFUEResolveResult *)resolve {
    MFUEResolveResult *r = [[MFUEResolveResult alloc] init];
    MFReadBackend *rb = [MFReadBackend shared];
    MFUEProfile *p = self.profile;

#define MFUE_STEP(field, addrExpr, labelFmt, ...)                            \
    do {                                                                     \
        r.field = [rb readU64:(addrExpr)];                                   \
        [r.trace addObject:[NSString stringWithFormat:                        \
            @"%@ = 0x%llx", [NSString stringWithFormat:labelFmt, ##__VA_ARGS__], \
            (unsigned long long)r.field]];                                   \
        if (!MFUEIsValidPtr(r.field)) {                                      \
            r.brokenAt = [NSString stringWithFormat:@"%@（值 0x%llx 不是合法指针）", \
                          [NSString stringWithFormat:labelFmt, ##__VA_ARGS__],   \
                          (unsigned long long)r.field];                      \
            return r;                                                        \
        }                                                                    \
    } while (0)

    // ① 前置：模块基址
    r.libBase = self.libBase;
    if (r.libBase == 0) {
        r.brokenAt = @"模块基址为 0 —— 先做「模块定位」";
        [r.trace addObject:r.brokenAt];
        return r;
    }
    [r.trace addObject:[NSString stringWithFormat:@"libBase = 0x%llx", r.libBase]];

    // ② GWorld = Read<u64>(libBase + 静态偏移)
    uint64_t gwAddr = r.libBase + p.gworldStaticOffset;
    r.gworld = [rb readU64:gwAddr];
    [r.trace addObject:[NSString stringWithFormat:
        @"GWorld = Read(0x%llx + 0x%llX) = 0x%llx",
        r.libBase, p.gworldStaticOffset, r.gworld]];
    if (!MFUEIsValidPtr(r.gworld)) {
        r.brokenAt = [NSString stringWithFormat:
            @"GWorld 不是合法指针（0x%llx）—— 静态偏移 0x%llX 可能已随版本失效",
            r.gworld, p.gworldStaticOffset];
        return r;
    }

    // ③ 本地玩家链（对齐 RefreshControllerChain @ 0x100010b3c）
    MFUE_STEP(gameInstance,      r.gworld + p.world_gameInstance,          @"UWorld+0x%X → GameInstance", p.world_gameInstance);
    MFUE_STEP(localPlayers,      r.gameInstance + p.gameInstance_localPlayers, @"GameInstance+0x%X → LocalPlayers", p.gameInstance_localPlayers);
    MFUE_STEP(localPlayer,       r.localPlayers,                            @"LocalPlayers[0] → ULocalPlayer");
    MFUE_STEP(playerController,  r.localPlayer + p.localPlayer_controller,  @"ULocalPlayer+0x%X → PlayerController", p.localPlayer_controller);
    MFUE_STEP(pawn,              r.playerController + p.controller_pawn,    @"PlayerController+0x%X → Pawn", p.controller_pawn);
    MFUE_STEP(cameraManager,     r.playerController + p.controller_cameraManager, @"PlayerController+0x%X → CameraManager", p.controller_cameraManager);

    /*
     * ④ 队伍（非致命）—— 这条链的命名是历史遗留：
     *     Pawn + 0x10C0     = AGPCharacterBase::TeamComp（UGPTeamComponent*），不是 PlayerState；
     *     TeamComp + 0x108  = UGPTeamComponent::TeamID。
     * 两跳算下来正好落在真字段上，所以功能是对的，只是名字骗人。
     */
    r.playerState = [rb readU64:r.pawn + p.pawn_playerState];
    if (MFUEIsValidPtr(r.playerState)) {
        r.teamID = [rb readInt32:r.playerState + p.playerState_teamID];
        [r.trace addObject:[NSString stringWithFormat:
            @"Pawn+0x%X → TeamComp = 0x%llx，+0x%X → TeamID = %d",
            p.pawn_playerState, r.playerState, p.playerState_teamID, r.teamID]];
    } else {
        r.teamID = 0;
        [r.trace addObject:[NSString stringWithFormat:
            @"Pawn+0x%X → TeamComp 非法（0x%llx），队伍功能跳过",
            p.pawn_playerState, r.playerState]];
    }

    // ⑤ 敌人列表（对齐 GetEnemyThread 的遍历）
    r.level = [rb readU64:r.gworld + p.world_persistentLevel];
    [r.trace addObject:[NSString stringWithFormat:
        @"UWorld+0x%X → ULevel = 0x%llx", p.world_persistentLevel, r.level]];
    if (!MFUEIsValidPtr(r.level)) {
        r.brokenAt = [NSString stringWithFormat:
            @"UWorld+0x%X → ULevel 非法（0x%llx）", p.world_persistentLevel, r.level];
        return r;
    }

    r.actorsData = [rb readU64:r.level + p.level_actorsData];
    r.actorsNum  = [rb readInt32:r.level + p.level_actorsNum];
    [r.trace addObject:[NSString stringWithFormat:
        @"ULevel+0x%X → Actors.Data = 0x%llx，+0x%X → Num = %d",
        p.level_actorsData, r.actorsData, p.level_actorsNum, r.actorsNum]];

    // 数量判据（对齐原文 if (v16 - 1 <= 0xFFF)）
    if (r.actorsNum <= 0 || r.actorsNum > kMFUE_ActorsMax) {
        r.brokenAt = [NSString stringWithFormat:
            @"Actors 数量异常（%d，允许 1..%d）", r.actorsNum, kMFUE_ActorsMax];
        return r;
    }
    if (!MFUEIsValidPtr(r.actorsData)) {
        r.brokenAt = [NSString stringWithFormat:@"Actors.Data 非法（0x%llx）", r.actorsData];
        return r;
    }

    r.brokenAt = nil;
    return r;

#undef MFUE_STEP
}

#pragma mark - 相机

- (BOOL)readCamera:(MFCamera *)out result:(MFUEResolveResult *)r {
    MFReadBackend *rb = [MFReadBackend shared];

    if (!MFUEIsValidPtr(r.cameraManager)) return NO;

    /*
     * [M5.135] 固定偏移，不再扫描。
     *
     *     APlayerCameraManager + 0x2D60  FCameraCacheEntry
     *         + 0x10                    FMinimalViewInfo POV
     *             +0x00  Location  (FEncVector：X,Y,Z,handler)
     *             +0x10  Rotation  (Pitch,Yaw,Roll)
     *             +0x1C  FOV
     *
     * 一次 48 字节读够用：readCameraStruct 返回 12 个 float，正好覆盖
     * Location(4) + Rotation(3) + FOV + DesiredFOV + 正交参数。
     * FEncVector 的 handler 在 f[3]，数值本身是明文（DecVector 只做原样拷贝）。
     */
    const uint64_t pov = r.cameraManager + kMFUE_CameraManager_CacheEntry
                                      + kMFUE_CameraCache_POV;
    float f[12] = {0};
    if (![rb readCameraStruct:pov out:f]) {
        NSLog(@"[MF][UE] 相机读失败 pov=0x%llx（CameraManager=0x%llx）",
              (unsigned long long)pov, (unsigned long long)r.cameraManager);
        return NO;
    }

    MFCamera c = {0};
    c.x = f[0]; c.y = f[1]; c.z = f[2];                 /* f[3] = EncHandler，忽略 */
    c.pitch = f[4]; c.yaw = f[5]; c.roll = f[6];
    c.fov = f[7];

    /* 校验：坐标必须有限且量级合理；角度与 FOV 必须落在物理范围内。
     * 读错页时通常得到 0 或垃圾，这两组判据足以拒掉。 */
    if (!isfinite(c.x) || !isfinite(c.y) || !isfinite(c.z)) return NO;
    if (fabsf(c.x) > 1e6f || fabsf(c.y) > 1e6f || fabsf(c.z) > 1e6f) return NO;
    if (!(c.fov >= kMFUE_POV_FovMin && c.fov <= kMFUE_POV_FovMax)) return NO;
    if (!(c.pitch >= -90.5f && c.pitch <= 90.5f)) return NO;
    if (!(c.yaw >= -180.5f && c.yaw <= 180.5f)) return NO;

    if (out) *out = c;
    NSLog(@"[MF][UE] 相机: loc(%.1f,%.1f,%.1f) rot(%.2f,%.2f,%.2f) fov=%.1f",
          c.x, c.y, c.z, c.pitch, c.yaw, c.roll, c.fov);
    return YES;
}

#pragma mark - 敌人

- (NSArray<MFEntity *> *)enumerateActors:(MFUEResolveResult *)r
                                  camera:(MFCamera)camera
                                  screen:(MFScreen)screen {
    NSMutableArray<MFEntity *> *out = [NSMutableArray array];
    if (r.brokenAt != nil || r.actorsNum <= 0) return out;

    MFReadBackend *rb = [MFReadBackend shared];
    MFUEProfile *p = self.profile;

    /* [M5.146] 自己的队伍（用于"同队不画"）—— 人机没有 PlayerState，不受影响 */
    uint32_t myTeam = 0;
    if (MFUEIsValidPtr(r.pawn)) {
        uint64_t myTC = 0;
        if ([rb readU64:r.pawn + p.pawn_playerState out:&myTC] && MFUEIsValidPtr(myTC)) {
            (void)[rb readRemote:myTC + p.playerState_teamID into:&myTeam size:4];
        }
    }

    /* ★ 批量读整个指针数组（对齐原实现）：
     *   mingyun 原文：sw533...(sGamePid, v15, vActors, 8 * v16);
     *   一次系统调用拿 N 个指针，比逐个读快几十倍 —— 也大幅减少读取痕迹。
     */
    /*
     * [M5.135] 宽松读：指针数组可能跨到未映射页，旧写法一处失败就整批归零。
     * calloc 先清零 —— 没读到的槽保持 0，后面 MFUEIsValidPtr 会自然跳过。
     */
    size_t bytes = (size_t)r.actorsNum * 8;
    uint64_t *ptrs = (uint64_t *)calloc((size_t)r.actorsNum, sizeof(uint64_t));
    if (ptrs == NULL) return out;
    size_t got = [rb readRemotePartial:r.actorsData into:ptrs size:bytes];
    int usable = (int)(got / sizeof(uint64_t));
    if (usable <= 0) {
        free(ptrs);
        return out;
    }

    for (int i = 0; i < usable; i++) {
        @autoreleasepool {
            uint64_t actor = ptrs[i];
            if (!MFUEIsValidPtr(actor)) continue;

            /*
             * [M5.138] 跳过自己。
             * r.pawn 是 PlayerController+controller_pawn（AController::Pawn）读出来的本机 Pawn，
             * 它同样躺在 ULevel::Actors 里。以前不过滤，结果给自己也画框、还画一条指向屏幕
             * 底部的射线，背敌提示里那个"1m"多半也是自己。
             */
            if (r.pawn != 0 && actor == r.pawn) continue;

            /*
             * ★ [M5.139] 隐藏 / 待销毁的 Actor 不画 —— 这就是"空气框"的来源。
             *
             * 靶场里的隐形靶、已经销毁但还挂在 Actors 数组里的残影，位置全都在，
             * 只是 bHidden 或 bActorIsBeingDestroyed 置位。以前不看这两个标志，
             * 于是屏幕上出现"框在空地上、里面没有人"。
             *
             * 偏移来自 SDK（同版本 1.201.37117）：
             *   AActor::bHidden               @ 0x0090 bit0
             *   AActor::bActorIsBeingDestroyed@ 0x0095 bit1
             * 一次读 16 字节同时覆盖这两个字节。
             */
            uint8_t flags[16] = {0};
            if ([rb readRemote:actor + 0x90 into:flags size:sizeof(flags)]) {
                if (flags[0] & 0x01) continue;   // bHidden
                if (flags[5] & 0x02) continue;   // bActorIsBeingDestroyed
            }

            /*
             * [M5.135] 坐标必须两跳，而且要用世界坐标：
             *     Actor + 0x180        → RootComponent
             *     RootComponent + 0x220 → ComponentToWorld.Translation（世界坐标）
             *
             * 0x220 不是猜的：USceneComponent::K2_GetComponentLocation 的 native
             * 实现就是先取 &ComponentToWorld（+0x210）、再读 +0x10 的 Translation。
             *
             * 旧写法 `actor + 0x220` 少跳了 RootComponent —— 那个偏移在 AActor 里
             * 落在 Pad_1FA[0x76] 的填充区，所以永远读到 0。
             */
            /*
             * ★ [M5.148] 只认「有骨骼的角色」。
             *
             * 子弹、投掷物、箱子、场景物件全都有 RootComponent 和坐标 —— 以前它们
             * 统统被当成"人"画出来，就是你看到的"子弹也有框/到处是空气"。
             * 真正的角色一定有 USkeletalMeshComponent 且骨骼数 ≥ 20。
             */
            {
                uint64_t meshChk = 0, boneDataChk = 0;
                int32_t boneNumChk = 0;
                if (![rb readU64:actor + kMFUE_Character_Mesh out:&meshChk] ||
                    !MFUEIsValidPtr(meshChk)) continue;
                if (![rb readU64:meshChk + 0x750 out:&boneDataChk] ||
                    !MFUEIsValidPtr(boneDataChk)) continue;
                if (![rb readRemote:meshChk + 0x750 + 8 into:&boneNumChk size:4]) continue;
                if (boneNumChk < 20) continue;
            }

            uint64_t rootComp = 0;
            if (![rb readU64:actor + p.actor_rootComponent out:&rootComp]) continue;
            if (!MFUEIsValidPtr(rootComp)) continue;
            float pos[3] = {0};
            if (![rb readFloat3:rootComp + p.scenecomponent_worldLocation out:pos]) continue;

            // 合法性判据（对齐原文 fabsf(x) <= 10000000.0f）
            if (!(fabsf(pos[0]) <= kMFUE_PosAbsMax)) continue;
            if (!(fabsf(pos[1]) <= kMFUE_PosAbsMax)) continue;
            if (!(fabsf(pos[2]) <= kMFUE_PosAbsMax)) continue;
            // 全 0 通常是未初始化的对象，不是真目标
            if (pos[0] == 0.0f && pos[1] == 0.0f && pos[2] == 0.0f) continue;

            MFEntity *e = [[MFEntity alloc] init];
            e.address = actor;
            e.worldX = pos[0]; e.worldY = pos[1]; e.worldZ = pos[2];

            float cam[3] = {camera.x, camera.y, camera.z};
            e.distanceMeters = [MFProjection distanceMetersFrom:pos to:cam];
            e.screen = [[MFProjection shared] projectTarget:pos camera:camera screen:screen];
            e.isVisible = e.screen.valid;

            // 方位角（背敌提示用，不依赖游戏字段）
            {
                float dx = pos[0] - camera.x, dy = pos[1] - camera.y;
                float ty = atan2f(dy, dx) / kMF_Deg2Rad;
                float d = ty - camera.yaw;
                while (d >  180.0f) d -= 360.0f;
                while (d < -180.0f) d += 360.0f;
                e.bearingDeg = d;
                e.isBehind = (fabsf(d) > kMFBehindAngleDeg);
            }

            /*
             * ★ [M5.146] 人机 / 队伍（真机验证过的判据）
             *
             * 人机没有 PlayerState（actor+0x390 == 0），真人一定有；
             * 队伍走 Pawn+0x10C0 → UGPTeamComponent+0x108。
             * 实测训练营：自己 team=1、PlayerState 非空；5 个人机 team=0、PlayerState 全空。
             */
            {
                uint32_t teamVal = 0;
                uint64_t tc = 0;
                if ([rb readU64:actor + p.pawn_playerState out:&tc] && MFUEIsValidPtr(tc)) {
                    (void)[rb readRemote:tc + p.playerState_teamID into:&teamVal size:4];
                }
                e.teamId = (int)teamVal;

                uint64_t ps = 0;
                BOOL havePS = [rb readU64:actor + kMFUE_Actor_PlayerState out:&ps] &&
                              MFUEIsValidPtr(ps);
                e.isBot = havePS ? NO : YES;
                if (havePS) {
                    uint64_t uinVal = 0;
                    if ([rb readU64:ps + 0x490 out:&uinVal]) e.uin = uinVal;
                }

                /* [M5.147] 手持武器：+0x4D8 空则用 +0x588（真机实测自己走的就是 0x588） */
                uint64_t combat = 0;
                if ([rb readU64:actor + kMFUE_Actor_CombatComponent out:&combat] &&
                    MFUEIsValidPtr(combat)) {
                    uint64_t wpn = 0;
                    (void)[rb readU64:combat + kMFUE_Combat_WeaponA out:&wpn];
                    if (!MFUEIsValidPtr(wpn)) {
                        (void)[rb readU64:combat + kMFUE_Combat_WeaponB out:&wpn];
                    }
                    if (MFUEIsValidPtr(wpn)) {
                        uint64_t wid = 0;
                        if ([rb readU64:wpn + kMFUE_Weapon_ID out:&wid] && wid > 0) {
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
                if (myTeam != 0 && teamVal == myTeam && havePS) {
                    continue;      /* 队友：不画（人机即使 team 相同也照画） */
                }
            }

            /*
             * ★ [M5.144] 头/甲/包等级：装备槽 → 物品 ID → 十进制解码。
             *
             * 链路（《物资与头甲等级机制》对同版本游戏的反编译）：
             *     actor + 0x24E0 → 装备组件
             *            + 0x1D8 → 槽位数组（10 槽 × 0x30 字节，槽内 +0 是 uint64 物品 ID）
             * ID 十进制编码：第 2~4 位 = 类型码（101 头 / 105 甲 / 108 包），第 8 位 = 等级。
             */
            {
                uint64_t equipComp = 0;
                if ([rb readU64:actor + kMFUE_Pawn_EquipmentComponent out:&equipComp] &&
                    MFUEIsValidPtr(equipComp)) {
                    uint64_t slots = 0;
                    if ([rb readU64:equipComp + kMFUE_Equip_SlotsArray out:&slots] &&
                        MFUEIsValidPtr(slots)) {
                        uint8_t rawSlots[kMFUE_Equip_SlotCount * kMFUE_Equip_SlotStride];
                        if ([rb readRemote:slots into:rawSlots size:sizeof(rawSlots)]) {
                            for (uint32_t s = 0; s < kMFUE_Equip_SlotCount; s++) {
                                uint64_t itemId = 0;
                                memcpy(&itemId, rawSlots + s * kMFUE_Equip_SlotStride,
                                       sizeof(itemId));
                                if (itemId < 10000001ULL || itemId > 0x4A87F317FULL) continue;
                                if (e.equipRawID == 0) e.equipRawID = itemId;

                                char dec[24] = {0};
                                int len = snprintf(dec, sizeof(dec), "%llu",
                                                   (unsigned long long)itemId);
                                if (len < 8) continue;
                                int typeCode = (dec[1] - '0') * 100 + (dec[2] - '0') * 10 + (dec[3] - '0');
                                int level = dec[7] - '0';
                                if (level < 1 || level > 6) continue;
                                switch (typeCode) {
                                    case 101: e.helmetLevel = level;   e.equipKnown = YES; break;
                                    case 105: e.armorLevel = level;    e.armorKnown = YES; e.equipKnown = YES; break;
                                    case 108: e.backpackLevel = level; e.equipKnown = YES; break;
                                    default: break;
                                }
                            }
                        }
                    }
                }
            }

            [out addObject:e];
        }
    }
    free(ptrs);
    return out;
}

#pragma mark - 诊断

- (NSString *)diagnosticReport {
    MFUEResolveResult *r = [self resolve];
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"复刻版 · UE4 链解析\n"];
    [s appendString:@"─────────────────────────────\n\n"];
    [s appendString:[NSString stringWithFormat:@"偏移表：%@\n\n", self.profile]];
    [s appendString:@"逐级结果：\n"];
    for (NSString *t in r.trace) [s appendFormat:@"  %@\n", t];
    [s appendString:@"\n"];

    if (r.brokenAt) {
        [s appendFormat:@"✗ 断在：%@\n\n", r.brokenAt];
        [s appendString:
            @"排查方向：\n"
            @"· 「模块基址为 0」→ 先做「模块定位」\n"
            @"· 「GWorld 不是合法指针」→ 静态偏移 0x178B44E0 随版本失效，需重取\n"
            @"· 「ULevel 非法」→ PersistentLevel 偏移失效\n"
            @"· 「Actors 数量异常」→ 现在读的是 ULevel+0x98/+0xA0；先确认 level 真是 ULevel\n"];
    } else {
        [s appendFormat:
            @"✓ 全链打通\n"
            @"  模块基址 0x%llx\n"
            @"  GWorld    0x%llx\n"
            @"  玩家      0x%llx（Pawn 0x%llx）\n"
            @"  队伍      %d\n"
            @"  Actors    %d 个 @ 0x%llx\n",
            r.libBase, r.gworld, r.playerController, r.pawn,
            r.teamID, r.actorsNum, r.actorsData];

        // 顺手试一下相机
        MFCamera cam = {0};
        NSMutableString *crep = [NSMutableString string];
        [crep appendFormat:@"\n相机：固定偏移 CacheEntry=0x%X  POV=+0x%X\n",
            kMFUE_CameraManager_CacheEntry, kMFUE_CameraCache_POV];
        if ([self readCamera:&cam result:r]) {
            [crep appendFormat:@"✓ loc(%.1f, %.1f, %.1f)  rot(%.2f, %.2f, %.2f)  fov=%.1f\n",
                cam.x, cam.y, cam.z, cam.pitch, cam.yaw, cam.roll, cam.fov];
        } else {
            [crep appendString:@"⚠ 相机没读出来 —— 先确认 CameraManager 有效、POV 所在页已映射\n"];
        }
        [s appendString:crep];
    }

    gUEReport = s;
    return s;
}

@end
