//
//  MFCleanup.mm — 清理系统残留（实现）
//
#import "MFCleanup.h"
#import <sys/stat.h>

/// 删除前的保护名单 —— 路径里出现任一子串就不删
/// （对齐分析结论：这层保护会让配置里 blacklist 的项不必然被删，例如 /var/jb 被长度保护挡下）
static NSArray<NSString *> *MFProtectedSubstrings(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ @".pid", @"MGNH", @".apple", @"com.apple.dfkr", @"killapps", @"leemin" ];
    });
    return a;
}

static const NSUInteger MFMinPathLength = 9;

@implementation MFCleanupResult
- (instancetype)init {
    if ((self = [super init])) {
        _deleted = [NSMutableArray array];
        _failed = [NSMutableArray array];
    }
    return self;
}
@end

@interface MFCleanup ()
@property (nonatomic, strong) NSDictionary *rules;
@end

@implementation MFCleanup

+ (instancetype)shared {
    static MFCleanup *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFCleanup alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self loadRules];
    }
    return self;
}

- (void)loadRules {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"cleanup_rules" ofType:@"plist"];
    if (!path) {
        NSLog(@"[MF][Cleanup] 找不到 cleanup_rules.plist");
        self.rules = @{};
        return;
    }
    NSError *e = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&e];
    if (!data) {
        NSLog(@"[MF][Cleanup] 读取失败: %@", e);
        self.rules = @{};
        return;
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:&e];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MF][Cleanup] 配置格式异常: %@", e);
        self.rules = @{};
        return;
    }
    self.rules = plist;
    NSLog(@"[MF][Cleanup] 规则已加载：%lu 个目录", (unsigned long)self.rules.count);
}

+ (NSDictionary *)ruleSummary {
    NSDictionary *r = [MFCleanup shared].rules;
    NSUInteger bl = 0, wl = 0;
    for (NSString *k in r) {
        NSDictionary *cfg = r[k];
        if (![cfg isKindOfClass:[NSDictionary class]]) continue;
        bl += [cfg[@"blacklist"] count];
        wl += [cfg[@"whitelist"] count];
    }
    return @{ @"dirs": @(r.count), @"blacklistRules": @(bl), @"whitelistRules": @(wl) };
}

#pragma mark - 规则匹配

/// 单条规则 → 是否命中名称
- (BOOL)name:(NSString *)name matchesRule:(id)rule {
    if ([rule isKindOfClass:[NSString class]]) {
        return [name isEqualToString:rule];
    }
    if ([rule isKindOfClass:[NSDictionary class]]) {
        NSString *match = rule[@"match"];
        NSString *pattern = rule[@"name"];
        if ([match isEqualToString:@"regexp"] && pattern.length) {
            NSError *e = nil;
            NSRegularExpression *re =
                [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&e];
            if (!re) {
                NSLog(@"[MF][Cleanup] 正则编译失败 %@: %@", pattern, e.localizedDescription);
                return NO;
            }
            NSRange full = NSMakeRange(0, name.length);
            return [re firstMatchInString:name options:0 range:full] != nil;
        }
    }
    return NO;
}

/// 决策：该名称是否应被删除？（返回命中的规则来源，nil 表示保留）
- (NSString *)decideForName:(NSString *)name config:(NSDictionary *)cfg {
    NSArray *bl = [cfg[@"blacklist"] isKindOfClass:[NSArray class]] ? cfg[@"blacklist"] : @[];
    NSArray *wl = [cfg[@"whitelist"] isKindOfClass:[NSArray class]] ? cfg[@"whitelist"] : @[];
    NSString *def = [cfg[@"default"] isKindOfClass:[NSString class]] ? cfg[@"default"] : nil;

    // 1) blacklist 命中 → 删
    for (id rule in bl) {
        if ([self name:name matchesRule:rule]) return @"blacklist";
    }
    // 2) 未命中 blacklist，检查 whitelist → 保留
    for (id rule in wl) {
        if ([self name:name matchesRule:rule]) return nil;
    }
    // 3) 都未命中 → 仅当 default 为 blacklist 时删
    if ([def isEqualToString:@"blacklist"]) return @"default";
    return nil;
}

/// 保护名单 + 长度保护
- (BOOL)isProtected:(NSString *)path {
    if (path.length < MFMinPathLength) return YES;
    for (NSString *s in MFProtectedSubstrings()) {
        if ([path rangeOfString:s].location != NSNotFound) return YES;
    }
    return NO;
}

#pragma mark - 扫描

- (NSArray<MFCleanupItem *> *)scanWithStats:(MFCleanupResult **)statsOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<MFCleanupItem *> *selected = [NSMutableArray array];
    MFCleanupResult *st = [[MFCleanupResult alloc] init];

    for (NSString *root in self.rules) {
        NSDictionary *cfg = self.rules[root];
        if (![cfg isKindOfClass:[NSDictionary class]]) continue;

        NSArray *children = [fm contentsOfDirectoryAtPath:root error:NULL];
        if (!children) continue;             // 目录不存在 / 无权访问 → 跳过
        st.scannedDirs++;
        st.scannedEntries += children.count;

        for (NSString *name in children) {
            NSString *srcMark = [self decideForName:name config:cfg];
            if (!srcMark) continue;          // 保留

            // 合成待删路径：目录 + 名称
            NSString *full = [root hasSuffix:@"/"]
                ? [root stringByAppendingString:name]
                : [root stringByAppendingPathComponent:name];

            if ([self isProtected:full]) {
                st.protectedSkipped++;
                NSLog(@"[MF][Cleanup] 保护名单跳过: %@", full);
                continue;
            }

            MFCleanupItem *it = [[MFCleanupItem alloc] init];
            it.path = full;
            it.name = name;
            it.ruleRoot = root;
            it.matchedBy = srcMark;
            it.isDirectory = NO;

            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir]) {
                it.isDirectory = isDir;
                if (!isDir) {
                    NSDictionary *attr = [fm attributesOfItemAtPath:full error:NULL];
                    it.size = [attr[NSFileSize] unsignedLongLongValue];
                }
            }
            [selected addObject:it];
        }
    }

    st.selected = selected.count;
    if (statsOut) *statsOut = st;
    return selected;
}

#pragma mark - 删除

- (MFCleanupResult *)deleteItems:(NSArray<MFCleanupItem *> *)items {
    NSFileManager *fm = [NSFileManager defaultManager];
    MFCleanupResult *st = [[MFCleanupResult alloc] init];

    for (MFCleanupItem *it in items) {
        // 再核一遍保护名单（清单可能来自界面停留期间）
        if ([self isProtected:it.path]) {
            st.protectedSkipped++;
            continue;
        }
        NSError *e = nil;
        if ([fm removeItemAtPath:it.path error:&e]) {
            [st.deleted addObject:it];
            NSLog(@"[MF][Cleanup] 已删除: %@", it.path);
        } else {
            NSString *msg = [NSString stringWithFormat:@"%@ → %@", it.path,
                             e.localizedDescription ?: @"unknown"];
            [st.failed addObject:msg];
            NSLog(@"[MF][Cleanup] 删除失败: %@", msg);
        }
    }
    return st;
}

@end
