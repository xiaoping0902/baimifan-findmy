//
//  MFUEGNames.mm — UE4 类名解析（FNamePool）
//
//  布局结论、证据来源、以及「哪些是实测、哪些仍未定」都写在 MFUEGNames.h 的文件头里。
//  这里只记实现层面的取舍。
//
//  ── 核心公式（FNamePool，本作真实形态）──
//
//      blocks   = GNames + bias                 // bias = 0xC8 = 200（双证）
//      block    = Read<u64>(blocks + 8 * (id >> offsetBits))
//      entry    = block + (id & ((1 << offsetBits) - 1)) * stride
//      header   = Read<u16>(entry)              // bIsWide:1 | (ProbeHash:5 | Len:10)
//      string   = entry + 2                     // ANSI 或 UTF-16LE，由 bIsWide 决定
//
//  和旧实现（MFDrawingLayer.mm 里那份照抄 mingyun 的代码）的差别：
//
//    旧：entry = Read<u64>(gnames + ((id >> 15) & 0xFFF8) + 200)
//        chars = entry + 2 * (id & 0x3FFFF)
//        · 没有处理 FNameEntry 的 2 字节头 —— 把头当成第一个字符读，
//          所以从第一个字符起就整体错位
//        · 块号 15 位 与 块内 18 位 自相矛盾（两段加起来 33 位 > 32 位 id 空间，
//          数学上不可能同时成立）
//        · 读死了 UTF-16 —— 本作绝大多数名字是 ANSI，wide 读法直接得到乱码
//
//    新：块内位宽 offsetBits 运行时实测（见 resolveOffsetBits:），
//        头部按 2 字节解，编码按 bIsWide 逐条判断，两种编码都支持。
//
#import "MFUEGNames.h"
#import "MFUEReader.h"                  /* 只用它拿 libBase / profile（不改它） */
#import "../Read/MFReadBackend.h"
#include <stdlib.h>
#include <CoreFoundation/CFStringEncodingExt.h>   /* GB18030 —— 中文名解码 */
#include <string.h>

#pragma mark - 常量

/// 探测结果的存盘 key（换 key 会让旧结论失效重探）
static NSString *const kMFUEGNamesPersistKey = @"mf.ue.gnames.probe.v1";

/// FNameEntry 头部宽度。dump 日志：FNameEntry::Header=0x0 / String=0x2 ⇒ 2 字节
static const uint32_t kMFUEGEntryHeaderBytes = 2;

/// 类名长度上限（dump 日志 General::MaxFNameLen = 512）
static const uint32_t kMFUEGMaxNameChars = 512;

/// 单次读载荷的字节上限 = 512 字符 × 2 字节（任务要求：最多 1024 字节）
static const uint32_t kMFUEGMaxPayloadBytes = 1024;

/// 块扫描的字节上限。别让一次误判（offsetBits 探成 30）把内存吃光。
static const uint32_t kMFUEGMaxBlockBytes = 512 * 1024;

/// 名字缓存条数上限（超了就整体清空，简单且不会无界增长）
static const NSUInteger kMFUEGCacheLimit = 4096;

/// 单次读「头 + 64 字节载荷」——类名绝大多数在这 66 字节里，省掉第二次系统调用
static const uint32_t kMFUEGHeadProbeBytes = 64;

/*
 * Blocks[] 在池内的偏移候选。
 *
 * 200(0xC8) 排第一：这是本作的真实值，两条独立证据——
 *   · MobileDumper7.log 第 74 行：FNamePool::Blocks: 0xC8 -> 0x12CB54000
 *   · mingyun 反编译原文的「+200」
 * 其余是兜底：万一游戏改版把 allocator 换成 UE 标准形态（Blocks 在 +0x10）或别的排布，
 * 自探还能自己找回来，不用回来改代码。
 */
static const uint32_t kMFUEGBiasCandidates[] = {
    200,    // 0xC8 —— 本作实测值（首选）
    0x10,   // UE 标准 FNameEntryAllocator 的 Blocks[] 偏移
    0x00, 0x08, 0x18, 0x20, 0x28, 0x30, 0x40, 0x90, 0x100,
};
static const size_t kMFUEGBiasCandidateCount =
    sizeof(kMFUEGBiasCandidates) / sizeof(kMFUEGBiasCandidates[0]);

/// 块内位宽的候选（实测值优先，这里只是兜底顺序）
static const uint32_t kMFUEGOffsetBitsCandidates[] = {16, 15, 18, 14, 17};
static const size_t kMFUEGOffsetBitsCandidateCount =
    sizeof(kMFUEGOffsetBitsCandidates) / sizeof(kMFUEGOffsetBitsCandidates[0]);

#pragma mark - FNameEntry 头部 / 字符串的小工具（纯 C，无状态）

/// 从 2 字节头里取长度。两种位域切法都支持（见 MFUENamesHeader 注释）。
static inline uint32_t MFUELenFromHeader(uint16_t raw, MFUENamesHeader variant) {
    if (variant == MFUENamesHeaderLen15) {
        return (uint32_t)((raw >> 1) & 0x7FFFu);      // bIsWide:1 + Len:15
    }
    return (uint32_t)((raw >> 6) & 0x03FFu);          // bIsWide:1 + ProbeHash:5 + Len:10
}

/// bIsWide 位。两种位域切法里它都在 bit0 —— 这是 UE 的固定约定。
static inline BOOL MFUEWideFromHeader(uint16_t raw) {
    return (raw & 0x0001u) != 0;
}

/*
 * 名字字符白名单：字母 / 数字 / 下划线。
 *
 * 这一关是「垃圾内存拦截器」：读过界、读错块、位宽猜错，解出来的都不是
 * 纯标识符（要么控制字符、要么半个汉字的代理对），一律判失败。
 * UE 的类名/属性名本身就是纯标识符，所以这条判据不会误杀真名字。
 */
static inline BOOL MFUEIsNameChar(unichar c) {
    if (c >= 'a' && c <= 'z') return YES;
    if (c >= 'A' && c <= 'Z') return YES;
    if (c >= '0' && c <= '9') return YES;
    if (c == '_') return YES;
    return NO;
}

/// 从原始字节解出一个名字。失败（含非法字符、长度 0）返回 nil。
/*
 * [M5.137] 窄字符名（bIsWide == 0）不能逐字节当 Latin-1。
 *
 * 这个池子里同时住着两类名字：
 *   · 类名 / 对象名 —— 纯 ASCII（"PickupBase"、"DFMPlayerCharacter"）
 *   · 物品名 / 显示名 —— 中文
 * 旧实现把每个字节直接塞进 unichar，中文就变成 "æ­¦å™¨" 这种乱码。
 * 更糟的是乱码过不了 kindForClassName 的后缀匹配，分类全部落到 Unknown，
 * 于是「分类不可用 → 全画」，屏幕上就出现一堆画在空气里的框 ——
 * 乱码和空气框其实是同一个根因。
 *
 * 解码顺序：UTF-8（现代 UE 默认）→ GB18030（本地化/老资源）→ 逐字节（纯 ASCII 兜底）。
 */
static NSString *_Nullable MFUEDecodeNarrow(const uint8_t *src, uint32_t len) {
    if (src == NULL || len == 0) return nil;

    NSData *d = [NSData dataWithBytes:src length:len];
    NSString *utf8 = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (utf8.length > 0) return utf8;

    CFStringRef cf = CFStringCreateWithBytes(kCFAllocatorDefault, src, len,
                                             kCFStringEncodingGB_18030_2000, false);
    if (cf != NULL) {
        NSString *gb = (__bridge_transfer NSString *)cf;
        if (gb.length > 0) return gb;
    }

    unichar buf[kMFUEGMaxNameChars];
    uint32_t n = 0;
    for (uint32_t i = 0; i < len && n < kMFUEGMaxNameChars; i++) {
        unichar c = (unichar)src[i];
        if (c == 0) break;
        if (!MFUEIsNameChar(c)) return nil;
        buf[n++] = c;
    }
    return (n == 0) ? nil : [NSString stringWithCharacters:buf length:n];
}

static NSString *_Nullable MFUEDecodeName(const uint8_t *src, uint32_t len, BOOL wide) {
    if (src == NULL || len == 0 || len > kMFUEGMaxNameChars) return nil;

    if (!wide) return MFUEDecodeNarrow(src, len);

    unichar buf[kMFUEGMaxNameChars];
    uint32_t n = 0;
    for (uint32_t i = 0; i < len; i++) {
        unichar c = (unichar)((uint16_t)src[i * 2] | ((uint16_t)src[i * 2 + 1] << 8));
        if (c == 0) break;                 // 提前遇到 NUL：正常（Len 通常不含 NUL）
        if (!MFUEIsNameChar(c)) return nil; // 垃圾拦截
        buf[n++] = c;
    }
    if (n == 0) return nil;
    return [NSString stringWithCharacters:buf length:n];
}

static inline BOOL MFUEIsPowerOfTwo64(uint64_t v) {
    return (v != 0) && ((v & (v - 1)) == 0);
}

static inline uint32_t MFUELog2_64(uint64_t v) {
    uint32_t b = 0;
    while (v > 1) { v >>= 1; b++; }
    return b;
}

#pragma mark - MFUEGNames

/*
 * 私有方法全部在这里先声明一遍。
 * 理由：这些方法在实现里互相调用（probeIfNeeded → runProbe → hitTestBias …），
 * 依赖「clang 允许同 @implementation 内前向引用」的宽松行为太脆；
 * 显式声明一遍，编译期就能确定签名对得上，云构建不会因为顺序炸。
 */
@interface MFUEGNames ()
- (BOOL)runProbe:(NSMutableString *)rep;
- (BOOL)hitTestBias:(uint32_t)bias
             block0:(uint64_t *)outBlock
            variant:(MFUENamesHeader *)outVariant
           encoding:(MFUENamesEncoding *)outEncoding
             report:(NSMutableString *)rep;
- (uint32_t)resolveOffsetBitsReport:(NSMutableString *)rep;
- (NSInteger)scoreOffsetBits:(uint32_t)bits;
- (BOOL)tryFlatLayoutReport:(NSMutableString *)rep;
- (BOOL)validateCurrentConfig;
- (void)persistProbe;
- (BOOL)adoptPersistedConfig;
- (uint64_t)blockPointerForIndex:(uint32_t)blockIndex;
- (uint64_t)entryAddressForID:(uint32_t)classId;
- (nullable NSString *)nameAtEntry:(uint64_t)entry
                           variant:(MFUENamesHeader)variant
                          encoding:(MFUENamesEncoding)encoding;
- (nullable NSString *)nameAtEntry:(uint64_t)entry;
- (NSUInteger)sweepBlock:(uint32_t)blockIndex
               landmarks:(NSArray<NSString *> *)landmarks
              maxEntries:(NSUInteger)maxEntries
                  report:(NSMutableString *)rep;
@end

@implementation MFUEGNames {
    NSMutableDictionary<NSNumber *, id> *_nameCache;       // id → NSString / NSNull
    NSMutableDictionary<NSNumber *, NSNumber *> *_blockCache; // 块号 → 块指针（含失败 0）

    uint64_t _flatBase;        // 扁平兜底布局的表基址
    BOOL     _probeOK;         // 探测是否成功
    NSTimeInterval _lastProbeTime;   // 上次尝试探测的时刻（失败后节流用）
}

+ (instancetype)shared {
    static MFUEGNames *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[MFUEGNames alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _nameCache   = [NSMutableDictionary dictionary];
        _blockCache  = [NSMutableDictionary dictionary];
        _layout      = MFUENamesLayoutUnknown;
        _blocksBias  = 0;
        _offsetBits  = 0;
        _stride      = 2;                     // dump 日志：FNameEntry::Stride = 0x2
        _headerVariant = MFUENamesHeaderLen10; // dump 日志：bUseCasePreservingName = false
        _encoding    = MFUENamesEncodingAuto;
        _probeReport = @"（还没探测过 GNames）";
        _gnamesBase  = 0;
        _libBase     = 0;
    }
    return self;
}

#pragma mark - 探测入口

- (BOOL)probeIfNeeded {
    if (_probeOK) return YES;

    /*
     * ★ 探测失败【不能】永久记住 ★
     *
     * 真机时序：HUD 还没绑定游戏进程时 libBase = 0，这时候调用一次就会失败。
     * 如果失败也标记「探过了」，等 libBase 到位后这个模块就永远返回 nil ——
     * 表现是「类名功能整局都不工作」，而且完全看不出是时序问题。
     * 所以：成功才锁死；失败只节流（2 秒内不重复扫），下次调用自动重试。
     */
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (_lastProbeTime > 0 && (now - _lastProbeTime) < 2.0) return NO;

    @synchronized (self) {
        if (_probeOK) return YES;
        now = [NSDate timeIntervalSinceReferenceDate];
        if (_lastProbeTime > 0 && (now - _lastProbeTime) < 2.0) return NO;
        _lastProbeTime = now;

        NSMutableString *rep = [NSMutableString string];
        BOOL ok = [self runProbe:rep];
        _probeOK = ok;
        _probeReport = [rep copy];

        /*
         * 探测成功后清一次名字缓存。
         * 理由：探测成功之前查过的 id 会被缓存成 NSNull（失败），
         * 如果不作废，那些 Actor 整局都拿不到类名 —— 表现是「刚绑定上时
         * 附近的东西分类正常，远处的永远是未知」，非常难查。
         */
        if (ok) [_nameCache removeAllObjects];

        NSLog(@"[MF][GNames] %@", _probeReport);
        return ok;
    }
}

- (void)resetProbe {
    @synchronized (self) {
        _probeOK = NO;
        _lastProbeTime = 0;
        _layout = MFUENamesLayoutUnknown;
        _offsetBits = 0;
        _blocksBias = 0;
        _gnamesBase = 0;
        _flatBase = 0;
        _probeReport = @"（已复位，下次用到时重探）";
        [_nameCache removeAllObjects];
        [_blockCache removeAllObjects];
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kMFUEGNamesPersistKey];
}

- (void)clearCache {
    @synchronized (self) {
        [_nameCache removeAllObjects];
    }
}

#pragma mark - 探测主体

- (BOOL)runProbe:(NSMutableString *)rep {
    [rep appendString:@"探测开始\n"];

    /* ① 定位 GNames 池 */
    uint64_t base = self.libBase;
    if (base == 0) base = [MFUEReader shared].libBase;

    MFUEProfile *p = self.profile;
    if (p == nil) p = [MFUEReader shared].profile;

    if (base == 0) {
        [rep appendString:@"  ✗ 模块基址为 0（先做模块定位）\n"];
        return NO;
    }
    if (p == nil) {
        [rep appendString:@"  ✗ 拿不到偏移表 MFUEProfile\n"];
        return NO;
    }

    uint64_t gnames = base + p.gnamesStaticOffset;
    [rep appendFormat:@"  模块基址 0x%llx + 0x%llX(%llu) → GNames 池 0x%llx\n",
        (unsigned long long)base, (unsigned long long)p.gnamesStaticOffset,
        (unsigned long long)p.gnamesStaticOffset, (unsigned long long)gnames];

    if (!MFUEIsValidPtr(gnames)) {
        [rep appendFormat:@"  ✗ GNames 池地址 0x%llx 不在合法指针区间\n",
            (unsigned long long)gnames];
        return NO;
    }
    _gnamesBase = gnames;

    /* ② 先试上次存盘的结论 —— 能省掉一次全量探测（游戏没更新时基本必中） */
    if ([self adoptPersistedConfig] && [self validateCurrentConfig]) {
        [rep appendFormat:@"  沿用上次结论：layout=%ld bias=%u offsetBits=%u variant=%ld\n",
            (long)_layout, _blocksBias, _offsetBits, (long)_headerVariant];
        [self persistProbe];
        return YES;
    }

    /* ③ 扫 bias：判据是「entry 0 解得 None」——这是 UE 名字池的铁律，
     *    本作 dump 日志第 67 行也验证过 `Entry 0 reads "None"`。 */
    uint64_t block0 = 0;
    MFUENamesHeader variant = MFUENamesHeaderLen10;
    MFUENamesEncoding enc = MFUENamesEncodingAnsi;

    uint32_t bias = 0;
    BOOL found = NO;

    if (self.forcedBlocksBias > 0) {
        uint32_t forced = self.forcedBlocksBias;
        if ([self hitTestBias:forced block0:&block0 variant:&variant encoding:&enc report:rep]) {
            bias = forced;
            found = YES;
            [rep appendFormat:@"  ✓ 强制 bias=%u(0x%X) 命中\n", bias, bias];
        } else {
            [rep appendFormat:@"  ⚠ 强制 bias=%u(0x%X) 没命中，继续自动探测\n", forced, forced];
        }
    }

    if (!found) {
        for (size_t i = 0; i < kMFUEGBiasCandidateCount && !found; i++) {
            uint32_t cand = kMFUEGBiasCandidates[i];
            if ([self hitTestBias:cand block0:&block0 variant:&variant encoding:&enc report:rep]) {
                bias = cand;
                found = YES;
                [rep appendFormat:@"  ✓ bias 命中：%u (0x%X)\n", bias, bias];
            } else {
                [rep appendFormat:@"  · bias %u (0x%X) 不成立（Blocks[0] 非法或 entry0 解不出名字）\n",
                    cand, cand];
            }
        }
    }

    if (!found) {
        [rep appendString:@"  ⚠ FNamePool 形态没探出来，转扁平兜底…\n"];
        if ([self tryFlatLayoutReport:rep]) {
            return YES;
        }
        [rep appendString:@"  ✗ 扁平兜底也不成立 —— 结论：这个名字池布局不认识\n"];
        return NO;
    }

    /* ④ 固定 bias / 头变体 / 编码，再定块内位宽 */
    _layout = MFUENamesLayoutPool;
    _blocksBias = bias;
    _headerVariant = variant;
    _encoding = enc;

    /*
     * 编码一致性地记一笔：
     * 如果 entry0 是靠 ANSI 解出来的，而它的 bIsWide 位却是 1（或反过来），
     * 说明这个头部布局里 bit0 不是 bIsWide —— 那就固定用探测到的编码，
     * 不要逐条按位判断（否则一半条目会乱码）。
     */
    {
        uint16_t raw = 0;
        if ([[MFReadBackend shared] readRemote:block0 into:&raw size:sizeof(raw)]) {
            BOOL bit = MFUEWideFromHeader(raw);
            BOOL probedWide = (enc == MFUENamesEncodingWide);
            if (bit != probedWide) {
                [rep appendFormat:@"  ⚠ entry0 的 bit0=%d 但实际编码是 %@ —— "
                    @"头部 bit0 不是 bIsWide，改为固定编码\n",
                    (int)bit, probedWide ? @"UTF-16" : @"ANSI"];
                _encoding = probedWide ? MFUENamesEncodingWide : MFUENamesEncodingAnsi;
            } else {
                _encoding = MFUENamesEncodingAuto;   // bit0 可信 → 逐条按位判断
            }
        } else {
            /* 连头部都读不到：退回逐条按 bIsWide 判断（比固定一种编码更不容易整片乱码） */
            _encoding = MFUENamesEncodingAuto;
        }
    }

    _offsetBits = [self resolveOffsetBitsReport:rep];
    [rep appendFormat:@"  块内位宽 offsetBits=%u（stride=%u）\n", _offsetBits, _stride];

    /* ⑤ 最终自检 + 存盘 */
    if (![self validateCurrentConfig]) {
        [rep appendString:@"  ✗ 配置确定后仍然解不出名字（entry0 不是 'None' 也不是合法标识符）\n"];
        _layout = MFUENamesLayoutUnknown;
        return NO;
    }

    [rep appendFormat:@"  结论：layout=FNamePool bias=%u(0x%X) offsetBits=%u stride=%u "
        @"header=%@ encoding=%@\n",
        _blocksBias, _blocksBias, _offsetBits, _stride,
        (_headerVariant == MFUENamesHeaderLen10 ? @"Len10" : @"Len15"),
        (_encoding == MFUENamesEncodingAuto ? @"按 bIsWide" :
         (_encoding == MFUENamesEncodingWide ? @"UTF-16" : @"ANSI"))];

    [self persistProbe];
    return YES;
}

/// 用给定 bias 试 Blocks[0]，看 entry0 能不能解出名字。
/// 强命中 = 解出 "None"；弱命中 = 前几条里 ≥3 条是可打印标识符。
- (BOOL)hitTestBias:(uint32_t)bias
             block0:(uint64_t *)outBlock
            variant:(MFUENamesHeader *)outVariant
           encoding:(MFUENamesEncoding *)outEncoding
             report:(NSMutableString *)rep {
    uint64_t block0 = 0;
    if (![[MFReadBackend shared] readU64:_gnamesBase + bias out:&block0]) return NO;
    if (!MFUEIsValidPtr(block0)) return NO;

    MFUENamesHeader variants[2] = { MFUENamesHeaderLen10, MFUENamesHeaderLen15 };
    MFUENamesEncoding encs[2] = { MFUENamesEncodingAnsi, MFUENamesEncodingWide };

    /* 强判据：entry0 == "None" */
    for (int vi = 0; vi < 2; vi++) {
        for (int ei = 0; ei < 2; ei++) {
            NSString *n = [self nameAtEntry:block0
                                    variant:variants[vi]
                                   encoding:encs[ei]];
            if (n != nil && [n isEqualToString:@"None"]) {
                if (outBlock) *outBlock = block0;
                if (outVariant) *outVariant = variants[vi];
                if (outEncoding) *outEncoding = encs[ei];
                return YES;
            }
        }
    }

    /* 弱判据：万一某个版本 entry0 不叫 None（改过引擎），
     * 用「前 4 条里有 3 条是合法标识符」兜一下，并把命中的组合记进日志。 */
    for (int vi = 0; vi < 2; vi++) {
        for (int ei = 0; ei < 2; ei++) {
            int good = 0;
            NSString *sample = nil;
            for (uint32_t id = 0; id < 4; id++) {
                uint64_t entry = block0 + (uint64_t)id * _stride;
                NSString *n = [self nameAtEntry:entry
                                        variant:variants[vi]
                                       encoding:encs[ei]];
                if (n != nil) {
                    good++;
                    if (sample == nil) sample = n;
                }
            }
            if (good >= 3) {
                [rep appendFormat:@"  ~ bias %u 弱命中（前 4 条解出 %d 条，首条 \"%@\"）"
                    @"—— entry0 不是 'None'，可能是改造过的池\n", bias, good, sample];
                if (outBlock) *outBlock = block0;
                if (outVariant) *outVariant = variants[vi];
                if (outEncoding) *outEncoding = encs[ei];
                return YES;
            }
        }
    }
    return NO;
}

/// 定块内位宽：先实测块间距（dump 工具用的就是这招），再用高位 id 交叉验证。
- (uint32_t)resolveOffsetBitsReport:(NSMutableString *)rep {
    if (self.forcedOffsetBits > 0) {
        [rep appendFormat:@"  块内位宽：外部强制 %u\n", self.forcedOffsetBits];
        return self.forcedOffsetBits;
    }

    /* ① 实测：连续读 Blocks[0..5]，相邻差就是块字节数 */
    uint32_t measured = 0;
    uint64_t prev = 0;
    uint64_t delta = 0;
    int deltaSamples = 0;
    BOOL deltaConsistent = YES;

    for (uint32_t i = 0; i < 6; i++) {
        uint64_t bp = 0;
        if (![[MFReadBackend shared] readU64:_gnamesBase + _blocksBias + (uint64_t)i * 8u
                                         out:&bp]) break;
        if (!MFUEIsValidPtr(bp)) break;      // 后面的块还没分配
        if (prev != 0) {
            uint64_t d = bp - prev;
            if (d > 0) {
                if (deltaSamples == 0) {
                    delta = d;
                } else if (d != delta) {
                    deltaConsistent = NO;
                }
                deltaSamples++;
            }
        }
        prev = bp;
    }

    if (deltaSamples > 0 && deltaConsistent) {
        uint64_t entriesPerBlock = delta / (uint64_t)_stride;
        if (MFUEIsPowerOfTwo64(entriesPerBlock)) {
            uint32_t bits = MFUELog2_64(entriesPerBlock);
            if (bits >= 8 && bits <= 22) {
                measured = bits;
                [rep appendFormat:@"  块间距实测 0x%llx（%d 个样本）→ 每块 %llu 条 → offsetBits=%u\n",
                    (unsigned long long)delta, deltaSamples,
                    (unsigned long long)entriesPerBlock, bits];
            }
        } else {
            [rep appendFormat:@"  块间距实测 0x%llx 不是 2 的幂的倍数（每块 %llu 条）—— 不采信\n",
                (unsigned long long)delta, (unsigned long long)entriesPerBlock];
        }
    } else if (deltaSamples > 0) {
        [rep appendFormat:@"  相邻块间距不一致（%d 个样本，首个 0x%llx）—— 块非连续分配，实测作废\n",
            deltaSamples, (unsigned long long)delta];
    } else {
        [rep appendString:@"  只分配了 1 个块（或块指针不连续）—— 无法实测块间距\n"];
    }

    /* ② 候选评分：用「必须落在第 1 块」的 id 试解，能解出合法标识符的加分 */
    uint32_t cands[6];
    size_t n = 0;
    if (measured) cands[n++] = measured;
    for (size_t i = 0; i < kMFUEGOffsetBitsCandidateCount && n < 6; i++) {
        uint32_t c = kMFUEGOffsetBitsCandidates[i];
        BOOL dup = NO;
        for (size_t j = 0; j < n; j++) if (cands[j] == c) { dup = YES; break; }
        if (!dup) cands[n++] = c;
    }

    uint32_t best = 0;
    NSInteger bestScore = NSIntegerMin;

    for (size_t i = 0; i < n; i++) {
        uint32_t bits = cands[i];
        NSInteger score = [self scoreOffsetBits:bits];
        if (measured && bits == measured) score += 1;   // 实测值加一分（平局时胜出）
        [rep appendFormat:@"    offsetBits=%u → 高位探测得分 %ld\n", bits, (long)score];
        if (score > bestScore) {
            bestScore = score;
            best = bits;
        }
    }

    if (best == 0) best = 16;   // 理论上到不了；兜底用 UE 标准值

    if (bestScore <= 0 && !measured) {
        [rep appendFormat:@"  ⚠ 所有候选都解不出高位 id（大概是只分了一个块）—— "
            @"暂定 offsetBits=%u，这条**未证实**\n", best];
    }
    return best;
}

/// 给某个 offsetBits 打分：拿 (1<<bits)+k 这种「必须坐落在第 1 块」的 id 去解。
- (NSInteger)scoreOffsetBits:(uint32_t)bits {
    if (bits == 0 || bits >= 24) return NSIntegerMin;

    NSInteger score = 0;
    MFUENamesEncoding enc = _encoding;

    for (uint32_t k = 0; k < 4; k++) {
        uint64_t id = ((uint64_t)1 << bits) + k;
        uint64_t blockIndex = id >> bits;
        uint64_t block = [self blockPointerForIndex:(uint32_t)blockIndex];
        if (!MFUEIsValidPtr(block)) { score -= 2; continue; }

        uint64_t mask = ((uint64_t)1 << bits) - 1;
        uint64_t entry = block + (id & mask) * (uint64_t)_stride;
        if (!MFUEIsValidPtr(entry)) { score -= 2; continue; }

        NSString *n = [self nameAtEntry:entry variant:_headerVariant encoding:enc];
        score += (n != nil) ? 2 : -1;
    }
    return score;
}

/// 扁平兜底：万一这版引擎不是 FNamePool。
/// 两种可能都试：① +bias 处存的是「表首指针」；② 表就地内联在 +bias。
- (BOOL)tryFlatLayoutReport:(NSMutableString *)rep {
    MFUENamesHeader variants[2] = { MFUENamesHeaderLen10, MFUENamesHeaderLen15 };
    MFUENamesEncoding encs[2] = { MFUENamesEncodingAnsi, MFUENamesEncodingWide };

    for (size_t bi = 0; bi < kMFUEGBiasCandidateCount; bi++) {
        uint32_t bias = kMFUEGBiasCandidates[bi];

        uint64_t indirect = 0;
        uint64_t bases[2] = { 0, 0 };
        int baseCount = 0;
        if ([[MFReadBackend shared] readU64:_gnamesBase + bias out:&indirect] &&
            MFUEIsValidPtr(indirect)) {
            bases[baseCount++] = indirect;
        }
        bases[baseCount++] = _gnamesBase + bias;   // 内联形态

        for (int b = 0; b < baseCount; b++) {
            for (int vi = 0; vi < 2; vi++) {
                for (int ei = 0; ei < 2; ei++) {
                    NSString *n = [self nameAtEntry:bases[b]
                                            variant:variants[vi]
                                           encoding:encs[ei]];
                    if (n != nil && [n isEqualToString:@"None"]) {
                        _layout = MFUENamesLayoutFlat;
                        _flatBase = bases[b];
                        _blocksBias = bias;
                        _headerVariant = variants[vi];
                        _encoding = encs[ei];
                        _offsetBits = 0;      // 扁平布局用不到
                        [rep appendFormat:@"  ✓ 扁平命中：bias=%u(0x%X) %@ variant=%d enc=%d\n",
                            bias, bias, (b == 0 ? @"间接指针" : @"内联"),
                            vi, ei];
                        [self persistProbe];
                        return YES;
                    }
                }
            }
        }
    }
    return NO;
}

/// 用当前配置解 entry0，判定这套配置是否还能用（沿用存盘结论 / 探测收尾都走它）。
- (BOOL)validateCurrentConfig {
    if (_layout == MFUENamesLayoutUnknown || _gnamesBase == 0) return NO;

    /* 扁平布局：直接按 id0 解 */
    if (_layout == MFUENamesLayoutFlat) {
        NSString *n = [self nameAtEntry:_flatBase variant:_headerVariant encoding:_encoding];
        return n != nil;
    }

    if (_offsetBits == 0) return NO;

    uint64_t block0 = [self blockPointerForIndex:0];
    if (!MFUEIsValidPtr(block0)) return NO;

    NSString *n0 = [self nameAtEntry:block0 variant:_headerVariant encoding:_encoding];
    if (n0 == nil) return NO;
    if ([n0 isEqualToString:@"None"]) return YES;

    /* 不叫 None 也放过，但要求前 4 条里至少 3 条能解出来 */
    int good = 1;
    for (uint32_t id = 1; id < 4; id++) {
        uint64_t entry = block0 + (uint64_t)id * _stride;
        if ([self nameAtEntry:entry variant:_headerVariant encoding:_encoding] != nil) good++;
    }
    return good >= 3;
}

#pragma mark - 存盘 / 读取

- (void)persistProbe {
    if (_layout == MFUENamesLayoutUnknown || _gnamesBase == 0) return;
    NSDictionary *d = @{
        @"layout":  @(_layout),
        @"bias":    @(_blocksBias),
        @"bits":    @(_offsetBits),
        @"stride":  @(_stride),
        @"variant": @(_headerVariant),
        @"enc":     @(_encoding),
        @"flat":    @(_flatBase),
    };
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kMFUEGNamesPersistKey];
}

- (BOOL)adoptPersistedConfig {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                       dictionaryForKey:kMFUEGNamesPersistKey];
    if (![d isKindOfClass:[NSDictionary class]] || d.count == 0) return NO;

    NSInteger layout = [d[@"layout"] integerValue];
    if (layout != MFUENamesLayoutPool && layout != MFUENamesLayoutFlat) return NO;

    _layout        = (MFUENamesLayout)layout;
    _blocksBias    = [d[@"bias"] unsignedIntValue];
    _offsetBits    = [d[@"bits"] unsignedIntValue];
    _stride        = [d[@"stride"] unsignedIntValue];
    _headerVariant = (MFUENamesHeader)[d[@"variant"] integerValue];
    _encoding      = (MFUENamesEncoding)[d[@"enc"] integerValue];
    _flatBase      = [d[@"flat"] unsignedLongLongValue];

    if (_stride < 1 || _stride > 8) _stride = 2;                 // 存盘值坏了就回默认
    if (_headerVariant != MFUENamesHeaderLen10 &&
        _headerVariant != MFUENamesHeaderLen15) _headerVariant = MFUENamesHeaderLen10;
    if (_encoding != MFUENamesEncodingAuto &&
        _encoding != MFUENamesEncodingAnsi &&
        _encoding != MFUENamesEncodingWide) _encoding = MFUENamesEncodingAuto;

    /*
     * ★ 位宽必须在这里再查一遍 ★
     * entry 0 的解析用不到 offsetBits（块号恒为 0），所以 validateCurrentConfig
     * 是查不出「存盘点里的 bits 被写坏」的 —— 那种情况会一路通过校验、
     * 然后所有 id>0 的查询全部落在错地址上，表现为「类名全 nil」而日志一切正常。
     * 所以宁可直接作废、重探一次。
     */
    if (_layout == MFUENamesLayoutPool && (_offsetBits < 8 || _offsetBits > 22)) return NO;
    if (_blocksBias > 0x400) return NO;

    return YES;
}

#pragma mark - 取块指针 / 算 entry 地址

/// 块号 → 块基址（带缓存；失败也缓存 0，避免反复读）
- (uint64_t)blockPointerForIndex:(uint32_t)blockIndex {
    if (_gnamesBase == 0) return 0;
    if (blockIndex > 0x3FFFF) return 0;          // 18 位块号上限，超了必是解析错误

    NSNumber *key = @(blockIndex);
    NSNumber *hit = nil;
    @synchronized (_blockCache) {
        hit = _blockCache[key];
    }
    if (hit != nil) return hit.unsignedLongLongValue;

    uint64_t v = 0;
    uint64_t addr = _gnamesBase + _blocksBias + (uint64_t)blockIndex * 8u;
    if (![[MFReadBackend shared] readU64:addr out:&v]) v = 0;
    if (!MFUEIsValidPtr(v)) v = 0;

    @synchronized (_blockCache) {
        if (_blockCache.count < 512) _blockCache[key] = @(v);
    }
    return v;
}

/// id → FNameEntry 地址。返回 0 表示不可用。
- (uint64_t)entryAddressForID:(uint32_t)classId {
    if (_layout == MFUENamesLayoutUnknown) return 0;

    if (_layout == MFUENamesLayoutFlat) {
        uint64_t addr = _flatBase + (uint64_t)classId * (uint64_t)_stride;
        return MFUEIsValidPtr(addr) ? addr : 0;
    }

    uint32_t bits = _offsetBits;
    if (bits == 0 || bits >= 24) return 0;

    uint32_t blockIndex = classId >> bits;
    uint64_t block = [self blockPointerForIndex:blockIndex];
    if (!MFUEIsValidPtr(block)) return 0;

    uint64_t mask = ((uint64_t)1 << bits) - 1;
    uint64_t addr = block + (classId & mask) * (uint64_t)_stride;
    return MFUEIsValidPtr(addr) ? addr : 0;
}

#pragma mark - 解名字

/// 解一条 FNameEntry。显式传头变体/编码（探测阶段要用它穷举组合）。
- (nullable NSString *)nameAtEntry:(uint64_t)entry
                           variant:(MFUENamesHeader)variant
                          encoding:(MFUENamesEncoding)encoding {
    if (!MFUEIsValidPtr(entry)) return nil;

    MFReadBackend *rb = [MFReadBackend shared];

    /* ① 一条读拿到「2 字节头 + 64 字节载荷」——绝大多数类名都在里面 */
    uint8_t head[kMFUEGEntryHeaderBytes + kMFUEGHeadProbeBytes];
    if (![rb readRemote:entry into:head size:sizeof(head)]) return nil;

    uint16_t raw = (uint16_t)((uint16_t)head[0] | ((uint16_t)head[1] << 8));
    uint32_t len = MFUELenFromHeader(raw, variant);
    if (len == 0 || len > kMFUEGMaxNameChars) return nil;

    BOOL wide;
    switch (encoding) {
        case MFUENamesEncodingAnsi: wide = NO; break;
        case MFUENamesEncodingWide: wide = YES; break;
        default:                    wide = MFUEWideFromHeader(raw); break;
    }

    const uint8_t *src = head + kMFUEGEntryHeaderBytes;
    size_t need = (size_t)len * (wide ? 2u : 1u);

    /* ② 超过 64 字节的长名字，补一次精确读 */
    uint8_t payload[kMFUEGMaxPayloadBytes];
    if (need > kMFUEGHeadProbeBytes) {
        if (need > sizeof(payload)) return nil;      // 超上限直接放弃（任务要求 ≤1024 字节）
        if (![rb readRemote:entry + kMFUEGEntryHeaderBytes into:payload size:need]) return nil;
        src = payload;
    }

    return MFUEDecodeName(src, len, wide);
}

/// 用当前配置解（正常路径）
- (nullable NSString *)nameAtEntry:(uint64_t)entry {
    return [self nameAtEntry:entry variant:_headerVariant encoding:_encoding];
}

#pragma mark - 公开接口：取类名

- (nullable NSString *)classNameForID:(int32_t)classId {
    if (classId < 0) return nil;

    NSNumber *key = @(classId);

    id cached = nil;
    @synchronized (_nameCache) {
        cached = _nameCache[key];
    }
    if (cached != nil) return (cached == [NSNull null]) ? nil : (NSString *)cached;

    NSString *name = nil;
    if ([self probeIfNeeded]) {
        uint64_t entry = [self entryAddressForID:(uint32_t)classId];
        if (entry != 0) name = [self nameAtEntry:entry];
    }

    @synchronized (_nameCache) {
        if (_nameCache.count >= kMFUEGCacheLimit) [_nameCache removeAllObjects];
        _nameCache[key] = name ? (id)name : (id)[NSNull null];
    }
    if (name != nil) _resolvedCount++; else _failedCount++;
    return name;
}

- (nullable NSString *)classNameForObject:(uint64_t)object {
    if (!MFUEIsValidPtr(object)) return nil;
    int32_t idx = [[MFReadBackend shared] readInt32:object + kMFUE_UObject_Name];
    if (idx <= 0) return nil;
    return [self classNameForID:idx];
}

- (nullable NSString *)classNameForActor:(uint64_t)actor {
    /* 任务约定的语义：直接读 +0x1C。注意那是 UObject::Name（对象名），
     * 不是类名 —— 详见 MFUEGNames.h 文件头与 MFUEOffsets.h 的说明。 */
    return [self classNameForObject:actor];
}

- (nullable NSString *)classNameForActorClass:(uint64_t)actor {
    if (!MFUEIsValidPtr(actor)) return nil;

    uint64_t cls = [[MFReadBackend shared] readU64:actor + kMFUE_UObject_Class];
    if (!MFUEIsValidPtr(cls)) return nil;

    /* UClass 也是 UObject，它的 Name（+0x1C）就是类名，例如 "PickupBase" */
    return [self classNameForObject:cls];
}

#pragma mark - 诊断

- (NSString *)statsText {
    return [NSString stringWithFormat:
            @"<MFUEGNames layout=%ld bias=%u bits=%u stride=%u variant=%ld enc=%ld "
            @"ok=%lu fail=%lu cache=%lu>",
            (long)_layout, _blocksBias, _offsetBits, _stride,
            (long)_headerVariant, (long)_encoding,
            (unsigned long)_resolvedCount, (unsigned long)_failedCount,
            (unsigned long)_nameCache.count];
}

/*
 * 真机一次性验证。
 *
 * 做三件事：
 *   ① 把探测结论打出来（布局 / bias / 位宽 / 头变体 / 编码）
 *   ② 解一批定点 id（0..15、块边界附近的 id）—— low id 必定是引擎内建名，
 *      高 id 用来验证「块号 + 块内偏移」这套算术没算错
 *   ③ 顺序扫首块并报出命中地标关键词的名字（PickupBase / Character 之类）——
 *      这一步能直接回答「类名到底能不能用」：扫出来的名字是游戏里的真类名
 *      而不是垃圾，就说明整套解析是对的。
 *
 * 第 ③ 步不依赖 offsetBits（它只在块内顺序走），所以即使位宽还没定死，
 * 也能先用它确认「头部 + 编码 + stride」这三件事对不对。
 */
- (NSString *)selfTest {
    NSMutableString *out = [NSMutableString string];

    BOOL ok = [self probeIfNeeded];
    [out appendString:@"══ GNames 自检 ══\n"];
    [out appendString:_probeReport];
    [out appendString:@"\n"];

    if (!ok) {
        [out appendString:@"结论：✗ 名字池没探出来，类名功能不可用。\n"];
        return out;
    }

    [out appendFormat:@"统计：%@\n\n", [self statsText]];

    /* ② 定点 id */
    [out appendString:@"定点 id：\n"];
    uint32_t fixedIds[20] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 100, 1000, 4096, 0};
    for (int i = 0; i < 20; i++) {
        if (fixedIds[i] == 0 && i > 0) break;
        NSString *n = [self classNameForID:(int32_t)fixedIds[i]];
        [out appendFormat:@"  [%u] %@\n", fixedIds[i], n ?: @"（解不出）"];
    }

    /* 块边界：正确位宽下，第 1 块的首条必须是真名字 */
    if (_layout == MFUENamesLayoutPool && _offsetBits > 0 && _offsetBits < 24) {
        uint64_t boundary = ((uint64_t)1 << _offsetBits);
        [out appendFormat:@"\n块边界（offsetBits=%u，边界 id=%llu）：\n",
            _offsetBits, (unsigned long long)boundary];
        for (int k = 0; k < 3; k++) {
            uint64_t id = boundary + (uint64_t)k;
            NSString *n = [self classNameForID:(int32_t)id];
            [out appendFormat:@"  [%llu] %@\n", (unsigned long long)id, n ?: @"（解不出）"];
        }
    }

    /* ③ 扫首块：地标关键词 */
    NSArray<NSString *> *landmarks = @[@"PickupBase", @"Pickup", @"Character",
                                       @"Weapon", @"Player", @"Inventory", @"Item"];
    [out appendString:@"\n扫描首块（找地标类名）：\n"];
    NSUInteger hit = [self sweepBlock:0 landmarks:landmarks maxEntries:6000 report:out];
    [out appendFormat:@"  首块命中地标 %lu 条\n", (unsigned long)hit];

    if (hit > 0) {
        [out appendString:@"结论：✓ 解出的名字里出现了游戏真实类名 —— 布局正确，类名可用。\n"];
    } else {
        [out appendString:
            @"结论：⚠ 首块没命中地标。两种可能：\n"
            @"       · offsetBits 或 bias 还需要微调（看上面探测日志的候选得分）\n"
            @"       · 该块里本来就没有这些名字（换 blockIndex 再扫）\n"];
    }
    return out;
}

/*
 * 顺序扫一个块。
 *
 * 为什么要「顺序走」而不是逐条算地址：
 *   FNameEntry 是变长的（2 字节头 + Len*字符宽度），顺序走一遍只需要**一次**读，
 *   而且能把整块的名字都拿出来 —— 找地标类名靠这个，比逐条随机读快两个数量级。
 *
 * 走法：cursor += 2 + Len*宽，再按 stride 对齐。UE 的分配器就是这么排的。
 * 万一对齐假设错了（某些版本不补对齐），走两步就会解出垃圾 —— 所以这里
 * 两种对齐（stride / 1 字节）都试一次，谁走得远信谁。
 */
- (NSUInteger)sweepBlock:(uint32_t)blockIndex
               landmarks:(NSArray<NSString *> *)landmarks
              maxEntries:(NSUInteger)maxEntries
                  report:(NSMutableString *)rep {
    if (_layout != MFUENamesLayoutPool) {
        [rep appendString:@"  （非 FNamePool 布局，跳过顺序扫）\n"];
        return 0;
    }
    if (_offsetBits == 0 || _offsetBits >= 24) return 0;

    uint64_t entriesPerBlock = (uint64_t)1 << _offsetBits;
    uint64_t bytes = entriesPerBlock * (uint64_t)_stride;
    if (bytes == 0 || bytes > kMFUEGMaxBlockBytes) {
        [rep appendFormat:@"  （块太大 %llu 字节，跳过）\n", (unsigned long long)bytes];
        return 0;
    }

    uint64_t blockPtr = [self blockPointerForIndex:blockIndex];
    if (!MFUEIsValidPtr(blockPtr)) {
        [rep appendFormat:@"  块 %u 未分配（块指针非法）\n", blockIndex];
        return 0;
    }

    uint8_t *buf = (uint8_t *)malloc((size_t)bytes);
    if (buf == NULL) return 0;
    if (![[MFReadBackend shared] readRemote:blockPtr into:buf size:(size_t)bytes]) {
        free(buf);
        [rep appendString:@"  读块失败\n"];
        return 0;
    }

    NSUInteger bestWalked = 0;
    NSUInteger bestHits = 0;
    NSMutableArray<NSString *> *bestLines = nil;

    size_t aligns[2] = { (size_t)_stride, (size_t)1 };
    for (int a = 0; a < 2; a++) {
        size_t align = aligns[a];
        if (align == 0) align = 1;

        NSUInteger walked = 0;
        NSUInteger hits = 0;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        size_t cursor = 0;

        while (walked < maxEntries) {
            if (cursor + kMFUEGEntryHeaderBytes > (size_t)bytes) break;

            uint16_t raw = (uint16_t)((uint16_t)buf[cursor] |
                                      ((uint16_t)buf[cursor + 1] << 8));
            if (raw == 0) break;                       // 块尾：未使用区域全 0

            uint32_t len = MFUELenFromHeader(raw, _headerVariant);
            if (len == 0 || len > kMFUEGMaxNameChars) break;   // 走歪了

            BOOL wide;
            switch (_encoding) {
                case MFUENamesEncodingAnsi: wide = NO; break;
                case MFUENamesEncodingWide: wide = YES; break;
                default: wide = MFUEWideFromHeader(raw); break;
            }

            size_t need = (size_t)len * (wide ? 2u : 1u);
            size_t off = cursor + kMFUEGEntryHeaderBytes;
            if (off + need > (size_t)bytes) break;

            NSString *name = MFUEDecodeName(buf + off, len, wide);
            if (name == nil) break;                    // 解不出合法名字 → 这条走法不对

            for (NSString *lm in landmarks) {
                if ([name rangeOfString:lm].location != NSNotFound) {
                    if (lines.count < 40) {
                        uint64_t id = ((uint64_t)blockIndex << _offsetBits) + walked;
                        [lines addObject:[NSString stringWithFormat:@"    #%llu %@",
                                          (unsigned long long)id, name]];
                    }
                    hits++;
                    break;
                }
            }

            size_t adv = kMFUEGEntryHeaderBytes + need;
            adv = (adv + align - 1) / align * align;
            cursor += adv;
            walked++;
        }

        if (walked > bestWalked) {
            bestWalked = walked;
            bestHits = hits;
            bestLines = lines;
        }
    }
    free(buf);

    [rep appendFormat:@"  块 %u：%lu 条可解析（对齐方式取走得最远的那次）\n",
        blockIndex, (unsigned long)bestWalked];
    for (NSString *l in bestLines) [rep appendFormat:@"%@\n", l];

    return bestHits;
}

@end
