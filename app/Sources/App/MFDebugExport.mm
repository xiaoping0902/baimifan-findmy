#import "MFDebugExport.h"
#import "../Features/MFPaths.h"
#import "../Features/MFCleanup.h"
#import "../Features/MFKeychain.h"
#import "../Features/MFAntiBan.h"
#import "../Kernel/MFKernel.h"
#import "../Kernel/MFKernelBridge.h"
#import "../HUD/MFHUDLauncher.h"
#import "../HUD/MFHUDLog.h"
#import "../Game/MFGameReader.h"
#import "../Read/MFReadBackend.h"
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <sys/resource.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <pwd.h>
#import <UIKit/UIKit.h>

NSString * const MFDebugExportDir = @"/var/mobile/Media/mf-debug";

static NSString *gMFDebugExportError = nil;

@implementation MFDebugExport

+ (NSString *)lastError { return gMFDebugExportError; }

#pragma mark - 可用性

+ (BOOL)isAvailable {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 建目录（Media 下面，AFC 直接可见）
    if (![fm fileExistsAtPath:MFDebugExportDir]) {
        NSError *err = nil;
        if (![fm createDirectoryAtPath:MFDebugExportDir
           withIntermediateDirectories:YES attributes:nil error:&err]) {
            gMFDebugExportError = [NSString stringWithFormat:
                @"建目录失败：%@（errno=%d）", err.localizedDescription, errno];
            NSLog(@"[MF][Export] ❌ %@", gMFDebugExportError);
            return NO;
        }
    }

    // 写测试：能建目录不代表能写文件（Media 的属主是 mobile，
    // 但某些设备上额外挂了 ACL）
    NSString *probe = [MFDebugExportDir stringByAppendingPathComponent:@".probe"];
    NSError *werr = nil;
    if (![@"ok" writeToFile:probe atomically:YES
                   encoding:NSUTF8StringEncoding error:&werr]) {
        gMFDebugExportError = [NSString stringWithFormat:
            @"写测试失败：%@（errno=%d）", werr.localizedDescription, errno];
        NSLog(@"[MF][Export] ❌ %@", gMFDebugExportError);
        return NO;
    }
    [fm removeItemAtPath:probe error:NULL];

    gMFDebugExportError = nil;
    return YES;
}

#pragma mark - 日志镜像

/// 把某个来源直接写进导出目录（不走 Documents 中转）
static BOOL MFWriteText(NSString *name, NSString *text) {
    if (text == nil) text = @"(空)";
    NSString *p = [MFDebugExportDir stringByAppendingPathComponent:name];
    return [text writeToFile:p atomically:YES
                    encoding:NSUTF8StringEncoding error:NULL];
}

+ (NSUInteger)syncLogs {
    if (![self isAvailable]) return 0;
    NSUInteger n = 0;

    // 内核链日志
    char *kfd = mf_read_klog();
    if (kfd != NULL) {
        NSString *s = [NSString stringWithUTF8String:kfd];
        free(kfd);
        if (s && MFWriteText(@"kfd.log", s)) n++;
    } else {
        MFWriteText(@"kfd.log", @"（还没有内核日志 —— 先跑一次「启动内核」）");
        n++;
    }

    // HUD 子进程日志
    char *hud = MFHUDLogRead();
    if (hud != NULL) {
        NSString *s = [NSString stringWithUTF8String:hud];
        free(hud);
        if (s && MFWriteText(@"hud.log", s)) n++;
    } else {
        MFWriteText(@"hud.log", @"（还没有 HUD 日志 —— 先点一次「启动悬浮窗」）");
        n++;
    }

    NSLog(@"[MF][Export] 已同步 %lu 份日志", (unsigned long)n);
    return n;
}

#pragma mark - 状态快照

+ (BOOL)writeStateSnapshot {
    if (![self isAvailable]) return NO;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    // ── 环境 ──
    struct utsname u; uname(&u);
    d[@"device"] = @{
        @"machine":   @(u.machine),
        @"sysname":   @(u.sysname),
        @"release":   @(u.release),
        @"uid":       @(getuid()),
        @"gid":       @(getgid()),
        @"euid":      @(geteuid()),
    };
    size_t sz = 0;
    sysctlbyname("kern.version", NULL, &sz, NULL, 0);
    if (sz > 0) {
        /* ObjC++ 下 malloc 的 void* 不能隐式转 char*，必须显式转换 */
        char *buf = (char *)malloc(sz);
        if (buf != NULL) {
            if (sysctlbyname("kern.version", buf, &sz, NULL, 0) == 0) {
                d[@"kernversion"] = @(buf);
            }
            free(buf);
        }
    }
    int mfp = 0; size_t ms = sizeof(mfp);
    if (sysctlbyname("kern.maxfilesperproc", &mfp, &ms, NULL, 0) == 0) {
        d[@"maxfilesperproc"] = @(mfp);
    }
    struct rlimit rl = {0,0};
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        d[@"rlimit_nofile"] = @{ @"soft": @(rl.rlim_cur), @"hard": @(rl.rlim_max) };
    }

    // ── 导出能力 ──
    d[@"export"] = @{
        @"dir":       MFDebugExportDir,
        @"available": @([self isAvailable]),
        @"error":     gMFDebugExportError ?: [NSNull null],
    };

    // ── 内核 ──
    MFKernel *k = [MFKernel shared];
    MFEnumRoute route = [k availableRoute];        // 只读属性，会顺手探测
    d[@"kernel"] = @{
        @"open":     @([k isOpen]),
        @"state":    @(k.state),
        @"kbase":    @([k isOpen] ? k.kbase : 0),
        @"lastErr":  k.lastError ?: @"",
        @"route":    @((NSInteger)route),
        @"routeName": route == MFEnumRouteTaskForPid ? @"C: task_for_pid"
                    : route == MFEnumRoutePrivileged  ? @"A: host_priv"
                    : route == MFEnumRouteDefault     ? @"B: processor_set_default"
                                                      : @"无可用枚举路",
    };

    // ── 读取链 ──
    MFGameReader *r = [MFGameReader shared];
    MFReadBackend *rb = [MFReadBackend shared];
    d[@"readchain"] = @{
        @"targetTaskPort": @(r.targetTaskPort),
        @"gateOpen":       @(rb.gateOpen),
        @"modeFlag":       @(rb.modeFlag),
        @"rootObjectBase":  @(r.rootObjectBase),
        @"entityArrayBase": @(r.entityArrayBase),
        @"lootArrayBase":   @(r.lootArrayBase),
        @"stats":          [rb statsText] ?: @"?",
    };

    // ── HUD ──
    d[@"hud"] = @{
        @"running": @([MFHUDLauncher isHUDRunning]),
        @"pid":     @([MFHUDLauncher hudPID]),
    };

    // ── 清理 / 防封 ──
    NSDictionary *rs = [MFCleanup ruleSummary];
    d[@"cleanup"] = @{
        @"dirs":      rs[@"dirs"] ?: @0,
        @"blacklist": rs[@"blacklistRules"] ?: @0,
        @"whitelist": rs[@"whitelistRules"] ?: @0,
    };
    d[@"keychain"] = @{
        @"mode":     [[MFKeychain shared] keychainModeOctal] ?: @"不可读",
        @"gameMode": [[MFKeychain shared] gameModeStatusText] ?: @"?",
    };
    d[@"antiban"] = @{
        @"plist": [[MFAntiBan shared] plistPath] ?: @"未找到",
    };

    // ── 构建 ──
    d[@"build"] = @{
        @"bundleID":   [NSBundle mainBundle].bundleIdentifier ?: @"?",
        @"version":    [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"?",
        @"executable": [NSBundle mainBundle].executablePath ?: @"?",
    };

    d[@"exportedAt"] = [[NSDate date] description];

    NSError *e = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&e];
    if (json == nil) {
        NSLog(@"[MF][Export] state.json 序列化失败: %@", e);
        return NO;
    }
    NSString *p = [MFDebugExportDir stringByAppendingPathComponent:@"state.json"];
    BOOL ok = [json writeToFile:p atomically:YES];
    NSLog(@"[MF][Export] state.json %@", ok ? @"已写出" : @"写失败");
    return ok;
}

#pragma mark - 自截图

+ (BOOL)captureSelfScreenshot {
    if (![self isAvailable]) return NO;

    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (win == nil) {
        win = UIApplication.sharedApplication.windows.firstObject;
    }
    if (win == nil) {
        NSLog(@"[MF][Export] 没有可用窗口，截图跳过");
        return NO;
    }

    /*
     * 用 UIGraphicsImageRenderer 抓自己的窗口。
     * 跨 App 的画面抓不到（那需要 DDI / dvt screenshot）——
     * 但至少能看到我们的 UI 到底渲染成什么样。
     */
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;                      // 1x 就够看布局，文件也小
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rend = [[UIGraphicsImageRenderer alloc]
                                     initWithSize:win.bounds.size format:fmt];

    UIImage *img = [rend imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
    }];
    if (img == nil) return NO;

    NSData *png = UIImagePNGRepresentation(img);
    if (png == nil) return NO;

    NSString *p = [MFDebugExportDir stringByAppendingPathComponent:@"screen.png"];
    BOOL ok = [png writeToFile:p atomically:YES];
    NSLog(@"[MF][Export] 截图 %@（%lu 字节）%@",
          ok ? @"已写出" : @"写失败", (unsigned long)png.length, p);
    return ok;
}

#pragma mark - 一键

+ (NSString *)exportAll {
    NSMutableString *log = [NSMutableString string];

    [log appendFormat:@"导出目录：%@\n", MFDebugExportDir];

    if (![self isAvailable]) {
        [log appendFormat:@"❌ 不可写：%@\n\n", gMFDebugExportError ?: @"未知"];
        [log appendString:@"排查方向：\n"
                        @"· no-sandbox 权限是否生效（看首页系统自检的 /var/mobile 那行）\n"
                        @"· /var/mobile/Media 是否挂载\n"];
        return log;
    }

    NSUInteger n = [self syncLogs];
    [log appendFormat:@"✅ 日志 %lu 份\n", (unsigned long)n];

    BOOL st = [self writeStateSnapshot];
    [log appendFormat:@"%@ state.json\n", st ? @"✅" : @"❌"];

    BOOL sh = [self captureSelfScreenshot];
    [log appendFormat:@"%@ screen.png\n", sh ? @"✅" : @"⚠️（可能不在前台）"];

    [log appendFormat:@"\nWindows 侧执行：\n    python scripts/dev.py pull"];

    NSLog(@"[MF][Export] %@", log);
    return log;
}

+ (BOOL)clearExports {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:MFDebugExportDir error:NULL];
    BOOL all = YES;
    for (NSString *it in items) {
        NSString *p = [MFDebugExportDir stringByAppendingPathComponent:it];
        if (![fm removeItemAtPath:p error:NULL]) all = NO;
    }
    return all;
}

@end
