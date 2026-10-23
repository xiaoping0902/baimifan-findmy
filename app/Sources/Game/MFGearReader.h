//
//  MFGearReader.h — 物资 / 装备属性读取
//
//  ── 它解决什么问题 ──
//
//  绘制层已经有完整的物资绘制路径（等级配色、价值强调、统计窗），
//  但它要的三个字段一直是假的：
//      e.name  = 类名（显示 "InventoryPickup_DeadBody" 这种垃圾）
//      e.level = Read<u32>(actor + 0x68)     ← 白米饭的候选偏移
//      e.value = Read<u32>(actor + 0xDC)     ← 白米饭的候选偏移
//
//  0x68 / 0xDC 是白米饭**自己那套对象**的布局，套在 UE4 Actor 上读到的是
//  AActor 头里的别的字段 —— 不是"偏一点"，是完全无关的数据。
//
//  ── 真实字段在哪（全部来自 Dumper-7 SDK 1.201.37117，静态 dump 直读）──
//
//  拾取物基类 DFMGameplay.PickupBase 的自有字段从 +0x0FB8 开始：
//      +0x0FC0  bool      bIsHiddenItem
//      +0x0FE0  enum      SourceType        （EEItemSourceType）
//      +0x0FF0  FName     InventoryIdName   ← 物品 ID 名（要 GNames 解析）
//      +0x0FF8  UClass*   InventoryType     ← 物品类型类
//      +0x1000  int32     StackCount        ← 堆叠数量
//      +0x1008  int32     Durability        ← 耐久
//
//  子类 DFMGameplay.InventoryPickup（可搜索容器：盒子 / 尸体 / 保险箱）多出：
//      +0x1240  FInventoryItemInfo  PickupItemInfo   ← 2048 字节的物品详情
//      +0x10A0  FGPWeaponDescInfo   GunDescInfo      ← 枪械描述
//      +0x1DB8  bool                bIsPickupContainer
//      +0x1DBA  bool                bIsWeaponModule
//
//  FInventoryItemInfo（2048B，来源 StructsInfo.json）里：
//      +0x0010  FItemID  ItemID            （+0x00 Category / +0x04 Sequence）
//      +0x0038  int32    ItemCount
//      +0x0054  float    ItemArmorHealth
//      +0x02E8  FItemArchiveInfo ArchiveInfo
//      +0x0564  int32    StarNum
//  FItemArchiveInfo 里：
//      +0x0240  int64    EquipmentValue   ← ★ 真正的"价值"
//
//  FItemID.Category 的取值语义 = EEItemMainType（EnumsInfo.json 直读）：
//      10 武器  11 装备  13 配件  14 医疗  15 收藏品  16 杂物
//      17 箱子  19 食物  21 投掷物 24 道具 31 低价值武器 37 弹药 39 载具
//  装备（11）再按 EEEquipmentItemType 细分：
//      1 头盔  5 胸甲  7 胸挂  8 背包  9 安全箱  12 钥匙链
//
//  ── 设计原则：自验证读取 ──
//
//  偏移是静态推出来的，**没有真机验证过**。所以这里不做"读到什么就用什么"，
//  而是每一层都做**值域校验**：
//      · Category 必须落在 EEItemMainType 的已知取值集合里
//      · ItemCount 必须是 1..10000
//      · EquipmentValue 必须是 0..1e8
//  任何一项越界，就认为"这个偏移在当前游戏版本上不成立"，
//  退回不可信状态，绘制层显示"物资"而不是显示垃圾数字。
//
//  这比"读出来就画"慢不了多少，但能保证：屏幕上出现的每个数字都是真的。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 装备类别（与 MFGearCatalog 的 MFGearCategory 对齐）

/// 物品主类型（EEItemMainType 的子集，只列我们关心的）
typedef NS_ENUM(uint32_t, MFGearItemMainType) {
    MFGearItemMainTypeNone          = 0,
    MFGearItemMainTypeWeapon        = 10,
    MFGearItemMainTypeEquip         = 11,
    MFGearItemMainTypeWeaponExtra   = 12,
    MFGearItemMainTypeAdapter       = 13,
    MFGearItemMainTypeMedicine      = 14,
    MFGearItemMainTypeCollection    = 15,
    MFGearItemMainTypeSundry        = 16,
    MFGearItemMainTypeBox           = 17,
    MFGearItemMainTypeWeaponStruct  = 18,
    MFGearItemMainTypeFood          = 19,
    MFGearItemMainTypeThrowable     = 21,
    MFGearItemMainTypePerk          = 22,
    MFGearItemMainTypeGadget        = 24,
    MFGearItemMainTypeItemSkill     = 25,
    MFGearItemMainTypeWeaponSkin    = 28,
    MFGearItemMainTypeFashion       = 30,
    MFGearItemMainTypePoorWeapon    = 31,
    MFGearItemMainTypeAmmo          = 37,
    MFGearItemMainTypeCommercialize = 38,
    MFGearItemMainTypeVehicle       = 39,
    MFGearItemMainTypeVehicleAdapter= 40,
    MFGearItemMainTypeVehicleSkin   = 41,
    MFGearItemMainTypeHero          = 88,
};

/// 装备子类型（EEEquipmentItemType）
typedef NS_ENUM(uint32_t, MFGearEquipSubType) {
    MFGearEquipSubTypeNone        = 0,
    MFGearEquipSubTypeHelmet      = 1,    // 头盔
    MFGearEquipSubTypeBreastPlate = 5,    // 胸甲
    MFGearEquipSubTypeChestHang   = 7,    // 胸挂
    MFGearEquipSubTypeBag         = 8,    // 背包
    MFGearEquipSubTypeSafeBox     = 9,    // 安全箱
    MFGearEquipSubTypeKeyChain    = 12,   // 钥匙链
};

/// 拾取来源（EEPickupSourceType）。
///
/// ★ 纠错记录 ★ 原来这里写的是 EEItemSourceType（None/NaturalContainer/…），
///   但 sdk-gear 全库核对后确认：EEItemSourceType **0 处字段引用**，是遗留枚举；
///   PickupBase.SourceType 的真实类型是 EEPickupSourceType。
typedef NS_ENUM(uint32_t, MFGearItemSource) {
    MFGearItemSourceDefault   = 0,   // 默认
    MFGearItemSourceBodyBox   = 1,   // 尸体箱
    MFGearItemSourceDiscard   = 2,   // 玩家丢弃
    MFGearItemSourceNormalBox = 3,   // 普通箱子
};

#pragma mark - 读出来的一件物资

@interface MFGearInfo : NSObject

/// 物品 ID 名（PickupBase.InventoryIdName 解出来的字符串）。
/// 拿不到就为 nil —— 绘制层应回退到 MFGearCatalog 的 fallbackLabel。
@property (nonatomic, copy, nullable) NSString *itemIdName;

/// 物品 ID 的 FName 原始两段（ComparisonIndex + Number）。
/// 查物品定义表时要用它当主键 —— 字符串可能解不出来，但索引一定在。
@property (nonatomic, assign) uint32_t itemIdNameIndex;
@property (nonatomic, assign) uint32_t itemIdNameNumber;

/// 等级（FDFMCommonItemRow.Quality）。
/// ★ 来源是**物品定义表**，不是 Actor —— Actor 上根本没有 Quality 字段。
/// -1 表示没查到（表没加载 / 这行不在表里）。
@property (nonatomic, assign) int quality;
@property (nonatomic, assign) BOOL hasQuality;

/// 物品主类型（EEItemMainType）。0 = 未知
@property (nonatomic, assign) MFGearItemMainType mainType;
/// 装备子类型（仅在 mainType == Equip 时有意义）
@property (nonatomic, assign) MFGearEquipSubType equipSubType;
/// 该类型下的具体物品编号（FItemID.Sequence）
@property (nonatomic, assign) uint32_t sequence;
/// 来源
@property (nonatomic, assign) MFGearItemSource source;

/// 数量（容器里是这一堆的数量）
@property (nonatomic, assign) int count;
/// 价值（ArchiveInfo.EquipmentValue）。0 且 hasValue == NO 表示没读到
@property (nonatomic, assign) long long value;
@property (nonatomic, assign) BOOL hasValue;
/// 星级（StarNum）。0 且 hasStar == NO 表示没读到
@property (nonatomic, assign) int starNum;
@property (nonatomic, assign) BOOL hasStar;

/// 容器标志（Actor 上的 bIsPickupContainer / 类名体现的容器类型）
@property (nonatomic, assign) BOOL isContainer;

/// 整体可信度：至少 mainType 和 count 之一通过了值域校验
@property (nonatomic, assign) BOOL trustworthy;

/// 给日志用的单行摘要
- (NSString *)summary;

@end

#pragma mark - 读取器

/// 物品 ID 名解析回调。
/// 为什么用回调而不是直接调 GNames：FName 池解析是另一块（MFUEGNames），
/// 这里只负责把「名字索引」变成字符串，避免两个模块互相 import 成环。
/// 传入 FName 的 ComparisonIndex，返回解出的名字或 nil。
typedef NSString *_Nullable (^MFGearNameLookup)(uint32_t nameIndex);

@interface MFGearReader : NSObject

+ (instancetype)shared;

/// 由上层注入。不注入时 itemIdName 恒为 nil，其余字段照常工作。
@property (nonatomic, copy, nullable) MFGearNameLookup nameLookup;

/// 读一个 Actor 的物资信息。不认识的类名 / 读失败都返回 nil。
/// className 传 GNames 解出来的类名（可以带模块前缀，内部会归一化）。
- (MFGearInfo *_Nullable)readGearForActor:(uint64_t)actor
                                className:(NSString *_Nullable)className
                                  isActor:(BOOL *)outIsActor;

/// 展开容器内容 —— 盒子里 / 尸体上到底有什么。
///
/// 走 RepItemArray(0x1F38) → TArray<FInventoryItemInfo>（Data=0x2040 / Num=0x2048 / 步长 0x800）。
/// 每件物品只读 ItemID + Count 那 0x40 字节，不读整件，所以一次展开 = 1 + N 次远程读。
/// 因此：上限 32 件、结果进 2 秒缓存、上层应按距离或开关决定要不要调。
/// 返回数组（读不到就是空数组，不返回 nil）。
- (NSArray<MFGearInfo *> *)containedItemsForActor:(uint64_t)actor;

#pragma mark 值域校验（公开给自检用）

/// 是否是合法的 EEItemMainType 取值
+ (BOOL)isValidMainType:(uint32_t)v;
/// 值域校验：数量
+ (BOOL)isPlausibleCount:(int32_t)v;
/// 值域校验：价值
+ (BOOL)isPlausibleValue:(long long)v;

#pragma mark 文案

+ (NSString *)textForMainType:(MFGearItemMainType)t;
+ (NSString *)textForEquipSubType:(MFGearEquipSubType)t;

/// 自检：不读内存，只验值域规则与枚举映射是否自洽
- (NSString *)selfCheckReport;

@end

NS_ASSUME_NONNULL_END
