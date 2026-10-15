//
//  MFHUDControl.mm — 控制台 ↔ HUD 子进程的控制通道（实现）
//
#import "MFHUDControl.h"
#import "MFHUDLog.h"

#import <notify.h>
#import <unistd.h>
#import <stdlib.h>
#import <QuartzCore/QuartzCore.h>

NSString *const MFHUDExitNotificationName = @"com.mf.findmy.hud.exit";
NSString *const MFHUDPIDFilePath = @"/var/mobile/Library/Caches/mf.findmy.hud.pid";

/*
 * 文件级状态。
 *
 * 为什么不放 ivar：这条通道的生命周期 = 进程生命周期，
 * 而且要在 HUD 引导阶段（还没有任何对象）就能注册。
 */
static int sExitToken = NOTIFY_TOKEN_INVALID;
static dispatch_source_t sWatchdog = nil;
static BOOL sFired = NO;
static BOOL sSawOwnPID = NO;
static dispatch_block_t sExitHandler = nil;

/// 看门狗启动后的宽限期：控制台在 posix_spawn 返回后立刻写 PID 文件，
/// HUD 侧 main() 起来之前文件通常已经就位。3 秒足够，且不会误杀。
static const NSTimeInterval kMFHUDWatchdogGrace = 3.0;
/// 连续多少次读到「不是我」才认定被外部结束（防单次读失败误判）。
static const int kMFHUDWatchdogMisses = 2;

static void MFHUDFireExit(NSString *reason) {
    if (sFired) return;
    sFired = YES;

    if (sWatchdog) { dispatch_source_cancel(sWatchdog); sWatchdog = nil; }
    if (sExitToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(sExitToken);
        sExitToken = NOTIFY_TOKEN_INVALID;
    }

    MFHUDLogLine(@"收到退出请求（%@），HUD 开始退出", reason);
    dispatch_block_t handler = sExitHandler;
    sExitHandler = nil;
    if (handler) handler();
}

@implementation MFHUDControl

+ (void)requestExit {
    MFHUDLogLine(@"控制台请求结束 HUD（notify + PID 文件双通道）");
    notify_post(MFHUDExitNotificationName.UTF8String);

    /*
     * 通知走 notifyd，正常在毫秒级送达。这里再撤掉 PID 文件作为兜底：
     * HUD 看门狗读不到自己的 pid 就会自己退出 —— 这条路不依赖 notifyd
     * 状态，也不依赖信号权限。
     */
    if ([[NSFileManager defaultManager] fileExistsAtPath:MFHUDPIDFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:MFHUDPIDFilePath error:NULL];
    }
}

+ (void)watchForExitRequest:(dispatch_block_t)handler {
    if (sFired) { if (handler) handler(); return; }
    if (sExitHandler) return;   // 只认第一次注册
    sExitHandler = [handler copy];

    notify_register_dispatch(MFHUDExitNotificationName.UTF8String, &sExitToken,
                             dispatch_get_main_queue(), ^(int token) {
        MFHUDFireExit(@"Darwin 通知");
    });

    const NSTimeInterval startedAt = CACurrentMediaTime();
    __block int misses = 0;
    sWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
    dispatch_source_set_timer(sWatchdog,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                              (uint64_t)(NSEC_PER_SEC),
                              (uint64_t)(200 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(sWatchdog, ^{
        if (CACurrentMediaTime() - startedAt < kMFHUDWatchdogGrace) return;
        NSString *stored = [NSString stringWithContentsOfFile:MFHUDPIDFilePath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (stored.intValue == (int)getpid()) { misses = 0; sSawOwnPID = YES; return; }
        if (++misses >= kMFHUDWatchdogMisses) MFHUDFireExit(@"PID 文件看门狗");
    });
    dispatch_resume(sWatchdog);

    MFHUDLogLine(@"退出通道已装好：notify=%@ + PID 文件 %@",
                 MFHUDExitNotificationName, MFHUDPIDFilePath);
}

+ (void)stopWatching {
    if (sWatchdog) { dispatch_source_cancel(sWatchdog); sWatchdog = nil; }
    if (sExitToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(sExitToken);
        sExitToken = NOTIFY_TOKEN_INVALID;
    }
    sExitHandler = nil;
}

+ (BOOL)watchdogSawOwnPID { return sSawOwnPID; }

@end
