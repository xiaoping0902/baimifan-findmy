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
    @synchronized (self) {
        NSDictionary *previous = [self readReportForToken:token];
        if ([previous[@"pid"] isEqual:report[@"pid"]] && [previous[@"token"] isEqual:token]) {
            NSString *oldState = previous[@"state"];
            NSString *newState = report[@"state"];
            // Late GPU/main-queue callbacks must not resurrect a stopped or failed
            // launch, including by overwriting its persisted terminal diagnostics.
            if (([oldState isEqual:@"stopped"] || [oldState isEqual:@"failed"]) && ![oldState isEqual:newState]) return YES;
            if ([oldState isEqual:@"stopping"] && ![newState isEqual:@"stopped"] && ![newState isEqual:@"failed"] &&
                ![newState isEqual:@"stopping"]) return YES;
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:error]) return NO;
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:error];
        if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
        // HUD runs as root; the mobile console must be able to read its result.
        chmod(path.fileSystemRepresentation, 0644);
        return YES;
    }
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
    // A cleanup acknowledgement is not process-death evidence. The launcher
    // separately cancels its wait and confirms this session actually exited.
    if ([report[@"state"] isEqual:@"stopped"] || [report[@"state"] isEqual:@"stopping"]) return MFHUDStartupPending;
    if (![report[@"state"] isEqual:@"ready"]) return MFHUDStartupPending;
    for (NSString *key in @[@"menuContextID", @"drawingContextID", @"menuRegistered",
                            @"drawingRegistered", @"menuFrame", @"drawingFrame"]) {
        if (![report[key] isKindOfClass:NSNumber.class] || [report[key] unsignedIntValue] == 0)
            return MFHUDStartupPending;
    }
    return MFHUDStartupReady;
}
@end
