//
//  MFItemTable.mm — 物品定义表查询的实现
//
//  实现策略（按代价从低到高，失败才降级）：
//
//    ① 按 GObjects 下标直取 GameItem（3 次读）
//       —— 同一版本内 InternalIndex 稳定，dump 与运行时一致
//    ② 用 RowStruct 指针相等校验「这确实是物品表」（再 2 次读）
//    ③ 遍历 RowMap 建 FName → rowPtr 索引（分批读，一次加载）
//    ④ 查询时只读目标行的 Quality / Price（2 次读），带缓存
//
//  任何一步失败都不崩：返回 NO / nil，上层退回"没有等级和价值"的显示。
//
#import "MFItemTable.h"
#import "MFUEOffsets.h"
#import "MFUEReader.h"        /* 只为拿 libBase（模块基址） */
#import "../Read/MFReadBackend.h"
#import <string.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - GObjects（来源：MobileDumper7.log 第 45-51 行 + Basic.hpp:235-290）

/// GObjects 静态偏移（RVA，相对主程序模块基址）
static const uint64_t kMFItem_GObjectsRVA          = 0x177A17B8ULL;
/// TUObjectArray 字段（注意：Objects 在 +0x20，UE 标准是 +0x00 —— 本作改造过）
static const uint32_t kMFItem_ObjArray_NumElements = 0x14;
static const uint32_t kMFItem_ObjArray_NumChunks   = 0x18;
static const uint32_t kMFItem_ObjArray_Objects     = 0x20;
static const uint32_t kMFItem_ElementsPerChunk     = 0x10000;
/// FUObjectItem: +0x00 UObject*，整项 0x18
static const uint32_t kMFItem_FUObjectItem_Object  = 0x00;
static const uint32_t kMFItem_FUObjectItemStride   = 0x18;

#pragma mark - UObject / UDataTable / 行结构

/// 本作 UObject 布局（dump 日志 210-215 行）：Class@0x08 / Name@0x1C
static const uint32_t kMFItem_UObject_Class = 0x08;
static const uint32_t kMFItem_UObject_Name  = 0x1C;

/// UDataTable（Engine_classes.hpp:24519-24520）
static const uint32_t kMFItem_DataTable_RowStruct = 0x28;   // UScriptStruct*
static const uint32_t kMFItem_DataTable_RowMap    = 0x30;   // TMap<FName, uint8*>，0x50 字节

/// FDFMCommonItemRow（DFMGlobalDefines_structs.hpp，576 字节）
static const uint32_t kMFItem_Row_ItemID   = 0x0010;   // FName
static const uint32_t kMFItem_Row_Quality  = 0x0068;   // int32 ← 等级
static const uint32_t kMFItem_Row_Price    = 0x00DC;   // int32 ← 价值
static const uint32_t kMFItem_Row_Valuable = 0x01B8;   // bool
static const uint32_t kMFItem_Row_Size     = 576;

/// 一次读多个行时，单次请求的上限（不跨页太多，稳妥）
static const uint32_t kMFItem_ReadChunkBytes = 0x1000;

#pragma mark - 已知对象下标（GObjects dump 直读，同一版本内稳定）

static const int32_t kMFItem_Index_GameItem         = 0x1B602;  // DataTable GameItem.GameItem
static const int32_t kMFItem_Index_DFMCommonItemRow = 0x70DD;   // ScriptStruct DFMCommonItemRow

#pragma mark - TMap / TSet 元素布局（运行时自探）

/// TSet 内部：TArray<TSetElement> 的 Data / Num
static const uint32_t kMFItem_TSet_Data = 0x00;
static const uint32_t kMFItem_TSet_Num  = 0x08;

/// 元素大小：TPair<FName, uint8*> 16 字节 + HashNextId/HashIndex 8 字节 = 24
static const uint32_t kMFItem_TSetElemStride = 24;

/// 元素内字段顺序的两种可能（UE 各版本不同）
typedef NS_ENUM(NSInteger, MFItemMapLayout) {
    MFItemMapLayoutUnknown = 0,
    /// A: Value 在前 —— FName@+0x00, ptr@+0x08, Hash@+0x10
    MFItemMapLayoutValueFirst = 1,
    /// B: Hash 在前 —— Hash@+0x00, FName@+0x08, ptr@+0x10
    MFItemMapLayoutHashFirst  = 2,
};

#pragma mark - 值域

/// Quality 的合理上限（游戏是 0–6 级，留足余量）
static const int32_t kMFItem_MaxQuality = 20;
/// Price 上限（1 亿）
static const int32_t kMFItem_MaxPrice = 100000000;

#pragma mark - 小工具

static inline int32_t MFItemReadI32(const uint8_t *p) { int32_t v = 0; memcpy(&v, p, 4); return v; }
static inline uint32_t MFItemReadU32(const uint8_t *p) { uint32_t v = 0; memcpy(&v, p, 4); return v; }
static inline uint64_t MFItemReadU64(const uint8_t *p) { uint64_t v = 0; memcpy(&v, p, 8); return v; }

#pragma mark - MFItemRow

@implementation MFItemRow
- (instancetype)init {
    if ((self = [super init])) { _quality = -1; _price = -1; }
    return self;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<ItemRow q=%d p=%d valuable=%d @0x%llx>",
            _quality, _price, _valuable, (unsigned long long)_rowAddress];
}
@end

#pragma mark - MFItemTable

@implementation MFItemTable {
    BOOL _ready;
    NSUInteger _rowCount;
    NSMutableString *_report;
    /// FName(u64: cmpIndex | number<<32) → row 指针
    NSMutableDictionary<NSNumber *, NSNumber *> *_rowIndex;
    /// 已读过的行的属性缓存
    NSMutableDictionary<NSNumber *, MFItemRow *> *_rowCache;
    MFItemMapLayout _mapLayout;
    uint64_t _gameItem;
    uint64_t _rowStructExpected;
}

+ (instancetype)shared {
    static MFItemTable *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[MFItemTable alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _report = [NSMutableString string];
        _rowIndex = [NSMutableDictionary dictionary];
        _rowCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)ready { return _ready; }
- (NSUInteger)rowCount { return _rowCount; }
- (NSString *)probeReport { return _report; }

- (void)reset {
    _ready = NO;
    _rowCount = 0;
    _mapLayout = MFItemMapLayoutUnknown;
    _gameItem = 0;
    _rowStructExpected = 0;
    [_rowIndex removeAllObjects];
    [_rowCache removeAllObjects];
    [_report setString:@""];
}

#pragma mark GObjects 取对象

/// 按 GObjects 下标取 UObject 指针。
/// 三次读：块指针数组 → 块基址 → 槽位里的 Object 指针。
- (uint64_t)objectAtIndex:(int32_t)index {
    if (index < 0) return 0;
    MFReadBackend *rb = [MFReadBackend shared];
    uint64_t libBase = [MFUEReader shared].libBase;
    if (libBase == 0) return 0;

    uint64_t gobjects = libBase + kMFItem_GObjectsRVA;

    // 先确认 NumElements 合理 —— 这一步同时验证 GObjects 偏移对不对
    int32_t numElements = [rb readInt32:gobjects + kMFItem_ObjArray_NumElements];
    if (numElements <= 0 || numElements > 5000000) return 0;
    if (index >= numElements) return 0;

    uint64_t objsPtr = [rb readU64:gobjects + kMFItem_ObjArray_Objects];
    if (!MFUEIsValidPtr(objsPtr)) return 0;

    const int32_t chunk = index / (int32_t)kMFItem_ElementsPerChunk;
    const int32_t off   = index % (int32_t)kMFItem_ElementsPerChunk;

    uint64_t chunkBase = [rb readU64:objsPtr + (uint64_t)chunk * 8];
    if (!MFUEIsValidPtr(chunkBase)) return 0;

    uint64_t itemAddr = chunkBase + (uint64_t)off * kMFItem_FUObjectItemStride;
    uint64_t obj = [rb readU64:itemAddr + kMFItem_FUObjectItem_Object];
    return MFUEIsValidPtr(obj) ? obj : 0;
}

/// 读对象的类名（两跳：+0x08 拿 UClass，再 +0x1C 拿名字索引），仅用于日志
- (NSString *_Nullable)classNameOfObject:(uint64_t)obj {
    MFReadBackend *rb = [MFReadBackend shared];
    uint64_t cls = [rb readU64:obj + kMFItem_UObject_Class];
    if (!MFUEIsValidPtr(cls)) return nil;
    int32_t nameIdx = [rb readInt32:cls + kMFItem_UObject_Name];
    if (nameIdx <= 0 || !self.nameLookup) return nil;
    return self.nameLookup((uint32_t)nameIdx);
}

#pragma mark 加载

- (BOOL)loadIfNeeded {
    if (_ready) return YES;
    [_report setString:@""];

    MFReadBackend *rb = [MFReadBackend shared];
    if (![rb gateOpen]) {
        [_report appendString:@"✗ 读取门未开（target task port 未绑定）\n"];
        return NO;
    }
    if ([MFUEReader shared].libBase == 0) {
        [_report appendString:@"✗ 模块基址为 0 —— 先做「模块定位」\n"];
        return NO;
    }

    // ── ① 定位 GameItem ──
    _gameItem = [self objectAtIndex:kMFItem_Index_GameItem];
    if (!MFUEIsValidPtr(_gameItem)) {
        [_report appendFormat:@"✗ GameItem 下标 0x%X 取不到对象\n", kMFItem_Index_GameItem];
        return NO;
    }
    NSString *cls = [self classNameOfObject:_gameItem];
    [_report appendFormat:@"① GameItem @0x%llx 类名=%@\n",
        (unsigned long long)_gameItem, cls ?: @"(解不出)"];

    // ── ② 校验 RowStruct 指针 == DFMCommonItemRow ──
    uint64_t rowStruct = [rb readU64:_gameItem + kMFItem_DataTable_RowStruct];
    _rowStructExpected = [self objectAtIndex:kMFItem_Index_DFMCommonItemRow];
    [_report appendFormat:@"② RowStruct=0x%llx，期望(DFMCommonItemRow)=0x%llx  %@\n",
        (unsigned long long)rowStruct, (unsigned long long)_rowStructExpected,
        (rowStruct == _rowStructExpected && rowStruct != 0) ? @"✓ 匹配" : @"✗ 不匹配"];

    if (rowStruct == 0 || rowStruct != _rowStructExpected) {
        /*
         * 不匹配有两种可能：
         *   · 下标漂了（换了游戏版本 / 加载顺序不同）
         *   · RowStruct 不是物品表
         * 不管哪种，都不能拿 Quality/Price 去读 —— 读出来就是垃圾。
         * 直接放弃，上层退回"无等级/无价值"。宁可少显示，不可显示错的。
         */
        return NO;
    }

    // ── ③ 遍历 RowMap ──
    const uint64_t rowMap = _gameItem + kMFItem_DataTable_RowMap;
    uint64_t dataPtr = [rb readU64:rowMap + kMFItem_TSet_Data];
    int32_t num = [rb readInt32:rowMap + kMFItem_TSet_Num];

    if (!MFUEIsValidPtr(dataPtr) || num <= 0 || num > 200000) {
        [_report appendFormat:@"✗ RowMap 异常：Data=0x%llx Num=%d\n",
            (unsigned long long)dataPtr, num];
        return NO;
    }
    _rowCount = (NSUInteger)num;

    // ── ④ 自探元素布局（用前 8 行投票，比单行可靠）──
    _mapLayout = [self probeMapLayoutWithData:dataPtr num:num];
    [_report appendFormat:@"④ TMap 元素布局 = %@（前 8 行投票）\n",
        _mapLayout == MFItemMapLayoutValueFirst ? @"A: Value 在前"
      : _mapLayout == MFItemMapLayoutHashFirst  ? @"B: Hash 在前"
      : @"未知"];
    if (_mapLayout == MFItemMapLayoutUnknown) {
        return NO;
    }

    const uint32_t nameOff = (_mapLayout == MFItemMapLayoutValueFirst) ? 0x00 : 0x08;
    const uint32_t ptrOff  = (_mapLayout == MFItemMapLayoutValueFirst) ? 0x08 : 0x10;

    // ── ⑤ 分批读整个元素数组，建 FName → rowPtr 索引 ──
    const uint64_t totalBytes = (uint64_t)num * kMFItem_TSetElemStride;
    uint64_t done = 0;
    NSUInteger built = 0;
    NSUInteger badRows = 0;

    while (done < totalBytes) {
        uint32_t ask = (uint32_t)MIN((uint64_t)kMFItem_ReadChunkBytes, totalBytes - done);
        uint8_t buf[kMFItem_ReadChunkBytes];
        memset(buf, 0, sizeof(buf));
        if (![rb readRemote:dataPtr + done into:buf size:ask]) {
            // 某一段读失败：跳过这一段继续，不要整表放弃
            done += ask;
            continue;
        }

        for (uint32_t i = 0; i + kMFItem_TSetElemStride <= ask; i += kMFItem_TSetElemStride) {
            const uint8_t *e = buf + i;
            uint32_t cmpIndex = MFItemReadU32(e + nameOff);
            uint32_t number   = MFItemReadU32(e + nameOff + 4);
            uint64_t rowPtr   = MFItemReadU64(e + ptrOff);

            // 值域校验：名字索引不能太大，行指针必须是合法指针
            if (cmpIndex == 0 || cmpIndex > 20000000) { badRows++; continue; }
            if (!MFUEIsValidPtr(rowPtr)) { badRows++; continue; }

            uint64_t key = ((uint64_t)number << 32) | (uint64_t)cmpIndex;
            _rowIndex[@(key)] = @(rowPtr);
            built++;
        }
        done += ask;
    }

    [_report appendFormat:@"⑤ 索引建立：%lu 行有效 / %lu 行跳过（Num=%d）\n",
        (unsigned long)built, (unsigned long)badRows, num];

    if (built < 10) {
        [_report appendString:@"   ✗ 有效行太少，判定布局仍然不对\n"];
        [_rowIndex removeAllObjects];
        return NO;
    }

    _ready = YES;
    [_report appendString:@"✓ 物品表已就绪\n"];
    return YES;
}

/// 用前 8 行投票决定元素内字段顺序。
/// 判据：FName 索引是小整数且非零；行指针必须落在合法指针区间。
- (MFItemMapLayout)probeMapLayoutWithData:(uint64_t)dataPtr num:(int32_t)num {
    MFReadBackend *rb = [MFReadBackend shared];
    const int32_t probe = MIN(num, 8);
    uint8_t buf[8 * kMFItem_TSetElemStride];
    memset(buf, 0, sizeof(buf));

    const uint32_t ask = (uint32_t)probe * kMFItem_TSetElemStride;
    if (![rb readRemote:dataPtr into:buf size:ask]) return MFItemMapLayoutUnknown;

    NSUInteger scoreA = 0, scoreB = 0;
    for (int32_t i = 0; i < probe; i++) {
        const uint8_t *e = buf + (NSUInteger)i * kMFItem_TSetElemStride;

        // A: FName@0x00 + ptr@0x08
        {
            uint32_t cmp = MFItemReadU32(e + 0x00);
            uint64_t ptr = MFItemReadU64(e + 0x08);
            if (cmp > 0 && cmp <= 20000000) scoreA++;
            if (MFUEIsValidPtr(ptr)) scoreA++;
        }
        // B: FName@0x08 + ptr@0x10
        {
            uint32_t cmp = MFItemReadU32(e + 0x08);
            uint64_t ptr = MFItemReadU64(e + 0x10);
            if (cmp > 0 && cmp <= 20000000) scoreB++;
            if (MFUEIsValidPtr(ptr)) scoreB++;
        }
    }

    const NSUInteger full = (NSUInteger)probe * 2;
    if (scoreA == full) return MFItemMapLayoutValueFirst;
    if (scoreB == full) return MFItemMapLayoutHashFirst;
    // 都不是满分时取分高者（≥ 75% 才接受，否则判未知）
    if (scoreA >= full * 3 / 4 && scoreA > scoreB) return MFItemMapLayoutValueFirst;
    if (scoreB >= full * 3 / 4 && scoreB > scoreA) return MFItemMapLayoutHashFirst;
    return MFItemMapLayoutUnknown;
}

#pragma mark 查询

- (BOOL)lookupComparisonIndex:(uint32_t)comparisonIndex
                       number:(uint32_t)number
                         row:(MFItemRow *_Nullable *_Nullable)outRow {
    if (!_ready || comparisonIndex == 0) return NO;

    // 主键：先只按 comparisonIndex 找（大多数物品 number 都是 0）
    // 若精确 key 不中，再退化为"同 cmpIndex 的任意一行"
    uint64_t exact = ((uint64_t)number << 32) | (uint64_t)comparisonIndex;

    uint64_t rowPtr = 0;
    NSNumber *v = _rowIndex[@(exact)];
    if (v) {
        rowPtr = v.unsignedLongLongValue;
    } else if (number != 0) {
        v = _rowIndex[@((uint64_t)comparisonIndex)];
        if (v) rowPtr = v.unsignedLongLongValue;
    }
    if (!MFUEIsValidPtr(rowPtr)) return NO;

    NSNumber *key = @(exact);
    MFItemRow *cached = _rowCache[key];
    if (cached == nil) {
        MFReadBackend *rb = [MFReadBackend shared];

        /*
         * 一次读覆盖 Quality(0x68) 与 Price(0xDC)：
         * 从行首 0x60 开始读 0x90 字节 → 覆盖 0x60..0xF0，
         * 含 0x68(Quality) 和 0xDC(Price)。同一次系统调用里拿两个字段。
         */
        uint8_t buf[0x90];
        memset(buf, 0, sizeof(buf));
        if (![rb readRemote:rowPtr + 0x60 into:buf size:sizeof(buf)]) return NO;

        int32_t quality = MFItemReadI32(buf + (kMFItem_Row_Quality - 0x60));
        int32_t price   = MFItemReadI32(buf + (kMFItem_Row_Price   - 0x60));

        MFItemRow *r = [[MFItemRow alloc] init];
        r.comparisonIndex = comparisonIndex;
        r.number = number;
        r.rowAddress = rowPtr;
        // 值域校验：越界说明这一行的偏移不成立，宁可给 -1 也不给错数
        r.quality = (quality >= 0 && quality <= kMFItem_MaxQuality) ? quality : -1;
        r.price   = (price   >= 0 && price   <= kMFItem_MaxPrice)   ? price   : -1;

        uint8_t vb = 0;
        if ([rb readRemote:rowPtr + kMFItem_Row_Valuable into:&vb size:1]) {
            r.valuable = (vb != 0);
        }

        _rowCache[key] = r;
        cached = r;
    }

    if (outRow) *outRow = cached;
    return YES;
}

- (BOOL)lookupItemIdString:(NSString *)itemId row:(MFItemRow *_Nullable *_Nullable)outRow {
    if (!_ready || itemId.length == 0 || !self.nameLookup) return NO;

    // 反向遍历成本高，这里只在诊断时用：逐行解名比对
    for (NSNumber *k in _rowIndex) {
        uint64_t kv = k.unsignedLongLongValue;
        uint32_t cmp = (uint32_t)(kv & 0xFFFFFFFFULL);
        uint32_t num = (uint32_t)(kv >> 32);
        NSString *name = self.nameLookup(cmp);
        if ([name isEqualToString:itemId]) {
            return [self lookupComparisonIndex:cmp number:num row:outRow];
        }
    }
    return NO;
}

#pragma mark 诊断

- (NSString *)sampleReport:(NSUInteger)limit {
    if (!_ready) {
        return [NSString stringWithFormat:@"[物品表] 未就绪\n%@", _report];
    }

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"[物品表] 共 %lu 行，布局=%@\n", (unsigned long)_rowCount,
        _mapLayout == MFItemMapLayoutValueFirst ? @"A(Value在前)"
      : _mapLayout == MFItemMapLayoutHashFirst  ? @"B(Hash在前)" : @"?"];

    NSUInteger shown = 0;
    for (NSNumber *k in _rowIndex) {
        if (shown >= limit) break;
        uint64_t kv = k.unsignedLongLongValue;
        uint32_t cmp = (uint32_t)(kv & 0xFFFFFFFFULL);
        uint32_t num = (uint32_t)(kv >> 32);

        MFItemRow *row = nil;
        if (![self lookupComparisonIndex:cmp number:num row:&row] || row == nil) continue;

        NSString *name = self.nameLookup ? self.nameLookup(cmp) : nil;
        [s appendFormat:@"  [%08X] %-40s 等级=%2d 价值=%9d%@\n",
            cmp, (name ?: @"(无名)").UTF8String,
            row.quality, row.price, row.valuable ? @" ★贵重" : @""];
        shown++;
    }
    if (shown == 0) {
        [s appendString:@"  （一行都没解出名字 —— nameLookup 没注入或 GNames 未就绪）\n"];
    }
    return s;
}

@end

NS_ASSUME_NONNULL_END
