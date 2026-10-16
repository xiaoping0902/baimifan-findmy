#import "MFUEReader.h"
#import "Offsets.h"                       /* kMF_Deg2Rad / kMFBehindAngleDeg 等常量在这 */
#import "../Read/MFReadBackend.h"
#include <math.h>

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

    // ④ 队伍（非致命 —— 读不到不影响绘制）
    r.playerState = [rb readU64:r.pawn + p.pawn_playerState];
    if (MFUEIsValidPtr(r.playerState)) {
        r.teamID = [rb readInt32:r.playerState + p.playerState_teamID];
        [r.trace addObject:[NSString stringWithFormat:
            @"Pawn+0x%X → PlayerState = 0x%llx，+0x%X → TeamID = %d",
            p.pawn_playerState, r.playerState, p.playerState_teamID, r.teamID]];
    } else {
        r.teamID = 0;
        [r.trace addObject:[NSString stringWithFormat:
            @"Pawn+0x%X → PlayerState 非法（0x%llx），队伍功能跳过",
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
 * 在 CameraManager 里扫 CameraCacheEntry 的偏移。
 *
 * 为什么需要「扫」而不是写死：
 *   mingyun 的报告里【没有这个值】—— 它只用到 CameraManager 指针，
 *   没读 POV（它靠的是投影时另外找相机）。所以这个偏移我们没有现成来源。
 *
 * 为什么扫得动：
 *   FMinimalViewInfo 的布局是 UE4 引擎级的（跨平台、跨版本基本稳定）：
 *       +0x00  FVector  Location   3×float   —— 世界坐标，量级 1e3~1e5
 *       +0x0C  FRotator Rotation   3×float   —— Pitch ∈ [-90,90]、Yaw ∈ [-180,180]
 *       +0x18  float    FOV                  —— 通常 30~120
 *   三段同时成立的偏移极少 → 这个判据是【自验证】的。
 *
 * 代价：只读 CameraManager 起始的 0x2000 字节（一次读），不会伤设备。
 */
- (uint32_t)scanCameraCacheOffset:(uint64_t)cameraManager
                           report:(NSMutableString *)rep {
    const uint32_t kScanSize = 0x2000;
    const uint32_t kStep     = 4;          // UE 结构体按 4/8 对齐，4 步进不会漏

    if (!MFUEIsValidPtr(cameraManager)) {
        if (rep) [rep appendString:@"  ✗ CameraManager 指针非法，跳过扫描\n"];
        return 0;
    }

    MFReadBackend *rb = [MFReadBackend shared];
    uint8_t *buf = (uint8_t *)malloc(kScanSize);
    if (buf == NULL) return 0;
    BOOL ok = [rb readRemote:cameraManager into:buf size:kScanSize];
    if (!ok) {
        free(buf);
        if (rep) [rep appendString:@"  ✗ 读 CameraManager 失败\n"];
        return 0;
    }

    uint32_t hits = 0;
    uint32_t first = 0;
    for (uint32_t off = 0; off + kMFUE_POV_Size <= kScanSize; off += kStep) {
        float *f = (float *)(buf + off);
        float lx = f[0], ly = f[1], lz = f[2];
        float pitch = f[3], yaw = f[4], roll = f[5];
        float fov = f[6];

        // 坐标段：非零、有限、量级合理
        if (!(fabsf(lx) > 1.0f && fabsf(lx) < 1e6f)) continue;
        if (!(fabsf(ly) > 1.0f && fabsf(ly) < 1e6f)) continue;
        if (!(fabsf(lz) > 1.0f && fabsf(lz) < 1e6f)) continue;
        // 角度段：Pitch 必须落在 ±90，Yaw 必须在 ±180 —— 这两条最有辨识度
        if (!(pitch >= -90.5f && pitch <= 90.5f)) continue;
        if (!(yaw   >= -180.5f && yaw  <= 180.5f)) continue;
        if (!(roll  >= -180.5f && roll <= 180.5f)) continue;
        // FOV
        if (!(fov >= kMFUE_POV_FovMin && fov <= kMFUE_POV_FovMax)) continue;

        hits++;
        if (first == 0) {
            first = off;
            if (rep) [rep appendFormat:
                @"  ✓ 候选 @ +0x%X : loc(%.1f, %.1f, %.1f) rot(%.2f, %.2f, %.2f) fov=%.1f\n",
                off, lx, ly, lz, pitch, yaw, roll, fov];
        }
    }
    free(buf);

    if (rep) [rep appendFormat:@"  扫描完成：%u 个候选（步进 %u 字节，范围 0x%X）\n",
              hits, kStep, kScanSize];

    if (hits == 0) return 0;

    /* 多于一个候选时：取第一个。
     * 理由：CameraCacheEntry 在 APlayerCameraManager 里通常排得很靠前，
     *      而且它的三段时间全部命中判据，后面偶然命中的概率低于它。
     * 若真机验证不对，改这里或用 report 里的候选列表手工指定。 */
    if (hits > 1 && rep) [rep appendString:@"  ⚠ 多个候选，取第一个（可用诊断报告人工核对）\n"];
    return first;
}

- (BOOL)readCamera:(MFCamera *)out result:(MFUEResolveResult *)r {
    MFUEProfile *p = self.profile;
    MFReadBackend *rb = [MFReadBackend shared];

    if (!MFUEIsValidPtr(r.cameraManager)) return NO;

    uint32_t cacheOff = p.cameraManager_cacheEntry;
    if (cacheOff == 0) {
        NSMutableString *rep = [NSMutableString stringWithString:@"[相机偏移扫描]\n"];
        cacheOff = [self scanCameraCacheOffset:r.cameraManager report:rep];
        NSLog(@"[MF][UE] %@", rep);
        if (cacheOff == 0) return NO;
        p.cameraManager_cacheEntry = cacheOff;
        [p saveToDefaults];          // 扫到就记下来，下次不用重扫
    }

    uint64_t povAddr = r.cameraManager + cacheOff;
    // FCameraCacheEntry 头 4 字节是 float TimeStamp，所以要再跳一层
    // 已知 mingyun 未提供该值 → 先按「cacheOff 直接就是 POV」试，
    // 失败再试 +0x4（TimeStamp 在前）。
    for (int shift = 0; shift <= 1; shift++) {
        uint64_t a = povAddr + (shift ? 4 : 0);
        MFCamera c = {0};
        if (![rb readRemote:a + kMFUE_POV_Location into:&c.x size:4]) continue;
        [rb readRemote:a + kMFUE_POV_Location + 4  into:&c.y size:4];
        [rb readRemote:a + kMFUE_POV_Location + 8  into:&c.z size:4];
        [rb readRemote:a + kMFUE_POV_Rotation      into:&c.pitch size:4];
        [rb readRemote:a + kMFUE_POV_Rotation + 4  into:&c.yaw   size:4];
        [rb readRemote:a + kMFUE_POV_Rotation + 8  into:&c.roll  size:4];
        [rb readRemote:a + kMFUE_POV_FOV           into:&c.fov   size:4];

        // 校验：过不了就当这次 shift 不对
        if (!(fabsf(c.x) > 1.0f && fabsf(c.x) < 1e6f)) continue;
        if (!(c.fov >= kMFUE_POV_FovMin && c.fov <= kMFUE_POV_FovMax)) continue;
        if (!(c.pitch >= -90.5f && c.pitch <= 90.5f)) continue;

        if (out) *out = c;
        NSLog(@"[MF][UE] 相机: cacheOff=0x%X shift=%d loc(%.1f,%.1f,%.1f) "
              @"rot(%.2f,%.2f,%.2f) fov=%.1f",
              cacheOff, shift, c.x, c.y, c.z, c.pitch, c.yaw, c.roll, c.fov);
        return YES;
    }
    return NO;
}

#pragma mark - 敌人

- (NSArray<MFEntity *> *)enumerateActors:(MFUEResolveResult *)r
                                  camera:(MFCamera)camera
                                  screen:(MFScreen)screen {
    NSMutableArray<MFEntity *> *out = [NSMutableArray array];
    if (r.brokenAt != nil || r.actorsNum <= 0) return out;

    MFReadBackend *rb = [MFReadBackend shared];
    MFUEProfile *p = self.profile;

    /* ★ 批量读整个指针数组（对齐原实现）：
     *   mingyun 原文：sw533...(sGamePid, v15, vActors, 8 * v16);
     *   一次系统调用拿 N 个指针，比逐个读快几十倍 —— 也大幅减少读取痕迹。
     */
    size_t bytes = (size_t)r.actorsNum * 8;
    uint64_t *ptrs = (uint64_t *)malloc(bytes);
    if (ptrs == NULL) return out;
    if (![rb readRemote:r.actorsData into:ptrs size:bytes]) {
        free(ptrs);
        return out;
    }

    for (int i = 0; i < r.actorsNum; i++) {
        @autoreleasepool {
            uint64_t actor = ptrs[i];
            if (!MFUEIsValidPtr(actor)) continue;

            float pos[3] = {0};
            if (![rb readFloat3:actor + p.actor_worldPos out:pos]) continue;

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
            @"· 「Actors 数量异常」→ 可能读到的是别的结构\n"];
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
        [crep appendFormat:@"\n相机：cacheEntry 偏移 = 0x%X%@\n",
            self.profile.cameraManager_cacheEntry,
            self.profile.cameraManager_cacheEntry ? @"" : @"（未校准，将自动扫描）"];
        if ([self readCamera:&cam result:r]) {
            [crep appendFormat:@"✓ loc(%.1f, %.1f, %.1f)  rot(%.2f, %.2f, %.2f)  fov=%.1f\n",
                cam.x, cam.y, cam.z, cam.pitch, cam.yaw, cam.roll, cam.fov];
        } else {
            [crep appendString:@"⚠ 相机没读出来 —— 先手动跑一次「相机偏移扫描」看候选列表\n"];
        }
        [s appendString:crep];
    }

    gUEReport = s;
    return s;
}

@end
