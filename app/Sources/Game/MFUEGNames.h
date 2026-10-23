//
//  MFUEGNames.h — UE4 类名解析（FName 池 / FNamePool）
//
//  ══════════════════════════════════════════════════════════════════════
//  【这个文件解决什么问题】
//
//  绘制层要按「这个 Actor 是 PickupBase 还是 DFMPlayerCharacter」分类，
//  但在此之前工程里根本没有一个可靠的类名来源：
//    · MFUEReader.mm   只读坐标，完全没有类名解析
//    · MFDrawingLayer.mm 里的 classNameForID: 是照抄 mingyun 反编译公式，
//      语义未验证，且「块号 >>15 / 块内 & 0x3FFFF」两个位宽自相矛盾
//    · kindForClassName: 依赖类名关键词（Character / Item / Weapon），
//      className 一旦为 nil，所有物资都会被判成「未知」
//
//  ══════════════════════════════════════════════════════════════════════
//  【布局结论（本次核实）】
//
//  权威来源：游戏 1.201.37117 的 MobileDumper-7 自检日志
//      C:\Users\xiaoping\Desktop\三角洲\DeltaForce-iOS-SDK\MobileDumper7.log
//  日志原文（第 70–77 行）：
//      GNames pointer: 0x117AA76C0
//      GNames offset:  0x1173776C0        ← 与我们 kMFUE_DefaultGNames 完全一致
//      GNames layout type: FNamePool      ← 不是 TNameEntryArray！
//      FNamePool::BlocksBit: 0x12
//      FNamePool::Blocks: 0xC8 -> 0x12CB54000     ← Blocks[] 在池内 +0xC8 处
//      FNameEntry::Stride: 0x2
//      FNameEntry::Header: 0x0
//      FNameEntry::String: 0x2
//  同日志第 67 行：`Entry 0 reads "None"; decoded 50 of 50 sampled names,
//                  8 matched known engine names.` —— 这套布局是**被工具自验证过的**。
//  另有第 318/320 行：bUseNamePool = true，bUseCasePreservingName = false。
//  另有第 87 行：General::MaxFNameLen = 512（类名长度上限的真实来源）。
//
//  于是三条硬结论：
//    ① GNames 是 **FNamePool**（UE 4.23+ 的名字池），不是 chunked 指针数组；
//    ② FNameEntry 头部 2 字节，字符串从 +0x2 开始（Header/Stride 双证）；
//    ③ Blocks[] 指针数组在本作里位于池内 **+0xC8 = 200** ——
//       这正好解释 mingyun 那个「+200」魔法数：它不是随便的偏置，
//       就是 Blocks[] 的成员偏移。反编译与 dump 工具两条独立来源对上了。
//
//  ⚠ 但 UE 标准 FNameEntryAllocator 里 Blocks[] 在 +0x10，不是 +0xC8。
//    本作引擎明显被改造过（旁证：dump 日志第 210–215 行给出的 UObject 布局也是
//    重排的 —— Class@0x08 / Outer@0x10 / Flags@0x18 / Name@0x1C / Index@0x24，
//    而标准 UE4 是 Flags@0x08 / Index@0x0C / Class@0x10 / Name@0x18 / Outer@0x20）。
//    所以「按 UE 文档写死偏移」在本作上必错，偏移必须自探 —— 本模块就是这么做的。
//
//  ══════════════════════════════════════════════════════════════════════
//  【仍未静态定死的一件事：块内位宽 offsetBits】
//
//  公式族确定无疑：entry = Blocks[id >> offsetBits] + (id & ((1<<offsetBits)-1)) * stride
//  但 offsetBits 到底是 15 / 16 / 18，三份资料三种说法：
//    · mingyun 反编译：块号用 >>15（15 位），块内却用 & 0x3FFFF（18 位）——自相矛盾
//    · UE 标准 FNamePool：>>16 / & 0xFFFF（16 位）
//    · 本作 dump 日志：BlocksBit = 0x12 = 18（18 位）
//  静态资料无法裁决（GObjects dump 里只有地址和名字，没有 FName id）
//  ⇒ 本模块**运行时实测块间距**（Blocks[1]-Blocks[0] 除以 stride 就是每块条目数），
//    用实测值定 offsetBits，再用高位 id 的解码成功率交叉验证，并把结论打进日志。
//    测不出来时退回 16 并明确标注「未证实」。
//
//  ══════════════════════════════════════════════════════════════════════
//  【一个必须提醒上层的坑：+0x1C 是「对象名」，不是「类名」】
//
//  任务约定 classNameForActor: 读 actor + 0x1C。按 dump 日志第 214/111 行，
//  UObject::Name = 0x1C，而 UObject::Class = 0x08 —— 也就是说 +0x1C 是**这个对象
//  自己的 FName 索引**（例如 "DFMPlayerCharacter_C_7"），不是它的类（"DFMPlayerCharacter"）。
//  两者对「hasSuffix:@"Character"」这类判定的结果不一样（对象名带 _C_n 后缀）。
//  所以本模块同时提供：
//      - classNameForObject:     读 +0x1C（= 任务里的 classNameForActor: 语义）
//      - classNameForActorClass: 读 +0x08 拿 UClass*，再读 +0x1C 拿**类名**
//  绘制层若要做「按类名分类」，应当用 classNameForActorClass:。
//
//  ══════════════════════════════════════════════════════════════════════
//  【安全约定（硬要求）】
//
//    · 任何地址在做 Read 之前先过 MFUEIsValidPtr
//    · 名字长度上限 512 字符 / 1024 字节，越界直接放弃
//    · 任何一步失败返回 nil，绝不抛异常、绝不越界读
//    · 解出的字符串必须全部是可打印标识符字符，否则判失败（垃圾内存拦截）
//    · 每个 id 结果进缓存（失败也缓存成 NSNull），避免反复读远程内存
//
#import <Foundation/Foundation.h>
#import "MFUEOffsets.h"
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 池的形态。探测结果，只读。
typedef NS_ENUM(NSInteger, MFUENamesLayout) {
    /// 还没探测过 / 探测失败
    MFUENamesLayoutUnknown = 0,
    /// FNamePool：Blocks[] 是指针数组，块内按 (id & mask) * stride 取址
    /// （本作的实际形态，见文件头结论①）
    MFUENamesLayoutPool = 1,
    /// 扁平：整张表是一段连续 FNameEntry，entry = base + id * stride。
    /// ★ 未在真机证实，只是兜底分支 —— 万一某个版本改回扁平表，探测能自己切过去。
    MFUENamesLayoutFlat = 2,
};

/// FNameEntry 头部 2 字节的位域切法。本作 bUseCasePreservingName=false，
/// 按 UE 源码应当是 Len10；但头部宽度这件事只有真机读出来才算数，所以两种都支持。
typedef NS_ENUM(NSInteger, MFUENamesHeader) {
    /// bIsWide:1 + Len:15（UE 的 WITH_CASE_PRESERVING_NAME = 1 那一支）
    MFUENamesHeaderLen15 = 0,
    /// bIsWide:1 + ProbeHash:5 + Len:10（= 0 那一支，本作大概率是它）
    MFUENamesHeaderLen10 = 1,
};

/// 字符串编码的强制模式（探测用；正常运行时用 Auto = 每条按 bIsWide 位）
typedef NS_ENUM(NSInteger, MFUENamesEncoding) {
    MFUENamesEncodingAuto = 0,   // 按头部 bit0（bIsWide）逐条判断
    MFUENamesEncodingAnsi = 1,   // 强制 1 字节/字符
    MFUENamesEncodingWide = 2,   // 强制 UTF-16LE，2 字节/字符
};

@interface MFUEGNames : NSObject

+ (instancetype)shared;

#pragma mark - 输入

/// 目标进程的模块基址。0 表示「还没定位」——此时会退回读 MFUEReader.shared.libBase。
@property (nonatomic, assign) uint64_t libBase;

/// 偏移表（拿 gnamesStaticOffset）。nil 时退回 MFUEReader.shared.profile。
@property (nonatomic, strong, nullable) MFUEProfile *profile;

/// 强制指定 Blocks[] 的池内偏移（0 = 自动探测）。
/// 默认 0：自动探。真机日志里已经确认是 0xC8，除非游戏改版否则不用动。
@property (nonatomic, assign) uint32_t forcedBlocksBias;

/// 强制指定块内位宽（0 = 自动探测：先测块间距，再高位交叉验证）。
@property (nonatomic, assign) uint32_t forcedOffsetBits;

#pragma mark - 探测结果（只读）

@property (nonatomic, readonly) MFUENamesLayout layout;
@property (nonatomic, readonly) uint32_t blocksBias;      // Blocks[] 在池内的偏移
@property (nonatomic, readonly) uint32_t offsetBits;      // 块内位宽
@property (nonatomic, readonly) uint32_t stride;          // 每条 FNameEntry 的步长（本作 2）
@property (nonatomic, readonly) MFUENamesHeader headerVariant;
@property (nonatomic, readonly) MFUENamesEncoding encoding;
@property (nonatomic, readonly) uint64_t gnamesBase;      // = libBase + gnamesStaticOffset
@property (nonatomic, readonly) NSString *probeReport;    // 探测全过程（可直接 NSLog）

@property (nonatomic, readonly) NSUInteger resolvedCount;
@property (nonatomic, readonly) NSUInteger failedCount;

#pragma mark - 探测

/// 幂等。YES = 布局已确认、可以开始解名；NO = 拿不到（原因写进 probeReport）。
- (BOOL)probeIfNeeded;

/// 丢掉探测结果与缓存，下次调用重新探（游戏更新后手动重置用）。
- (void)resetProbe;

#pragma mark - 取类名

/// FName 索引 → 字符串。失败返回 nil（不返回 @"?"，保持与绘制层原有语义一致：
/// nil 表示「这帧没类名」，上层据此走保守分支）。
- (nullable NSString *)classNameForID:(int32_t)classId;

/// 读 object + UObject::Name(+0x1C) → FName 索引 → 名字。
/// ★ 这是**对象名**（"XXX_C_7" 这种），任务约定里的 classNameForActor: 即此语义。
- (nullable NSString *)classNameForActor:(uint64_t)actor;

/// 同 classNameForActor:，换个更准确的名字（+0x1C 是 UObject.Name，见文件头）。
- (nullable NSString *)classNameForObject:(uint64_t)object;

/// 读 object + UObject::Class(+0x08) 拿 UClass*，再读它的 Name(+0x1C) → **类名**。
/// 绘制层要按「PickupBase / DFMPlayerCharacter」分类，应该用这个。
- (nullable NSString *)classNameForActorClass:(uint64_t)actor;

#pragma mark - 诊断

- (void)clearCache;
- (NSString *)statsText;

/// 真机一次性验证：解一批 id 打日志 + 扫首块、报出命中地标关键词的名字。
/// 返回值可直接塞进 HUD 的诊断页。
- (NSString *)selfTest;

@end

NS_ASSUME_NONNULL_END
