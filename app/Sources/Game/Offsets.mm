//
//  Offsets.mm — 偏移表（实现）
//
#import "Offsets.h"

static NSString *const kCalibrationFile = @"mf_offsets_calibrated.plist";

@implementation MFGameProfile
- (instancetype)init {
    if ((self = [super init])) {
        _entityCountOffset    = kMFEntityCount;
        _entityPositionOffset = kMFEntityPosition;
        _cameraPtrOffset      = kMFCameraPtrOffset;
        _lootLevelOffset      = kMFLoot_Level;
        _lootValueOffset      = kMFLoot_Value;
        _rootChain = @[ @0x98, @0x30, @0x408, @0x3A0, @(0x10C0), @0x108, @0xF8 ];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ pid=%@ ent=0x%X pos=0x%X cam=0x%X>",
            self.displayName, self.bundleID, self.processName ?: @"?",
            self.entityCountOffset, self.entityPositionOffset, self.cameraPtrOffset];
}
@end

@implementation MFOffsets

+ (instancetype)shared {
    static MFOffsets *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFOffsets alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self buildProfiles];
        _current = _profiles.firstObject;
        [self loadCalibration];
    }
    return self;
}

- (void)buildProfiles {
    NSMutableArray *arr = [NSMutableArray array];

    // 三角洲行动 —— 先做这个（防封模块已证它是目标之一）
    MFGameProfile *dfm = [[MFGameProfile alloc] init];
    dfm.bundleID    = @"com.tencent.tmgp.dfm";
    dfm.displayName = @"三角洲行动";
    dfm.processName = @"";                       // 【未证】运行时探测
    dfm.moduleName  = @"";                       // 【未证】
    [arr addObject:dfm];

    // 其余三个：架构留位，偏移待各自校准
    NSArray *others = @[
        @[ @"com.tencent.tmgp.pubgmhd", @"和平精英" ],
        @[ @"com.tencent.mf.uam",       @"暗区突围" ],
        @[ @"com.tencent.tmgp.codev",   @"codev"    ],
    ];
    for (NSArray *kv in others) {
        MFGameProfile *p = [[MFGameProfile alloc] init];
        p.bundleID    = kv[0];
        p.displayName = kv[1];
        p.processName = @"";
        p.moduleName  = @"";
        [arr addObject:p];
    }
    _profiles = arr;
}

- (MFGameProfile *)profileForBundleID:(NSString *)bundleID {
    for (MFGameProfile *p in self.profiles) {
        if ([p.bundleID isEqualToString:bundleID]) return p;
    }
    return nil;
}

#pragma mark - 校准持久化

- (NSString *)calibrationPath {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docs stringByAppendingPathComponent:kCalibrationFile];
}

- (BOOL)saveCalibration {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (MFGameProfile *p in self.profiles) {
        d[p.bundleID] = @{
            @"processName": p.processName ?: @"",
            @"moduleName":  p.moduleName ?: @"",
            @"entityCountOffset":    @(p.entityCountOffset),
            @"entityPositionOffset": @(p.entityPositionOffset),
            @"cameraPtrOffset":      @(p.cameraPtrOffset),
            @"lootLevelOffset":      @(p.lootLevelOffset),
            @"lootValueOffset":      @(p.lootValueOffset),
        };
    }
    return [d writeToFile:[self calibrationPath] atomically:YES];
}

- (BOOL)loadCalibration {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self calibrationPath]];
    if (![d isKindOfClass:[NSDictionary class]] || d.count == 0) return NO;

    for (NSString *bid in d) {
        MFGameProfile *p = [self profileForBundleID:bid];
        if (!p) continue;
        NSDictionary *e = d[bid];
        if (![e isKindOfClass:[NSDictionary class]]) continue;

        if ([e[@"processName"] length]) p.processName = e[@"processName"];
        if ([e[@"moduleName"] length])  p.moduleName  = e[@"moduleName"];
        if (e[@"entityCountOffset"])    p.entityCountOffset    = [e[@"entityCountOffset"] unsignedIntValue];
        if (e[@"entityPositionOffset"]) p.entityPositionOffset = [e[@"entityPositionOffset"] unsignedIntValue];
        if (e[@"cameraPtrOffset"])      p.cameraPtrOffset      = [e[@"cameraPtrOffset"] unsignedIntValue];
        if (e[@"lootLevelOffset"])      p.lootLevelOffset      = [e[@"lootLevelOffset"] unsignedIntValue];
        if (e[@"lootValueOffset"])      p.lootValueOffset      = [e[@"lootValueOffset"] unsignedIntValue];
    }
    NSLog(@"[MF][Offsets] 已加载真机校准");
    return YES;
}

#pragma mark - 摘要

- (NSString *)summary {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"当前档案：%@\n", self.current.displayName];
    [s appendFormat:@"  进程名：%@\n", [self.current.processName length] ? self.current.processName : @"【未证·待探测】"];
    [s appendFormat:@"  模块名：%@\n", [self.current.moduleName length] ? self.current.moduleName : @"【未证·待探测】"];
    [s appendFormat:@"  实体数量偏移：0x%X（已证）\n", self.current.entityCountOffset];
    [s appendFormat:@"  实体坐标偏移：0x%X（已证）\n", self.current.entityPositionOffset];
    [s appendFormat:@"  相机指针偏移：0x%X（已证）\n", self.current.cameraPtrOffset];
    if (self.current.lootLevelOffset == 0) {
        [s appendString:@"  物资等级/价值偏移：【未证·待真机校准】\n"];
    } else {
        [s appendFormat:@"  物资等级：0x%X  价值：0x%X\n",
         self.current.lootLevelOffset, self.current.lootValueOffset];
    }
    [s appendFormat:@"\n内置档案 %lu 个", (unsigned long)self.profiles.count];
    return s;
}

@end
