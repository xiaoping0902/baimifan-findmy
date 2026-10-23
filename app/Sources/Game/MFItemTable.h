//
//  MFItemTable.h — 物品定义表（DataTable）查询
//
//  ══════════════════════════════════════════════════════════════════════
//  【为什么需要这个模块】
//
//  装备 ESP 需要「这个物资几级、值多少钱、叫什么名字」。
//
//  这些字段**不在 Actor 上**。Actor（PickupBase）身上只有：
//      InventoryIdName(0x0FF0) 物品 ID（FName）
//      ItemID.Category/Sequence 物品类型
//      ItemCount / StarNum / Durability
//
//  `Quality` / `InitialGuidePrice` / `Name` 在**物品定义表**里：
//      结构 FDFMCommonItemRow（576 字节，Dumper-7 直读）
//          +0x0010  ItemID              FName      ← 表的主键
//          +0x0018  Name                FText      ← 中文显示名
//          +0x0050  ShortName           FText
//          +0x0068  Quality             int32      ← ★ 等级
//          +0x00DC  InitialGuidePrice   int32      ← ★ 价值
//          +0x01B8  bValuableItem       bool       ← 贵重标志
//
//  ★ 白米饭那两个「Actor+0x68 / Actor+0xDC」就是这两个字段的偏移 ——
//    偏移值本身没错，错的是**拿它去加到 Actor 上**。
//    正确做法是：先找到表、查出那一行、再把偏移加到**行**上。
//
//  ══════════════════════════════════════════════════════════════════════
//  【怎么找到那张表】
//
//  游戏里 427 个 DataTable 实例。我们要的是 GameItem.GameItem。
//
//  定位不靠扫名字，靠 **GObjects 数组下标**：同一游戏版本内，
//  一个 UObject 的 InternalIndex 是稳定的（dump 与运行时一致）。
//  所以 dump 里记下的下标可以直接用：
//      GameItem.GameItem            [0001B602]
//      ItemPriceTable.ItemPriceTable[0001B5C1]
//      DFMCommonItemRow（RowStruct）[000070DD]
//
//  取到 GameItem 之后，用 **RowStruct 指针相等** 来校验它确实是物品表：
//      Read<u64>(dataTable + 0x28) == 地址(DFMCommonItemRow)
//  这比比对类名字符串可靠 —— 名字可能被本地化/改写，指针不会说谎。
//
//  ══════════════════════════════════════════════════════════════════════
//  【GObjects 的布局（dump 日志第 45-51 行 + Basic.hpp:235-290 双证）】
//
//      GObjects 静态偏移(RVA)  = 0x177A17B8
//      TUObjectArray:
//          +0x14  int32 NumElements        (= 114784)
//          +0x18  int32 NumChunks
//          +0x20  FUObjectItem** Objects   ← 块指针数组（UE 标准是 +0x00，本作改造过）
//      ElementsPerChunk = 0x10000
//      FUObjectItem: +0x00 UObject* Object，stride = 0x18
//
//  ══════════════════════════════════════════════════════════════════════
//  【最大的不确定处：TMap 的元素布局】
//
//      UDataTable::RowMap 是 TMap<FName, uint8*>，位于 +0x30，大小 0x50。
//      TMap = TSet<TPair<FName, uint8*>>，TSet 内是 TSparseArray：
//          +0x00 TArray::Data   (ptr@0x00 / num@0x08)
//      元素是 TSetElement<TPair<FName,uint8*>>，但字段顺序有两种可能：
//          A) Value 在前：FName(8) + ptr(8) + HashNextId(4) + HashIndex(4) = 24
//          B) Hash 在前：HashNextId(4) + HashIndex(4) + FName(8) + ptr(8) = 24
//      UE 各版本不同，Dumper 作者在源码里也只留了一句 "Good luck with it"。
//
//  ⇒ 所以本模块**运行时自探**：读第一行，看前 8 字节像 FName 索引、
//    后 8 字节像合法堆指针，就判 A；反过来判 B。并用「多行都能过校验」
//    来交叉确认，结论打进日志。
//
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 表里一行的关键属性
@interface MFItemRow : NSObject
@property (nonatomic, assign) uint32_t comparisonIndex;
@property (nonatomic, assign) uint32_t number;
/// 等级（FDFMCommonItemRow.Quality @0x68）。-1 = 没读到
@property (nonatomic, assign) int quality;
/// 价值（FDFMCommonItemRow.InitialGuidePrice @0xDC）。-1 = 没读到
@property (nonatomic, assign) int price;
/// 贵重标志（bValuableItem @0x1B8）
@property (nonatomic, assign) BOOL valuable;
/// 行在远程内存里的地址（诊断用）
@property (nonatomic, assign) uint64_t rowAddress;
@end

@interface MFItemTable : NSObject

+ (instancetype)shared;

#pragma mark 生命周期

/// 定位并加载表（幂等）。返回 YES 表示可用。
/// 内部：定位 GameItem → 校验 RowStruct → 遍历 RowMap 建索引。
- (BOOL)loadIfNeeded;

/// 丢掉已加载的表，下次重新定位（游戏更新 / 换地图后调用）
- (void)reset;

@property (nonatomic, readonly) BOOL ready;
/// 表里有多少行（RowMap 的 Num）
@property (nonatomic, readonly) NSUInteger rowCount;
/// 自探结论（TMap 元素布局 / 各步结果），可直接 NSLog
@property (nonatomic, readonly) NSString *probeReport;

#pragma mark 查询

/// 按 FName 查行。
/// comparisonIndex / number 直接来自 PickupBase.InventoryIdName（FName，8 字节）。
/// 命中返回 YES 并填充 out 参数；未命中返回 NO。
- (BOOL)lookupComparisonIndex:(uint32_t)comparisonIndex
                       number:(uint32_t)number
                         row:(MFItemRow *_Nullable *_Nullable)outRow;

/// 按 FName → 字符串（需要先注入 nameLookup）查行，供调试/日志用
- (BOOL)lookupItemIdString:(NSString *)itemId row:(MFItemRow *_Nullable *_Nullable)outRow;

/// 名字解析回调（FName 索引 → 字符串）。由上层注入（通常是 MFUEGNames）。
@property (nonatomic, copy, nullable) NSString *_Nullable (^nameLookup)(uint32_t comparisonIndex);

/// 诊断：把表里前 limit 行的 (ItemID, Quality, Price) 打出来。
/// 这是"表到底读到没有"的最直接证据。
- (NSString *)sampleReport:(NSUInteger)limit;

@end

NS_ASSUME_NONNULL_END
