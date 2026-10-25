//
//  MFDrawingLayer.mm — 透明绘制层（实现）
//
#import "MFDrawingLayer.h"
#import "../Render/MFOverlayView.h"
#import "../Game/MFGameReader.h"
#import "../Game/MFUEReader.h"
#import "../Game/MFSettings.h"
#import "../Game/MFUEGNames.h"       /* [M5.85] 类名解析（FNamePool，已核实布局） */
#import "../Game/MFGearCatalog.h"    /* [M5.85] 物资/装备类名分类目录 */
#import "../Game/MFGearReader.h"     /* [M5.85] 物资属性读取（真实偏移） */
#import "../Game/MFItemNames.h"      /* [M5.159] 物品 ID → 中文名 */
#import "../Game/MFItemTable.h"      /* [M5.86] 物品定义表（等级/价值/名字） */
#import "../Game/Offsets.h"
#import "../Read/MFReadBackend.h"
#import "../Read/MFExternalFeed.h"
#import "MFHUDLog.h"
#import "MFRadar.h"        /* [M5.139] 圆形雷达（移植自参考项目 radar.h） */
#import "../Game/MFBones.h"  /* [M5.141] 真骨骼（ComponentSpaceTransforms） */

#import <QuartzCore/QuartzCore.h>      // CACurrentMediaTime（自检动画）

#include "imgui.h"
#include <limits.h>     /* [M5.85] INT_MAX：装备价值是 int64，落到 MFEntity.value(int) 前要钳制 */
#include <stdlib.h>   /* calloc —— 宽松读要清零 */
#include <math.h>     /* tanf —— 盒子高度按焦距算 */

static BOOL gDrawEnabled = YES;

/*
 * ★★ [M5.74] 绘制层的数据源 ★★
 *
 * 项目里有两条读游戏的链，能力完全不同：
 *
 *   ① MFUEReader —— 模块基址 + GWorld 静态偏移 → GameInstance → … → Actors
 *      起点只有一个 libBase，而 libBase 由「模块定位」自动拿到。
 *      也就是说：**这条链可以自动建立**，一键开始跑的就是它。
 *
 *   ② MFGameReader —— 白米饭那条纯偏移链，起点是三个**手工校准**的绝对地址
 *      （rootObjectBase / entityArrayBase / lootArrayBase）。
 *      它自己头文件里就写着「当前尚无基址校准 UI」——
 *      全工程没有任何地方能给这三个值赋值。
 *
 * 在此之前绘制层接的是 ②：cameraOK 恒为 false，屏幕上永远什么都没有，
 * 表现就是用户说的「数据链接不上」。
 *
 * 现在：② 只要校准过就优先（它能提供物资分级/队伍/血量），
 *       没校准时自动落到 ① —— 至少人物框、背敌提示能工作。
 */
typedef NS_ENUM(NSInteger, MFDrawSource) {
    MFDrawSourceNone = 0,
    MFDrawSourceUE4,          // 可自动建立
    MFDrawSourceCalibrated,   // 需要手工校准的三个绝对基址
    MFDrawSourceExternal,     // Frida agent 通过 UDP 推来的（真机唯一可行的路）
};

/// Actor 的用途分类 —— 由类 ID 解析出的 UE 类名判定。
/// 没有这层分类的话，ULevel::Actors 里整关卡的静态物件都会被画成人物框。
typedef NS_ENUM(NSInteger, MFActorKind) {
    MFActorKindUnknown = 0,
    MFActorKindPerson,
    MFActorKindLoot,
    MFActorKindBox,
};

/// UE4 那条链的 Actor 世界坐标缓存。
///
/// ULevel::Actors 是**整个关卡**的 Actor 列表（静态物件也算在内），数量可能上千。
/// 逐个 mach_vm_remap 读坐标 = 每帧上千次系统调用，主线程会直接被钉死。
/// 所以：指针数组定期重读、坐标按预算轮转读、世界坐标缓存下来，
/// 投影用当前相机每帧重算（相机每帧都在动）。
@interface MFUECachedActor : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, assign) float x, y, z;
@property (nonatomic, assign) int32_t classID;
@property (nonatomic, assign) MFActorKind kind;
@property (nonatomic, copy, nullable) NSString *className;
@property (nonatomic, assign) CFTimeInterval seenAt;
@end
@implementation MFUECachedActor
@end

static const NSUInteger kMFUEActorBudgetPerFrame = 320;   // 每帧最多读多少个 Actor 坐标
static const NSTimeInterval kMFUEActorTTL = 1.0;          // 多久没更新就丢弃
static const NSTimeInterval kMFUEResolveTTL = 1.0;        // 链结构最快多久重解一次
static const NSTimeInterval kMFUEAddressTTL = 1.0;        // Actor 指针数组多久重读一次
static const NSTimeInterval kMFUEHistogramInterval = 15.0; // 类名直方图多久打一次日志

@interface MFDrawingLayer ()
@property (nonatomic, strong) MFGameReader *reader;
/// 这一帧有没有真正画出东西（决定绘制层是全速还是低频空转）
- (void)noteDrawingActivity:(BOOL)active;
/// 取一帧数据：先试已校准的 MFGameReader，再落到可自动建立的 UE4 链
- (BOOL)acquireFrameWithSize:(CGSize)size
                      camera:(MFCamera *)outCamera
                    entities:(NSArray<MFEntity *> **)outEntities
                        loot:(NSArray<MFEntity *> **)outLoot
                      source:(MFDrawSource *)outSource;
- (BOOL)acquireUE4FrameWithSize:(CGSize)size
                         camera:(MFCamera *)outCamera
                       entities:(NSArray<MFEntity *> **)outEntities
                           loot:(NSArray<MFEntity *> **)outLoot
                         source:(MFDrawSource *)outSource;
/// UE4 链断在哪里（限流记录，不要每帧刷屏）
- (void)noteUE4Issue:(NSString *)reason;
/// 懒启动外部数据源（Frida agent → UDP）
- (void)startExternalFeedIfNeeded;
/// 用外部数据源组装一帧；数据过期/无相机时返回 NO，让上层回退到本地链
- (BOOL)acquireExternalFrameWithSize:(CGSize)size
                              camera:(MFCamera *)outCamera
                            entities:(NSArray<MFEntity *> **)outEntities
                                loot:(NSArray<MFEntity *> **)outLoot
                              source:(MFDrawSource *)outSource;
/// 本帧数据来自哪条链（诊断文本）
- (NSString *)dataSourceText;
/// 类 ID → UE 类名（GNames 解析，带缓存与可打印性校验）
- (NSString *_Nullable)classNameForID:(int32_t)classID;
/// 类名 → 人物 / 物资 / 盒子 / 未识别
- (MFActorKind)kindForClassName:(NSString *)name;
/// 解析成功率够不够用来过滤（不够就退回全画）
- (BOOL)classificationUsable;
- (void)recordKind:(MFActorKind)kind className:(NSString *_Nullable)name;
- (void)logClassHistogramIfDue;
- (void)drawBackEnemies:(NSArray<MFEntity *> *)ents
               drawList:(ImDrawList *)dl
               settings:(MFSettings *)st
                 screen:(ImVec2)screen;
- (BOOL)drawRealBonesForEntity:(MFEntity *)e drawList:(ImDrawList *)dl
                      settings:(MFSettings *)st camera:(MFCamera)cam screen:(ImVec2)screen;
- (void)drawRadar:(NSArray<MFEntity *> *)ents
         drawList:(ImDrawList *)dl
         settings:(MFSettings *)st
           camera:(MFCamera)cam
           screen:(ImVec2)screen;
- (void)drawSkeleton:(MFEntity *)e drawList:(ImDrawList *)dl
            settings:(MFSettings *)st camera:(MFCamera)cam at:(ImVec2)pt
              height:(float)bodyPx;
- (ImVec2)smoothPoint:(ImVec2)raw address:(uint64_t)addr settings:(MFSettings *)st;
@end

/// UIKit 颜色 → ImU32（ImGui 的 ABGR 打包格式）
static ImU32 MFU32(UIColor *c, float alphaScale = 1.0f) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { r = g = b = 1; a = 1; }
    a *= alphaScale;
    return IM_COL32((int)(r * 255), (int)(g * 255), (int)(b * 255), (int)(a * 255));
}

static ImU32 MFU32A(UIColor *c, int alpha) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { r = g = b = 1; }
    return IM_COL32((int)(r * 255), (int)(g * 255), (int)(b * 255), alpha);
}

/* ── 字号支持（[M5.2] 接线）─────────────────────────────────────
 * DrawList 的 AddText 有一个带 (font, size) 的重载 —— 用它就能逐条文本设字号，
 * 不用 PushFont/PopFont，也不会影响 ImGui 的窗口字体栈。
 * CalcTextSize 不接受字号，所以按 GetFontSize() 等比缩放算宽度。
 */
static float MFTextK(float size) {
    float base = ImGui::GetFontSize();
    return (base > 0.5f) ? (size / base) : 1.0f;
}
static ImVec2 MFTextSize(const char *s, float size) {
    ImVec2 t = ImGui::CalcTextSize(s);
    float k = MFTextK(size);
    return ImVec2(t.x * k, t.y * k);
}
static void MFText(ImDrawList *dl, float size, ImVec2 pos, ImU32 col, const char *s) {
    dl->AddText(ImGui::GetFont(), MAX(8.0f, size), pos, col, s);
}

@implementation MFDrawingLayer {
    MFGameReader *_reader;
    NSUInteger _entCount;
    NSUInteger _lootCount;
    BOOL _camOK;

    /* ── 平滑绘制缓存（[M5.2]）──
     * key = 实体地址，value = 上一帧的屏幕坐标（CGPoint —— NSValue 原生支持）。
     * 打开「平滑绘制」时，新坐标按 lerp 追上去，视觉上不会一格一格跳。
     * 只在 smoothAim 打开时使用；关掉时直接清空，避免残留旧位置。
     */
    NSMutableDictionary<NSNumber *, NSValue *> *_smoothCache;

    /* ── 背敌计数（[M5.2]）── 供底部状态条显示 */
    NSUInteger _backEnemyCount;

    /* ── UE4 链状态（[M5.74]）────────────────────────── */
    MFDrawSource _source;                                   // 本帧用的是哪条链
    NSMutableDictionary<NSNumber *, MFUECachedActor *> *_ueActors;   // 地址 → 世界坐标
    NSMutableArray<NSNumber *> *_ueActorAddrs;              // 本关卡的 Actor 指针数组
    NSUInteger _ueCursor;                                   // 坐标轮转游标
    MFUEResolveResult *_ueResolve;                          // 缓存的链解析结果
    CFTimeInterval _ueResolveAt, _ueAddrsAt, _ueIssueAt;
    NSString *_ueLastIssue;

    /* ── 类名解析与分类（[M5.75]）────────────────────── */
    NSMutableDictionary<NSNumber *, id> *_classNameByID;    // 类 ID → 类名 / NSNull（解析失败）
    NSUInteger _classResolved, _classFailed;                // 解析成功率决定分类是否可用
    NSMutableDictionary<NSString *, NSNumber *> *_kindHistogram;  // 类名 → 出现次数
    CFTimeInterval _histogramAt;
    NSUInteger _kindPerson, _kindLoot, _kindBox, _kindUnknown;
    NSUInteger _kindReal, _kindBot;                         // 真人 / 人机（本帧）
}

+ (void)setEnabled:(BOOL)enabled { gDrawEnabled = enabled; }
+ (BOOL)enabled { return gDrawEnabled; }

- (instancetype)init {
    if ((self = [super init])) {
        _reader = [MFGameReader shared];
        _smoothCache = [NSMutableDictionary dictionary];
        _ueActors = [NSMutableDictionary dictionary];
        _ueActorAddrs = [NSMutableArray array];
        _classNameByID = [NSMutableDictionary dictionary];
        _kindHistogram = [NSMutableDictionary dictionary];

        /*
         * [M5.85] 把「名字索引 → 字符串」接给物资读取器。
         *
         * 为什么用回调注入而不是让 MFGearReader 直接 import MFUEGNames：
         *   FName 池解析和物资字段读取是两个独立关注点，
         *   物资模块只该关心"字段在哪"，名字怎么解是 GNames 模块的事。
         *   这样两条也能各自单独测试/替换。
         *
         * block 只捕获类（不捕获 self），所以不会造成循环引用。
         */
        [MFGearReader shared].nameLookup = ^NSString *(uint32_t nameIndex) {
            return [[MFUEGNames shared] classNameForID:(int32_t)nameIndex];
        };
    }
    return self;
}

#pragma mark - 类名解析与分类（[M5.75]）

/*
 * ★ [M5.85] 类名解析已改为委托 MFUEGNames ★
 *
 * 原来这里照抄 mingyun 的两行公式：
 *     entry = Read<u64>(sGName + ((id >> 15) & 0xFFF8) + 200)
 *     chars = entry + 2 * (id & 0x3FFFF)          ← UTF-16
 *
 * 那两行有三个硬伤（详见 MFUEOffsets.h 的 GNames 段与 MFUEGNames.h 文件头）：
 *   ① 块号切 15 位、块内却取 18 位 —— 加起来 33 位 > 32 位 id 空间，数学上不可能
 *   ② FNameEntry 头部 2 字节被当成第一个字符读了，整条从首字符起错位
 *   ③ 写死 UTF-16，而本作 bUseCasePreservingName = false，绝大多数条目是 ANSI
 *
 * 现在的真值来自 MobileDumper7.log 的自检输出：
 *   FNamePool / Blocks@池内+0xC8 / Header@0x0 / String@0x2 / Stride=2 / Entry0="None"
 * 具体取址与编码判断都在 MFUEGNames 里，本层只负责计数和缓存。
 */
- (NSString *)classNameForID:(int32_t)classID {
    if (classID <= 0) return nil;
    NSNumber *key = @(classID);
    id cached = _classNameByID[key];
    if (cached) return (cached == [NSNull null]) ? nil : cached;

    // MFUEGNames 自己做指针合法性判断、可打印性校验、按 id 缓存、失败节流。
    NSString *name = [[MFUEGNames shared] classNameForID:classID];

    if (name.length == 0) {
        _classFailed++;
        _classNameByID[key] = [NSNull null];
        return nil;
    }
    _classResolved++;
    _classNameByID[key] = name;
    return name;
}

/// 类名 → 用途。
///
/// ★ [M5.85] 改为委托 MFGearCatalog 的真实类名表 ★
///
/// 原实现是「类名包含某关键词就当物资/盒子」，两个方向都有问题：
///   漏：真物资的类名不一定含 Item / Pickup / Weapon
///   脏：下面这些全都含 "Pickup"，全都不是场景 Actor ——
///       PickupManager / PickupFactoryComponent / PickupStaticMeshComponent /
///       NearbyPickupItem（UI）/ DFMAITask_Pickup（AI 任务）/
///       DFMAIDecorator_NearbyPickupCheck / PickupOpenBoxAnimInstance
///       它们一旦被当成物资，屏幕上就是整批"有坐标有距离"的假目标。
///
/// 现在 MFGearCatalog 依据 SDK 里的真实继承链判（PickupBase / InventoryPickup /
/// PlunderPickup / 各 InventoryPickup_* 子类），并带一张显式忽略表；
/// 同时支持剥模块前缀（DFMGameplay.）和蓝图后缀（BP_xxx_C）。
/// 角色仍用「类名以 Character 结尾」——CharacterMovementComponent 这类
/// 组件已经在目录内部被忽略表拦掉了。
- (MFActorKind)kindForClassName:(NSString *)name {
    if (name.length == 0) return MFActorKindUnknown;

    switch ([[MFGearCatalog shared] actorKindForClassName:name]) {
        case MFGearActorKindCharacter: return MFActorKindPerson;
        case MFGearActorKindLoot:      return MFActorKindLoot;
        case MFGearActorKindContainer: return MFActorKindBox;
        default:                       return MFActorKindUnknown;
    }
}

/// 分类是否已经可信到可以用来过滤。
/// 判据：解析成功过、且成功率不低于一半。不满足就退回「不分类、全画」。
- (BOOL)classificationUsable {
    if (_classResolved == 0) return NO;
    return _classResolved * 2 >= (_classResolved + _classFailed);
}

- (void)recordKind:(MFActorKind)kind className:(NSString *)name {
    switch (kind) {
        case MFActorKindPerson: _kindPerson++; break;
        case MFActorKindLoot:   _kindLoot++;   break;
        case MFActorKindBox:    _kindBox++;    break;
        default:                _kindUnknown++; break;
    }
    if (name.length) {
        _kindHistogram[name] = @([_kindHistogram[name] unsignedIntegerValue] + 1);
    }
}

#pragma mark - 平滑坐标（[M5.2]）

/// 打开时：新坐标向旧坐标插值追上去；关闭时：直接用新坐标并清缓存
- (ImVec2)smoothPoint:(ImVec2)raw address:(uint64_t)addr settings:(MFSettings *)st {
    if (!st.smoothAim) {
        if (_smoothCache.count) [_smoothCache removeAllObjects];
        return raw;
    }
    NSNumber *key = @(addr);
    NSValue *old = _smoothCache[key];
    ImVec2 out = raw;
    if (old) {
        CGPoint o = old.CGPointValue;
        const float k = 0.45f;              // 追赶系数：越大越跟手，越小越平滑
        out.x = (float)o.x + (raw.x - (float)o.x) * k;
        out.y = (float)o.y + (raw.y - (float)o.y) * k;
    }
    _smoothCache[key] = [NSValue valueWithCGPoint:CGPointMake(out.x, out.y)];
    return out;
}

- (NSUInteger)lastEntityCount { return _entCount; }
- (NSUInteger)lastLootCount { return _lootCount; }
- (BOOL)lastCameraOK { return _camOK; }

#pragma mark - 每帧

/*
 * [M5.66] 绘制层的「有没有内容」反馈。
 *
 * 绘制层是全屏 2048×2732 的 Metal surface —— 每帧 clear + present 都要
 * 真金白银的显存带宽。可它经常无事可做：总开关关着、还没绑定目标进程、
 * 相机读不到、屏幕上没有敌人也没有物资。
 *
 * 这种时候把 overlay 的空闲帧率压到 20，有内容时立刻恢复满帧。
 * 菜单层用的是同一套机制（交互满帧、空闲 12）。
 */
- (void)noteDrawingActivity:(BOOL)active {
    MFOverlayView *overlay = self.overlay;
    if (!overlay) return;
    NSInteger want = active ? 0 : 20;      // 0 = 不降频，直接用满帧率
    if (overlay.idleFPS != want) {
        overlay.idleFPS = want;
        NSLog(@"[MF][Draw] 绘制层空闲帧率 → %ld（%s）", (long)want, active ? "有内容" : "无内容");
    }
}

/// UE4 链断在哪里 —— 限流记录一次，不要每帧刷日志
- (void)noteUE4Issue:(NSString *)reason {
    if (reason.length == 0) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (_ueLastIssue && [reason isEqualToString:_ueLastIssue] && now - _ueIssueAt < 10.0) return;
    _ueLastIssue = [reason copy];
    _ueIssueAt = now;
    MFHUDLogLine(@"[绘制] UE4 链未通：%@", reason);
}

- (BOOL)acquireFrameWithSize:(CGSize)size
                      camera:(MFCamera *)outCamera
                    entities:(NSArray<MFEntity *> **)outEntities
                        loot:(NSArray<MFEntity *> **)outLoot
                      source:(MFDrawSource *)outSource {
    // ⓪ 外部数据源（Frida agent → UDP）—— 真机上唯一能通的路
    [self startExternalFeedIfNeeded];
    if ([self acquireExternalFrameWithSize:size camera:outCamera
                                  entities:outEntities loot:outLoot source:outSource]) {
        return YES;
    }

    // ① 手工校准过的那条链优先：它能给出物资分级 / 队伍 / 血量这些字段。
    MFGameReader *calibrated = [MFGameReader shared];
    if (calibrated.ready && calibrated.rootObjectBase != 0) {
        NSDictionary *frame = [calibrated readFrameWithSize:size];
        if ([frame[@"cameraOK"] boolValue]) {
            NSDictionary *cd = frame[@"camera"];
            MFCamera cam = {0};
            cam.x     = [cd[@"x"] floatValue];
            cam.y     = [cd[@"y"] floatValue];
            cam.z     = [cd[@"z"] floatValue];
            cam.pitch = [cd[@"pitch"] floatValue];
            cam.yaw   = [cd[@"yaw"] floatValue];
            cam.roll  = [cd[@"roll"] floatValue];
            cam.fov   = [cd[@"fov"] floatValue];
            if (outCamera) *outCamera = cam;
            if (outEntities) *outEntities = frame[@"entities"] ?: @[];
            if (outLoot) *outLoot = frame[@"loot"] ?: @[];
            if (outSource) *outSource = MFDrawSourceCalibrated;
            return YES;
        }
    }
    // ② 回退到可自动建立的 UE4 链
    return [self acquireUE4FrameWithSize:size camera:outCamera
                                entities:outEntities loot:outLoot source:outSource];
}

#pragma mark - 外部数据源（Frida agent → UDP，[M5.83]）

/*
 * 真机现状决定了必须有这条路：
 *   task_for_pid 全线 kr=0x5（PPL 挡 csblob 里的私有 entitlements）
 *   processor_set_tasks 全线 kr=0x4（没有 host_priv）
 *   → 本进程永远拿不到游戏的 task port，mach_vm_remap 无从谈起
 *
 * 但设备是 Dopamine 3.0.12 越狱 + frida-server，Frida 用 ptrace 注入 agent
 * 到游戏进程【内部】，agent 读内存不受任何限制。它把每帧的
 * 坐标 / 人机标志 / 类名打包成 UDP 推给 HUD 进程，这里解码后照常投影绘制。
 */
- (void)startExternalFeedIfNeeded {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *err = nil;
        if ([[MFExternalFeed shared] startOnPort:MFExternalFeedDefaultPort error:&err]) {
            MFHUDLogLine(@"[Feed] 外部数据源监听 127.0.0.1:%u（等 Frida agent 推流）",
                         (unsigned)MFExternalFeedDefaultPort);
        } else {
            MFHUDLogLine(@"[Feed] 监听失败：%@", err ?: @"?");
        }
    });
}

- (BOOL)acquireExternalFrameWithSize:(CGSize)size
                              camera:(MFCamera *)outCamera
                            entities:(NSArray<MFEntity *> **)outEntities
                                loot:(NSArray<MFEntity *> **)outLoot
                              source:(MFDrawSource *)outSource {
    MFExternalFeed *feed = [MFExternalFeed shared];
    if (!feed.running || !feed.fresh) return NO;

    MFCamera cam = {0};
    if (![feed snapshotCamera:&cam] || cam.fov < 1.0f) return NO;

    NSArray<MFFeedEntity *> *raw = [feed snapshotEntities];
    if (raw.count == 0) return NO;

    const MFScreen screen = [MFProjection screenWithSize:size fov:cam.fov];
    const float camPos[3] = {cam.x, cam.y, cam.z};
    const float maxDraw = MAX([MFSettings shared].boxDrawDistance, 100.0f);
    NSMutableArray<MFEntity *> *ents = [NSMutableArray arrayWithCapacity:raw.count];
    NSMutableArray<MFEntity *> *lootOut = [NSMutableArray array];

    for (MFFeedEntity *fe in raw) {
        const float world[3] = {fe.worldX, fe.worldY, fe.worldZ};
        MFEntity *e = [[MFEntity alloc] init];
        // 外部数据没有稳定的对象地址；用坐标量化值当平滑缓存的 key
        e.address = (uint64_t)(uint32_t)(int32_t)(fe.worldX * 8.0f) |
                    ((uint64_t)(uint32_t)(int32_t)(fe.worldZ * 8.0f) << 32);
        e.worldX = fe.worldX;
        e.worldY = fe.worldY;
        e.worldZ = fe.worldZ;
        e.distanceMeters = [MFProjection distanceMetersFrom:world to:camPos];
        if (e.distanceMeters > maxDraw) continue;
        e.screen = [[MFProjection shared] projectTarget:world camera:cam screen:screen];
        e.isVisible = e.screen.valid;
        e.isBot = fe.isBot;

        /* [M5.160] 协议 v2 的字段搬进绘制实体 */
        e.teamId        = fe.team;
        e.helmetLevel   = fe.helmet;
        e.armorLevel    = fe.armor;
        e.backpackLevel = fe.bag;
        e.health        = fe.health;
        e.uin           = fe.uin;
        e.weaponRawID   = fe.weaponId;
        if (fe.helmet || fe.armor || fe.bag) {
            e.equipKnown = YES;
            e.armorKnown = (fe.armor != 0);
        }
        if (fe.weaponId) e.weaponId = (int)((fe.weaponId / 10000000ULL) % 1000ULL);

        {   // 方位角：只由坐标 + 相机 yaw 算
            float dx = fe.worldX - cam.x, dy = fe.worldY - cam.y;
            float ty = atan2f(dy, dx) / kMF_Deg2Rad;
            float d = ty - cam.yaw;
            while (d >  180.0f) d -= 360.0f;
            while (d < -180.0f) d += 360.0f;
            e.bearingDeg = d;
            e.isBehind = (fabsf(d) > kMFBehindAngleDeg);
        }

        if (fe.kind == 2)      { e.isLoot = YES; [lootOut addObject:e]; }
        else if (fe.kind == 3) { e.isBox  = YES; [lootOut addObject:e]; }
        else                   { [ents addObject:e]; }
    }

    if (outCamera) *outCamera = cam;
    if (outEntities) *outEntities = ents;
    if (outLoot) *outLoot = lootOut;
    if (outSource) *outSource = MFDrawSourceExternal;

    // 数据新鲜、相机也有 —— 即使本帧没实体也算“取到了”，
    // 否则会掉回读不到数据的本地链路
    return YES;
}

- (BOOL)acquireUE4FrameWithSize:(CGSize)size
                         camera:(MFCamera *)outCamera
                       entities:(NSArray<MFEntity *> **)outEntities
                           loot:(NSArray<MFEntity *> **)outLoot
                         source:(MFDrawSource *)outSource {
    MFUEReader *ue = [MFUEReader shared];
    if (ue.libBase == 0) {
        [self noteUE4Issue:@"libBase = 0（HUD 还没拿到模块基址，见绑定日志）"];
        return NO;
    }
    if (![MFReadBackend shared].gateOpen) {
        [self noteUE4Issue:@"读取后端门未开（目标 task port 未绑定）"];
        return NO;
    }

    const CFTimeInterval now = CACurrentMediaTime();
    if (_ueResolve == nil || now - _ueResolveAt > kMFUEResolveTTL) {
        _ueResolve = [ue resolve];
        _ueResolveAt = now;
    }
    MFUEResolveResult *r = _ueResolve;
    if (r == nil || r.brokenAt) {
        [self noteUE4Issue:r.brokenAt ?: @"链解析失败"];
        _ueResolve = nil;                 // 下一帧立刻重试
        return NO;
    }

    // 相机每帧都要读 —— 玩家一直在动
    MFCamera cam = {0};
    if (![ue readCamera:&cam result:r]) {
        [self noteUE4Issue:@"相机读不出来（CameraCacheEntry 扫描没命中）"];
        _ueResolve = nil;
        return NO;
    }
    if (outCamera) *outCamera = cam;

    MFReadBackend *rb = [MFReadBackend shared];
    // [M5.135] 坐标两跳：AActor+0x180 → RootComponent，再 +0x220 → ComponentToWorld.Translation。
    // 0x220 是 K2_GetComponentLocation 的 native 实现自己用的偏移（ComponentToWorld@0x210 + 0x10）。
    // 旧实现直接读 Actor+0x220，少跳了一级，落在 AActor 的填充区，恒为 0。
    const uint32_t rootOffset = ue.profile.actor_rootComponent;
    const uint32_t locOffset  = ue.profile.scenecomponent_worldLocation;
    // [M5.85] 注意：ue.profile.actor_classID（0x1C）已经**不再用于分类**。
    // 按 dump 日志，本作 UObject::Name 就在 0x1C，读它得到的是对象名（"XXX_C_7"）
    // 而不是类名；类名要两跳（+0x08 → UClass，再 +0x1C → 类名索引）。
    // 下面这一行保留只是为了诊断时能和旧日志对照，实际分类不再引用它。
    const uint32_t classIDOffset = ue.profile.actor_classID;
    (void)classIDOffset;

    // ── Actor 指针数组：定期重读（一次批量读，几十 KB）──
    if (_ueActorAddrs.count == 0 || now - _ueAddrsAt > kMFUEAddressTTL) {
        [_ueActorAddrs removeAllObjects];
        _ueAddrsAt = now;
        _ueCursor = 0;
        size_t bytes = (size_t)r.actorsNum * 8;
        uint64_t *ptrs = (uint64_t *)calloc((size_t)r.actorsNum, sizeof(uint64_t));
        if (ptrs) {
            /* [M5.135] 宽松读：跨页失败时只丢尾巴，不整批作废 */
            size_t got = [rb readRemotePartial:r.actorsData into:ptrs size:bytes];
            int usable = (int)(got / sizeof(uint64_t));
            for (int i = 0; i < usable; i++)
                if (MFUEIsValidPtr(ptrs[i])) [_ueActorAddrs addObject:@(ptrs[i])];
            free(ptrs);
        }
    }

    // ── 坐标：轮转读，每帧有预算 ──
    const NSUInteger total = _ueActorAddrs.count;
    if (total > 0) {
        NSUInteger budget = MIN(kMFUEActorBudgetPerFrame, total);
        for (NSUInteger i = 0; i < budget; i++) {
            uint64_t addr = _ueActorAddrs[(_ueCursor + i) % total].unsignedLongLongValue;
            uint64_t rootComp = 0;
            if (![rb readU64:addr + rootOffset out:&rootComp]) continue;
            if (!MFUEIsValidPtr(rootComp)) continue;
            float pos[3] = {0};
            if (![rb readFloat3:rootComp + locOffset out:pos]) continue;
            if (!(fabsf(pos[0]) <= kMFUE_PosAbsMax)) continue;
            if (!(fabsf(pos[1]) <= kMFUE_PosAbsMax)) continue;
            if (!(fabsf(pos[2]) <= kMFUE_PosAbsMax)) continue;
            if (pos[0] == 0.0f && pos[1] == 0.0f && pos[2] == 0.0f) continue;
            NSNumber *key = @(addr);
            MFUECachedActor *cached = _ueActors[key];
            if (cached == nil) {
                cached = [[MFUECachedActor alloc] init];
                cached.address = addr;
                _ueActors[key] = cached;
            }
            cached.x = pos[0]; cached.y = pos[1]; cached.z = pos[2];
            cached.seenAt = now;
            /*
             * ★ [M5.85] 类名必须走两跳 —— 这是分类恒失败的真正根因 ★
             *
             * 本作 UObject 布局（MobileDumper7.log 第 210-215 行，运行时实测）：
             *     UObject::Class = 0x08    UObject::Outer = 0x10
             *     UObject::Flags = 0x18    UObject::Name  = 0x1C    UObject::Index = 0x24
             * 与 UE 标准（Flags@0x08 / Class@0x10 / Name@0x18 / Outer@0x20）**顺序不同**。
             *
             * 所以原来的 actor + 0x1C 读到的是 **UObject.Name** ——
             * 这个对象自己的名字，形如 "DFMPlayerCharacter_C_7"，不是它的类名。
             * 拿它去 hasSuffix:@"Character"，被 "_C_7" 一挡就永远不匹配 →
             * 所有 Actor 都落进 Unknown → 分类不可用 → 物资/人物全都画不出来。
             *
             * 类名的正确路径是两跳：
             *     cls = Read<u64>(actor + 0x08)      → UClass*
             *     id  = Read<u32>(cls   + 0x1C)      → UClass 自己的名字索引
             * MFUEGNames 的 classNameForActorClass: 就是这条路径，并且内部对每一步
             * 都做了指针合法性判断。
             */
            if (cached.classID == 0) {          // 0 = 还没试过
                cached.classID = -1;            // -1 = 试过了（成功与否都别每帧重试）
                cached.className = [[MFUEGNames shared] classNameForActorClass:addr];
                cached.kind = [self kindForClassName:cached.className];
                // 解析成功率决定「分类能不能用来过滤」；这里要自己维护计数，
                // 因为分类已经不再经过 classNameForID: 了。
                if (cached.className.length > 0) _classResolved++;
                else                             _classFailed++;
            }
        }
        _ueCursor = (_ueCursor + budget) % total;
    }

    // ── 用当前相机把缓存的世界坐标投影出来 ──
    const MFScreen screen = [MFProjection screenWithSize:size fov:cam.fov];
    const float camPos[3] = {cam.x, cam.y, cam.z};
    /*
     * 距离闸：UE4 的 Actors 是整关卡的列表，几百米外的静态物件没有任何意义，
     * 全画出来会把 GPU 拉满。用菜单里的「盒子距离」当上限，保底 100 米。
     */
    const float maxDrawDistance = MAX([MFSettings shared].boxDrawDistance, 100.0f);
    const BOOL classify = [self classificationUsable];
    NSMutableArray<MFEntity *> *ents = [NSMutableArray arrayWithCapacity:_ueActors.count];
    NSMutableArray<MFEntity *> *lootOut = [NSMutableArray array];
    NSMutableArray<NSNumber *> *stale = nil;
    for (NSNumber *key in _ueActors) {
        MFUECachedActor *a = _ueActors[key];
        if (now - a.seenAt > kMFUEActorTTL) {          // 读不到了（离开关卡/对象销毁）
            if (stale == nil) stale = [NSMutableArray array];
            [stale addObject:key];
            continue;
        }
        [self recordKind:a.kind className:a.className];

        /*
         * 分类可用时丢掉"认不出来"的 Actor —— ULevel::Actors 里有大量
         * 地图静态物件，全画出来就是满屏框。分类不可用时（GNames 公式没对上）
         * 退回全画，宁可糊也不能空。
         */
        if (classify && a.kind == MFActorKindUnknown) continue;

        const float world[3] = {a.x, a.y, a.z};
        MFEntity *e = [[MFEntity alloc] init];
        e.address = a.address;
        e.worldX = a.x; e.worldY = a.y; e.worldZ = a.z;
        e.distanceMeters = [MFProjection distanceMetersFrom:world to:camPos];
        if (e.distanceMeters > maxDrawDistance) continue;   // 太远，连投影都不用做
        e.screen = [[MFProjection shared] projectTarget:world camera:cam screen:screen];
        e.isVisible = e.screen.valid;
        {   // 方位角 —— 只由坐标 + 相机 yaw 算，不依赖任何游戏字段
            float dx = a.x - cam.x, dy = a.y - cam.y;
            float ty = atan2f(dy, dx) / kMF_Deg2Rad;
            float d = ty - cam.yaw;
            while (d >  180.0f) d -= 360.0f;
            while (d < -180.0f) d += 360.0f;
            e.bearingDeg = d;
            e.isBehind = (fabsf(d) > kMFBehindAngleDeg);
        }
        // 物资 / 容器走独立的绘制路径（等级配色 + 价值强调 + 名字）
        if (a.kind == MFActorKindLoot || a.kind == MFActorKindBox) {
            e.isLoot = YES;
            e.isBox  = (a.kind == MFActorKindBox);

            /*
             * ★ [M5.85] 物资字段换成真实来源 ★
             *
             * 原来这两行读的是白米饭的候选偏移：
             *     e.level = Read<u32>(actor + 0x68);
             *     e.value = Read<u32>(actor + 0xDC);
             * sdk-gear 核对后确认：0x68 / 0xDC 确实是 Quality / InitialGuidePrice，
             * 但它们属于**物品配置行 FDFMCommonItemRow**，不是 Actor 字段。
             * 落在 AActor 区间里读到的是 PrimaryActorTick / InitialLifeSpan 附近的无关数据 ——
             * 所以之前屏幕上那些"等级/价值"是垃圾。
             *
             * 现在走 MFGearReader，字段来源（Dumper-7 SDK 1.201.37117）：
             *   PickupBase  +0x0FF0  InventoryIdName      物品 ID（FName，靠 GNames 解）
             *   PickupBase  +0x0FE0  SourceType           来源（EEPickupSourceType）
             *   PickupItemInfo +0x10 ItemID.Category      物品主类型（EEItemMainType）
             *   PickupItemInfo +0x38 ItemCount            数量
             *   PickupItemInfo +0x564 StarNum             星级
             *   ArchiveInfo +0x240   EquipmentValue       价值（仅尸体/掉落可信，见头文件）
             */
            MFGearInfo *gear = [[MFGearReader shared] readGearForActor:a.address
                                                             className:a.className
                                                               isActor:NULL];
            if (gear) {
                // 名字：优先物品 ID 名；拿不到就用目录的可读标签（"尸体盒"/"武器箱"），
                // 绝不把 "InventoryPickup_DeadBody" 这种原始类名当物品名显示
                e.name = gear.itemIdName.length
                       ? gear.itemIdName
                       : [[MFGearCatalog shared] fallbackLabelForClassName:a.className];

                if (gear.count > 0) e.count = gear.count;

                // 价值：只有通过值域校验才采信
                if (gear.hasValue && gear.value > 0) {
                    e.value = (gear.value > (long long)INT_MAX) ? INT_MAX : (int)gear.value;
                }

                /*
                 * 等级：优先用**物品定义表**里的 Quality（真·品质，0–6 级）。
                 * 查不到（表没加载 / 这行不在表里）才退回 Actor 上的 StarNum。
                 * 两者不是一回事：Quality 是品质分级，StarNum 是星级，别混用。
                 */
                if (gear.hasQuality)   e.level = gear.quality;
                else if (gear.hasStar) e.level = gear.starNum;

                e.gearCategory = (uint32_t)gear.mainType;
            } else {
                // 连 PickupBase 头都没读到：至少给个可读标签，别显示类名
                e.name = [[MFGearCatalog shared] fallbackLabelForClassName:a.className];
            }
            [lootOut addObject:e];
        } else if (a.kind == MFActorKindPerson) {
            /*
             * ★ [M5.77] 人机 / 真人 ★
             *
             * AGPCharacterBase + 0x0E60 = bool bIsPlayerAI
             * （Dumper-7 SDK：GPGameplay_classes.hpp，AGPCharacterBase 的字段）
             * 1 = 人机，0 = 真人。整个角色继承链共用这个偏移。
             *
             * 读失败时保持 false（当真人画）—— 宁可多画一个真人框，
             * 也不要把真人误标成人机。
             */
            uint8_t isAI = 0;
            if ([rb readRemote:a.address + ue.profile.character_isAI into:&isAI size:1]) {
                e.isBot = (isAI != 0);
            }
            if (e.isBot) _kindBot++; else _kindReal++;
            [ents addObject:e];
        } else {
            [ents addObject:e];
        }
    }
    for (NSNumber *key in stale) [_ueActors removeObjectForKey:key];
    [self logClassHistogramIfDue];

    if (outEntities) *outEntities = ents;
    if (outLoot) *outLoot = lootOut;
    if (outSource) *outSource = MFDrawSourceUE4;
    return YES;
}

/// 定期把「这一关卡里都有哪些类、各自命中什么分类」打到日志 ——
/// 这是调整分类关键词的唯一依据（没有真机就没法猜游戏用了哪些类名）。
- (void)logClassHistogramIfDue {
    const CFTimeInterval now = CACurrentMediaTime();
    if (now - _histogramAt < kMFUEHistogramInterval) return;
    _histogramAt = now;

    NSArray<NSString *> *top = [_kindHistogram keysSortedByValueUsingComparator:
        ^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    NSMutableString *sample = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN((NSUInteger)12, top.count); i++) {
        [sample appendFormat:@"%@×%@ ", top[i], _kindHistogram[top[i]]];
    }
    MFHUDLogLine(@"[绘制] UE4 分类(累计)：角色=%lu（真人 %lu / 人机 %lu）物资=%lu 盒子=%lu 未识别=%lu"
                 @" · GNames 解析 ok=%lu fail=%lu(%@) · 类名 Top: %@",
                 (unsigned long)_kindPerson, (unsigned long)_kindReal, (unsigned long)_kindBot,
                 (unsigned long)_kindLoot,
                 (unsigned long)_kindBox, (unsigned long)_kindUnknown,
                 (unsigned long)_classResolved, (unsigned long)_classFailed,
                 [self classificationUsable] ? @"分类生效" : @"退回全画",
                 sample.length ? sample : @"（一个类名都没解出来）");

    /*
     * ★ [M5.85] 装备对接的观测点 ★
     *
     * 装备 ESP 牵涉三环，任何一环不对屏幕上就是空白。这三行日志就是为了
     * 让真机上"一眼看出断在哪"，不用再回头翻代码：
     *
     *   ① GNames 探测结论 —— 类名能不能解出来（layout/bias/bits/ok-fail）
     *      若 layout=Unknown 或 ok 恒 0：FNamePool 没探出来，
     *      看 MFUEGNames 的 probeReport，那里有 4 组候选的命中情况。
     *
     *   ② 物资读取器自检 —— 偏移表本身有没有写错（纯本地计算，不依赖游戏内存）
     *      只在第一次打，避免刷屏。
     *
     *   ③ 分类计数 —— 物资/盒子各命中多少。若物资=0 而角色有值，
     *      说明类名表需要按真机关卡的实际类名补条目。
     */
    MFHUDLogLine(@"[装备] %@", [[MFUEGNames shared] statsText]);

    static BOOL gearSelfCheckLogged = NO;
    if (!gearSelfCheckLogged) {
        gearSelfCheckLogged = YES;
        MFHUDLogLine(@"[装备] %@", [[MFGearReader shared] selfCheckReport]);
        MFHUDLogLine(@"[装备] %@", [[MFGearCatalog shared] selfCheckReport]);
    }

    /*
     * 物品定义表一旦就绪，立刻打 8 行样例。
     *
     * 这是「等级到底有没有真的读到」最直接的证据：
     * 表就会显示真实物品 ID + 品质 + 价值；
     * 表没读到就一直是"未就绪"，同时 probeReport 会说明断在哪一步
     * （GObjects 偏移 → 下标 → RowStruct 校验 → TMap 布局 → 索引）。
     */
    static BOOL itemTableLogged = NO;
    if (!itemTableLogged && [MFItemTable shared].ready) {
        itemTableLogged = YES;
        MFHUDLogLine(@"[装备] %@", [[MFItemTable shared] sampleReport:8]);
    }
}

- (void)overlayBuildUI:(MFImGuiContext *)ctx overlay:(MFOverlayView *)overlay {
    _entCount = 0;
    _lootCount = 0;
    _camOK = NO;

    MFSettings *st = [MFSettings shared];
    if (!gDrawEnabled || !st.masterEnabled || !st.drawEnabled) { [self noteDrawingActivity:NO]; return; }

    const CGSize size = overlay.bounds.size;
    if (size.width < 1 || size.height < 1) { [self noteDrawingActivity:NO]; return; }

    // ── 渲染自检：不碰游戏内存，纯合成数据 ──
    //   用途：在偏移校准之前，独立验证 ImGui → Metal → 透明层 → 投影 这条链。
    if (st.renderSelfTest) {
        [self runSelfTest:st overlay:overlay];
        [self noteDrawingActivity:YES];
        return;
    }

    // Source selection must run even when local memory access is unavailable:
    // acquireFrameWithSize starts/checks the independent external feed first.
    // Each local source validates its own readiness before attempting reads.
    MFCamera cam = {0};
    NSArray<MFEntity *> *ents = nil;
    NSArray<MFEntity *> *loot = nil;
    MFDrawSource source = MFDrawSourceNone;
    _camOK = [self acquireFrameWithSize:size camera:&cam entities:&ents loot:&loot source:&source];
    _source = source;
    if (!_camOK) { [self noteDrawingActivity:NO]; return; }

    _entCount = ents.count;
    _lootCount = loot.count;

    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    if (!dl) return;

    const int initialVertices = dl->VtxBuffer.Size;
    const ImVec2 screen((float)size.width, (float)size.height);

    // ── 人/盒子 ──
    for (MFEntity *e in ents) {
        if (!e.isVisible) continue;
        [self drawEntity:e drawList:dl settings:st screen:screen camera:cam];
    }

    /* ── [M5.139] 雷达：画在实体循环之后、背敌之前 ── */
    [self drawRadar:ents drawList:dl settings:st camera:cam screen:screen];

    if (st.backEnemyEnabled) {
        [self drawBackEnemies:ents drawList:dl settings:st screen:screen];
    }

    // ── 物资 ──
    if (st.showLoot || st.showBox) {
        for (MFEntity *e in loot) {
            if (!e.isVisible) continue;
            [self drawLoot:e drawList:dl settings:st screen:screen];
        }
    }

    // ── 物资统计窗（可选）──
    if (st.showLootStats) [self drawStats:st loot:loot];

    // Base activity on generated content after visibility/settings filters.
    [self noteDrawingActivity:(dl->VtxBuffer.Size > initialVertices || st.showLootStats)];
}

#pragma mark - 人 / 盒子

- (void)drawEntity:(MFEntity *)e drawList:(ImDrawList *)dl
          settings:(MFSettings *)st screen:(ImVec2)screen camera:(MFCamera)cam {
    /* ── [M5.2] 人机过滤 ──
     * isBot 来自实体字段；未校准时恒 NO —— 所以「人机显示」关掉【不会】把所有人都隐藏，
     * 只会隐藏真的判定为人机的那些。这是「未校准不画错」的关键。
     */
    if (e.isBot && !st.showBot) return;

    /* ── [M5.2] 平滑坐标 ── */
    ImVec2 pt = [self smoothPoint:ImVec2(e.screen.x, e.screen.y)
                          address:e.address settings:st];

    /*
     * ★ [M5.137] 位置是【胶囊体中心】，不是脚底。
     *
     * ComponentToWorld.Translation 对 ACharacter 来说就是胶囊中心（离地约 90cm）。
     * 旧代码把 pt 当脚底（p2.y = pt.y，框只往上长），所以整框和假骨骼都高出半个身子 ——
     * 这就是"骨骼画在人头顶上面"的直接原因。
     *
     * 高度也不再拍脑袋用 2200：按投影焦距算，
     *     bodyPx = 人体高(cm) × focal / 距离(cm)
     * 不同 FOV / 分辨率下都能贴合。
     */
    /*
     * ★ [M5.138] 直接用投影求「身体上下两端」，不再靠 FOV 估算。
     *
     * 位置是胶囊中心，±88cm 就是胶囊顶/底。把这两点各投影一次，
     * 得到的两条 Y 就是身体在屏幕上的真实高度 —— 与 FOV、分辨率、距离全部自洽。
     * 上一版按 180cm×焦距/距离 估，实测框比人高了将近一倍（真机截图确认）。
     */
    MFScreen psc = [MFProjection screenWithSize:CGSizeMake(screen.x, screen.y) fov:cam.fov];
    float topXYZ[3] = { e.worldX, e.worldY, e.worldZ + 88.0f };
    float botXYZ[3] = { e.worldX, e.worldY, e.worldZ - 88.0f };
    MFPoint2D tp = [MFProjection projectTarget:topXYZ camera:cam screen:psc];
    MFPoint2D bp = [MFProjection projectTarget:botXYZ camera:cam screen:psc];

    float topY = 0.0f, botY = 0.0f;
    if (tp.valid && bp.valid && bp.y > tp.y) {
        topY = tp.y;
        botY = bp.y;
    } else {
        /* 退化情况（深度太近 / FOV 异常）：退回按焦距估算，并且居中 */
        float focal = (psc.focal > 0.0f) ? psc.focal : (screen.x * 0.5f);
        float est = 180.0f * focal / MAX(e.distanceMeters * 100.0f, 1.0f);
        est = MIN(MAX(est, 8.0f), screen.y * 0.8f);
        topY = pt.y - est * 0.5f;
        botY = pt.y + est * 0.5f;
    }
    float bodyPx = MAX(botY - topY, 8.0f);
    float w = bodyPx * 0.45f;
    ImVec2 p1(pt.x - w * 0.5f, topY);
    ImVec2 p2(pt.x + w * 0.5f, botY);

    /* ── 主色：人机用「队伍色」提示、真人用「人物信息色」──
     * 队伍颜色槽 [M5.2] 接线：编队模式下用队员色，未校准时 teamId=0 → 走人物信息色。
     */
    BOOL useTeamColor = st.showTeam && e.teamId != 0;
    ImU32 boxCol = useTeamColor
        ? MFU32([st colorForSlot:MFColorSlotTeam], 0.9f)
        : MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.85f);

    // 框
    dl->AddRect(p1, p2, boxCol, 0.0f, 0, 1.5f);

    /* ── 血条（[M5.2] 接线：三种样式 + 真实血量）──
     * health < 0 = 未校准 → 按满格画（保持原占位行为，不显示假数据）
     */
    if (st.showHealth) {
        float ratio = (e.health >= kMFHealthMin && e.health <= kMFHealthMax)
                    ? (e.health / 100.0f) : 1.0f;
        ImU32 hpCol = MFU32(ratio > 0.5f ? [UIColor systemGreenColor]
                                         : [UIColor systemRedColor], 0.92f);

        switch (st.healthBarStyle) {
            case 0: {   /* 细线：贴在框底的一根 2px 线 */
                ImVec2 b1(p1.x, p2.y + 1.0f), b2(p2.x, p2.y + 3.0f);
                dl->AddRectFilled(b1, b2, IM_COL32(0, 0, 0, 150));
                dl->AddRectFilled(b1, ImVec2(b1.x + (b2.x - b1.x) * ratio, b2.y), hpCol);
                break;
            }
            case 1: {   /* 圆头：左侧竖条 + 圆角 */
                float bw = MAX(3.0f, w * 0.13f);
                ImVec2 b1(p1.x - bw - 3.0f, p1.y), b2(p1.x - 3.0f, p2.y);
                dl->AddRectFilled(b1, b2, IM_COL32(0, 0, 0, 150), bw * 0.5f);
                ImVec2 f2(b2.x, b1.y + (b2.y - b1.y) * ratio);
                dl->AddRectFilled(ImVec2(b1.x, f2.y), f2, hpCol, bw * 0.5f);
                break;
            }
            default: {  /* 分段：6 格，一格一格的 */
                const int segs = 6;
                float bw = MAX(3.0f, w * 0.13f);
                float gap = 1.5f;
                float totalH = p2.y - p1.y;
                float segH = (totalH - gap * (segs - 1)) / segs;
                float x1 = p1.x - bw - 3.0f, x2 = p1.x - 3.0f;
                dl->AddRectFilled(ImVec2(x1, p1.y), ImVec2(x2, p2.y),
                                  IM_COL32(0, 0, 0, 150), 1.0f);
                for (int i = 0; i < segs; i++) {
                    // 从下往上填：血量越低，顶部格越少
                    float segTop = p2.y - (i + 1) * segH - i * gap;
                    float fillTop = segTop + segH * (1.0f - MIN(1.0f, MAX(0.0f, ratio * segs - i)));
                    if (ratio * segs <= i) continue;
                    dl->AddRectFilled(ImVec2(x1 + 1, fillTop), ImVec2(x2 - 1, segTop + segH),
                                      hpCol, 1.0f);
                }
                break;
            }
        }
    }

    /* ── 距离（[M5.2] 用 fontInfo 字号）── */
    if (st.showDistance) {
        char buf[32];
        snprintf(buf, sizeof(buf), "[%.0fm]", e.distanceMeters);
        ImVec2 ts = MFTextSize(buf, st.fontInfo);
        MFText(dl, st.fontInfo, ImVec2(pt.x - ts.x * 0.5f, p2.y + 2.0f), boxCol, buf);
    }

    /* ══════════ [M5.148] 文字块：按小玉的排版自下而上堆 ══════════
     *      手持
     *      头X 甲Y 包Z
     *      队N : 人物ID
     *      名字   血条
     *   框顶 = 骨骼头，框底 = 骨骼脚，距离在框下面
     */
    {
        const char *name = e.name.length ? e.name.UTF8String
                          : (e.isBot ? "人机" : "敌人");

        char lHeld[32], lArmor[48], lTeam[48], lName[96];
        {
            const char *wn = e.weaponRawID ? MFItemNameForID(e.weaponRawID) : NULL;
            if (wn)              snprintf(lHeld, sizeof(lHeld), "持 %s", wn);
            else if (e.weaponId) snprintf(lHeld, sizeof(lHeld), "持 W%d", e.weaponId);
            else                 snprintf(lHeld, sizeof(lHeld), "持 空手");
        }

        ImU32 armorCol = MFU32([st colorForSlot:MFColorSlotArmor]);
        if (e.equipKnown) {
            int h = e.helmetLevel, a = e.armorLevel, b = e.backpackLevel;
            snprintf(lArmor, sizeof(lArmor), "头%d 甲%d 包%d", h, a, b);
            switch (MAX(h, MAX(a, b))) {
                case 2: armorCol = IM_COL32(0, 255, 0, 235); break;
                case 3: armorCol = IM_COL32(135, 206, 250, 235); break;
                case 4: armorCol = IM_COL32(122, 103, 238, 235); break;
                case 5: armorCol = IM_COL32(255, 219, 0, 235); break;
                case 6: armorCol = IM_COL32(255, 0, 0, 235); break;
                default: break;
            }
        } else {
            snprintf(lArmor, sizeof(lArmor), "头- 甲- 包-");
        }

        if (e.uin) snprintf(lTeam, sizeof(lTeam), "队%d : %llu", e.teamId,
                            (unsigned long long)e.uin);
        else       snprintf(lTeam, sizeof(lTeam), "队%d", e.teamId);

        if (e.health >= kMFHealthMin && e.health <= kMFHealthMax)
            snprintf(lName, sizeof(lName), "%s  %d", name, e.health);
        else
            snprintf(lName, sizeof(lName), "%s", name);

        const float lh = MAX(13.0f, st.fontInfo + 2.0f);
        const float topY0 = p1.y - 4.0f - lh * (st.showHeld ? 3.0f : 3.0f);
        float y = topY0;

        if (st.showHeld) {
            ImVec2 ts = MFTextSize(lHeld, st.fontInfo);
            MFText(dl, st.fontInfo, ImVec2(pt.x - ts.x * 0.5f, y),
                   MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.9f), lHeld);
        }
        if (st.showArmor) {
            ImVec2 ts = MFTextSize(lArmor, st.fontInfo);
            MFText(dl, st.fontInfo, ImVec2(pt.x - ts.x * 0.5f, y + lh), armorCol, lArmor);
        }
        if (st.showTeam) {
            ImVec2 ts = MFTextSize(lTeam, st.fontInfo);
            MFText(dl, st.fontInfo, ImVec2(pt.x - ts.x * 0.5f, y + lh * 2.0f),
                   MFU32([st colorForSlot:MFColorSlotTeam]), lTeam);
        }
        if (st.showName) {
            ImVec2 ts = MFTextSize(lName, st.fontPerson);
            MFText(dl, st.fontPerson, ImVec2(pt.x - ts.x * 0.5f, y + lh * 3.0f),
                   boxCol, lName);
        }
    }

    /* ── [M5.152] 射线：从【屏幕顶部中心】连到目标（之前画在底边，方向是反的）── */
    if (st.showTracer) {
        dl->AddLine(ImVec2(screen.x * 0.5f, 0.0f), pt,
                    MFU32([st colorForSlot:MFColorSlotPersonInfo], 0.55f), 1.0f);
    }

    /* ── 骨骼（[M5.2] 接线：受 skeletonDistance 限制）── */
    if (st.showSkeleton && e.distanceMeters <= st.skeletonDistance) {
        /* [M5.141] 优先画真骨骼；读不到再退回占位火柴人 */
        if (![self drawRealBonesForEntity:e drawList:dl settings:st
                                   camera:cam screen:screen]) {
            [self drawSkeleton:e drawList:dl settings:st camera:cam
                            at:ImVec2(pt.x, (topY + botY) * 0.5f) height:bodyPx];
        }
    }
}

/// 简化骨架。
/// ⚠️ 分析明确标注「骨骼连线拓扑 + 骨骼矩阵来源」是【未证】项，
///    这里用「头-肩-胯」三点近似，真机拿到真实骨骼数组后替换本函数即可。
- (void)drawSkeleton:(MFEntity *)e drawList:(ImDrawList *)dl
            settings:(MFSettings *)st camera:(MFCamera)cam at:(ImVec2)pt
              height:(float)bodyPx {
    /*
     * [M5.137] 以胶囊中心为基准，上下各摊半身。
     * 旧版把 pt 当脚底、整体往上画 —— 画面上的表现就是"骨架飘在人头顶"。
     */
    const float half = MAX(bodyPx, 8.0f) * 0.5f;
    ImU32 col = MFU32([st colorForSlot:MFColorSlotSkeleton], 0.9f);
    float th = MAX(1.0f, st.skeletonThickness);

    ImVec2 head(pt.x, pt.y - half * 0.92f);
    ImVec2 neck(pt.x, pt.y - half * 0.74f);
    ImVec2 hip (pt.x, pt.y + half * 0.10f);
    ImVec2 lShoulder(pt.x - half * 0.22f, pt.y - half * 0.62f);
    ImVec2 rShoulder(pt.x + half * 0.22f, pt.y - half * 0.62f);
    ImVec2 lFoot(pt.x - half * 0.14f, pt.y + half * 0.95f);
    ImVec2 rFoot(pt.x + half * 0.14f, pt.y + half * 0.95f);

    dl->AddLine(head, neck, col, th);
    dl->AddLine(lShoulder, rShoulder, col, th);
    dl->AddLine(neck, hip, col, th);
    dl->AddLine(hip, lFoot, col, th);
    dl->AddLine(hip, rFoot, col, th);
    dl->AddLine(lShoulder, lFoot, col, th * 0.6f);
    dl->AddLine(rShoulder, rFoot, col, th * 0.6f);
}

#pragma mark - 真骨骼（[M5.141]）

/*
 * 骨骼读取成本：每个角色 2 次头部读 + 15 次变换读。60Hz 下会把 kread 打爆，
 * 所以按 actor 缓存 250ms；读失败（骨数没有对应索引表 / 几何校验不过）
 * 就回退到占位骨架，绝不画乱线。
 */
typedef struct {
    uint64_t actor;
    double   stamp;
    BOOL     ok;
    float    pts[kMFBoneCount][3];
} MFBoneCacheEntry;
static MFBoneCacheEntry gMFBoneCache[64];

static MFBoneCacheEntry *MFBoneCacheFor(uint64_t actor) {
    MFBoneCacheEntry *reuse = &gMFBoneCache[0];
    for (int i = 0; i < 64; i++) {
        if (actor != 0 && gMFBoneCache[i].actor == actor) return &gMFBoneCache[i];
        if (gMFBoneCache[i].stamp < reuse->stamp) reuse = &gMFBoneCache[i];
    }
    reuse->actor = actor;
    reuse->stamp = 0;
    reuse->ok = NO;
    return reuse;
}

- (BOOL)drawRealBonesForEntity:(MFEntity *)e drawList:(ImDrawList *)dl
                      settings:(MFSettings *)st camera:(MFCamera)cam screen:(ImVec2)screen {
    if (e.address == 0) return NO;

    const double now = CACurrentMediaTime();
    MFBoneCacheEntry *c = MFBoneCacheFor(e.address);
    if (now - c->stamp > 0.25) {
        c->stamp = now;
        c->ok = MFBoneReadWorld(e.address, c->pts);
    }
    if (!c->ok) return NO;

    MFScreen sc = [MFProjection screenWithSize:CGSizeMake(screen.x, screen.y) fov:cam.fov];
    ImVec2 sp[kMFBoneCount];
    for (int i = 0; i < kMFBoneCount; i++) {
        MFPoint2D p = [MFProjection projectTarget:c->pts[i] camera:cam screen:sc];
        if (!p.valid) return NO;
        sp[i] = ImVec2(p.x, p.y);
    }

    const int *links = NULL;
    int linkCount = 0;
    MFBoneLinks(&links, &linkCount);
    ImU32 col = MFU32([st colorForSlot:MFColorSlotSkeleton], 0.9f);
    float th = MAX(1.0f, st.skeletonThickness);
    for (int i = 0; i < linkCount; i++) {
        int a = links[i * 2], b = links[i * 2 + 1];
        if (a < 0 || a >= kMFBoneCount || b < 0 || b >= kMFBoneCount) continue;
        dl->AddLine(sp[a], sp[b], col, th);
    }
    return YES;
}

#pragma mark - 雷达（[M5.139]，移植自参考项目）

/*
 * 数据全部是现成的：相机位置/偏航（MFCamera）、每个实体的世界坐标与距离。
 * 布局、投影、配色对齐 小玉源码 jni/src/radar.h 的 ComputeRadarLayout /
 * ProjectRadarOffset / RenderRadarBase，只保留玩家雷达部分。
 */
- (void)drawRadar:(NSArray<MFEntity *> *)ents
         drawList:(ImDrawList *)dl
         settings:(MFSettings *)st
           camera:(MFCamera)cam
           screen:(ImVec2)screen {
    if (!dl || screen.x <= 0 || screen.y <= 0) return;

    MFRadarConfig cfg;
    cfg.selfX = cam.x;
    cfg.selfY = cam.y;
    cfg.yawDeg = cam.yaw;
    cfg.rangeM = 120.0f;          /* 量程 120m，够覆盖当前交战距离 */
    cfg.xRatio = 0.125f;          /* 参考实现的默认布局 */
    cfg.yRatio = 0.370f;
    cfg.radiusRatio = 0.139f;
    cfg.northUp = NO;             /* 前方朝上 */

    enum { kMaxBlips = 192 };
    MFRadarBlip blips[kMaxBlips];
    int n = 0;

    for (MFEntity *e in ents) {
        if (n >= kMaxBlips) break;
        if (e.isLoot || e.isBox) continue;                       /* 雷达只放人 */
        if (e.worldX == 0.0f && e.worldY == 0.0f) continue;      /* 未读到坐标 */
        if (!isfinite(e.worldX) || !isfinite(e.worldY)) continue;

        blips[n].x = e.worldX;
        blips[n].y = e.worldY;
        blips[n].distM = e.distanceMeters;
        blips[n].isBot = e.isBot;
        blips[n].color = e.isBot ? IM_COL32(255, 190, 90, 235)
                                 : IM_COL32(238, 80, 70, 235);
        n++;
    }

    MFRadarRender(dl, screen, &cfg, blips, n);
}

#pragma mark - 背敌提示（[M5.2] 新增，原版有我们之前没实现）

/*
 * 画法：在屏幕中心画一个半径 = backEnemyRadius(px) 的环，
 *       背后有敌人时，在对应方位角上打一个标记。
 *
 * 为什么用「屏幕中心 + 方位角」而不是直接画在敌人位置：
 *   背后的敌人在屏幕上是【投影不出来的】（在相机后面），
 *   所以必须用方位角映射到屏幕边缘的位置来表示方向 —— 这正是原版「背敌提示」的用途。
 *
 * 方位角来自 MFGameReader 的 bearingDeg，只由坐标 + 相机 yaw 算得，
 * 【不依赖任何游戏字段】—— 所以校准之前就能工作。
 */
- (void)drawBackEnemies:(NSArray<MFEntity *> *)ents
               drawList:(ImDrawList *)dl
               settings:(MFSettings *)st
                 screen:(ImVec2)screen {
    if (!st.backEnemyEnabled) return;

    ImU32 col = MFU32([st colorForSlot:MFColorSlotBackEnemy], 0.95f);
    ImVec2 c(screen.x * 0.5f, screen.y * 0.5f);
    float R = MAX(40.0f, st.backEnemyRadius);     // 单位 px（对齐原版）

    int n = 0;
    for (MFEntity *e in ents) {
        if (!e.isBehind) continue;
        if (e.isBot && !st.showBot) continue;
        n++;

        /* bearingDeg: 0=前 负=左 正=右 ±180=后
         * 映射到屏幕角度：-90°(左) → 左半屏；+90°(右) → 右半屏；180 → 正下
         * 用「从上方开始顺时针」的屏坐标约定：
         *   screenAngle = bearing - 90   （bearing=-90 → -180 左；+90 → 0 右；180 → 90 下）
         */
        float rad = (e.bearingDeg - 90.0f) * kMF_Deg2Rad;
        ImVec2 p(c.x + cosf(rad) * R, c.y + sinf(rad) * R);

        switch (st.backEnemyStyle) {
            case MFBackEnemyStyleCircle:      /* 圆形：实心点 + 距离 */
                dl->AddCircleFilled(p, 5.0f, col, 12);
                break;
            case MFBackEnemyStyleArrow: {     /* 箭头：从环上指向外侧 */
                ImVec2 dir(cosf(rad), sinf(rad));
                ImVec2 tip(p.x + dir.x * 11.0f, p.y + dir.y * 11.0f);
                ImVec2 l(p.x - dir.y * 6.0f, p.y + dir.x * 6.0f);
                ImVec2 r(p.x + dir.y * 6.0f, p.y - dir.x * 6.0f);
                dl->AddTriangleFilled(tip, l, r, col);
                break;
            }
            default:                          /* 圆环：空心圈 */
                dl->AddCircle(p, 7.0f, col, 16, 2.0f);
                break;
        }

        // 距离数字（背敌也要知道多远）
        char buf[24];
        snprintf(buf, sizeof(buf), "%.0fm", e.distanceMeters);
        ImVec2 ts = MFTextSize(buf, st.fontInfo * 0.85f);
        MFText(dl, st.fontInfo * 0.85f,
               ImVec2(p.x - ts.x * 0.5f, p.y + 9.0f), col, buf);
    }

    /* 有背敌时把环也画出来（没背敌就不画，免得挡视野）*/
    if (n > 0 && st.backEnemyStyle != MFBackEnemyStyleCircle) {
        dl->AddCircle(c, R, MFU32([st colorForSlot:MFColorSlotBackEnemy], 0.30f), 48, 1.0f);
    }
    _backEnemyCount = n;
}

#pragma mark - 物资

- (void)drawLoot:(MFEntity *)e drawList:(ImDrawList *)dl
        settings:(MFSettings *)st screen:(ImVec2)screen {
    // Keep the item and container switches independent. The detail switch only
    // changes the loot marker's presentation after its parent feature is on.
    if (e.isBox) {
        if (!st.showBox || e.distanceMeters > st.boxDrawDistance) return;
    } else if (!st.showLoot || e.distanceMeters > st.lootDrawDistance) {
        return;
    }

    // ① 数值过滤（对齐分析已证的业务行为）
    if (st.minLootValue != 0 && e.value > 0 && e.value < st.minLootValue) return;
    if (st.minLootLevel != 0 && e.level > 0 && e.level < st.minLootLevel) return;

    // ② 颜色（已证：等级 3/4/5/6 各自色；非 3–6 且价值【严格大于】9999 → 用 3 级色强调）
    UIColor *col;
    if (e.level >= kMFLootLevelMin && e.level <= kMFLootLevelMax) {
        static const MFColorSlot slots[4] = {
            MFColorSlotLoot3, MFColorSlotLoot4, MFColorSlotLoot5, MFColorSlotLoot6
        };
        col = [st colorForSlot:slots[e.level - kMFLootLevelMin]];
    } else if (e.value > kMFLootValueHighlight) {
        col = [st colorForSlot:MFColorSlotLoot3];      // 强调
    } else {
        col = [st colorForSlot:MFColorSlotLootLow];    // 0–2 级色
    }

    ImU32 c = MFU32(col, 0.95f);

    // ③ 标签（已证格式串：%s\n等级[%d]\n价值[%d]\n[%.1fm]）
    //    [M5.2] 接线：用「盒子字号」fontBox
    if (st.showLootName) {
        NSString *name = e.name.length ? e.name : @"物资";
        NSString *label = [NSString stringWithFormat:@"%@\n等级[%d]\n价值[%d]\n[%.1fm]",
                           name, e.level, e.value, e.distanceMeters];
        const char *txt = label.UTF8String;
        ImVec2 ts = MFTextSize(txt, st.fontBox);
        MFText(dl, st.fontBox,
               ImVec2(e.screen.x - ts.x * 0.5f, e.screen.y - ts.y), c, txt);
    } else if (!e.isBox) {
        dl->AddCircle(ImVec2(e.screen.x, e.screen.y), 4.0f, c, 12, 1.5f);
    }

    // ④ 盒子（独立的绘制距离）
    if (e.isBox) {
        float s = MIN(60.0f, 800.0f / MAX(e.distanceMeters, 1.0f));
        dl->AddRect(ImVec2(e.screen.x - s, e.screen.y - s),
                    ImVec2(e.screen.x + s, e.screen.y + s),
                    c, 3.0f, 0, 1.5f);
    }
}

#pragma mark - 统计窗

- (void)drawStats:(MFSettings *)st loot:(NSArray<MFEntity *> *)loot {
    // 已证：程序里有独立的「物资统计窗口」，等级/价值分组展示
    static BOOL open = YES;
    ImGui::SetNextWindowSize(ImVec2(220, 160), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(24, 120), ImGuiCond_FirstUseEver);
    if (ImGui::Begin("物资统计", &open,
                     ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings |
                     ImGuiWindowFlags_AlwaysAutoResize)) {
        NSUInteger byLevel[7] = {0};
        long long totalValue = 0;
        for (MFEntity *e in loot) {
            int lv = (e.level >= 0 && e.level <= 6) ? e.level : 0;
            byLevel[lv]++;
            totalValue += e.value;
        }
        ImGui::Text("共 %lu 件", (unsigned long)loot.count);
        ImGui::Separator();
        for (int lv = 6; lv >= 3; lv--) {
            if (byLevel[lv] == 0) continue;
            ImGui::TextColored(ImVec4(0.98f, 0.82f, 0.30f, 1.0f),
                               "%d 级：%lu", lv, (unsigned long)byLevel[lv]);
        }
        if (byLevel[0]) ImGui::TextDisabled("其他：%lu", (unsigned long)byLevel[0]);
        ImGui::Separator();
        ImGui::Text("总价值：%lld", totalValue);
        // ImGui 的格式化不认 %@，必须转成 UTF-8 C 串
        ImGui::TextDisabled("%s", [[MFOffsets shared] summary].UTF8String);
    }
    ImGui::End();
}

#pragma mark - 渲染自检

/// 合成数据渲染。不读任何游戏内存。
///
/// 相机约定（来自 Game/MFProjection.h）：
///   前向 F = (cosP·cosY, cosP·sinY, sinP)  → P=Y=0 时 F=(1,0,0)，即朝 +X 看
///   右向 R = (-sinY, cosY, 0)              → y>0 在屏幕右侧
///   上向 U = (-sinP·cosY, -sinP·sinY, cosP) → z>0 在屏幕上方
- (void)runSelfTest:(MFSettings *)st overlay:(MFOverlayView *)overlay {
    const CGSize size = overlay.bounds.size;
    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    if (!dl) return;

    const float t = (float)(fmod(CACurrentMediaTime(), 6.0));   // 0–6 秒循环
    const float bob = sinf(t * 1.6f) * 60.0f;                   // 目标上下浮动

    MFCamera cam = (MFCamera){0};
    cam.fov = 90.0f;

    MFScreen sc = [MFProjection screenWithSize:size fov:cam.fov];

    // 场景：4 个「人」（不同距离/横向）+ 4 个「物资」（不同等级/价值）
    struct Item { float x, y, z; int level, value; BOOL isLoot; const char *name; };
    static const struct Item kItems[] = {
        {  300,   0,  0, 0,     0, NO,  "近距目标" },
        {  600, 120, 20, 0,     0, NO,  "中距目标" },
        { 1000, -160, 0, 0,     0, NO,  "远距目标" },
        {  800,   0, -60, 0,    0, NO,  "低位目标" },
        {  450,  260, 0, 3,   500, YES, "3级物资" },
        {  450, -260, 0, 4,  4000, YES, "4级物资" },
        {  700,  200, 0, 5, 20000, YES, "5级物资" },
        {  700, -200, 0, 6, 99999, YES, "6级物资" },
    };

    for (size_t i = 0; i < sizeof(kItems) / sizeof(kItems[0]); i++) {
        const struct Item *it = &kItems[i];
        float world[3] = { it->x, it->y, it->z + bob };

        MFPoint2D p = [[MFProjection shared] projectTarget:world camera:cam screen:sc];
        if (!p.valid) continue;

        MFEntity *e = [[MFEntity alloc] init];
        e.screen = p;
        e.isVisible = YES;
        e.worldX = world[0]; e.worldY = world[1]; e.worldZ = world[2];

        float camPos[3] = { cam.x, cam.y, cam.z };
        e.distanceMeters = [MFProjection distanceMetersFrom:world to:camPos];
        e.name = [NSString stringWithUTF8String:it->name];

        if (it->isLoot) {
            e.isLoot = YES;
            e.level = it->level;
            e.value = it->value;
            [self drawLoot:e drawList:dl settings:st screen:ImVec2((float)size.width, (float)size.height)];
        } else {
            [self drawEntity:e drawList:dl settings:st
                       screen:ImVec2((float)size.width, (float)size.height) camera:cam];
        }
    }

    // 顶部提示条
    ImGui::SetNextWindowPos(ImVec2(20, 20), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.9f);
    if (ImGui::Begin("##selftest", nullptr,
                     ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                     ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoInputs)) {
        ImGui::TextColored(ImVec4(0.19f, 0.82f, 0.35f, 1.0f), "渲染自检模式");
        ImGui::Separator();
        ImGui::Text("画面尺寸  %.0f × %.0f", size.width, size.height);
        ImGui::Text("帧         %.1f s", t);
        ImGui::Text("看到的框        4 个（随距离缩放）");
        ImGui::Text("看到的物资标签  4 个（3/4/5/6 级各自色）");
        ImGui::TextDisabled("这条链通了 = ImGui/Metal/透明层/投影 全正常");
        ImGui::TextDisabled("关掉「渲染自检」才会回到读游戏内存的模式");
    }
    ImGui::End();
}

#pragma mark - 诊断

- (NSString *)dataSourceText {
    switch (_source) {
        case MFDrawSourceUE4:        return @"UE4 链（模块基址 + GWorld 静态偏移，自动建立）";
        case MFDrawSourceCalibrated: return @"已校准的白米饭链（三个绝对基址）";
        case MFDrawSourceExternal:   return @"外部数据源（Frida agent → UDP）";
        default:                     return @"未取到（见下面的断点说明）";
    }
}

- (NSString *)dumpFrameWithSize:(CGSize)size {
    MFCamera cam = {0};
    NSArray<MFEntity *> *ents = nil;
    NSArray<MFEntity *> *loot = nil;
    MFDrawSource source = MFDrawSourceNone;
    BOOL ok = [self acquireFrameWithSize:size camera:&cam entities:&ents loot:&loot source:&source];
    _source = source;

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"数据源：%@\n", [self dataSourceText]];
    [s appendFormat:@"相机：%@\n", ok ? @"✓" : @"✗"];
    if (ok) {
        [s appendFormat:@"  位置 (%.1f, %.1f, %.1f)\n  角度 (%.1f, %.1f, %.1f)  FOV %.1f\n",
         cam.x, cam.y, cam.z, cam.pitch, cam.yaw, cam.roll, cam.fov];
    }
    [s appendFormat:@"实体：%lu\n物资：%lu\n",
     (unsigned long)ents.count, (unsigned long)loot.count];
    [s appendFormat:@"\n%@\n", [[MFReadBackend shared] statsText]];
    [s appendFormat:@"UE4 缓存：Actor 指针 %lu 个 · 坐标 %lu 个 · 游标 %lu\n",
     (unsigned long)_ueActorAddrs.count, (unsigned long)_ueActors.count,
     (unsigned long)_ueCursor];
    if (_ueLastIssue) [s appendFormat:@"UE4 最近问题：%@\n", _ueLastIssue];

    [s appendString:@"\n—— MFGameReader（手工校准那条）——\n"];
    [s appendString:[[MFGameReader shared] diagnosticReport]];
    [s appendString:@"\n—— MFUEReader（可自动建立那条）——\n"];
    [s appendString:[[MFUEReader shared] diagnosticReport]];
    return s;
}

@end
