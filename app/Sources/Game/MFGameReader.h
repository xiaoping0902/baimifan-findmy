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
@property (nonatomic, assign) BOOL isVisible;   // 投影成功

#pragma mark 人物属性（[M5.2] 为「开关接线」新增）
/// 人机标志。偏移未校准时恒为 NO —— 此时「人机显示」不会误判
@property (nonatomic, assign) BOOL isBot;
/// 队伍编号。0 = 未知（未校准）—— 此时所有目标同队，队伍颜色不影响显示
@property (nonatomic, assign) int teamId;
/// 手持武器编号。0 = 未知
@property (nonatomic, assign) int weaponId;
/// 血量 0..100。-1 = 未知（未校准）—— 此时按满格画，与原占位行为一致
@property (nonatomic, assign) int health;
/// 头甲等级 0=无甲
@property (nonatomic, assign) int armorLevel;
@property (nonatomic, assign) BOOL armorKnown;

/// 相对相机朝向的方位角（度），**带符号**：
///   0 = 正前 · 负 = 左 · 正 = 右 · ±180 = 正后
/// ★ 由坐标 + 相机 yaw 算得，【不依赖任何游戏字段】——
///   所以背敌提示在校准之前就能工作。
@property (nonatomic, assign) float bearingDeg;
/// 是否在背后（|bearingDeg| > 90）
@property (nonatomic, assign) BOOL isBehind;
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
/// 校准顺序（真机调试面板里逐项填）：
///   1) rootObjectBase  —— 从它按 rootChain 走一步，能读出合理的相机指针
///   2) entityArrayBase —— 从它 + entityCountOffset 能读出合理的实体数量（1..500）
///   3) lootArrayBase   —— 同上
@property (nonatomic, assign) uint64_t rootObjectBase;   // 指针链根（相机路）
@property (nonatomic, assign) uint64_t entityArrayBase;  // 实体数组起始（实体路）
@property (nonatomic, assign) uint64_t lootArrayBase;    // 物资数组起始

/// ★ 审查修正 F1：这三个基址原本全工程 0 个写点 —— 读取链永远不可达。
/// 现在提供持久化：存 NSUserDefaults，启动时自动读回。
/// 真机校准时在「进程列表 → 基址校准」里填十六进制值。
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

/// ④ 读物资（含等级/价值/名称）
- (NSArray<MFEntity *> *)readLootWithCamera:(MFCamera)camera screen:(MFScreen)screen;

/// 一次性拿齐
- (NSDictionary *)readFrameWithSize:(CGSize)size;

#pragma mark 诊断

- (NSString *)diagnosticReport;

@end

NS_ASSUME_NONNULL_END
