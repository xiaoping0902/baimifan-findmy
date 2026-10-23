#import "MFHUDPassiveState.h"
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

@implementation MFHUDPassiveState
+ (NSString *)snapshotPathForToken:(NSString *)token directory:(NSString *)directory {
    if (![token isKindOfClass:NSString.class] || token.length == 0 || token.length > 80) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"] invertedSet];
    if ([token rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"hud-state-%@.json", token]];
}

+ (BOOL)writeSnapshot:(NSDictionary *)snapshot token:(NSString *)token
            directory:(NSString *)directory error:(NSError **)error {
    NSString *path = [self snapshotPathForToken:token directory:directory];
    if (!path) {
        if (error) *error = [NSError errorWithDomain:@"MFHUDPassiveState" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"HUD 状态快照的会话 token 无效"}];
        return NO;
    }
    NSMutableDictionary *report = [snapshot mutableCopy];
    report[@"schemaVersion"] = @1;
    report[@"pid"] = @(getpid());
    report[@"token"] = token;
    report[@"exportedAt"] = NSDate.date.description;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:error];
    if (!data) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0755} error:error]) return NO;
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    // The HUD runs as root; the mobile console/AFC must be able to read it.
    if (chmod(path.fileSystemRepresentation, 0644) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    return YES;
}
@end
