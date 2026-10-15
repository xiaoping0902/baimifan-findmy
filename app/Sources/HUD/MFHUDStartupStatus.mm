#import "MFHUDStartupStatus.h"
#include <sys/stat.h>

@implementation MFHUDStartupStatus
+ (NSString *)currentToken {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [args indexOfObject:@"-mf-session"];
    return (index != NSNotFound && index + 1 < args.count) ? args[index + 1] : nil;
}

+ (NSString *)reportPathForToken:(NSString *)token {
    if (![token isKindOfClass:NSString.class] || token.length == 0 || token.length > 80) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"] invertedSet];
    if ([token rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return [@"/var/mobile/Media/mf-debug" stringByAppendingPathComponent:
            [NSString stringWithFormat:@"hud-startup-%@.json", token]];
}

+ (BOOL)writeReport:(NSDictionary *)report token:(NSString *)token error:(NSError **)error {
    NSString *path = [self reportPathForToken:token];
    if (!path) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    // HUD runs as root; the mobile console must be able to read its result.
    chmod(path.fileSystemRepresentation, 0644);
    return YES;
}

+ (NSDictionary *)readReportForToken:(NSString *)token {
    NSString *path = [self reportPathForToken:token];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

+ (MFHUDStartupState)stateForReport:(NSDictionary *)report pid:(int)pid
                            token:(NSString *)token processAlive:(BOOL)alive {
    if (!alive) return MFHUDStartupExited;
    if (![report isKindOfClass:NSDictionary.class] ||
        ![report[@"pid"] isKindOfClass:NSNumber.class] || [report[@"pid"] intValue] != pid ||
        ![report[@"token"] isEqual:token]) return MFHUDStartupPending;
    if ([report[@"state"] isEqual:@"failed"]) return MFHUDStartupFailed;
    // [M5.66] 用户在启动过程中点了「退出」/控制台结束悬浮窗：
    // HUD 会自己写下 stopped，这里要当成「已退出」而不是继续等到超时。
    if ([report[@"state"] isEqual:@"stopped"]) return MFHUDStartupExited;
    if (![report[@"state"] isEqual:@"ready"]) return MFHUDStartupPending;
    for (NSString *key in @[@"menuContextID", @"drawingContextID", @"menuRegistered",
                            @"drawingRegistered", @"menuFrame", @"drawingFrame"]) {
        if (![report[key] isKindOfClass:NSNumber.class] || [report[key] unsignedIntValue] == 0)
            return MFHUDStartupPending;
    }
    return MFHUDStartupReady;
}
@end
