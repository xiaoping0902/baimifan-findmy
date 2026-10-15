//
//  MFUEOffsets.h — UE4 对象图偏移表
//
//  ── 来源（全部是反编译原文，不是推断）──
//
//  样本：mingyun 2.0.4 —— 三角洲行动 iOS 版 ESP
//        SHA-256 5383b9759685dd5fd2b89123093db277f6cdc14a8b9cbde7ef2b7a470ead75a1
//        二进制 SHA-256 ac5e622d24a13768f5466366e13dbefd32661fb8b133696236dcbe298c2bee61
//
//  取证位置：
//    · RefreshControllerChain  @ 0x100010b3c   → 本地玩家链
//    · GetEnemyThread          @ 0x100010c0c   → GWorld 定位 + 敌人遍历
//    · ESPReadMeshWorldPos     @ 0x1000118ac   → 世界坐标
//
//  ── 交叉验证 ──
//
//  白米饭的「根指针链」是：0x98 → 0x30 → 0x408 → 0x3A0 → 0x10C0 → 0x108 → 0xF8
//  对照 mingyun：
//      0x30   = ULocalPlayer + 0x30      → PlayerController       ✅
//      0x408  = PlayerController + 0x408 → PlayerCameraManager    ✅
//      0x3A0  = PlayerController + 0x3A0 → AcknowledgedPawn       ✅
//      0x10C0 = Pawn + 0x10C0            → PlayerState            ✅
//      0x108  = PlayerState + 0x108      → 阵营/队伍 ID           ✅
//      0xF8   = UWorld + 0xF8            → PersistentLevel        ✅
//      0x220  = AActor + 0x220           → FVector 世界坐标       ✅
//
//  **7 个偏移全部命中。** 两个作者用的是同一套 UE4 偏移。
//
//  ── 版本风险（必须记住）──
//
//  这些都是「游戏当前版本」的偏移。游戏一更新就可能变。
//  所以本文件里的每个值都做成【运行时可改】，而不是硬编码常量。
//
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 默认值（mingyun 2.0.4 反编译原文）

/*
 * ★ 注意 0x 后面的注释都是「反编译里那个十进制数」——
 *   保留原始形态，方便与报告逐条对照复核。
 */

/// GWorld 的静态偏移：GWorld = Read<u64>(libUE4 基址 + 本值)
/// 反编译原文：v8 = Read<unsigned long>(sLibBase + 395003104);
/// 395003104 = 0x178AA5E0
static const uint64_t kMFUE_DefaultGWorld   = 0x178AA5E0ULL;

/// UWorld → GameInstance（UE4: UWorld::OwningGameInstance）
/// 原文：Read<u64>(GWorld + 400)
static const uint32_t kMFUE_World_GameInstance = 400;      // 0x190

/// GameInstance → LocalPlayers（TArray 数据指针，取 [0]）
/// 原文：Read<u64>(v1 + 56)
static const uint32_t kMFUE_GameInstance_LocalPlayers = 56; // 0x38

/// ULocalPlayer → PlayerController
/// 原文：Read<u64>(v3 + 48)
static const uint32_t kMFUE_LocalPlayer_Controller = 48;    // 0x30

/// APlayerController → AcknowledgedPawn
/// 原文：Read<u64>(r + 928)
static const uint32_t kMFUE_Controller_Pawn = 928;          // 0x3A0

/// APlayerController → PlayerCameraManager
/// 原文：Read<u64>(v4 + 1032)
static const uint32_t kMFUE_Controller_CameraManager = 1032;// 0x408

/// APawn → PlayerState
/// 原文：Read<u64>(gCharacter + 4288)
static const uint32_t kMFUE_Pawn_PlayerState = 4288;        // 0x10C0

/// PlayerState → 阵营/队伍 ID（int）
/// 原文：Read<int>(v11 + 264)
static const uint32_t kMFUE_PlayerState_TeamID = 264;       // 0x108

/// UWorld → PersistentLevel（ULevel*）
/// 原文：Read<u64>(gGWorld + 248)
static const uint32_t kMFUE_World_PersistentLevel = 248;    // 0xF8

/// ULevel → Actors 数组数据指针（TArray::Data）
/// 原文：Read<u64>(v13 + 496)
static const uint32_t kMFUE_Level_ActorsData = 496;         // 0x1F0

/// ULevel → Actors 数量（int, TArray::Num）
/// 原文：Read<int>(v14 + 504)
static const uint32_t kMFUE_Level_ActorsNum  = 504;         // 0x1F8

/// AActor → 世界坐标（FVector = 3 × float = 12 字节）
/// 原文：sw533...（pid, actor + 544, &v7, 12）
static const uint32_t kMFUE_Actor_WorldPos   = 544;         // 0x220

#pragma mark - 合法性判据（对齐原实现的错误处理）

/// 世界坐标绝对值上限。原文：fabsf(x) <= 10000000.0f
/// 超出即视为读错/未初始化，直接丢弃该目标
static const float kMFUE_PosAbsMax = 10000000.0f;

/// Actors 数量上限。原文：if (v16 - 1 <= 0xFFF)
static const int kMFUE_ActorsMax = 0xFFF;

/// 指针合法性：地址必须落在这个区间。
/// 原文：if ((a1 - 0x100000001) < 0x2EFFFFFFFF)
///       → 即 0x100000001 .. 0x2F00000000
static const uint64_t kMFUE_PtrMin = 0x100000001ULL;
static const uint64_t kMFUE_PtrMax = 0x2F00000000ULL;

static inline BOOL MFUEIsValidPtr(uint64_t p) {
    return (p >= kMFUE_PtrMin && p < kMFUE_PtrMax);
}

#pragma mark - FMinimalViewInfo（UE4 标准布局，跨平台一致）

/// 相机 POV 结构：Location@0x0 / Rotation@0xC / FOV@0x18
static const uint32_t kMFUE_POV_Location = 0x00;   // FVector 3×float
static const uint32_t kMFUE_POV_Rotation = 0x0C;   // FRotator 3×float（Pitch/Yaw/Roll）
static const uint32_t kMFUE_POV_FOV      = 0x18;   // float
static const uint32_t kMFUE_POV_Size     = 0x1C;

/// FMinimalViewInfo 的合法性判据（用于「在 CameraManager 里扫 CameraCache 偏移」）
static const float kMFUE_POV_FovMin = 20.0f;       // 视场角下限
static const float kMFUE_POV_FovMax = 150.0f;      // 视场角上限

#pragma mark - 运行时可改偏移

/// 一份 UE4 适配记录。全部字段运行时可改（游戏更新只改这里）。
@interface MFUEProfile : NSObject

@property (nonatomic, assign) uint64_t gworldStaticOffset;   // 模块基址 + 本值 = GWorld

@property (nonatomic, assign) uint32_t world_gameInstance;
@property (nonatomic, assign) uint32_t gameInstance_localPlayers;
@property (nonatomic, assign) uint32_t localPlayer_controller;
@property (nonatomic, assign) uint32_t controller_pawn;
@property (nonatomic, assign) uint32_t controller_cameraManager;
@property (nonatomic, assign) uint32_t pawn_playerState;
@property (nonatomic, assign) uint32_t playerState_teamID;
@property (nonatomic, assign) uint32_t world_persistentLevel;
@property (nonatomic, assign) uint32_t level_actorsData;
@property (nonatomic, assign) uint32_t level_actorsNum;
@property (nonatomic, assign) uint32_t actor_worldPos;

/// CameraManager → CameraCacheEntry（FCameraCacheEntry）
/// ★ mingyun 的报告里【没有这个值】—— 它只用到 CameraManager 指针，没读 POV。
///   默认为 0，表示「未校准」；此时用 scanCameraCacheOffset: 自动扫描。
@property (nonatomic, assign) uint32_t cameraManager_cacheEntry;

/// 从 Documents 载入/保存运行时可改值
+ (instancetype)loadFromDefaults;
- (void)saveToDefaults;

@end

NS_ASSUME_NONNULL_END
