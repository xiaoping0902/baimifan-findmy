//
//  MFGearCatalog.mm — 物资 / 装备分类目录的实现
//
//  设计原则（三条，缺一不可）：
//    ① 精确表优先。游戏 SDK 里有的类名就逐条列出来，不靠关键词猜。
//    ② 有明确的"这不是 Actor"表。同名前缀的组件/UI/管理器必须显式归零，
//       否则 ULevel::Actors 里会冒出一堆假目标。
//    ③ 兜底启发式放在最后，且只在"看起来像拾取物"时生效。它可能误判，
//       但它的输出只会影响"要不要画"，不会伪造名字/等级/价值。
//
//  ★ 不读内存。本文件所有结论只来自类名字符串。★
//
#import "MFGearCatalog.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 归一化

/// 把 GNames 解出来的类名压成"裸类名"，便于查表。
///
/// 需要处理的三种形态：
///     "DFMGameplay.InventoryPickup_DeadBody"   ← 带模块前缀（SDK / GObjects dump 的写法）
///     "InventoryPickup_DeadBody"               ← 运行时 UClass 的常见写法（无前缀）
///     "BP_Pickup_Helmet_C"                     ← 蓝图生成类（UE4 惯例：BP_ 前缀 + _C 后缀）
static NSString *MFGearNormalizedClassName(NSString *raw) {
    if (raw.length == 0) return @"";
    NSString *s = raw;

    // 模块前缀：取最后一个 '.' 之后的部分
    NSRange dot = [s rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location + 1 < s.length) {
        s = [s substringFromIndex:dot.location + 1];
    }

    // 蓝图生成类的 _C 后缀（UClass 名字尾部的 _C 是蓝图标记，不是类语义的一部分）
    if (s.length > 2 && [s hasSuffix:@"_C"]) {
        s = [s substringToIndex:s.length - 2];
    }
    return s;
}

#pragma mark - 精确表

/// 类名 → Actor 用途。key 都是**归一化后**的裸类名。
static NSDictionary<NSString *, NSNumber *> *MFGearKindTable(void) {
    static NSDictionary<NSString *, NSNumber *> *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];

        // ── 容器：需要"打开"才出物品 ────────────────────────────────
        // 这些类在场景里是一个可交互的盒子/尸体，画的时候用框 + 类别标签。
        NSArray<NSString *> *containers = @[
            @"InventoryPickup",
            @"InventoryPickup_Container",
            @"InventoryPickup_DeadBody",
            @"InventoryPickup_DeadBodyQuest",
            @"InventoryPickup_DeadBodyWithSpecialEffect",
            @"InventoryPickup_JailBreakDeadBody",
            @"InventoryPickup_OpenBox",
            @"InventoryPickup_OpenBoxServer",          // 服务端版本，正常客户端不可见，列表里留着无害
            @"InventoryPickup_WeaponModule",
            @"InventoryPickup_EggGoldenNest",
            @"InventroyPickup_CollectionRoomPutBack",  // ★ 原文拼写就是 Inventroy（少一个 n）
            @"PlunderPickup",
            @"BlueprintPlunder",
            @"InventoryPickup_BombDefusalDeadBody",
            @"InventoryPickup_BombDefusalWeaponModule",
            @"PropHuntInventoryPickup_DeadBody",
            @"InventoryPickup_TradeContainer",
            @"CollectionRoomPickupPlaceActor",
            @"DFMCharBuffEntityPickUpAmmoBox",
        ];
        for (NSString *c in containers) m[c] = @(MFGearActorKindContainer);

        // ── 地面物资：走过去直接捡 ──────────────────────────────────
        NSArray<NSString *> *loot = @[
            @"PickupBase",                   // 基类；很多物资就是它的实例，类名就叫这个
            @"DFMCharacterBuffEntityAmmoPickup",
        ];
        for (NSString *c in loot) m[c] = @(MFGearActorKindLoot);

        t = [m copy];
    });
    return t;
}

/// 类名 → 装备类别（只收录**光凭类名**就能定死的）。
///
/// 这张表很短，是刻意的：绝大多数物品的类别在物品定义里，
/// 由类名硬猜"这是枪还是药"会得到一堆看似合理的错答案。
static NSDictionary<NSString *, NSNumber *> *MFGearCategoryTable(void) {
    static NSDictionary<NSString *, NSNumber *> *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{
            @"InventoryPickup_WeaponModule"          : @(MFGearCategoryWeapon),
            @"InventoryPickup_BombDefusalWeaponModule": @(MFGearCategoryWeapon),
            @"DFMCharacterBuffEntityAmmoPickup"      : @(MFGearCategoryAmmo),
            @"DFMCharBuffEntityPickUpAmmoBox"        : @(MFGearCategoryAmmo),
            @"InventoryPickup_EggGoldenNest"         : @(MFGearCategoryValuable),
            @"InventoryPickup_DeadBodyQuest"         : @(MFGearCategoryQuest),
            @"InventoryPickup_Container"             : @(MFGearCategoryContainer),
            @"InventoryPickup"                       : @(MFGearCategoryContainer),
            @"PlunderPickup"                         : @(MFGearCategoryContainer),
            @"BlueprintPlunder"                      : @(MFGearCategoryContainer),
        };
    });
    return t;
}

/// 已知"名字含 Pickup 但绝不是关卡 Actor"的短类名 —— 精确忽略表。
///
/// ★ 为什么单靠后缀规则不够 ★
///   GNames 解出来的是 UClass 的**短名**，模块前缀已经在归一化时丢了。
///   所以下面这些类无法靠"它在 DFMGameHud 模块"来排除，只能逐条点名：
///       NearbyPickupItem       ← 后缀是 Item，规则看不出来（看着像物资！）
///       DFMAITask_Pickup       ← 后缀是 Pickup，规则更看不出来（看着就是物资！）
///       DFMAIDecorator_NearbyPickupCheck  ← 后缀是 Check
///   这三条如果漏了，屏幕上会稳定多出整批有坐标、有距离的假目标。
static NSSet<NSString *> *MFGearExplicitIgnore(void) {
    static NSSet<NSString *> *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            // UI / HUD
            @"NearbyPickupItem", @"NearbyPickupHUD",
            @"InteractorBombDefusalPickupHudView",
            @"InteractorBombDefusalPickupItemHudView",
            @"BombDefusalPickupBaseHudView", @"BombDefusalPickupHudView",
            @"BombDefusalPickupItemBaseHudView", @"BombDefusalPickupItemHudView",
            @"BombDefusalPickupItemPCHudView", @"BombDefusalPickupPCHudView",
            // AI / 逻辑
            @"DFMAITask_Pickup", @"DFMAITask_RequestSearchPickupArea",
            @"DFMAITask_SpawnDropPoolPickup", @"DFMAIDecorator_NearbyPickupCheck",
            @"InteractorSinglePickupExecutor",
            @"BombDefusalInteractorSinglePickupExecutor",
            @"BombDefusalPickupBombInteractorExecutor",
            @"InteractorOptSingleItemContainerSpawnPickupExecuteComponent",
            @"PickupNtyInterface", @"PickupLibrary", @"PickupManager",
            @"PickupFactoryComponent", @"PickupProjectileMovementComponent",
            @"PickupStaticMeshComponent", @"PickupOpenBoxAnimInstance",
            @"BreakableSpawnPickupComponent", @"NearbyPickupReportComponent",
            @"BombDefusalPickupManager", @"CollectionRoomPickupActorManager",
            @"QA_TrackInventoryPickupMarker",
        ]];
    });
    return s;
}

/// 模块前缀是否属于"界面层"。
///
/// 双保险：类名**带**模块前缀时（SDK / dump 写法），一眼就知道它是 UI 模块的类。
/// 例如 DFMGameHud.NearbyPickupItem → 前缀 DFMGameHud 含 Hud → 不是 Actor。
/// 运行时若短名不带前缀，则靠上面的精确忽略表兜住。
static BOOL MFGearModuleIsUILayer(NSString *raw) {
    NSRange dot = [raw rangeOfString:@"."];
    if (dot.location == NSNotFound || dot.location == 0) return NO;
    NSString *mod = [raw substringToIndex:dot.location];
    return [mod hasSuffix:@"Hud"] || [mod hasSuffix:@"HUD"] ||
           [mod hasSuffix:@"UI"]  || [mod hasSuffix:@"UMG"] ||
           [mod hasSuffix:@"Widget"] || [mod hasSuffix:@"Widgets"];
}

/// 明确"不是 Actor"的类名特征。
///
/// ★ 这张表是防误画的关键 ★
/// 下面这些名字都含 "Pickup"，在 GNames 里解得出，但它们不是关卡里的 Actor：
/// 强行画出来就是满屏假目标，而且是那种"看着像真的"的假目标（有坐标、有距离）。
///
/// 判定用**后缀 + 包含**组合：
///   · 后缀：Component / Manager / Library / Interface / Executor / Task /
///           AnimInstance / Asset / View / HUD / Decorator / Factory
///   · 包含：HudView、_Hud
static BOOL MFGearLooksLikeNonActor(NSString *cls) {
    if (cls.length == 0) return YES;
    if ([MFGearExplicitIgnore() containsObject:cls]) return YES;

    static NSArray<NSString *> *suffixes = nil;
    static NSArray<NSString *> *contains = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffixes = @[
            @"Component", @"Manager", @"Library", @"Interface", @"Executor",
            @"Task", @"Decorator", @"AnimInstance", @"Asset", @"View",
            @"HUD", @"HudView", @"Factory", @"Subsystem", @"Settings",
            @"Config", @"Marker", @"FunctionLibrary", @"BlueprintLibrary",
        ];
        contains = @[ @"HudView", @"_Hud", @"HUD" ];
    });

    for (NSString *suf in suffixes) {
        if ([cls hasSuffix:suf]) return YES;
    }
    for (NSString *c in contains) {
        if ([cls rangeOfString:c].location != NSNotFound) return YES;
    }
    return NO;
}

#pragma mark - 实现

@implementation MFGearCatalog

+ (instancetype)shared {
    static MFGearCatalog *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[MFGearCatalog alloc] init]; });
    return s;
}

- (MFGearActorKind)actorKindForClassName:(NSString *_Nullable)className {
    if (className.length == 0) return MFGearActorKindIgnored;

    // ⓪ 带模块前缀时，先看模块本身是不是界面层（DFMGameHud.* 一律不画）
    if (MFGearModuleIsUILayer(className)) return MFGearActorKindIgnored;

    NSString *cls = MFGearNormalizedClassName(className);
    if (cls.length == 0) return MFGearActorKindIgnored;

    // ① 非 Actor 一律不画。这一步必须在查表之前 ——
    //    "PickupStaticMeshComponent" 里含 Pickup，但它是组件。
    if (MFGearLooksLikeNonActor(cls)) return MFGearActorKindIgnored;

    // ② 精确表
    NSNumber *hit = MFGearKindTable()[cls];
    if (hit) return (MFGearActorKind)hit.integerValue;

    // ③ 角色：以 Character 结尾。
    //    为什么用后缀而不是包含：CharacterMovementComponent / CharacterAnimSnapshotManager /
    //    GameplayAbility_CharacterJump 这些都**含** Character 但不是角色。
    //    （组件类在上一步已经被拦掉了，这里是第二道闸）
    if ([cls hasSuffix:@"Character"]) return MFGearActorKindCharacter;

    // ④ 前缀规则：游戏可能给拾取物加蓝图子类（BP_Pickup_XXX），
    //    裸类名不一定在精确表里，但前缀是可判的。
    if ([cls hasPrefix:@"InventoryPickup"] || [cls hasPrefix:@"InventroyPickup"]) {
        return MFGearActorKindContainer;
    }
    if ([cls hasPrefix:@"PlunderPickup"] || [cls hasPrefix:@"BlueprintPlunder"]) {
        return MFGearActorKindContainer;
    }
    if ([cls hasPrefix:@"BP_Pickup"] || [cls hasPrefix:@"Pickup_"]) {
        return MFGearActorKindLoot;
    }

    // ⑤ 兜底：类名里带 Pickup 且已经排除掉非 Actor 特征 → 按地面物资处理。
    //    ★ 这是启发式，可能误判。它只影响"要不要画"，不会伪造字段值。
    if ([cls rangeOfString:@"Pickup"].location != NSNotFound) {
        return MFGearActorKindLoot;
    }

    return MFGearActorKindIgnored;
}

- (MFGearCategory)categoryForClassName:(NSString *_Nullable)className {
    NSString *cls = MFGearNormalizedClassName(className);
    if (cls.length == 0) return MFGearCategoryUnknown;

    NSNumber *hit = MFGearCategoryTable()[cls];
    if (hit) return (MFGearCategory)hit.integerValue;

    // 前缀兜底：只处理"类名语义已经写明类型"的少数情况
    if ([cls hasSuffix:@"WeaponModule"])               return MFGearCategoryWeapon;
    if ([cls rangeOfString:@"Ammo"].location != NSNotFound) return MFGearCategoryAmmo;
    if ([cls hasSuffix:@"DeadBodyQuest"])              return MFGearCategoryQuest;
    if ([cls hasSuffix:@"DeadBody"] ||
        [cls hasSuffix:@"DeadBodyWithSpecialEffect"] ||
        [cls hasSuffix:@"JailBreakDeadBody"])          return MFGearCategoryContainer;

    return MFGearCategoryUnknown;
}

- (BOOL)isPickupLineageClassName:(NSString *_Nullable)className {
    NSString *cls = MFGearNormalizedClassName(className);
    if (cls.length == 0) return NO;
    if (MFGearLooksLikeNonActor(cls)) return NO;
    if (MFGearKindTable()[cls] != nil) return YES;
    return [cls rangeOfString:@"Pickup"].location != NSNotFound;
}

#pragma mark - 显示文本

- (NSString *)textForActorKind:(MFGearActorKind)kind {
    switch (kind) {
        case MFGearActorKindCharacter: return @"人物";
        case MFGearActorKindLoot:      return @"物资";
        case MFGearActorKindContainer: return @"容器";
        default:                       return @"未知";
    }
}

- (NSString *)textForCategory:(MFGearCategory)category {
    switch (category) {
        case MFGearCategoryWeapon:     return @"武器";
        case MFGearCategoryAttachment: return @"配件";
        case MFGearCategoryArmor:      return @"护甲";
        case MFGearCategoryAmmo:       return @"弹药";
        case MFGearCategoryMedical:    return @"医疗";
        case MFGearCategoryBackpack:   return @"背包";
        case MFGearCategoryKey:        return @"钥匙";
        case MFGearCategoryValuable:   return @"贵重";
        case MFGearCategoryQuest:      return @"任务";
        case MFGearCategoryContainer:  return @"容器";
        default:                       return @"";
    }
}

- (NSString *_Nullable)fallbackLabelForClassName:(NSString *_Nullable)className {
    NSString *cls = MFGearNormalizedClassName(className);
    if (cls.length == 0) return nil;

    // 常见容器的可读名。读不到物品定义时，至少让用户知道画的是什么。
    static NSDictionary<NSString *, NSString *> *labels = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        labels = @{
            @"PickupBase"                              : @"物资",
            @"InventoryPickup"                         : @"容器",
            @"InventoryPickup_Container"               : @"容器",
            @"InventoryPickup_DeadBody"                : @"尸体盒",
            @"InventoryPickup_DeadBodyQuest"           : @"任务尸体",
            @"InventoryPickup_DeadBodyWithSpecialEffect": @"尸体盒",
            @"InventoryPickup_JailBreakDeadBody"       : @"尸体盒",
            @"InventoryPickup_OpenBox"                 : @"已开盒子",
            @"InventoryPickup_OpenBoxServer"           : @"已开盒子",
            @"InventoryPickup_WeaponModule"            : @"武器箱",
            @"InventoryPickup_EggGoldenNest"           : @"金蛋巢",
            @"InventroyPickup_CollectionRoomPutBack"   : @"收藏室",
            @"PlunderPickup"                           : @"掠夺箱",
            @"BlueprintPlunder"                        : @"掠夺箱",
            @"InventoryPickup_BombDefusalDeadBody"     : @"尸体盒",
            @"InventoryPickup_BombDefusalWeaponModule" : @"武器箱",
            @"PropHuntInventoryPickup_DeadBody"        : @"尸体盒",
            @"InventoryPickup_TradeContainer"          : @"交易箱",
            @"CollectionRoomPickupPlaceActor"          : @"收藏品",
            @"DFMCharacterBuffEntityAmmoPickup"        : @"弹药",
            @"DFMCharBuffEntityPickUpAmmoBox"          : @"弹药箱",
        };
    });
    NSString *v = labels[cls];
    if (v) return v;

    // 未知类名：按 Actor 用途给个中性词，绝不把原始类名当物品名显示
    MFGearActorKind k = [self actorKindForClassName:cls];
    NSString *kindText = [self textForActorKind:k];
    return [kindText isEqualToString:@"未知"] ? nil : kindText;
}

#pragma mark - 自检

- (NSString *)selfCheckReport {
    NSMutableString *s = [NSMutableString string];

    // ① 表里每一条都必须能被自己识别回来（防手写错字）
    NSDictionary<NSString *, NSNumber *> *kindTable = MFGearKindTable();
    NSUInteger bad = 0;
    for (NSString *cls in kindTable) {
        MFGearActorKind want = (MFGearActorKind)kindTable[cls].integerValue;
        MFGearActorKind got  = [self actorKindForClassName:cls];
        if (got != want) {
            bad++;
            [s appendFormat:@"  ✗ %@ 期望 %@ 实得 %@\n",
                cls, [self textForActorKind:want], [self textForActorKind:got]];
        }
    }
    [s appendFormat:@"精确表 %lu 条，自我识别失败 %lu 条\n",
        (unsigned long)kindTable.count, (unsigned long)bad];

    // ② 必须被判定为"非 Actor"的样例（这些是真实的坑）
    NSArray<NSString *> *mustIgnore = @[
        @"PickupManager", @"PickupLibrary", @"PickupFactoryComponent",
        @"PickupStaticMeshComponent", @"PickupProjectileMovementComponent",
        @"NearbyPickupHUD", @"NearbyPickupItem", @"PickupNtyInterface",
        @"DFMAITask_Pickup", @"DFMAIDecorator_NearbyPickupCheck",
        @"InteractorSinglePickupExecutor", @"PickupOpenBoxAnimInstance",
        @"BombDefusalWeaponPickupOutlineConfigAsset",
        @"CharacterMovementComponent", @"CharacterAnimSnapshotManager",
    ];
    NSUInteger leaked = 0;
    for (NSString *cls in mustIgnore) {
        if ([self actorKindForClassName:cls] != MFGearActorKindIgnored) {
            leaked++;
            [s appendFormat:@"  ✗ 误判为 Actor：%@\n", cls];
        }
    }
    [s appendFormat:@"非 Actor 表 %lu 条，漏判 %lu 条\n",
        (unsigned long)mustIgnore.count, (unsigned long)leaked];

    // ③ 归一化：带模块前缀 / 蓝图后缀也要认
    struct { const char *in; MFGearActorKind want; } cases[] = {
        {"DFMGameplay.InventoryPickup_DeadBody", MFGearActorKindContainer},
        {"BP_Pickup_Helmet_C",                    MFGearActorKindLoot},
        {"DFMPlayerCharacter",                    MFGearActorKindCharacter},
        {"DFMGameplay.PickupBase",                MFGearActorKindLoot},
    };
    NSUInteger normBad = 0;
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        NSString *in = @(cases[i].in);
        MFGearActorKind got = [self actorKindForClassName:in];
        if (got != cases[i].want) {
            normBad++;
            [s appendFormat:@"  ✗ 归一化 %@ 期望 %@ 实得 %@\n",
                in, [self textForActorKind:cases[i].want], [self textForActorKind:got]];
        }
    }
    [s appendFormat:@"归一化样例 4 条，失败 %lu 条\n", (unsigned long)normBad];

    BOOL ok = (bad == 0 && leaked == 0 && normBad == 0);
    return [NSString stringWithFormat:@"[物资目录自检] %@\n%@",
            ok ? @"✓ 全通过" : @"✗ 有失败项", s];
}

@end

NS_ASSUME_NONNULL_END
