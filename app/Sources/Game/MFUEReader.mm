#import "MFUEReader.h"
#import "MFSettings.h"                 /* [M5.150] 队友开关 */

/* [M5.155] 供 MFGameReader（真正用于绘制的实体循环）使用的本地玩家信息 */
uint64_t gMFUELocalPawn = 0;
uint64_t gMFUELocalMesh = 0;
uint32_t gMFUELocalTeam = 0;
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
    /*
     * ★ [M5.173] Pawn 不再是致命步骤。
     *
     * 死亡 / 观战 / 换人 / 重生的一两秒里 Pawn 会短暂为 0 或非法。旧代码用 MFUE_STEP
     * 把它当"链断"直接返回，于是那段时间【相机和 Actors 明明都能读，整屏却什么都不画】
     * —— 这就是"一下子有效果一下子没有"的主要来源之一。
     * 现在：Pawn 读不到只让"自己是谁"退化（自过滤改用距离兜底），不影响出图。
     */
    r.pawn = [rb readU64:r.playerController + p.controller_pawn];
    [r.trace addObject:[NSString stringWithFormat:
        @"PlayerController+0x%X → Pawn = 0x%llx%@", p.controller_pawn, r.pawn,
        MFUEIsValidPtr(r.pawn) ? @"" : @"（非法 → 自过滤退化为距离兜底，本帧照常出图）"]];
    MFUE_STEP(cameraManager,     r.playerController + p.controller_cameraManager, @"PlayerController+0x%X → CameraManager", p.controller_cameraManager);

    /*
     * ④ 队伍（非致命）—— 这条链的命名是历史遗留：
     *     Pawn + 0x10C0     = AGPCharacterBase::TeamComp（UGPTeamComponent*），不是 PlayerState；
     *     TeamComp + 0x108  = UGPTeamComponent::TeamID。
     * 两跳算下来正好落在真字段上，所以功能是对的，只是名字骗人。
     */
    r.playerState = [rb readU64:r.pawn + p.pawn_playerState];

    /* [M5.155] 把本地 Pawn / 队伍号交给 MFGameReader（绘制走的是它的实体循环） */
    gMFUELocalPawn = r.pawn;
    gMFUELocalMesh = 0;
    if (MFUEIsValidPtr(r.pawn)) {
        uint64_t lm = 0;
        if ([rb readU64:r.pawn + 0x3D0 out:&lm]) gMFUELocalMesh = lm;
    }
    gMFUELocalTeam = 0;
    if (MFUEIsValidPtr(r.playerState)) {
        uint32_t teamLocal = 0;
        if ([rb readRemote:r.playerState + p.playerState_teamID into:&teamLocal size:4]) {
            gMFUELocalTeam = teamLocal;
        }
    }
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

/*
 * 读一处 POV（FMinimalViewInfo 前 0x20 字节）：
 *     +0x00 FEncVector Location（16 字节，X/Y/Z + handler）
 *     +0x10 FRotator  Rotation（Pitch/Yaw/Roll）
 *     +0x1C float     FOV
 * 先一次性读 32 字节；失败就拆成 16/12/4 三段 —— 段越小越不容易因跨页整块失败。
 */
static BOOL MFUEReadPOV(MFReadBackend *rb, uint64_t pov, float out[8]) {
    memset(out, 0, sizeof(float) * 8);
    if ([rb readRemote:pov into:out size:32]) return YES;

    float loc[4] = {0}, rot[3] = {0}, fov = 0.0f;
    if (![rb readRemote:pov           into:loc size:16]) return NO;
    if (![rb readRemote:pov + 0x10    into:rot size:12]) return NO;
    if (![rb readRemote:pov + 0x1C    into:&fov size:4]) return NO;
    memcpy(out,      loc, sizeof(loc));
    memcpy(out + 4,  rot, sizeof(rot));
    out[7] = fov;
    return YES;
}

/* 8 个 float → MFCamera，并做角度归一化与合法性校验 */
static BOOL MFUEBuildCamera(const float f[8], MFCamera *out) {
    MFCamera c = {0};
    c.x = f[0]; c.y = f[1]; c.z = f[2];        /* f[3] = EncHandler，忽略 */
    c.pitch = f[4]; c.yaw = f[5]; c.roll = f[6];
    c.fov = f[7];

    /* FRotator::Yaw 可能已经是 -180..180，也可能是 0..360 —— 先归一化再判 */
    while (c.yaw   >  180.0f) c.yaw   -= 360.0f;
    while (c.yaw   < -180.0f) c.yaw   += 360.0f;
    while (c.pitch >  180.0f) c.pitch -= 360.0f;
    while (c.pitch < -180.0f) c.pitch += 360.0f;
    while (c.roll  >  180.0f) c.roll  -= 360.0f;
    while (c.roll  < -180.0f) c.roll  += 360.0f;

    if (!isfinite(c.x) || !isfinite(c.y) || !isfinite(c.z)) return NO;
    if (fabsf(c.x) > 1e6f || fabsf(c.y) > 1e6f || fabsf(c.z) > 1e6f) return NO;
    if (!(c.fov >= kMFUE_POV_FovMin && c.fov <= kMFUE_POV_FovMax)) return NO;
    if (!(c.pitch >= -90.5f && c.pitch <= 90.5f)) return NO;

    if (out) *out = c;
    return YES;
}

- (BOOL)readCamera:(MFCamera *)out result:(MFUEResolveResult *)r {
    MFReadBackend *rb = [MFReadBackend shared];

    if (!MFUEIsValidPtr(r.cameraManager)) return NO;

    /*
     * ★ [M5.177] 双源 + 小读 + 分段兜底 ★
     *
     * 真机症状：屏幕「闪一下能画、然后长时间空白」。日志每 10 秒一条
     * 「相机读不出来（CameraCacheEntry 扫描没命中）」—— 限流后的持久失败。
     * KFD 本身没问题（同一条日志里 GWorld/Level/Actors 每 3 秒都读得到）。
     *
     * 三处加固：
     *   ① 两个相机字段都试：+0x2D60 CameraCachePrivate、+0x37B0 LastFrameCameraCachePrivate
     *      （SDK Engine_classes.hpp 里都是 FCameraCacheEntry）；
     *   ② 一次只读 32 字节（Location 16 + Rotation 12 + FOV 4），不再读 48；
     *      失败再拆成 16/12/4 三段读 —— 段小，跨页/页未映射时更容易成功；
     *   ③ 两处都不行时，把原始 8 个 float 打进日志，用来区分
     *      「读不到」（sawData=0）还是「读到了但校验不过」（raw 有值）。
     */
    static const uint32_t kSources[2] = {
        kMFUE_CameraManager_CacheEntry,          // 0x2D60
        kMFUE_CameraManager_LastCacheEntry,      // 0x37B0
    };

    float f[8] = {0};
    float lastBad[8] = {0};
    uint64_t pov0 = r.cameraManager + kSources[0] + kMFUE_CameraCache_POV;
    uint64_t pov1 = r.cameraManager + kSources[1] + kMFUE_CameraCache_POV;
    BOOL sawData = NO;
    int  okSource = -1;
    MFCamera cam = {0};

    for (int i = 0; i < 2; i++) {
        const uint64_t pov = (i == 0) ? pov0 : pov1;
        if (!MFUEReadPOV(rb, pov, f)) continue;
        sawData = YES;
        if (MFUEBuildCamera(f, &cam)) { okSource = i; break; }
        memcpy(lastBad, f, sizeof(lastBad));
    }

    if (okSource < 0) {
        static CFTimeInterval lastFailLog = 0;
        const CFTimeInterval nowLog = CACurrentMediaTime();
        if (nowLog - lastFailLog > 5.0) {
            lastFailLog = nowLog;
            NSLog(@"[MF][UE] 相机失败 cm=0x%llx pov0=0x%llx pov1=0x%llx sawData=%d "
                  @"raw=[%.3f %.3f %.3f %.3f | %.3f %.3f %.3f | fov=%.3f]",
                  (unsigned long long)r.cameraManager,
                  (unsigned long long)pov0, (unsigned long long)pov1, (int)sawData,
                  lastBad[0], lastBad[1], lastBad[2], lastBad[3],
                  lastBad[4], lastBad[5], lastBad[6], lastBad[7]);
        }
        return NO;
    }

    if (out) *out = cam;
    static CFTimeInterval lastOKLog = 0;
    const CFTimeInterval nowOK = CACurrentMediaTime();
    if (nowOK - lastOKLog > 5.0) {            /* [M5.173] 限流：每 5 秒一行 */
        lastOKLog = nowOK;
        NSLog(@"[MF][UE] 相机(src%d): loc(%.1f,%.1f,%.1f) rot(%.2f,%.2f,%.2f) fov=%.1f",
              okSource, cam.x, cam.y, cam.z, cam.pitch, cam.yaw, cam.roll, cam.fov);
    }
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

            /* [M5.153] 死人：actor+0xDC8 首字节非 0（分析报告剔除表 §4） */
            {
                uint8_t dead = 0;
                if ([rb readRemote:actor + kMFUE_Actor_DeadFlag into:&dead size:1] && dead != 0) {
                    continue;
                }
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

                /* [M5.153] 观战 / 未激活：PlayerState+0x4C0 的 bit0（剔除表 §5） */
                if (havePS) {
                    uint8_t inactive = 0;
                    if ([rb readRemote:ps + kMFUE_PlayerState_Remove into:&inactive size:1] &&
                        (inactive & 1)) {
                        continue;
                    }
                }

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
                if (myTeam != 0 && teamVal == myTeam && havePS &&
                    ![MFSettings shared].showTeammates) {
                    continue;      /* 队友：默认不画，菜单里可开（人机不受影响） */
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
                        /*
                         * [M5.149] 宽松读：480 字节很容易跨到未映射页，
                         * 严格读一旦失败整段作废 —— 这就是头甲一直显示 "头- 甲- 包-" 的原因。
                         */
                        uint8_t rawSlots[kMFUE_Equip_SlotCount * kMFUE_Equip_SlotStride];
                        size_t gotSlots = [rb readRemotePartial:slots
                                                           into:rawSlots
                                                           size:sizeof(rawSlots)];
                        if (gotSlots >= kMFUE_Equip_SlotStride) {
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
