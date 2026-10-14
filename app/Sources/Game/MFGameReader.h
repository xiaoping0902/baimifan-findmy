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
@end

@interface MFGameReader : NSObject

+ (instancetype)shared;

/// 当前目标 task port（由 MFKernel 枚举后写入）
@property (nonatomic, assign) uint32_t targetTaskPort;

/// 实体列表基址（真机校准时回填；0 = 未校准）
@property (nonatomic, assign) uint64_t entityListBase;

/// 物资列表基址（同上）
@property (nonatomic, assign) uint64_t lootListBase;

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
