//
//  MFPaths.mm — 共用路径与沙盒判定
//
#import "MFPaths.h"
#import <sys/stat.h>
#import <unistd.h>
#include <errno.h>

@implementation MFCleanupItem
- (NSString *)description {
    return [NSString stringWithFormat:@"<Cleanup %@ (%@, %@)>",
            self.path, self.isDirectory ? @"dir" : @"file", self.matchedBy];
}
@end

@implementation MFPaths

+ (NSString *)keychainDB {
    return @"/var/Keychains/keychain-2.db";
}

/// lsdidentifiers.plist 在 /var/containers/Shared/SystemGroup/<UUID>/Library/Darwin/, 
/// 也见 Linux/  目录 —— 逐层探测
+ (NSString *)lsdIdentifiersPlist {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @"/var/containers/Shared/SystemGroup";
    NSArray *groups = [fm contentsOfDirectoryAtPath:base error:NULL];
    for (NSString *g in groups) {
        for (NSString *sub in @[@"Library/Darwin", @"Library/Caches/com.apple.lsd", @"Library"]) {
            NSString *p = [base stringByAppendingPathComponent:
                           [g stringByAppendingPathComponent:
                            [sub stringByAppendingPathComponent:@"com.apple.lsdidentifiers.plist"]]];
            if ([fm fileExistsAtPath:p]) return p;
        }
    }
    return nil;
}

+ (BOOL)canListDirectory:(NSString *)path count:(NSUInteger *)count error:(NSString **)err {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (err) *err = @"路径不存在";
        return NO;
    }
    NSError *e = nil;
    NSArray *items = [fm contentsOfDirectoryAtPath:path error:&e];
    if (!items) {
        if (err) *err = e.localizedDescription ?: [NSString stringWithFormat:@"errno=%d", errno];
        return NO;
    }
    if (count) *count = items.count;
    return YES;
}

+ (BOOL)isRoot {
    return getuid() == 0 || geteuid() == 0;
}

+ (NSString *)humanSize:(unsigned long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    if (bytes < 1024ULL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / 1024.0 / 1024.0];
    return [NSString stringWithFormat:@"%.2f GB", bytes / 1024.0 / 1024.0 / 1024.0];
}

@end
