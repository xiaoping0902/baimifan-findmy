//
//  MFGearReader.mm — 物资 / 装备属性读取的实现
//
//  ── 读取策略：三次读，带缓存 ──
//
//  mach_vm_remap 每次映射一页、拷完立刻解除映射 —— 一次 readRemote 就是一次系统调用。
//  一个关卡里有几百个 Actor，如果每个字段读一次，主线程会被钉死。
//  所以这里把需要的字段**按页内邻近关系打包**，一个 Actor 最多读三次：
//
//    读 1  actor + 0x0FB8，0x70 字节   → PickupBase 头（来源/物品名/数量/耐久）
//    读 2  actor + 0x1248，0x40 字节   → ItemID.Category / Sequence / ItemCount
//    读 3  actor + 0x1768，0x40 字节   → ArchiveInfo.EquipmentValue / StarNum
//
//  三次都落在对象头部第一页（16KB 页内），不跨页，安全。
//  读 2 / 读 3 只在"类名看起来是容器"时才做 —— 地面散落物没有 PickupItemInfo。
//
//  再加一层按地址的短 TTL 缓存（2 秒）：物品属性不会逐帧变，
//  但 Actor 指针会被回收复用，所以 TTL 不能太长。
//
//  ── 能力边界（重要：别把话说满）──
//
//  静态 dump 能回答"字段在哪"，回答不了"值是多少"。所以本模块的真实能力是：
//
//    ✅ 能拿到
//        · 物品主类型  ItemID.Category（= EEItemMainType，装备分类的依据）
//        · 具体物品号  ItemID.Sequence
//        · 数量        ItemCount（容器内）/ StackCount（地面）
//        · 星级        StarNum（Actor + 0x17A4）
//        · 来源        SourceType（= EEPickupSourceType）
//        · 容器内容    RepItemArray → 盒子里每一件物品的类型与数量
//
//    ⚠️ 有条件
//        · 价值 ArchiveInfo.EquipmentValue（Actor + 0x1768）
//          它住在 FItemArchiveInfo 里 —— 那个结构是"击杀来历档案"，
//          同一块里还有 KillerName / BeKilledUin / MapID / KillerAmmoLevel。
//          所以它对**尸体 / 玩家掉落**有意义（"这人死时装备值多少"），
//          对**自然刷新的地面物资**很可能是 0。真机必须抽样确认，不能当通用价值用。
//
//    ❌ 拿不到
//        · 1–6 级品质。全库 12,619 个类里没有任何物品 Actor 带 Quality/Tier/Rarity；
//          EEEquipLevel(0–6) 枚举 0 处字段引用。品质只存在于物品配置行
//          FDFMCommonItemRow.Quality(0x68) 与 InitialGuidePrice(0xDC) ——
//          而配置表是 UDataTable，RowMap 是 TMap，内部布局无 SDK 背书。
//          ★ 白米饭之所以有 0x68/0xDC，正是因为它读的是**配置行**，不是 Actor。
//            我们走 Actor 路径，这两项拿不到 —— 绘制层请按 StarNum / 价值分档配色，
//            不要假装有品质。
//
#import "MFGearReader.h"
#import "MFGearCatalog.h"
#import "MFItemTable.h"      /* [M5.86] 物品定义表：等级/价值/名字的真实来源 */
#import "MFUEOffsets.h"
#import "../Read/MFReadBackend.h"
#import <QuartzCore/QuartzCore.h>   /* CACurrentMediaTime（缓存 TTL 计时） */
#import <string.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - PickupBase（DFMGameplay.PickupBase，自有字段起点 0x0FB8）

/// 一次读的起点与长度（见文件头"读取策略"）
static const uint32_t kMFGear_Read1_Base   = 0x0FB8;
static const uint32_t kMFGear_Read1_Length = 0x70;

// 下面这些是**绝对偏移**；相对 kMFGear_Read1_Base 的索引写在注释里
static const uint32_t kMFGear_PickupBase_bIsHiddenItem  = 0x0FC0;  // bool   → head[0x08]
static const uint32_t kMFGear_PickupBase_SourceType     = 0x0FE0;  // uint8  → head[0x28]
static const uint32_t kMFGear_PickupBase_InventoryIdName= 0x0FF0;  // FName  → head[0x38] 8 字节
static const uint32_t kMFGear_PickupBase_InventoryType  = 0x0FF8;  // UClass*→ head[0x40]
static const uint32_t kMFGear_PickupBase_StackCount     = 0x1000;  // int32  → head[0x48]
static const uint32_t kMFGear_PickupBase_Durability     = 0x1008;  // int32  → head[0x50]

#pragma mark - InventoryPickup（容器）

static const uint32_t kMFGear_PickupItemInfo_Base = 0x1240;   // FInventoryItemInfo 起点

static const uint32_t kMFGear_Read2_Base   = 0x1248;          // = 0x1240 + 0x08
static const uint32_t kMFGear_Read2_Length = 0x40;
static const uint32_t kMFGear_ItemID_Category  = 0x1250;      // = 0x1240 + 0x10  → r2[0x08]
static const uint32_t kMFGear_ItemID_Sequence  = 0x1254;      // = 0x1240 + 0x14  → r2[0x0C]
static const uint32_t kMFGear_ItemInfo_ItemCount = 0x1278;    // = 0x1240 + 0x38  → r2[0x30]

static const uint32_t kMFGear_Read3_Base    = 0x1768;
/// 长度 0x48：要覆盖到 StarNum（0x17A4，rel 0x3C，4 字节 → 到 0x40）。
/// 原来写 0x40 时 rel 0x3C + 4 正好顶到边界，自检按 8 字节余量算会判越界 ——
/// 这类"差 4 字节"的边界在 C 里最容易写错又最难发现，所以直接留足余量。
static const uint32_t kMFGear_Read3_Length  = 0x48;
/// ArchiveInfo.EquipmentValue = 0x1240 + 0x2E8(ArchiveInfo) + 0x240(EquipmentValue)
static const uint32_t kMFGear_Archive_EquipmentValue = 0x1768; // int64 → r3[0x00]
/// StarNum = 0x1240 + 0x564
static const uint32_t kMFGear_ItemInfo_StarNum       = 0x17A4; // int32 → r3[0x3C]

#pragma mark - 值域上限

/// 数量上限。正常一堆物品不会超过这个量级；超过说明读错或偏移失效。
static const int32_t kMFGear_MaxCount = 10000;
/// 价值上限（1 亿）。三角洲里最贵的物资也在百万级，1 亿足够宽。
static const long long kMFGear_MaxValue = 100000000LL;
/// 星级上限
static const int32_t kMFGear_MaxStar = 10;
/// 属性缓存时长（秒）
static const NSTimeInterval kMFGear_CacheTTL = 2.0;

#pragma mark - 容器内容（AInventoryPickup_Container::RepItemArray）

/*
 * ★ 盒子/尸体里到底有什么 —— 这条链是本次新增的能力 ★
 *
 * AInventoryPickup_Container::RepItemArray(0x1F38) → FItemArray::Items
 *   Items 是 TArray<FInventoryItemInfo>，绝对偏移：
 *       Data  = 0x2040 (u64)
 *       Num   = 0x2048 (int32)
 *       步长  = 0x800（= FInventoryItemInfo 的 2048 字节）
 *
 * 来源：sdk-gear《装备对接-SDK偏移表.md》。
 * DeadBody / OpenBox / TradeContainer / PropHunt 尸体全部继承同一条链 ——
 * 所以一条路径通吃所有可搜索容器。
 *
 * 代价：每件物品要多一次远程读（只读 ItemID + Count 那 0x40 字节，不读整件）。
 * 一个盒子 20 件就是 20 次读，所以：
 *   · 上限 32 件（kMFGear_Container_MaxItems）
 *   · 只在调用方明确要展开时才读（绘制层按距离/开关决定）
 *   · 结果同样进 2 秒缓存
 */
static const uint32_t kMFGear_Container_ItemsData  = 0x2040;
static const uint32_t kMFGear_Container_ItemsNum   = 0x2048;
static const uint32_t kMFGear_Container_ItemStride = 0x800;
static const uint32_t kMFGear_Container_MaxItems   = 32;

// 展开单件时用的**相对** FInventoryItemInfo 起点的偏移（不是 Actor 绝对偏移）
static const uint32_t kMFGear_ItemSt_ReadBase  = 0x08;   // 从 +0x08 读，覆盖 0x08..0x48
static const uint32_t kMFGear_ItemSt_ReadLen   = 0x40;
static const uint32_t kMFGear_ItemSt_Category  = 0x10;   // = ItemID + 0x00
static const uint32_t kMFGear_ItemSt_Sequence  = 0x14;   // = ItemID + 0x04
static const uint32_t kMFGear_ItemSt_Count     = 0x38;

#pragma mark - 小工具

/// 从字节缓冲里按小端读 int32（不假设缓冲地址对齐）
static inline int32_t MFGearReadI32(const uint8_t *p) {
    int32_t v = 0;
    memcpy(&v, p, 4);
    return v;
}
/// 从字节缓冲里按小端读 int64
static inline int64_t MFGearReadI64(const uint8_t *p) {
    int64_t v = 0;
    memcpy(&v, p, 8);
    return v;
}
static inline uint32_t MFGearReadU32(const uint8_t *p) {
    uint32_t v = 0;
    memcpy(&v, p, 4);
    return v;
}

#pragma mark - MFGearInfo

@implementation MFGearInfo

- (instancetype)init {
    if ((self = [super init])) {
        _mainType = MFGearItemMainTypeNone;
        _equipSubType = MFGearEquipSubTypeNone;
    }
    return self;
}

- (NSString *)summary {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@", self.itemIdName ?: @"(无名)"];
    [s appendFormat:@" · %@", [MFGearReader textForMainType:self.mainType]];
    if (self.mainType == MFGearItemMainTypeEquip) {
        [s appendFormat:@"/%@", [MFGearReader textForEquipSubType:self.equipSubType]];
    }
    if (self.count > 0)  [s appendFormat:@" ×%d", self.count];
    if (self.hasValue)   [s appendFormat:@" 价值%lld", self.value];
    if (self.hasStar)    [s appendFormat:@" %d星", self.starNum];
    if (self.isContainer) [s appendString:@" [容器]"];
    if (!self.trustworthy) [s appendString:@" ⚠︎不可信"];
    return s;
}

@end

#pragma mark - MFGearReader

@implementation MFGearReader {
    NSMutableDictionary<NSNumber *, MFGearInfo *> *_cache;
    NSMutableDictionary<NSNumber *, NSNumber *>   *_cacheAt;
    /// 容器内容缓存（与物品属性分开：展开一次要 N+1 次读，更不能重复做）
    NSMutableDictionary<NSNumber *, NSArray<MFGearInfo *> *> *_itemsCache;
    NSMutableDictionary<NSNumber *, NSNumber *>   *_itemsCacheAt;
    /// 物品表加载失败后的重试节流（每次重试要几次远程读，不能每帧做）
    CFTimeInterval _tableRetryAt;
}

+ (instancetype)shared {
    static MFGearReader *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[MFGearReader alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache   = [NSMutableDictionary dictionary];
        _cacheAt = [NSMutableDictionary dictionary];
        _itemsCache   = [NSMutableDictionary dictionary];
        _itemsCacheAt = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark 值域校验

+ (BOOL)isValidMainType:(uint32_t)v {
    // 与 EEItemMainType 的已知取值一一对应（EnumsInfo.json 直读）
    switch (v) {
        case 0: case 10: case 11: case 12: case 13: case 14: case 15:
        case 16: case 17: case 18: case 19: case 21: case 22: case 24:
        case 25: case 28: case 30: case 31: case 37: case 38: case 39:
        case 40: case 41: case 88:
            return YES;
        default:
            return NO;
    }
}

+ (BOOL)isPlausibleCount:(int32_t)v {
    return (v > 0 && v <= kMFGear_MaxCount);
}

+ (BOOL)isPlausibleValue:(long long)v {
    return (v >= 0 && v <= kMFGear_MaxValue);
}

#pragma mark 主读取

- (MFGearInfo *_Nullable)readGearForActor:(uint64_t)actor
                                className:(NSString *_Nullable)className
                                  isActor:(BOOL *)outIsActor {
    if (outIsActor) *outIsActor = NO;
    if (!MFUEIsValidPtr(actor)) return nil;

    /*
     * ① 先用类名决定"要不要读"。
     *    这一步很便宜（纯字符串），而 ULevel::Actors 里绝大多数 Actor 是地图静态物件 ——
     *    在读内存之前把它们挡掉，是性能上最划算的一道闸。
     */
    MFGearCatalog *cat = [MFGearCatalog shared];
    MFGearActorKind kind = [cat actorKindForClassName:className];
    if (kind == MFGearActorKindIgnored) return nil;
    if (outIsActor) *outIsActor = YES;
    if (kind == MFGearActorKindCharacter) return nil;   // 人物不归本类管

    const BOOL looksContainer = (kind == MFGearActorKindContainer);

    /*
     * ② 缓存。物品属性不会逐帧变，但 Actor 指针会被回收复用 —— 所以 TTL 只给 2 秒。
     */
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *key = @(actor);
    MFGearInfo *cached = _cache[key];
    if (cached) {
        NSNumber *at = _cacheAt[key];
        if (at && now - at.doubleValue <= kMFGear_CacheTTL) {
            return cached;
        }
    }

    MFReadBackend *rb = [MFReadBackend shared];
    if (!rb.gateOpen) return nil;

    // ── 读 1：PickupBase 头 ──────────────────────────────────────────
    uint8_t head[kMFGear_Read1_Length];
    memset(head, 0, sizeof(head));
    if (![rb readRemote:actor + kMFGear_Read1_Base into:head size:sizeof(head)]) {
        return nil;
    }

    MFGearInfo *info = [[MFGearInfo alloc] init];
    info.isContainer = looksContainer;

    // SourceType @ 0x0FE0
    {
        uint8_t raw = head[kMFGear_PickupBase_SourceType - kMFGear_Read1_Base];
        // 值域校验：真实类型是 EEPickupSourceType，只有 0..3
        // （0 Default / 1 BodyBox / 2 Discard / 3 NormalBox）
        info.source = (raw <= 3) ? (MFGearItemSource)raw : MFGearItemSourceDefault;
    }

    // InventoryIdName @ 0x0FF0（FName = ComparisonIndex(4) + Number(4)，共 8 字节）
    {
        const uint32_t base = kMFGear_PickupBase_InventoryIdName - kMFGear_Read1_Base;
        uint32_t nameIndex  = MFGearReadU32(head + base);
        uint32_t nameNumber = MFGearReadU32(head + base + 4);

        if (nameIndex > 0 && nameIndex <= 20000000) {
            info.itemIdNameIndex  = nameIndex;
            info.itemIdNameNumber = nameNumber;
            if (self.nameLookup) info.itemIdName = self.nameLookup(nameIndex);
        }
    }

    // StackCount @ 0x1000
    {
        int32_t v = MFGearReadI32(head + (kMFGear_PickupBase_StackCount - kMFGear_Read1_Base));
        if ([MFGearReader isPlausibleCount:v]) info.count = v;
    }

    /*
     * ③ 容器的物品详情。
     *
     *    ★ 这里刻意**不**只看类名 ★
     *    类名说是容器，也只能说明"它可能是容器"。真正的判据是
     *    PickupItemInfo.ItemID.Category 能不能落进 EEItemMainType 的合法集合 ——
     *    能，才说明 0x1240 这个偏移在当前版本上成立。
     *    所以下面即使 looksContainer 为 NO，只要读出来的 Category 合法，也采信。
     *    （地面散落物没有这段，读出来会是垃圾 → Category 越界 → 不采信，符合预期）
     */
    {
        uint8_t r2[kMFGear_Read2_Length];
        memset(r2, 0, sizeof(r2));
        if ([rb readRemote:actor + kMFGear_Read2_Base into:r2 size:sizeof(r2)]) {
            uint32_t category = MFGearReadU32(r2 + (kMFGear_ItemID_Category - kMFGear_Read2_Base));
            if ([MFGearReader isValidMainType:category] && category != 0) {
                info.mainType = (MFGearItemMainType)category;
                info.sequence = MFGearReadU32(r2 + (kMFGear_ItemID_Sequence - kMFGear_Read2_Base));

                int32_t c = MFGearReadI32(r2 + (kMFGear_ItemInfo_ItemCount - kMFGear_Read2_Base));
                if ([MFGearReader isPlausibleCount:c]) {
                    // 容器里这一堆的数量；地面散落物用 StackCount
                    info.count = c;
                }
                info.trustworthy = YES;
            }
        }
    }

    /*
     * ④ 价值与星级。只有第 ③ 步认出了物品类型才读 ——
     *    否则这两个偏移一定也在读垃圾，白花两次系统调用。
     */
    if (info.mainType != MFGearItemMainTypeNone) {
        uint8_t r3[kMFGear_Read3_Length];
        memset(r3, 0, sizeof(r3));
        if ([rb readRemote:actor + kMFGear_Read3_Base into:r3 size:sizeof(r3)]) {
            long long value = (long long)MFGearReadI64(r3 + (kMFGear_Archive_EquipmentValue - kMFGear_Read3_Base));
            if ([MFGearReader isPlausibleValue:value]) {
                info.value = value;
                info.hasValue = YES;
            }
            int32_t star = MFGearReadI32(r3 + (kMFGear_ItemInfo_StarNum - kMFGear_Read3_Base));
            if (star >= 0 && star <= kMFGear_MaxStar) {
                info.starNum = star;
                info.hasStar = YES;
            }
        }
    }

    /*
     * ⑤ 查物品定义表，拿「等级 / 价值」。
     *
     * ★ 这一步是装备对接的关键补丁 ★
     *
     * 前面的 ③④ 读的都是 Actor 上的字段。但 Quality（等级）和
     * InitialGuidePrice（价值）**不在 Actor 上** —— 它们在物品定义表
     * FDFMCommonItemRow 的某一行里，那一行由 InventoryIdName（FName）当主键。
     *
     * 白米饭的 0x68 / 0xDC 就是这两个字段在**行结构**里的偏移：
     * 在 Actor 上直接加是错的（读到 AActor 头），
     * 正确做法是查到行地址、再在行地址上加。
     *
     * 查表失败（表没加载 / 这行不在表里）时不设置 hasQuality/hasValue，
     * 绘制层退回「只有星级、没有等级」的显示 —— 不伪造。
     */
    if (info.itemIdNameIndex > 0) {
        [self lookupItemTableForInfo:info];
    }

    /*
     * ⑥ 兜底可信度：PickupBase 自己的字段读到了合理值，也算"这条读通了一半"。
     *    注意比 ③ 弱：数量对不代表物品类型对。
     */
    if (!info.trustworthy && (info.count > 0 || info.itemIdName.length > 0)) {
        info.trustworthy = YES;
    }

    _cache[key] = info;
    _cacheAt[key] = @(now);

    // 缓存别无限长 —— 每 256 条清一次过期项
    if (_cache.count > 256) {
        NSMutableArray<NSNumber *> *dead = [NSMutableArray array];
        for (NSNumber *k in _cacheAt) {
            if (now - _cacheAt[k].doubleValue > kMFGear_CacheTTL) [dead addObject:k];
        }
        [_cache removeObjectsForKeys:dead];
        [_cacheAt removeObjectsForKeys:dead];
    }

    return info;
}

#pragma mark 物品定义表

/// 查物品表补 Quality / Price。
///
/// 表加载失败时按 5 秒节流重试 —— 每次 loadIfNeeded 至少要几次远程读，
/// 不能每帧都做。表就绪后 lookup 只读目标行那两个字段（一次读 0x90 字节）。
- (void)lookupItemTableForInfo:(MFGearInfo *)info {
    MFItemTable *table = [MFItemTable shared];

    // 把名字解析回调转发过去（查表本身不依赖名字，但 sampleReport 诊断要用）
    if (table.nameLookup == nil && self.nameLookup != nil) {
        table.nameLookup = self.nameLookup;
    }

    if (!table.ready) {
        const CFTimeInterval now = CACurrentMediaTime();
        if (_tableRetryAt > 0 && now - _tableRetryAt < 5.0) return;
        _tableRetryAt = now;
        if (![table loadIfNeeded]) return;
    }

    MFItemRow *row = nil;
    if ([table lookupComparisonIndex:info.itemIdNameIndex
                              number:info.itemIdNameNumber
                                 row:&row] && row != nil) {
        if (row.quality >= 0) {
            info.quality = row.quality;
            info.hasQuality = YES;
        }
        if (row.price >= 0) {
            info.value = (long long)row.price;
            info.hasValue = YES;
        }
    }
}

#pragma mark 容器内容

- (NSArray<MFGearInfo *> *)containedItemsForActor:(uint64_t)actor {
    if (!MFUEIsValidPtr(actor)) return @[];

    MFReadBackend *rb = [MFReadBackend shared];
    if (!rb.gateOpen) return @[];

    const CFTimeInterval now = CACurrentMediaTime();
    NSNumber *key = @(actor);

    NSArray<MFGearInfo *> *cachedList = _itemsCache[key];
    if (cachedList) {
        NSNumber *at = _itemsCacheAt[key];
        if (at && now - at.doubleValue <= kMFGear_CacheTTL) return cachedList;
    }

    // ── TArray 头：Data(u64) @0x2040 + Num(i32) @0x2048，一次读 12 字节 ──
    uint8_t hdr[12];
    memset(hdr, 0, sizeof(hdr));
    if (![rb readRemote:actor + kMFGear_Container_ItemsData into:hdr size:sizeof(hdr)]) {
        _itemsCache[key] = @[];
        _itemsCacheAt[key] = @(now);
        return @[];
    }
    uint64_t data = (uint64_t)MFGearReadI64(hdr);
    int32_t num = MFGearReadI32(hdr + 8);

    /*
     * 值域校验（这一步是"偏移是否成立"的判据）：
     *   Data 必须是合法指针、Num 必须是 1..32。
     *   注意 Num 用**上限**而不是"越大越好"—— 这个字段读错时会是一个巨大的数，
     *   放任它循环就是几百次远程读，直接把帧率拖死。
     */
    if (!MFUEIsValidPtr(data) || num <= 0 || num > (int32_t)kMFGear_Container_MaxItems) {
        _itemsCache[key] = @[];
        _itemsCacheAt[key] = @(now);
        return @[];
    }

    NSMutableArray<MFGearInfo *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)num];
    const uint32_t relCat  = kMFGear_ItemSt_Category - kMFGear_ItemSt_ReadBase;
    const uint32_t relSeq  = kMFGear_ItemSt_Sequence - kMFGear_ItemSt_ReadBase;
    const uint32_t relCnt  = kMFGear_ItemSt_Count    - kMFGear_ItemSt_ReadBase;

    for (int32_t i = 0; i < num; i++) {
        uint64_t item = data + (uint64_t)i * kMFGear_Container_ItemStride;
        if (!MFUEIsValidPtr(item)) continue;

        uint8_t buf[kMFGear_ItemSt_ReadLen];
        memset(buf, 0, sizeof(buf));
        if (![rb readRemote:item + kMFGear_ItemSt_ReadBase into:buf size:sizeof(buf)]) continue;

        uint32_t category = MFGearReadU32(buf + relCat);
        if (![MFGearReader isValidMainType:category] || category == 0) continue;

        MFGearInfo *it = [[MFGearInfo alloc] init];
        it.mainType = (MFGearItemMainType)category;
        it.sequence = MFGearReadU32(buf + relSeq);
        it.isContainer = NO;

        int32_t c = MFGearReadI32(buf + relCnt);
        if ([MFGearReader isPlausibleCount:c]) it.count = c;

        it.trustworthy = YES;
        [out addObject:it];
    }

    _itemsCache[key] = [out copy];
    _itemsCacheAt[key] = @(now);

    // 同样别让缓存无限长
    if (_itemsCache.count > 128) {
        NSMutableArray<NSNumber *> *dead = [NSMutableArray array];
        for (NSNumber *k in _itemsCacheAt) {
            if (now - _itemsCacheAt[k].doubleValue > kMFGear_CacheTTL) [dead addObject:k];
        }
        [_itemsCache removeObjectsForKeys:dead];
        [_itemsCacheAt removeObjectsForKeys:dead];
    }

    return [out copy];
}

#pragma mark 文案

+ (NSString *)textForMainType:(MFGearItemMainType)t {
    switch (t) {
        case MFGearItemMainTypeWeapon:        return @"武器";
        case MFGearItemMainTypeEquip:         return @"装备";
        case MFGearItemMainTypeWeaponExtra:   return @"武器附件";
        case MFGearItemMainTypeAdapter:       return @"配件";
        case MFGearItemMainTypeMedicine:      return @"医疗";
        case MFGearItemMainTypeCollection:    return @"收藏品";
        case MFGearItemMainTypeSundry:        return @"杂物";
        case MFGearItemMainTypeBox:           return @"箱子";
        case MFGearItemMainTypeWeaponStruct:  return @"武器结构";
        case MFGearItemMainTypeFood:          return @"食物";
        case MFGearItemMainTypeThrowable:     return @"投掷物";
        case MFGearItemMainTypePerk:          return @"增益";
        case MFGearItemMainTypeGadget:        return @"道具";
        case MFGearItemMainTypeItemSkill:     return @"技能物品";
        case MFGearItemMainTypeWeaponSkin:    return @"武器皮肤";
        case MFGearItemMainTypeFashion:       return @"外观";
        case MFGearItemMainTypePoorWeapon:    return @"低价值武器";
        case MFGearItemMainTypeAmmo:          return @"弹药";
        case MFGearItemMainTypeCommercialize: return @"商业化";
        case MFGearItemMainTypeVehicle:       return @"载具";
        case MFGearItemMainTypeVehicleAdapter:return @"载具配件";
        case MFGearItemMainTypeVehicleSkin:   return @"载具皮肤";
        case MFGearItemMainTypeHero:          return @"英雄";
        default:                              return @"未知";
    }
}

+ (NSString *)textForEquipSubType:(MFGearEquipSubType)t {
    switch (t) {
        case MFGearEquipSubTypeHelmet:      return @"头盔";
        case MFGearEquipSubTypeBreastPlate: return @"胸甲";
        case MFGearEquipSubTypeChestHang:   return @"胸挂";
        case MFGearEquipSubTypeBag:         return @"背包";
        case MFGearEquipSubTypeSafeBox:     return @"安全箱";
        case MFGearEquipSubTypeKeyChain:    return @"钥匙链";
        default:                            return @"";
    }
}

#pragma mark 自检

- (NSString *)selfCheckReport {
    NSMutableString *s = [NSMutableString string];
    NSUInteger bad = 0;

    // ① 合法 mainType 必须全部通过校验，非法值必须被拒
    uint32_t good[] = {0,10,11,12,13,14,15,16,17,18,19,21,22,24,25,28,30,31,37,38,39,40,41,88};
    for (size_t i = 0; i < sizeof(good)/sizeof(good[0]); i++) {
        if (![MFGearReader isValidMainType:good[i]]) {
            bad++; [s appendFormat:@"  ✗ 合法类型被拒：%u\n", good[i]];
        }
    }
    uint32_t badv[] = {1,2,9,20,23,26,27,29,32,36,42,50,100,0xFFFFFFFF};
    for (size_t i = 0; i < sizeof(badv)/sizeof(badv[0]); i++) {
        if ([MFGearReader isValidMainType:badv[i]]) {
            bad++; [s appendFormat:@"  ✗ 非法类型被放行：%u\n", badv[i]];
        }
    }

    // ② 数量 / 价值 值域
    struct { int32_t v; BOOL ok; } countCases[] = {
        {0, NO}, {-1, NO}, {1, YES}, {48, YES}, {999, YES}, {10000, YES}, {10001, NO},
    };
    for (size_t i = 0; i < sizeof(countCases)/sizeof(countCases[0]); i++) {
        if ([MFGearReader isPlausibleCount:countCases[i].v] != countCases[i].ok) {
            bad++; [s appendFormat:@"  ✗ 数量校验不符：%d\n", countCases[i].v];
        }
    }
    struct { long long v; BOOL ok; } valueCases[] = {
        {-1, NO}, {0, YES}, {3500, YES}, {99999999, YES}, {100000000, YES}, {100000001, NO},
    };
    for (size_t i = 0; i < sizeof(valueCases)/sizeof(valueCases[0]); i++) {
        if ([MFGearReader isPlausibleValue:valueCases[i].v] != valueCases[i].ok) {
            bad++; [s appendFormat:@"  ✗ 价值校验不符：%lld\n", valueCases[i].v];
        }
    }

    // ③ 偏移换算自洽：读缓冲内的索引必须落在缓冲长度之内
    //    （这类写错是 C 里最容易犯又最难发现的越界）
    struct { const char *name; uint32_t absOff; uint32_t base; uint32_t len; } bounds[] = {
        {"SourceType",      kMFGear_PickupBase_SourceType,      kMFGear_Read1_Base, kMFGear_Read1_Length},
        {"InventoryIdName", kMFGear_PickupBase_InventoryIdName, kMFGear_Read1_Base, kMFGear_Read1_Length},
        {"StackCount",      kMFGear_PickupBase_StackCount,      kMFGear_Read1_Base, kMFGear_Read1_Length},
        {"ItemID.Category", kMFGear_ItemID_Category,            kMFGear_Read2_Base, kMFGear_Read2_Length},
        {"ItemID.Sequence", kMFGear_ItemID_Sequence,            kMFGear_Read2_Base, kMFGear_Read2_Length},
        {"ItemCount",       kMFGear_ItemInfo_ItemCount,         kMFGear_Read2_Base, kMFGear_Read2_Length},
        {"EquipmentValue",  kMFGear_Archive_EquipmentValue,     kMFGear_Read3_Base, kMFGear_Read3_Length},
        {"StarNum",         kMFGear_ItemInfo_StarNum,           kMFGear_Read3_Base, kMFGear_Read3_Length},
    };
    for (size_t i = 0; i < sizeof(bounds)/sizeof(bounds[0]); i++) {
        if (bounds[i].absOff < bounds[i].base) {
            bad++; [s appendFormat:@"  ✗ %s 绝对偏移小于读起点\n", bounds[i].name];
            continue;
        }
        uint32_t rel = bounds[i].absOff - bounds[i].base;
        // EquipmentValue 是 8 字节，其余按 4 字节算，留够余量
        uint32_t need = rel + 8;
        if (need > bounds[i].len) {
            bad++; [s appendFormat:@"  ✗ %s 越界：rel=0x%X need=%u len=%u\n",
                    bounds[i].name, rel, need, bounds[i].len];
        }
    }

    [s appendFormat:@"值域/枚举/越界 检查失败 %lu 项\n", (unsigned long)bad];
    return [NSString stringWithFormat:@"[装备读取自检] %@\n%@",
            bad == 0 ? @"✓ 全通过" : @"✗ 有失败项", s];
}

@end

NS_ASSUME_NONNULL_END
