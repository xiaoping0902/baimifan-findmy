//
//  Offsets.h — 游戏内存偏移表
//
//  ★ 设计原则（对齐《缺口盘点_还差什么.md》的处理策略）：
//    · 【已证】的字段直接写死（来自白米饭分析，指令级证据）
//    · 【未证】的字段全部留成变量 + 运行时可改，一张表改一处
//    · 目标游戏不同 → 整套换；同游戏不同版本 → 只改偏移
//
//  目标：三角洲行动 com.tencent.tmgp.dfm（先做这个，架构留多游戏位）
//
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 读取封装长度（已证：六个封装的唯一区别就是"读多少字节"）

enum {
    MFReadSizePointer   = 8,    // 指针 / 整数        （原 sub_1001FA8EC）
    MFReadSizeFloat3    = 12,   // float3（坐标）     （原 sub_1001FAA84）
    MFReadSizeFloat     = 4,    // 单 float（FOV）    （原 sub_1001FAA34）
    MFReadSizeCamera    = 48,   // 整个相机结构体 0x30（原 sub_1001FAADC）
    MFReadSizeWorldPos  = 12,   // 目标世界坐标       （原 sub_1001EF358）
    MFReadSizeWorldPos2 = 12,   // 世界坐标（方框版）  （原 sub_1001F8B10）
};

#pragma mark - 投影常量（已证）

/// 角度 → 弧度。原常量 dword_100D412F0 = 0.0174533
static const float kMF_Deg2Rad = 0.0174533f;

/// 深度剔除阈值。原常量 dword_100D4041C = 0.1
/// 深度小于它 → 返回哨兵 (-9999, -9999)，调用方丢弃该目标
static const float kMF_MinDepth = 0.1f;

/// 无效点哨兵（已证）
static const float kMF_Sentinel = -9999.0f;

/// 距离换算：世界坐标差平方和开方后 ÷100 得米 → 世界单位是厘米
static const float kMF_WorldUnitToMeter = 100.0f;

#pragma mark - 相机结构体（已证布局）

/// 相机结构体从 [对象 + kMFCameraPtrOffset] 取
static const uint32_t kMFCameraPtrOffset = 0x40;

/// 相机结构体内部偏移（已证）
static const uint32_t kMFCamera_X      = 0x10;   // float
static const uint32_t kMFCamera_Y      = 0x14;   // float
static const uint32_t kMFCamera_Z      = 0x18;   // float
static const uint32_t kMFCamera_Pitch  = 0x20;   // float 俯仰
static const uint32_t kMFCamera_Yaw    = 0x24;   // float 偏航
static const uint32_t kMFCamera_Roll   = 0x28;   // float 横滚
static const uint32_t kMFCamera_FOV    = 0x2C;   // float 视场角

#pragma mark - 实体（已证）

/// 实体数量（int）—— 已证：LDRSW X8,[X22,#0xE68] + CMP index+1
static const uint32_t kMFEntityCount   = 0xE68;

/// 实体世界坐标（3 个 float）
static const uint32_t kMFEntityPosition = 0x220;

#pragma mark - 物资（部分已证，字段偏移待真机校准）

/// 物资标签格式串（已证）
#define MF_LOOT_LABEL_FORMAT  "%s\n等级[%d]\n价值[%d]\n[%.1fm]"

/// 价值强调阈值（已证）：非 3–6 级但价值【严格大于】9999 → 用 3 级色
static const int kMFLootValueHighlight = 9999;

/// 等级颜色表索引范围（已证）：指令是无符号比较 `等级 - 3 < 4` → 覆盖 3/4/5/6
static const int kMFLootLevelMin = 3;
static const int kMFLootLevelMax = 6;

/// 【未证】物资对象上的等级/价值字段偏移。
///   分析已证「两次 4 字节请求分别读等级和价值」，但取值点在物资对象哪个偏移未逐条钉死。
///   真机校准时改这里。
static const uint32_t kMFLoot_Level  = 0x0;   // TODO: 真机校准
static const uint32_t kMFLoot_Value  = 0x0;   // TODO: 真机校准

#pragma mark - 全局变量（已证地址，未加 ASLR slide 的静态地址）

// 这些是白米饭主程序里的全局变量地址。复刻版没有同样的地址，
// 保留在这里是为了：① 交叉参照分析报告 ② 真机校准时对照读数。
// 实际使用请用 MFOffsets 结构体的动态值。
typedef struct {
    uint64_t cameraCacheXYZ;     // 原 0x100FF1DF0
    uint64_t cameraCacheAngles;  // 原 0x100FF1E08
    uint64_t cameraCacheFOV;     // 原 0x100FF1E14
    uint64_t cameraObjectBase;   // 原 0x100FF6610
    uint64_t dynamicOffsetBase;  // 原 0x100FF65D0
    uint64_t targetTaskPort;     // 原 0x100FF7470（门条件用）
    uint64_t modeFlag;           // 原 0x100FF7468（门条件用）
} MFOriginalGlobals;

static const MFOriginalGlobals kMFOriginalGlobals = {
    .cameraCacheXYZ    = 0x100FF1DF0,
    .cameraCacheAngles = 0x100FF1E08,
    .cameraCacheFOV    = 0x100FF1E14,
    .cameraObjectBase  = 0x100FF6610,
    .dynamicOffsetBase = 0x100FF65D0,
    .targetTaskPort    = 0x100FF7470,
    .modeFlag          = 0x100FF7468,
};

#pragma mark - 运行时可改的偏移表

/// 一条游戏适配记录
@interface MFGameProfile : NSObject
@property (nonatomic, copy)   NSString *bundleID;
@property (nonatomic, copy)   NSString *displayName;
@property (nonatomic, copy)   NSString *processName;    // 【未证】进程名，运行时探测后回填
@property (nonatomic, copy)   NSString *moduleName;     // 【未证】模块名，同上
@property (nonatomic, assign) uint32_t entityCountOffset;
@property (nonatomic, assign) uint32_t entityPositionOffset;
@property (nonatomic, assign) uint32_t cameraPtrOffset;
@property (nonatomic, assign) uint32_t lootLevelOffset;
@property (nonatomic, assign) uint32_t lootValueOffset;
/// 根指针链（已证：+0x98 → +0x30 → +0x408 → +0x3A0 → [dynBase]+0x10C0 → +0x108 → +0xF8）
@property (nonatomic, strong) NSArray<NSNumber *> *rootChain;
@end

@interface MFOffsets : NSObject
+ (instancetype)shared;

/// 当前生效的档案
@property (nonatomic, strong) MFGameProfile *current;

/// 全部内置档案
@property (nonatomic, readonly) NSArray<MFGameProfile *> *profiles;

- (nullable MFGameProfile *)profileForBundleID:(NSString *)bundleID;

/// 从 Documents 加载真机校准结果（覆盖内置值）
- (BOOL)loadCalibration;
- (BOOL)saveCalibration;

/// 自检摘要
- (NSString *)summary;
@end

NS_ASSUME_NONNULL_END
