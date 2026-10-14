//
//  MFAntiBan.mm — 防封（实现）
//
#import "MFAntiBan.h"
#import "MFPaths.h"
#import "MFKeychain.h"
#import <signal.h>
#include <errno.h>
#include <string.h>

static NSString *const kLSApplications = @"LSApplications";
static NSString *const kLSVendors      = @"LSVendors";
static NSString *const kAdvertiserKey  = @"LSAdvertiserIdentifier";
static NSString *const kVendorKey      = @"LSVendorIdentifier";

@implementation MFAntiBan

+ (instancetype)shared {
    static MFAntiBan *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFAntiBan alloc] init]; });
    return s;
}

#pragma mark - 探测

- (NSString *)plistPath {
    return [MFPaths lsdIdentifiersPlist];
}

- (NSDictionary *)dumpStructure {
    NSString *p = [self plistPath];
    if (!p) return @{ @"error": @"未找到 com.apple.lsdidentifiers.plist" };

    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:p];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return @{ @"path": p, @"error": @"plist 解析失败或格式非字典" };
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"path"] = p;
    for (NSString *k in plist) {
        id v = plist[k];
        if ([v isKindOfClass:[NSDictionary class]]) {
            out[k] = [NSString stringWithFormat:@"dict(%lu 项)", (unsigned long)[v count]];
        } else if ([v isKindOfClass:[NSArray class]]) {
            out[k] = [NSString stringWithFormat:@"array(%lu 项)", (unsigned long)[v count]];
        } else {
            out[k] = [NSString stringWithFormat:@"%@ = %@",
                      NSStringFromClass([v class]), v];
        }
    }
    return out;
}

- (NSDictionary *)currentIdentifiersForBundleID:(NSString *)bundleID {
    NSString *p = [self plistPath];
    if (!p) return nil;
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:p];
    NSDictionary *apps = plist[kLSApplications];
    if (![apps isKindOfClass:[NSDictionary class]]) return nil;
    id entry = apps[bundleID];
    return [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
}

#pragma mark - 备份

- (NSString *)backupPlistWithError:(NSString **)err {
    NSString *src = [self plistPath];
    if (!src) {
        if (err) *err = @"未找到 lsdidentifiers.plist";
        return nil;
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"lsdidentifiers-backup-%@.plist", [df stringFromDate:[NSDate date]]];
    NSString *dst = [docs stringByAppendingPathComponent:name];

    NSError *e = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e]) {
        if (err) *err = e.localizedDescription;
        return nil;
    }
    NSLog(@"[MF][AntiBan] 已备份 → %@", dst);
    return dst;
}

#pragma mark - 重置

- (NSDictionary<NSString *, NSString *> *)resetIdentifiersForGamesWithError:(NSString **)err {
    return [self resetIdentifiersForBundleIDs:[MFKeychain gameBundleIDs] error:err];
}

- (NSDictionary<NSString *, NSString *> *)resetIdentifiersForBundleIDs:(NSArray<NSString *> *)bundleIDs
                                                                 error:(NSString **)err {
    NSString *p = [self plistPath];
    if (!p) {
        if (err) *err = @"未找到 com.apple.lsdidentifiers.plist";
        return @{};
    }

    // 1) 读（propertyListWithData 等价）
    NSError *e = nil;
    NSData *raw = [NSData dataWithContentsOfFile:p options:0 error:&e];
    if (!raw) {
        if (err) *err = [NSString stringWithFormat:@"读取失败: %@", e.localizedDescription];
        return @{};
    }
    id parsed = [NSPropertyListSerialization propertyListWithData:raw
                                                          options:NSPropertyListMutableContainersAndLeaves
                                                           format:NULL
                                                            error:&e];
    if (![parsed isKindOfClass:[NSMutableDictionary class]]) {
        if (err) *err = [NSString stringWithFormat:@"解析失败: %@", e.localizedDescription ?: @"非字典"];
        return @{};
    }
    NSMutableDictionary *plist = parsed;   // mutableCopy 等价

    // 2) 确保 LSApplications / LSVendors 存在
    NSMutableDictionary *apps = plist[kLSApplications];
    if (![apps isKindOfClass:[NSMutableDictionary class]]) {
        apps = [NSMutableDictionary dictionary];
        plist[kLSApplications] = apps;
    }
    NSMutableDictionary *vendors = plist[kLSVendors];
    if (![vendors isKindOfClass:[NSMutableDictionary class]]) {
        vendors = [NSMutableDictionary dictionary];
        plist[kLSVendors] = vendors;
    }

    // 3) 逐个生成新标识符：idv / ida 用【同一个】统一值（对齐原实现语义）
    NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];
    for (NSString *bid in bundleIDs) {
        NSString *uuid = [[NSUUID UUID] UUIDString];

        NSMutableDictionary *entry = apps[bid];
        if (![entry isKindOfClass:[NSMutableDictionary class]]) {
            entry = [NSMutableDictionary dictionary];
        }
        entry[kAdvertiserKey] = uuid;      // ida
        entry[kVendorKey]     = uuid;      // idv —— 同一个值
        apps[bid] = entry;

        // LSVendors: <vendorID> → <bundleID> 形态；旧映射一并清掉避免残留
        NSArray *staleVendorKeys = [vendors allKeysForObject:bid];
        for (NSString *k in staleVendorKeys) [vendors removeObjectForKey:k];
        vendors[uuid] = bid;

        mapping[bid] = uuid;
        NSLog(@"[MF][AntiBan] %@ → %@", bid, uuid);
    }

    // 4) 写回（dataWithPropertyList + writeToFile:atomically: 等价）
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:plist
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:&e];
    if (!out) {
        if (err) *err = [NSString stringWithFormat:@"序列化失败: %@", e.localizedDescription];
        return @{};
    }
    if (![out writeToFile:p atomically:YES]) {
        if (err) *err = [NSString stringWithFormat:@"写回失败 errno=%d (%s)", errno, strerror(errno)];
        return @{};
    }

    NSLog(@"[MF][AntiBan] 已写回 %@（%lu 个目标）", p, (unsigned long)mapping.count);
    [self restartLSD];      // 收尾：让 lsd 重读
    return mapping;
}

#pragma mark - 收尾

- (BOOL)restartLSD {
    // 原实现末尾调 lrproki:("lsd")。这里用 SIGTERM 让 launchd 重启 lsd。
    // 失败不算致命：新标识符已落盘，下次 lsd 启动会读到。
    pid_t pid = 0;
    FILE *fp = popen("/usr/bin/killall -TERM lsd 2>&1", "r");
    if (fp) {
        char buf[256] = {0};
        fgets(buf, sizeof(buf), fp);
        pclose(fp);
        NSLog(@"[MF][AntiBan] killall lsd 已执行 (%s)", buf);
        (void)pid;
        return YES;
    }
    NSLog(@"[MF][AntiBan] killall lsd 执行失败");
    return NO;
}

@end
