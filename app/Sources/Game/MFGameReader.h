//
//  MFGameReader.h — 游戏数据读取
//
//  实现依据《读取与绘制_实现全解.md》§3 每帧四步：
//    ① 读相机 → ② 数实体 → ③ 逐个投影 → ④ 画
//
//  已证字段：
//    · 相机结构体 = [对象 + 0x40] → +0x10 X / +0x14 Y / +0x18 Z
//                                  +0x20 俯仰 / +0x24 偏航 / +0x28 横滚 / +0x2C FOV
//    · 实体数量在 +0xE68（int）
//    · 实体世界坐标在 +0x220（3 float）
//    · 根指针链：+0x98 → +0x30 → +0x408 → +0x3A0 → [dynBase]+0x10C0 → +0x108 → +0xF8
//
#import <Foundation/Foundation.h>
#import "MFProjection.h"
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个可绘制目标（人 / 盒子 / 物资）
@interface MFEntity : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, assign) float worldX, worldY, worldZ;
@property (nonatomic, assign) float distanceMeters;
@property (nonatomic, assign) MFPoint2D screen;
@property (nonatomic, copy,   nullable) NSString *name;
@property (nonatomic, assign) int level;        // 物资等级（读失败置 0 —— 对齐原实现）
@property (nonatomic, assign) int value;        // 物资价值（读失败/0 → 跳过）
@property (nonatomic, assign) BOOL isLoot;
@property (nonatomic, assign) BOOL isBox;

#pragma mark 物资 / 装备（[M5.85] 装备对接新增）
/// 一堆的数量（容器内 ItemCount / 地面 StackCount）。0 = 未知
@property (nonatomic, assign) int count;
/// 装备主类型，取值等于 MFGearItemMainType（= 游戏 EEItemMainType）。
/// 这里用 uint32_t 而不是那个枚举，是为了让本头文件不必 import MFGearReader.h —— 
/// 绘制层需要时自己转。0 = 未知。
@property (nonatomic, assign) uint32_t gearCategory;
@property (nonatomic, assign) BOOL isVisible;   // 投影成功

#pragma mark 人物属性（[M5.2] 为「开关接线」新增）
/// HUD 分类：普通/特殊 NPC 为 YES；已确认的可玩干员（包括 AI 干员）为 NO。
@property (nonatomic, assign) BOOL isBot;
/// 队伍编号。0 = 未知（未校准）—— 此时所有目标同队，队伍颜色不影响显示
@property (nonatomic, assign) int teamId;
/// 手持武器编号。0 = 未知
@property (nonatomic, assign) int weaponId;
/// 当前血量。-1 = 未知；读取失败不显示满血。
@property (nonatomic, assign) float health;
/// 当前最大血量。0 = 未知；血条按 health / maxHealth 绘制。
@property (nonatomic, assign) float maxHealth;
/// 头甲等级；equipKnown 为 YES 时，0 表示未装备。
@property (nonatomic, assign) int armorLevel;
/* 头/甲/包等级 1~6；0 的含义由 equipKnown 决定（已读完整=空，否则未知）。 */
@property (nonatomic, assign) int helmetLevel;
@property (nonatomic, assign) int backpackLevel;
@property (nonatomic, assign) BOOL equipKnown;
/* 第一个非零槽位物品 ID —— 用来核对 ID 编码格式 */
@property (nonatomic, assign) uint64_t equipRawID;
/* [M5.148] 人物 ID（PlayerState+0x490；未校准时为 0） */
@property (nonatomic, assign) uint64_t uin;
/// Live operator identity, distinct from the player-authored nickname / UIN.
@property (nonatomic, assign) uint64_t heroID;
@property (nonatomic, assign) uint64_t expertID;
@property (nonatomic, copy, nullable) NSString *heroName;
/// Bot-only display name: ordinary AI is 人机; verified special AI has its own name.
@property (nonatomic, copy, nullable) NSString *npcName;
/* [M5.159] 原始物品 ID（用于查中文名） */
@property (nonatomic, assign) uint64_t weaponRawID;
@property (nonatomic, assign) uint64_t helmetRawID;
@property (nonatomic, assign) uint64_t armorRawID;
@property (nonatomic, assign) uint64_t bagRawID;
@property (nonatomic, assign) BOOL armorKnown;

/* [M5.176] 护甲耐久 —— FArmorInfo.ArmorHP / MaxArmorHP（float，实测 45/45、20/20、55/55）
 * NAN 表示没读到当前值；真实 0 表示耐久耗尽，最大值缺失不影响当前值显示。 */
@property (nonatomic, assign) float helmetHP,  helmetMaxHP;
@property (nonatomic, assign) float armorHP,   armorMaxHP;

/// 相对相机朝向的方位角（度），**带符号**：
///   0 = 正前 · 负 = 左 · 正 = 右 · ±180 = 正后
/// ★ 由坐标 + 相机 yaw 算得，【不依赖任何游戏字段】——
///   所以背敌提示在校准之前就能工作。
@property (nonatomic, assign) float bearingDeg;
/// 是否在背后（|bearingDeg| > 90）
@property (nonatomic, assign) BOOL isBehind;
/// 目标朝向（度；优先 ControlRotation.Yaw，远端缺失时用已验证的复制身体朝向；NAN = 未知）。
@property (nonatomic, assign) float yawDeg;
@end

@interface MFGameReader : NSObject

+ (instancetype)shared;

/// 当前目标 task port（由 MFKernel 枚举后写入）
@property (nonatomic, assign) uint32_t targetTaskPort;

/// ★ 审查修正（报告 F4）：原来只有一个 entityListBase，被当成两个语义用 ——
///   · 当「指针链的根对象」传给 followChain（相机路走这条）
///   · 又当「实体数组起始」直接加偏移（实体/物资路走这条）
///   同一个值不可能同时成立，所以校准对了也只有一条路能通。拆成独立字段。
///
/// 校准检查顺序（地址须由调试取得；当前无输入面板）：
///   1) rootObjectBase  —— 从它按 rootChain 走一步，能读出合理的相机指针
///   2) entityArrayBase —— 从它 + entityCountOffset 能读出合理的实体数量（1..500）
///   3) lootArrayBase   —— 同上
@property (nonatomic, assign) uint64_t rootObjectBase;   // 指针链根（相机路）
@property (nonatomic, assign) uint64_t entityArrayBase;  // 实体数组起始（实体路）
@property (nonatomic, assign) uint64_t lootArrayBase;    // 物资数组起始

/// 保存的是当前运行实例的绝对地址，不能跨游戏重启复用。
/// 使用独立的版本化 NSUserDefaults 快照；仅在目标 task 的 PID、完整路径、
/// 启动时间都能确认且一致时恢复，身份不足/不匹配/格式错误时清零。
/// 这两个方法不会自动定位或校准地址，也不使用 UE4 的 mf.game.libbase。
/// 当前尚无基址校准 UI；目标端口切换也会先清空旧地址。
- (void)loadBasesFromDefaults;
- (void)saveBasesToDefaults;
/// 校准状态摘要（给自检报告用）
- (NSString *)calibrationSummary;

/// 门条件：端口有效即可读
@property (nonatomic, readonly) BOOL ready;

#pragma mark 每帧

/// ① 读相机
- (BOOL)readCamera:(MFCamera *_Nullable)out;

/// ②③ 读实体列表 + 逐个投影到屏幕
- (NSArray<MFEntity *> *)readEntitiesWithCamera:(MFCamera)camera screen:(MFScreen)screen;

/// ④ 读物资（含等级/价值；真实名称读取尚未实现）
- (NSArray<MFEntity *> *)readLootWithCamera:(MFCamera)camera screen:(MFScreen)screen;

/// 一次性拿齐
- (NSDictionary *)readFrameWithSize:(CGSize)size;

#pragma mark 诊断

- (NSString *)diagnosticReport;

@end

NS_ASSUME_NONNULL_END
