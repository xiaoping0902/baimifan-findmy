//
//  MFSettings.mm — 配置模型（实现）
//
#import "MFSettings.h"
#include <cmath>

static NSString *const kSettingsFile = @"mf_settings.plist";
static const NSInteger kMFColorDefaultsVersion = 1;

@implementation MFSettings {
    NSMutableDictionary<NSNumber *, UIColor *> *_colors;
}
@synthesize lootStatsXRatio = _lootStatsXRatio;
@synthesize lootStatsYRatio = _lootStatsYRatio;
@synthesize radarXRatio = _radarXRatio;
@synthesize radarYRatio = _radarYRatio;
@synthesize radarRadiusRatio = _radarRadiusRatio;

+ (instancetype)shared {
    static MFSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFSettings alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self resetToDefaults];
        [self load];
    }
    return self;
}

#pragma mark - 默认值

- (void)resetToDefaults {
    _masterEnabled = YES;
    _drawEnabled = YES;

    _showBot = YES;
    _showBotName = YES;
    _showBotSkeleton = YES;
    _showBotHealth = NO;
    _showBotTracer = NO;
    _showBotArmor = NO;
    _showTeammates = NO;      /* [M5.150] 队友默认不画 */
    _showName = YES;
    _showArmor = YES;
    _showSkeleton = NO;
    _showTracer = NO;
    _showTeam = YES;
    _showHeld = NO;
    _showDistance = YES;
    _showHealth = YES;
    _showRadar = NO;
    self.radarXRatio = 0.125f;
    self.radarYRatio = 400.0f / 1080.0f;
    self.radarRadiusRatio = 150.0f / 1080.0f;
    _showFPS = YES;

    _showLoot = NO;
    _showBox = NO;
    _showLootName = YES;
    _showLootStats = NO;
    self.lootStatsXRatio = 0.01f;
    self.lootStatsYRatio = 0.18f;

    _minLootLevel = 0;       // 0 = 停用等级过滤
    _minLootValue = 0;       // 0 = 停用价值过滤

    _boxDrawDistance = 200.0f;
    _lootDrawDistance = 120.0f;
    _skeletonDistance = 80.0f;

    _backEnemyEnabled = NO;
    _backEnemyRadius = 60.0f;
    _backEnemyDistance = 80.0f;
    _backEnemyStyle = MFBackEnemyStyleCircle;

    _fontPerson = 13.0f;
    _fontBox = 12.0f;
    _fontInfo = 13.0f;
    _fontArmor = 12.0f;
    _skeletonThickness = 1.5f;

    _refreshRate = 120; // Fresh installs request high refresh; saved choices are preserved.
    _healthBarStyle = 0;
    _smoothAim = NO;

    _spectatorMode = NO;
    _liveMode = NO;
    _captureProtectionEnabled = NO;
    _renderSelfTest = NO;

    // 颜色槽默认值（对齐分析的配色规则：3/4/5/6 级各自专属色）
    _colors = [NSMutableDictionary dictionary];
    [self setColorInternal:[UIColor whiteColor]                       slot:MFColorSlotPersonInfo];
    [self setColorInternal:[UIColor colorWithRed:0.75 green:0.75 blue:0.75 alpha:1] slot:MFColorSlotLootLow];
    [self setColorInternal:[UIColor colorWithRed:0.10 green:0.55 blue:1.00 alpha:1] slot:MFColorSlotLoot3];
    [self setColorInternal:[UIColor colorWithRed:0.76 green:0.28 blue:1.00 alpha:1] slot:MFColorSlotLoot4];
    [self setColorInternal:[UIColor colorWithRed:1.00 green:0.76 blue:0.05 alpha:1] slot:MFColorSlotLoot5];
    [self setColorInternal:[UIColor colorWithRed:1.00 green:0.12 blue:0.12 alpha:1] slot:MFColorSlotLoot6];
    [self setColorInternal:[UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1] slot:MFColorSlotTeam];
    [self setColorInternal:[UIColor colorWithRed:0.55 green:0.85 blue:1.00 alpha:1] slot:MFColorSlotArmor];
    [self setColorInternal:[UIColor colorWithRed:1.00 green:0.08 blue:0.08 alpha:1] slot:MFColorSlotSkeleton];
    [self setColorInternal:[UIColor colorWithRed:1.00 green:0.27 blue:0.23 alpha:1] slot:MFColorSlotBackEnemy];
    [self setColorInternal:UIColor.whiteColor slot:MFColorSlotBotSkeleton];
}

// Clamp at the model boundary so direct edits and persisted values obey the
// same screen-anchor contract. Invalid values return to their own default.
- (void)setLootStatsXRatio:(float)value {
    _lootStatsXRatio = std::isfinite(value) ? fmaxf(0, fminf(1, value)) : 0.01f;
}
- (void)setLootStatsYRatio:(float)value {
    _lootStatsYRatio = std::isfinite(value) ? fmaxf(0, fminf(1, value)) : 0.18f;
}
- (void)setRadarXRatio:(float)value {
    _radarXRatio = std::isfinite(value) ? fmaxf(0, fminf(1, value)) : 0.125f;
}
- (void)setRadarYRatio:(float)value {
    _radarYRatio = std::isfinite(value) ? fmaxf(0, fminf(1, value)) : 400.0f / 1080.0f;
}
- (void)setRadarRadiusRatio:(float)value {
    _radarRadiusRatio = std::isfinite(value) ? fmaxf(0.08f, fminf(0.25f, value)) : 150.0f / 1080.0f;
}

- (void)setColorInternal:(UIColor *)c slot:(MFColorSlot)s {
    _colors[@(s)] = c;
}

#pragma mark - 颜色

- (UIColor *)colorForSlot:(MFColorSlot)slot {
    return _colors[@(slot)] ?: [UIColor whiteColor];
}

- (void)setColor:(UIColor *)color forSlot:(MFColorSlot)slot {
    if (color) _colors[@(slot)] = color;
}

#pragma mark - 持久化

- (NSString *)filePath {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docs stringByAppendingPathComponent:kSettingsFile];
}

- (BOOL)save {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSArray *bools = @[
        @[@"masterEnabled", @(_masterEnabled)], @[@"drawEnabled", @(_drawEnabled)],
        @[@"showBot", @(_showBot)], @[@"showTeammates", @(_showTeammates)], @[@"showName", @(_showName)],
        @[@"showBotName", @(_showBotName)], @[@"showBotSkeleton", @(_showBotSkeleton)],
        @[@"showBotHealth", @(_showBotHealth)], @[@"showBotTracer", @(_showBotTracer)],
        @[@"showBotArmor", @(_showBotArmor)],
        @[@"showArmor", @(_showArmor)], @[@"showSkeleton", @(_showSkeleton)],
        @[@"showTracer", @(_showTracer)], @[@"showTeam", @(_showTeam)],
        @[@"showHeld", @(_showHeld)], @[@"showDistance", @(_showDistance)],
        @[@"showHealth", @(_showHealth)], @[@"showRadar", @(_showRadar)],
        @[@"showFPS", @(_showFPS)],
        @[@"showLoot", @(_showLoot)], @[@"showBox", @(_showBox)],
        @[@"showLootName", @(_showLootName)], @[@"showLootStats", @(_showLootStats)],
        @[@"backEnemyEnabled", @(_backEnemyEnabled)],
        @[@"spectatorMode", @(_spectatorMode)], @[@"liveMode", @(_liveMode)],
        @[@"captureProtectionEnabled", @(_captureProtectionEnabled)],
        @[@"smoothAim", @(_smoothAim)],
        @[@"renderSelfTest", @(_renderSelfTest)],
    ];
    for (NSArray *kv in bools) d[kv[0]] = kv[1];

    NSArray *nums = @[
        @[@"minLootLevel", @(_minLootLevel)], @[@"minLootValue", @(_minLootValue)],
        @[@"boxDrawDistance", @(_boxDrawDistance)],
        @[@"lootDrawDistance", @(_lootDrawDistance)],
        @[@"lootStatsXRatio", @(_lootStatsXRatio)],
        @[@"lootStatsYRatio", @(_lootStatsYRatio)],
        @[@"radarXRatio", @(_radarXRatio)], @[@"radarYRatio", @(_radarYRatio)],
        @[@"radarRadiusRatio", @(_radarRadiusRatio)],
        @[@"skeletonDistance", @(_skeletonDistance)],
        @[@"backEnemyRadius", @(_backEnemyRadius)],
        @[@"backEnemyDistance", @(_backEnemyDistance)],
        @[@"backEnemyStyle", @(_backEnemyStyle)],
        @[@"fontPerson", @(_fontPerson)], @[@"fontBox", @(_fontBox)],
        @[@"fontInfo", @(_fontInfo)], @[@"fontArmor", @(_fontArmor)],
        @[@"skeletonThickness", @(_skeletonThickness)],
        @[@"refreshRate", @(_refreshRate)],
        @[@"healthBarStyle", @(_healthBarStyle)],
    ];
    for (NSArray *kv in nums) d[kv[0]] = kv[1];

    NSMutableDictionary *cols = [NSMutableDictionary dictionary];
    for (NSNumber *k in _colors) {
        UIColor *c = _colors[k];
        CGFloat r = 0, g = 0, b = 0, a = 1;
        if ([c getRed:&r green:&g blue:&b alpha:&a]) {
            cols[k.stringValue] = @[@(r), @(g), @(b), @(a)];
        }
    }
    d[@"colors"] = cols;
    d[@"colorDefaultsVersion"] = @(kMFColorDefaultsVersion);

    return [d writeToFile:[self filePath] atomically:YES];
}

- (BOOL)load {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self filePath]];
    if (![d isKindOfClass:[NSDictionary class]] || d.count == 0) return NO;

    #define LOAD_BOOL(name) if (d[@#name]) _##name = [d[@#name] boolValue]
    // 显式转回字段自身类型：ObjC++ 下 double → enum 是硬错误，必须 cast
    #define LOAD_NUM(name)  if (d[@#name]) _##name = (__typeof__(_##name))[d[@#name] doubleValue]

    LOAD_BOOL(masterEnabled); LOAD_BOOL(drawEnabled);
    LOAD_BOOL(showBot); LOAD_BOOL(showTeammates); LOAD_BOOL(showName); LOAD_BOOL(showArmor);
    // Missing keys belong to an older shared human/bot configuration. Seed
    // the concise bot defaults on every load, retaining its saved master.
    _showBotName = YES; _showBotSkeleton = YES;
    _showBotHealth = NO; _showBotTracer = NO; _showBotArmor = NO;
    LOAD_BOOL(showBotName); LOAD_BOOL(showBotSkeleton); LOAD_BOOL(showBotHealth);
    LOAD_BOOL(showBotTracer); LOAD_BOOL(showBotArmor);
    _showTeammates = NO; // Teammates are excluded even in older saved configurations.
    LOAD_BOOL(showSkeleton); LOAD_BOOL(showTracer); LOAD_BOOL(showTeam);
    LOAD_BOOL(showHeld); LOAD_BOOL(showDistance); LOAD_BOOL(showHealth);
    LOAD_BOOL(showRadar);
    LOAD_BOOL(showFPS);
    LOAD_BOOL(showLoot); LOAD_BOOL(showBox); LOAD_BOOL(showLootName); LOAD_BOOL(showLootStats);
    LOAD_BOOL(backEnemyEnabled); LOAD_BOOL(spectatorMode); LOAD_BOOL(liveMode); LOAD_BOOL(smoothAim);
    LOAD_BOOL(renderSelfTest);
    LOAD_BOOL(captureProtectionEnabled);

    LOAD_NUM(minLootLevel); LOAD_NUM(minLootValue);
    LOAD_NUM(boxDrawDistance); LOAD_NUM(lootDrawDistance); LOAD_NUM(skeletonDistance);
    if (d[@"lootStatsXRatio"]) self.lootStatsXRatio = [d[@"lootStatsXRatio"] floatValue];
    if (d[@"lootStatsYRatio"]) self.lootStatsYRatio = [d[@"lootStatsYRatio"] floatValue];
    if (d[@"radarXRatio"]) self.radarXRatio = [d[@"radarXRatio"] floatValue];
    if (d[@"radarYRatio"]) self.radarYRatio = [d[@"radarYRatio"] floatValue];
    if (d[@"radarRadiusRatio"]) self.radarRadiusRatio = [d[@"radarRadiusRatio"] floatValue];
    LOAD_NUM(backEnemyRadius); LOAD_NUM(backEnemyStyle);
    LOAD_NUM(backEnemyDistance);
    LOAD_NUM(fontPerson); LOAD_NUM(fontBox); LOAD_NUM(fontInfo); LOAD_NUM(fontArmor);
    LOAD_NUM(skeletonThickness); LOAD_NUM(refreshRate); LOAD_NUM(healthBarStyle);

    #undef LOAD_BOOL
    #undef LOAD_NUM

    NSDictionary *cols = d[@"colors"];
    const BOOL migrateColorDefaults = [d[@"colorDefaultsVersion"] integerValue] < kMFColorDefaultsVersion;
    if ([cols isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in cols) {
            NSArray *rgba = cols[key];
            if (rgba.count == 4) {
                // Replace the shipped pale-red default, retaining custom hues.
                if (migrateColorDefaults && key.integerValue == MFColorSlotSkeleton &&
                    fabs([rgba[0] doubleValue]-1.0)<0.0001 &&
                    fabs([rgba[1] doubleValue]-.45)<0.0001 &&
                    fabs([rgba[2] doubleValue]-.45)<0.0001 &&
                    fabs([rgba[3] doubleValue]-1.0)<0.0001) continue;
                // Only migrate the previous shipped bot default; a custom
                // human or bot choice must survive the upgrade unchanged.
                if (migrateColorDefaults && key.integerValue == MFColorSlotBotSkeleton &&
                    fabs([rgba[0] doubleValue]-.10)<0.0001 &&
                    fabs([rgba[1] doubleValue]-1.0)<0.0001 &&
                    fabs([rgba[2] doubleValue]-.20)<0.0001 &&
                    fabs([rgba[3] doubleValue]-1.0)<0.0001) continue;
                _colors[@(key.integerValue)] =
                    [UIColor colorWithRed:[rgba[0] doubleValue]
                                    green:[rgba[1] doubleValue]
                                     blue:[rgba[2] doubleValue]
                                    alpha:[rgba[3] doubleValue]];
            }
        }
    }
    return YES;
}

- (NSString *)summary {
    return [NSString stringWithFormat:
            @"绘制:%@ 人机:%d 名字:%d 头甲:%d 骨骼:%d 射线:%d 队伍:%d 距离:%d 血量:%d",
            _drawEnabled ? @"开" : @"关",
            _showBot, _showName, _showArmor, _showSkeleton,
            _showTracer, _showTeam, _showDistance, _showHealth];
}

@end
