#import "MFHUDControl.h"
#import "MFHUDStartupStatus.h"
#import "MFHUDLog.h"
#import <notify.h>
#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const MFHUDExitNotificationName = @"com.mf.findmy.hud.exit";
NSString *const MFHUDPIDFilePath = @"/var/mobile/Library/Caches/mf.findmy.hud.pid";

static dispatch_queue_t MFControlQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.mf.hud.control", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static std::atomic<bool> sExitRequested(false), sSawOwnPID(false);
static int sExitToken = NOTIFY_TOKEN_INVALID;
static dispatch_source_t sWatchdog;
static dispatch_block_t sExitHandler;
static BOOL sWatching;

static NSString *MFSessionSuffix(pid_t pid, NSString *token) {
    if (token && ![MFHUDStartupStatus reportPathForToken:token]) return nil;
    return token ?: [NSString stringWithFormat:@"legacy-%d", pid];
}
static NSString *MFRequestPath(pid_t pid, NSString *token) {
    NSString *suffix = MFSessionSuffix(pid, token);
    return suffix ? [@"/var/mobile/Media/mf-debug" stringByAppendingPathComponent:
        [NSString stringWithFormat:@"hud-stop-%@.json", suffix]] : nil;
}
static void MFCancelWatchers(void) {
    if (sWatchdog) { dispatch_source_cancel(sWatchdog); sWatchdog = nil; }
    if (sExitToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(sExitToken);
        sExitToken = NOTIFY_TOKEN_INVALID;
    }
    sWatching = NO;
}
static void MFFireExit(void) {
    if (sExitRequested.exchange(true)) return;
    // Arm before logging, releasing windows or invoking client code: any one
    // of those may be where the main thread is stuck.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ _exit(EXIT_SUCCESS); });
    dispatch_block_t handler = sExitHandler;
    sExitHandler = nil;
    MFCancelWatchers();
    dispatch_async(dispatch_get_main_queue(), ^{ if (handler) handler(); });
}

@implementation MFHUDControl
+ (BOOL)withPIDRecordLock:(dispatch_block_t)operation {
    static thread_local unsigned depth = 0;
    if (depth) { operation(); return YES; }
    if (![NSFileManager.defaultManager createDirectoryAtPath:MFHUDPIDFilePath.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
    NSString *lockPath = [MFHUDPIDFilePath stringByAppendingString:@".lock"];
    // Darwin flock does not require write access. A root-created lock is
    // commonly 0644 after umask, and must remain lockable by mobile.
    int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDONLY | O_CLOEXEC, 0666);
    if (fd < 0) return NO;
    int result;
    do { result = flock(fd, LOCK_EX); } while (result < 0 && errno == EINTR);
    if (result < 0) { close(fd); return NO; }
    depth++;
    @try { operation(); }
    @finally { depth--; flock(fd, LOCK_UN); close(fd); }
    return YES;
}
+ (NSDictionary *)readPIDRecord {
    NSData *data = [NSData dataWithContentsOfFile:MFHUDPIDFilePath];
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *record = value;
        if (![record[@"pid"] isKindOfClass:NSNumber.class] || [record[@"pid"] intValue] <= 0) return nil;
        if (record[@"token"] && (![record[@"token"] isKindOfClass:NSString.class] ||
            ![MFHUDStartupStatus reportPathForToken:record[@"token"]])) return nil;
        return record;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    int pid = 0;
    return [scanner scanInt:&pid] && scanner.isAtEnd && pid > 0 ? @{ @"pid": @(pid) } : nil;
}
+ (BOOL)writePIDRecord:(NSDictionary *)record error:(NSError **)error {
    __block BOOL saved = NO;
    __block NSError *failure = nil;
    BOOL locked = [self withPIDRecordLock:^{
        NSError *writeError = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:&writeError];
        saved = data && [data writeToFile:MFHUDPIDFilePath options:NSDataWritingAtomic error:&writeError];
        failure = writeError;
        if (saved) chmod(MFHUDPIDFilePath.fileSystemRepresentation, 0644);
    }];
    if (!locked) failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno ?: EACCES userInfo:nil];
    if (!saved && error) *error = failure;
    return locked && saved;
}
+ (void)removePIDRecordIfMatching:(NSDictionary *)record {
    [self withPIDRecordLock:^{
        if (![[self readPIDRecord] isEqual:record]) return;
        [NSFileManager.defaultManager removeItemAtPath:MFHUDPIDFilePath error:NULL];
        NSString *path = MFRequestPath([record[@"pid"] intValue], record[@"token"]);
        if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    }];
}
+ (void)requestExit {
    NSString *ownToken = [MFHUDStartupStatus currentToken];
    NSDictionary *record = ownToken ? @{ @"pid": @(getpid()), @"token": ownToken } : [self readPIDRecord];
    if (!record) return;
    NSError *error = nil;
    if (![self requestExitForPID:[record[@"pid"] intValue] token:record[@"token"] error:&error])
        MFHUDLogLine(@"退出请求发送失败：%@", error);
}
+ (BOOL)requestExitForPID:(pid_t)pid token:(NSString *)token error:(NSError **)error {
    NSString *path = pid > 0 ? MFRequestPath(pid, token) : nil;
    if (!path) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }
    NSError *writeError = nil;
    BOOL saved = [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:&writeError];
    NSDictionary *request = @{ @"pid": @(pid), @"token": token ?: @"" };
    NSData *data = saved ? [NSJSONSerialization dataWithJSONObject:request options:0 error:&writeError] : nil;
    saved = data && [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
    if (saved) chmod(path.fileSystemRepresentation, 0644);
    // New token-bearing HUDs never observe the legacy global name.
    NSString *name = token ? [MFHUDExitNotificationName stringByAppendingFormat:@".%@", token] : MFHUDExitNotificationName;
    uint32_t status = notify_post(name.UTF8String);
    if (!saved && status != NOTIFY_STATUS_OK && error)
        *error = writeError ?: [NSError errorWithDomain:@"MFHUDNotify" code:status userInfo:nil];
    return saved || status == NOTIFY_STATUS_OK;
}
+ (void)watchForExitRequest:(dispatch_block_t)handler {
    dispatch_sync(MFControlQueue(), ^{
        if (sExitRequested.load()) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (handler) handler(); });
            return;
        }
        if (sWatching) return;
        sWatching = YES;
        sExitHandler = [handler copy];
        NSString *token = [MFHUDStartupStatus currentToken];
        pid_t pid = getpid();
        NSString *path = MFRequestPath(pid, token);
        NSString *name = token ? [MFHUDExitNotificationName stringByAppendingFormat:@".%@", token] : MFHUDExitNotificationName;
        uint32_t status = notify_register_dispatch(name.UTF8String, &sExitToken, MFControlQueue(), ^(int notificationToken) {
            MFFireExit();
        });
        if (status != NOTIFY_STATUS_OK) sExitToken = NOTIFY_TOKEN_INVALID;
        sWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, MFControlQueue());
        dispatch_source_set_timer(sWatchdog, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 25 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(sWatchdog, ^{
            if (!sSawOwnPID.load()) {
                NSDictionary *record = [self readPIDRecord];
                if ([record[@"pid"] intValue] == pid && (!token || [record[@"token"] isEqual:token]))
                    sSawOwnPID.store(true);
            }
            NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
            id request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if ([request isKindOfClass:NSDictionary.class] && [request[@"pid"] intValue] == pid &&
                [request[@"token"] isEqual:token ?: @""]) MFFireExit();
        });
        dispatch_resume(sWatchdog);
    });
}
+ (void)stopWatching { dispatch_async(MFControlQueue(), ^{ MFCancelWatchers(); sExitHandler = nil; }); }
+ (BOOL)exitRequested { return sExitRequested.load(); }
+ (BOOL)watchdogSawOwnPID { return sSawOwnPID.load(); }
@end
