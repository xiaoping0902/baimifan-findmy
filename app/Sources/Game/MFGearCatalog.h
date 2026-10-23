//
//  MFGearCatalog.h — 物资 / 装备的分类目录
//
//  ── 这个文件解决的问题 ──
//
//  绘制层原来用「类名包含某关键词」来判定 Actor 是人是物：
//      lootKeys = @[@"Item", @"Pickup", @"Loot", @"Weapon", ...]
//  只要类名里出现 Pickup 就当物资。
//
//  这个办法的问题不是"漏"，是"脏"：ULevel::Actors 是**整个关卡**的 Actor
//  列表，里面有 PickupManager / PickupStaticMeshComponent / NearbyPickupHUD /
//  DFMAITask_Pickup / PickupProjectileMovementComponent 这一堆——
//  它们全都含 "Pickup"，全都不是拾取物。反过来真物资也可能叫别的名字。
//
//  所以这里换成**真实类名表**：游戏 1.201.37117 的 Dumper-7 SDK 里，
//  拾取物是一条明确的继承链（见下），精确到类名，不靠猜。
//
//  ── 拾取物的真实继承链（来源：Dumper-7 SDK / GObjects-Dump-WithProperties.txt）──
//
//      DFMGameplay.PickupBase                          ← 所有拾取物 Actor 的基类
//        DFMGameplay.InventoryPickup                   ← 可搜索容器（打开后出物品列表）
//          InventoryPickup_Container
//          InventoryPickup_DeadBody                    ← 尸体盒（真人死亡掉落）
//          InventoryPickup_DeadBodyQuest
//          InventoryPickup_DeadBodyWithSpecialEffect
//          InventoryPickup_JailBreakDeadBody
//          InventoryPickup_OpenBox
//          InventoryPickup_OpenBoxServer
//          InventoryPickup_WeaponModule
//          InventoryPickup_EggGoldenNest
//          InventroyPickup_CollectionRoomPutBack       ← 原文拼写就是 Inventroy，别"修正"
//        DFMGameplay.PlunderPickup                     ← 掠夺容器
//      BombDefusal.InventoryPickup_BombDefusalDeadBody
//      BombDefusal.InventoryPickup_BombDefusalWeaponModule
//      PropHunt.PropHuntInventoryPickup_DeadBody
//      SOL.InventoryPickup_TradeContainer
//      SafeHouse.CollectionRoomPickupPlaceActor
//
//  名字里带 Pickup 但**不是**拾取物 Actor 的（同类但属于组件/UI/逻辑/资源）：
//      PickupManager / PickupLibrary / PickupFactoryComponent / PickupNtyInterface
//      PickupProjectileMovementComponent / PickupStaticMeshComponent
//      PickupBaseHudView / NearbyPickupHUD / NearbyPickupItem / PickupItemHudView
//      DFMAITask_Pickup / DFMAIDecorator_NearbyPickupCheck / InteractorSinglePickupExecutor
//      PickupOpenBoxAnimInstance / BombDefusalWeaponPickupOutlineConfigAsset
//    这些**会**被 GNames 解出名字，但绝不会出现在 ULevel::Actors 里当 Actor 画。
//    本目录把它们归到 Ignored，避免误画。
//
//  ── 与绘制层的分工 ──
//
//  本文件只回答两个问题，**不读游戏内存**：
//      ① 这个类名的 Actor 该不该画？画成人物 / 地面物资 / 容器？
//      ② 光凭类名能确定它属于哪一类装备？（能确定的很少，见 categoryForClassName）
//
//  「这个物资叫什么名字、几级、值多少钱、是什么装备」必须读物品定义才知道，
//  那部分是 MFGearReader 的活。类名给不了答案 —— 别在本文件里编。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Actor 用途

/// 一个 Actor 该被怎么画。
typedef NS_ENUM(NSInteger, MFGearActorKind) {
    /// 不画。要么不是 Actor（组件/UI/管理器），要么是地图静态物件。
    MFGearActorKindIgnored = 0,
    /// 可战斗角色（玩家 / 人机）
    MFGearActorKindCharacter,
    /// 地面物资 —— 走过去能直接捡
    MFGearActorKindLoot,
    /// 可搜索容器 —— 需要"打开"才出物品（盒子 / 箱子 / 尸体）
    MFGearActorKindContainer,
};

#pragma mark - 装备类别

/// 装备类别。
///
/// ★ 注意可信度差异 ★
///   · 由**类名**能确定的：只有少数几个容器类带明确类型（WeaponModule / AmmoBox / …），
///     这些标 [类名可定]。
///   · 其余全部要从**物品定义**读（物品类型枚举 / 类别字段），标 [需读物品定义]。
///   · 所以本枚举在类名阶段大多是 Unknown —— 这是诚实的，不是缺陷。
typedef NS_ENUM(NSInteger, MFGearCategory) {
    MFGearCategoryUnknown = 0,
    MFGearCategoryWeapon,        // 武器           [需读物品定义]
    MFGearCategoryAttachment,    // 配件/枪改       [需读物品定义]
    MFGearCategoryArmor,         // 护甲（头/甲）    [需读物品定义]
    MFGearCategoryAmmo,          // 弹药           [类名可定:AmmoPickup/AmmoBox]
    MFGearCategoryMedical,       // 医疗           [需读物品定义]
    MFGearCategoryBackpack,      // 背包           [需读物品定义]
    MFGearCategoryKey,           // 钥匙/门禁       [需读物品定义]
    MFGearCategoryValuable,      // 贵重（金条/情报/金蛋）  [类名可定:EggGoldenNest]
    MFGearCategoryQuest,         // 任务物品        [类名可定:*Quest*]
    MFGearCategoryContainer,     // 容器本身        [类名可定:InventoryPickup*]
};

#pragma mark - 目录

@interface MFGearCatalog : NSObject

+ (instancetype)shared;

/// 类名 → 该画成什么。
/// 入参可以是 GNames 解出来的裸类名（"InventoryPickup_DeadBody"），
/// 也可以带模块前缀（"DFMGameplay.InventoryPickup_DeadBody"）或蓝图后缀（"..._C"）。
- (MFGearActorKind)actorKindForClassName:(NSString *_Nullable)className;

/// 类名 → 装备类别（能确定的才返回非 Unknown）。
- (MFGearCategory)categoryForClassName:(NSString *_Nullable)className;

/// 是否能识别为拾取物体系（含容器）。给诊断日志用：
/// 一个关卡里如果这个比例极低，说明 GNames 解析或类名表需要更新。
- (BOOL)isPickupLineageClassName:(NSString *_Nullable)className;

#pragma mark 显示文本

- (NSString *)textForActorKind:(MFGearActorKind)kind;
- (NSString *)textForCategory:(MFGearCategory)category;

/// 类名 → 可读标签。给"还没读到物品定义时"的兜底显示用。
/// 例：InventoryPickup_DeadBody → "尸体盒"，PickupBase → "物资"
- (NSString *_Nullable)fallbackLabelForClassName:(NSString *_Nullable)className;

/// 自检：把内置类名表逐条过一遍分类，返回报告。
/// 用途：CI / 真机启动时确认表本身没写错（不依赖任何游戏内存）。
- (NSString *)selfCheckReport;

@end

NS_ASSUME_NONNULL_END
