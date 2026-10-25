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
//  ── 交叉验证（★ 逐条用 SDK 复核过，下面标了真伪）──
//
//  白米饭的「根指针链」是：0x98 → 0x30 → 0x408 → 0x3A0 → 0x10C0 → 0x108 → 0xF8
//  对照 mingyun：
//      0x30   = UPlayer + 0x30            → PlayerController       ✅
//      0x408  = APlayerController + 0x408 → PlayerCameraManager    ✅
//      0x3A0  = AController + 0x3A0       → Pawn                   ✅（不是 AcknowledgedPawn，那是 0x3F0，两个都在）
//      0x10C0 = AGPCharacterBase + 0x10C0 → UGPTeamComponent*      ⚠️ 名字叫 PlayerState 是错的
//      0x108  = UGPTeamComponent + 0x108  → TeamID                 ✅（所以这条两跳的算术是对的）
//      0xF8   = UWorld + 0xF8             → PersistentLevel        ✅
//      0x220  = AActor + 0x220            → ???                    ❌ 这是 Pad_1FA[0x76] 的填充区
//
//  所以："7 个全中" 是错觉 —— 前 6 个跳数成立，最后那个坐标偏移落在空档里，
//  读出来恒为 0。坐标必须走 AActor+0x180 → USceneComponent+0x168（见下方常量）。
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

/// Actor → FName 索引（int）。反编译原文：v85 = Read<int>(v21 + 28);
///
/// ⚠ [M5.82] 这个字段**不是类 ID**。按 dump 工具的 UObject 布局（Name@0x1C），
///    +28 读到的是 **UObject.Name** —— 这个对象自己的名字（"XXX_C_7" 这种），
///    不是它的 UClass。所以拿它去比 "Character" 后缀会因为 "_C_7" 而失配。
///    真正的类名路径：Read<u64>(actor + kMFUE_UObject_Class) → 再 +kMFUE_UObject_Name。
///    MFUEGNames 的 classNameForActorClass: 已封装；常量名保留是为了不改动旧调用点。
static const uint32_t kMFUE_Actor_ClassID = 28;               // 0x1C = UObject.Name

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

/*
 * ══════════════════════════════════════════════════════════════════════════
 *  GNames / FName —— [M5.82] 布局已核实，结论与旧注释完全不同，务必读完
 * ══════════════════════════════════════════════════════════════════════════
 *
 *  【旧注释（已作废）】
 *      entry = Read<u64>(gnamesBase + ((id >> 15) & 0xFFF8) + 200)
 *      chars = entry + 2 * (id & 0x3FFFF)
 *  这两行是 mingyun 反编译的照抄，本身自相矛盾：块号切 15 位、块内却取 18 位，
 *  两段加起来 33 位 > 32 位 id 空间，数学上不可能同时成立。而且它把 FNameEntry
 *  的 2 字节头也一起当成字符串读了 —— 从第一个字符起就整体错位。
 *
 *  【权威证据：游戏 1.201.37117 的 MobileDumper-7 自检日志】
 *      …\三角洲\DeltaForce-iOS-SDK\MobileDumper7.log
 *
 *      第 70-77 行：
 *          GNames pointer: 0x117AA76C0
 *          GNames offset:  0x1173776C0      ← 与 kMFUE_DefaultGNames 完全一致
 *          GNames layout type: FNamePool    ← 是 FNamePool，不是 TNameEntryArray
 *          FNamePool::BlocksBit: 0x12
 *          FNamePool::Blocks: 0xC8 -> 0x12CB54000
 *          FNameEntry::Stride: 0x2
 *          FNameEntry::Header: 0x0
 *          FNameEntry::String: 0x2
 *      第 67 行：Entry 0 reads "None"; decoded 50 of 50 sampled names,
 *                8 matched known engine names.        ← 布局被工具自验证过
 *      第 318/320 行：bUseNamePool = true，bUseCasePreservingName = false
 *      第 87 行：General::MaxFNameLen = 512              ← 名字长度上限的出处
 *
 *  【由此确定的三件事】
 *    ① GNames 池是 FNamePool（块指针数组 + 块内偏移），取址公式：
 *           block = Read<u64>(gnamesBase + bias + 8 * (id >> offsetBits))
 *           entry = block + (id & ((1 << offsetBits) - 1)) * stride
 *    ② FNameEntry 头部 2 字节，字符串从 +0x2 开始（Header/Stride 双证）
 *    ③ bias = 200 (0xC8) 就是 **Blocks[] 指针数组在池内的成员偏移**
 *       —— 这正好解释 mingyun 那个「+200」魔法数，不是随手偏置。
 *
 *  【还没定死的一件事：offsetBits（块内位宽）】
 *    · mingyun：块号 >>15（15 位）／块内 &0x3FFFF（18 位）—— 自相矛盾
 *    · UE 标准 FNamePool：>>16 / &0xFFFF（16 位）
 *    · 本作 dump 日志：FNamePool::BlocksBit = 0x12 = 18
 *    静态资料裁决不了（GObjects dump 里只有地址和名字，没有 FName id），
 *    所以 MFUEGNames 在**运行时实测块间距**来定 offsetBits，并用高位 id 交叉验证。
 *    这里不给死值 —— 谁把 15/16/18 写死，谁就是在赌。
 *
 *  【⚠ 另一个坑：+0x1C 是对象名，不是类名】
 *    dump 日志第 210-215 行的 UObject 布局（本作引擎被改造过，字段顺序与 UE 标准不同）：
 *        UObject::Vft  = 0x00     UObject::Class = 0x08
 *        UObject::Outer= 0x10     UObject::Flags = 0x18
 *        UObject::Name = 0x1C     UObject::Index = 0x24
 *    所以下面 kMFUE_Actor_ClassID(28/0x1C) 读到的其实是 **UObject.Name**（对象自己的名字，
 *    形如 "DFMPlayerCharacter_C_7"），不是它的类。要拿类名必须走：
 *        cls = Read<u64>(actor + kMFUE_UObject_Class);  id = Read<int32>(cls + kMFUE_UObject_Name)
 *    MFUEGNames 的 classNameForActorClass: 就是这条路径。
 * ══════════════════════════════════════════════════════════════════════════
 */

/// ⚠ 仅保留给旧实现（MFDrawingLayer.mm 里还没换掉的那段），**新代码不要用**。
/// 语义已被上面的核实推翻，改用 MFUEGNames 模块。
static const uint32_t kMFUE_GNamesEntryBias = 200;            // = Blocks[] 的池内偏移 0xC8
static const uint64_t kMFUE_GNamesChunkMask = 0xFFF8ULL;      // 旧公式残留，勿用

/// FNamePool 布局的实测常量（来源：MobileDumper7.log 第 73-77 行）
static const uint32_t kMFUE_FNameEntryHeaderBytes = 2;        // Header@0x0，String@0x2
static const uint32_t kMFUE_FNameEntryStride      = 2;        // FNameEntry::Stride
static const uint32_t kMFUE_FNameMaxChars         = 512;      // General::MaxFNameLen
static const uint32_t kMFUE_FNameBlocksBias       = 200;      // Blocks[] 在池内 +0xC8

/*
 * UObject 关键字段（本作改造后的布局，来源：dump 日志第 210-215 行）
 * 注意字段顺序与 UE4 标准（Flags@0x08 / Class@0x10 / Name@0x18 / Outer@0x20）不同。
 */
static const uint32_t kMFUE_UObject_Vft   = 0x00;
static const uint32_t kMFUE_UObject_Class = 0x08;   // UClass*
static const uint32_t kMFUE_UObject_Outer = 0x10;
static const uint32_t kMFUE_UObject_Flags = 0x18;
static const uint32_t kMFUE_UObject_Name  = 0x1C;   // FName（ComparisonIndex 就在 +0x1C）
static const uint32_t kMFUE_UObject_Index = 0x24;

/// FName 内部：ComparisonIndex(uint32) 在 +0x0，Number(uint32) 在 +0x4，共 8 字节
static const uint32_t kMFUE_FName_ComparisonIndex = 0x00;
static const uint32_t kMFUE_FName_Number          = 0x04;
static const uint32_t kMFUE_FName_Size            = 0x08;

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
/// ⚠ 名字是历史遗留，值是对的。
/// SDK 里 AGPCharacterBase + 0x10C0 是 `UGPTeamComponent* TeamComp`，**不是 PlayerState**；
/// 下一步 +0x108 才是 `UGPTeamComponent::TeamID`。两跳算下来正好命中真字段，
/// 所以队伍功能一直是好的 —— 只是"Pawn → PlayerState"这个说法会误导后来人。
static const uint32_t kMFUE_Pawn_PlayerState = 4288;        // 0x10C0 → TeamComp

/// UGPTeamComponent → 阵营/队伍 ID（int）
/// SDK：class UGPTeamComponent   +0x0108  int32 TeamID
static const uint32_t kMFUE_PlayerState_TeamID = 264;       // 0x108

/// UWorld → PersistentLevel（ULevel*）
/// SDK：class UWorld   +0x00F8  class ULevel* PersistentLevel
static const uint32_t kMFUE_World_PersistentLevel = 0x00F8;

/*
 * ULevel → Actors（TArray<AActor*>）
 *
 * ★ [M5.135] 从 0x1F0 / 0x1F8 改成 0x98 / 0xA0。旧值不是"过期"，是【读错了结构体位置】。
 *
 * 证据（MobileDumper-7，游戏 1.201.37117）：
 *     class alignas(0x10) ULevel final : public UObject
 *         +0x0098  TArray<class AActor*> Actors    // THIS IS THE ARRAY YOU'RE LOOKING FOR!
 *         +0x00A8  class UWorld* OwningWorld
 *         +0x01E5  uint8 Pad_1E5[0x5B]             // 0x1E5 .. 0x240 是填充区
 *         +0x0240  class AWorldSettings* WorldSettings
 *
 * 旧的 0x1F0 / 0x1F8 正好落在 Pad_1E5 里 —— 读到的不是字段，是被清零的填充字节。
 * 所以它不会崩、也不会报"读失败"，只会稳定拿到 0，然后在日志里伪装成
 * 「Actors.Data 非法 / Actors 数量异常」，把人往"偏移随版本失效"的方向带。
 */
static const uint32_t kMFUE_Level_ActorsData = 0x0098;      // TArray::Data
static const uint32_t kMFUE_Level_ActorsNum  = 0x00A0;      // TArray::Num（int32）

/*
 * Actor 的世界坐标必须两跳，不能直接从 AActor 上抠。
 *
 * 证据（Engine_classes.hpp）：
 *     AActor           +0x0180  class USceneComponent* RootComponent
 *     USceneComponent  +0x0168  struct FEncVector RelativeLocation (0x10)
 *     USceneComponent  +0x0178  struct FRotator  RelativeRotation  (0x0C)
 *     USceneComponent  +0x0184  struct FVector   RelativeScale3D   (0x0C)
 *
 * 旧的 0x220 落在 AActor 的 Pad_1FA[0x76]（0x1FA .. 0x270）填充区里 —— 同样是空档。
 *
 * ★ 关于 FEncVector 到底加不加密：二进制侧已经证明【内存里就是明文】。
 *     DecVector 的 NativeExecOffset = 0x109DFA15C，其取值的实体在 0x109880BA8：
 *         ldr   q0, [x0]        ; 一次读 16 字节
 *         mov   s1, v0.s[1]     ; Y
 *         mov   s2, v0.s[2]     ; Z
 *         ret                   ; X 已在 s0
 *     即把 X/Y/Z 原样返回；EncHandler(+0xC) 只出现在一条 bDynamic 通知分支里
 *     （ldrb [sp,#0xF] / tbnz bit0 / blr 全局回调），不参与任何数值变换。
 *     EncVector（0x10FCC599C）同样是原样拷贝 12 字节。
 *   所以 +0x168 的头 12 个字节可以直接当三个 float 用，不需要解密、也不需要判 handler。
 */
static const uint32_t kMFUE_Actor_RootComponent = 0x0180;   // AActor → USceneComponent*

/*
 * 世界坐标 = RootComponent + 0x220 = ComponentToWorld.Translation
 *
 * ★ 这不是估的，是二进制里 USceneComponent::K2_GetComponentLocation 自己走的路：
 *     thunk 0x109E13174 → 实现 0x109790348
 *         bl  GetComponentTransform()          // 0x107C06368 → 0x10110916C
 *         ldp s0, s1, [x0, #0x10]              // Translation.X / .Y
 *         ldr s2,     [x0, #0x18]              // Translation.Z
 *     而 GetComponentTransform 的存根只有两条指令：
 *         add x0, x0, #0x210 ; ret
 *   → ComponentToWorld 在 USceneComponent+0x210
 *   → FTransform.Translation 在 +0x10 → 合计 **Comp+0x220**
 *
 * 为什么不再用 RelativeLocation（0x168）：
 *   那是【局部坐标】。RootComponent 没挂父级时才碰巧等于世界坐标；一旦挂在
 *   载具 / 挂点下面，读出来就是零点附近的小偏移 —— 屏幕上直接画错位置。
 *
 * 顺带解释一个历史疑点：旧表里的 `actor + 0x220` 数值上正好等于
 * `RootComponent + 0x220` —— 当年是【少跳了 RootComponent 这一跳】，不是偏移算错。
 */
static const uint32_t kMFUE_SceneComponent_WorldLocation = 0x0220;

/*
 * 装备槽（头/甲/包）—— 来自《物资与头甲等级机制》对同版本游戏的反编译：
 *     actor + 0x24E0 (9440) → 装备组件
 *            + 0x1D8  (472) → 槽位数组
 *     10 槽 × 0x30 (48) 字节，每槽 +0x00 是物品 ID（uint64）
 * 物品 ID 是【十进制编码】：第 2~4 位 = 类型码（101 头 / 105 甲 / 108 包），
 * 第 8 位 = 等级 1~6。合法性区间 [10000001, 0x4A87F317F]。
 */
/* 手持武器（真机验证）：actor+0x1020 → 战斗组件 → +0x4D8（空则 +0x588）→ +0x838 武器ID */
static const uint32_t kMFUE_Actor_CombatComponent = 0x1020;
static const uint32_t kMFUE_Combat_WeaponA        = 0x04D8;
static const uint32_t kMFUE_Combat_WeaponB        = 0x0588;
static const uint32_t kMFUE_Weapon_ID             = 0x0838;

/* 人机/真人判定（真机验证）：人机的 PlayerState 为空，真人非空 */
static const uint32_t kMFUE_Actor_PlayerState = 0x0390;

static const uint32_t kMFUE_Pawn_EquipmentComponent = 0x24E0;
static const uint32_t kMFUE_Equip_SlotsArray        = 0x01D8;
static const uint32_t kMFUE_Equip_SlotStride        = 0x30;
static const uint32_t kMFUE_Equip_SlotCount         = 10;

/// 备选（局部坐标，仅当 RootComponent 未挂接时可用；留作对照）
static const uint32_t kMFUE_SceneComponent_RelativeLocation = 0x0168;

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

#pragma mark - 相机 POV（固定偏移，不再扫描）

/*
 * ★ [M5.135] 相机改成固定偏移，并把整条链算清楚。
 *
 * 证据（Engine_classes.hpp / Engine_structs.hpp）：
 *     APlayerCameraManager + 0x2D60  FCameraCacheEntry CameraCachePrivate   (0xA50)
 *     APlayerCameraManager + 0x37B0  FCameraCacheEntry LastFrameCameraCachePrivate
 *     FCameraCacheEntry:   float Timestamp @0x00, uint8 Pad_4[0x0C], FMinimalViewInfo POV @0x10
 *     FMinimalViewInfo:    FEncVector Location @0x00 (0x10)
 *                          FRotator  Rotation @0x10 (Pitch/Yaw/Roll)
 *                          float     FOV      @0x1C
 *
 * 旧常量是 Rotation@0x0C / FOV@0x18 —— 错位的根因是：这个 build 的 Location 是
 * 16 字节的 FEncVector，不是 12 字节的 FVector，所以后面所有字段整体后移 4 字节。
 * 旧代码照 12 字节排，读到的 pitch 其实是 handler 槽被当 float，fov 其实是 Roll。
 *
 * 也正因为偏移是确定的，`scanCameraCacheOffset:` 那套"扫 0x2000 字节取第一个命中"
 * 全部删掉：它判据太松、会误命中，而且一旦命中就写进 NSUserDefaults 永久生效。
 */
static const uint32_t kMFUE_CameraManager_CacheEntry = 0x2D60;
static const uint32_t kMFUE_CameraCache_POV          = 0x10;
static const uint32_t kMFUE_POV_Location = 0x00;   // FEncVector：X/Y/Z + handler
static const uint32_t kMFUE_POV_Rotation = 0x10;   // FRotator 3×float（Pitch/Yaw/Roll）
static const uint32_t kMFUE_POV_FOV      = 0x1C;   // float
static const uint32_t kMFUE_POV_Size     = 0x20;   // Location + Rotation + FOV

/// POV 的合法性判据（readCamera 用它拒掉读错页的那一帧）
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
/// Actor → USceneComponent*（RootComponent）。世界坐标要走它再跳到
/// scenecomponent_worldLocation（ComponentToWorld.Translation），不能直接读 Actor。
@property (nonatomic, assign) uint32_t actor_rootComponent;
@property (nonatomic, assign) uint32_t scenecomponent_worldLocation;

/// Actor → 类 ID（区分人物 / 物资 / 盒子）
@property (nonatomic, assign) uint32_t actor_classID;
/// 物资对象上的等级 / 价值字段（白米饭钉出来的候选值）
@property (nonatomic, assign) uint32_t loot_level;
@property (nonatomic, assign) uint32_t loot_value;

/// 角色字段（AGPCharacterBase，Dumper-7 SDK 1.201.37117）
@property (nonatomic, assign) uint32_t character_isAI;      // bool bIsPlayerAI
@property (nonatomic, assign) uint32_t character_isDead;    // bool LastIsDead

/// 从 Documents 载入/保存运行时可改值
+ (instancetype)loadFromDefaults;
- (void)saveToDefaults;

@end

NS_ASSUME_NONNULL_END
