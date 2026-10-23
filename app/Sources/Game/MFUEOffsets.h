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
///
/// ★★★ [M5.75] 这个值曾经被写成 0x178AA5E0 —— 那是**把十进制转十六进制时算错的**：
///     395003104 = 0x178B44E0
///     0x178AA5E0 = 394962400   ← 差了 40704 字节（0x9F00）
///   偏移体量约 377 MB，两个值看起来都"合理"，所以任何量级检查都发现不了，
///   但 GWorld = Read(libBase + 0x178AA5E0) 永远读到别的数据 → 整条链第一步就断。
///   现在按反编译原文的十进制常量重算，别名一份十进制值，方便对照复核。
static const uint64_t kMFUE_GWorldDecLiteral = 395003104ULL;   // 反编译原文
static const uint64_t kMFUE_DefaultGWorld   = 0x178B44E0ULL;   // = 395003104

/// GNames（FName 池）的静态偏移：sGName = libBase + 本值
/// 反编译原文：sGName = sLibBase + 389510848;
/// ★ 389510848 = 0x173776C0（旧文档里写的 0x1739D0C0 = 389664960，同样是转错的）
static const uint64_t kMFUE_GNamesDecLiteral = 389510848ULL;
static const uint64_t kMFUE_DefaultGNames   = 0x173776C0ULL;   // = 389510848

/// AActor → 类 ID（int）。反编译原文：v85 = Read<int>(v21 + 28);
/// 这个 ID 就是 UClass 的名字索引，用它把 Actor 分成人物/物资/盒子。
static const uint32_t kMFUE_Actor_ClassID = 28;               // 0x1C

/*
 * ★★★ [M5.77] 角色字段 —— 来源：Dumper-7 完整 SDK（游戏 1.201.37117）★★★
 *
 * 这是一份 12,619 个类、109,269 个 UObject 的完整 dump，字段偏移是编译期布局，
 * 不需要再猜。角色的继承链（SDK: DFMGameplay_classes.hpp / GPGameplay_classes.hpp）：
 *
 *   ADFMPlayerCharacter : ADFMCharacter : AGPCharacter : AGPCharacterBase   ← 真人
 *   ADFMAICharacter     : ADFMCharacter : AGPCharacter : AGPCharacterBase   ← 人机
 *   ADFMVirtualAICharacter / ADFMNPCCharacter : ADFMAICharacter             ← 人机
 *   ABattleFieldCharacter : ADFMPlayerCharacter                             ← 真人
 *
 * 下面三个字段都声明在 AGPCharacterBase 上，所以上面整条链通用。
 */
/// bool bIsPlayerAI —— 人机标志：1 = 人机，0 = 真人
static const uint32_t kMFUE_Character_IsAI   = 0x0E60;
/// bool LastIsDead —— 上一帧是否已死亡
static const uint32_t kMFUE_Character_IsDead = 0x0E35;

/// 角色类名后缀 —— 游戏的玩家/AI 角色类都以 Character 结尾
/// （CharacterMovementComponent / GameplayAbility_CharacterJump 这些不以它结尾）
#define kMFUE_CharacterSuffixName @"Character"

/// 物资对象的两个属性 —— 从白米饭 sub_1001F74CC 的原始指令逐条钉出来的：
///     0x1001f7d78  add x1, x23, #0xDC   → 读 4 字节 → w21（价值）
///     0x1001f7e00  add x1, x23, #0x68   → 读 4 字节 → w22（等级）
/// 注意：白米饭的物资对象来自它自己的容器（数量在 +0xE68），
/// 与 UE4 的 ULevel::Actors 不是同一个数组；这两个偏移能不能直接用在
/// Actor 上需要真机对照，所以默认按"候选"处理，读到什么都会打日志。
static const uint32_t kMFUE_Loot_LevelOffset = 0x68;
static const uint32_t kMFUE_Loot_ValueOffset = 0xDC;

/// GNames 解引用用的常量（来自 mingyun GetEnemyThread 的 GName 分支）
///     entry = Read<u64>(gnamesBase + ((id >> 15) & 0xFFF8) + 200)
///     chars = entry + 2 * (id & 0x3FFFF)
static const uint32_t kMFUE_GNamesEntryBias = 200;            // +0xC8
static const uint64_t kMFUE_GNamesChunkMask = 0xFFF8ULL;

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
/// GNames 池：模块基址 + 本值（类名解析用）
@property (nonatomic, assign) uint64_t gnamesStaticOffset;

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

/// Actor → 类 ID（区分人物 / 物资 / 盒子）
@property (nonatomic, assign) uint32_t actor_classID;
/// 物资对象上的等级 / 价值字段（白米饭钉出来的候选值）
@property (nonatomic, assign) uint32_t loot_level;
@property (nonatomic, assign) uint32_t loot_value;

/// 角色字段（AGPCharacterBase，Dumper-7 SDK 1.201.37117）
@property (nonatomic, assign) uint32_t character_isAI;      // bool bIsPlayerAI
@property (nonatomic, assign) uint32_t character_isDead;    // bool LastIsDead

/// CameraManager → CameraCacheEntry（FCameraCacheEntry）
/// ★ mingyun 的报告里【没有这个值】—— 它只用到 CameraManager 指针，没读 POV。
///   默认为 0，表示「未校准」；此时用 scanCameraCacheOffset: 自动扫描。
@property (nonatomic, assign) uint32_t cameraManager_cacheEntry;

/// 从 Documents 载入/保存运行时可改值
+ (instancetype)loadFromDefaults;
- (void)saveToDefaults;

@end

NS_ASSUME_NONNULL_END
