#import "MFHUDLog.h"

#import <unistd.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>

/*
 * 两个进程（控制台 / HUD）会写同一个文件。
 * 用 O_APPEND + 单行单 write，跨进程不会互相截断；
 * 再加一把进程内锁避免同进程多线程交错。
 */
static pthread_mutex_t g_hudlog_lock = PTHREAD_MUTEX_INITIALIZER;

// 日志上限，超了从头截断（避免无限增长）
static const long long kMFHUDLogMaxBytes = 256 * 1024;

// 文件大小检查不必每次都做 —— 每 64 行看一次就够，省一次 stat 系统调用。
static unsigned g_logWriteCount = 0;

/*
 * [M5.66] 热路径优化 ★
 *
 * 原来每一行日志都要：
 *   ① [[NSDateFormatter alloc] init] + dateFormat = @"HH:mm:ss.SSS"
 *      —— 这一项单次就 1~3ms（Formatter 要建 locale/cal/tz 的缓存）
 *   ② MFHUDLogPath() 每次都 createDirectory + fileExists + open/close 探测
 *   ③ attributesOfItemAtPath 每次都 stat
 *
 * 触摸诊断一次会写 192 行、启动阶段几十行 —— 光格式化就能吃掉几百毫秒，
 * 表现就是「点了没反应、界面发涩」。现在改成：
 *   · 用 gettimeofday + localtime_r 手写时间戳（无对象、无 locale）
 *   · 路径缓存 5 秒，期间只做一次 open/write/close
 *   · 大小检查 64 行一次
 */
static void MFFormatTimestamp(char *out, size_t capacity) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) { snprintf(out, capacity, "--:--:--.---"); return; }
    struct tm parts;
    if (localtime_r(&tv.tv_sec, &parts) == NULL) { snprintf(out, capacity, "--:--:--.---"); return; }
    snprintf(out, capacity, "%02d:%02d:%02d.%03d",
             parts.tm_hour, parts.tm_min, parts.tm_sec, (int)(tv.tv_usec / 1000));
}

/*
 * [M5.17] ★ 日志直接写进 /var/mobile/Media/mf-debug/
 *
 * 为什么改：
 *   HUD 子进程的日志原来只写 App 容器里的 Documents/mf_hud.log ——
 *   而 AFC（电脑侧唯一能读的通道）只能访问 /var/mobile/Media。
 *   结果就是：HUD 挂了我也看不到现场，只能等用户手动「导出诊断」，
 *   而那一步会覆盖成当前内容，旧现场就丢了。
 *
 *   真机已经吃过亏：pid 307 的 HUD 明明活着，但我拉到的 hud.log
 *   还是上一个会话（pid 614）的三行。现场是空的。
 *
 * 现在两个进程都直接写 Media —— 我有 no-sandbox，
 * 子进程继承同样的 entitlements，一样能写。
 * 保留 Documents 作为兜底（万一 Media 不可写）。
 */
static const char *kMFHUDLogMediaDir = "/var/mobile/Media/mf-debug";

static NSString *MFHUDLogPath(void) {
    // ① 首选：Media 目录（电脑侧 afc 能直接拉）
    NSString *mediaDir = [NSString stringWithUTF8String:kMFHUDLogMediaDir];
    if (mediaDir.length) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:mediaDir]) {
            [fm createDirectoryAtPath:mediaDir
          withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        NSString *p = [mediaDir stringByAppendingPathComponent:@"hud.log"];
        // 快速可用性探测：能打开就算可用
        int fd = open(p.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) { close(fd); return p; }
    }

    // ② 兜底：容器内的 Documents
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES);
    NSString *dir = (docs.count > 0) ? docs.firstObject : nil;
    if (dir == nil || dir.length == 0) {
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    }
    if (dir == nil || dir.length == 0) return nil;

    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    return [dir stringByAppendingPathComponent:@"mf_hud.log"];
}

/// 调用方必须已持有 g_hudlog_lock。
static NSString *MFHUDCachedLogPathLocked(void) {
    static NSString *cached = nil;
    static NSTimeInterval nextProbe = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (cached != nil && now < nextProbe) return cached;
    cached = MFHUDLogPath();
    nextProbe = now + 5.0;
    return cached;
}

void MFHUDLogLine(NSString *fmt, ...) {
    if (fmt == nil) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (body == nil) return;

    char stamp[32];
    MFFormatTimestamp(stamp, sizeof(stamp));
    NSString *line = [NSString stringWithFormat:@"%s [pid %d] %@\n",
                      stamp, getpid(), body];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return;

    pthread_mutex_lock(&g_hudlog_lock);

    NSString *path = MFHUDCachedLogPathLocked();
    if (path != nil) {
        // 超限就先截断（不必每行都 stat）
        if (++g_logWriteCount >= 64) {
            g_logWriteCount = 0;
            NSDictionary *attrs = [[NSFileManager defaultManager]
                attributesOfItemAtPath:path error:NULL];
            if (attrs != nil && [attrs fileSize] > (unsigned long long)kMFHUDLogMaxBytes) {
                [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        }

        int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) {
            // 单次 write，O_APPEND 保证跨进程原子追加
            write(fd, data.bytes, data.length);
            close(fd);
        }
    }

    pthread_mutex_unlock(&g_hudlog_lock);
}

char *MFHUDLogRead(void) {
    NSString *path = MFHUDLogPath();
    if (path == nil) return NULL;

    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d == nil || d.length == 0) return NULL;

    char *out = (char *)malloc(d.length + 1);
    if (out == NULL) return NULL;
    memcpy(out, d.bytes, d.length);
    out[d.length] = '\0';
    return out;
}

void MFHUDLogClear(void) {
    NSString *path = MFHUDLogPath();
    if (path == nil) return;
    pthread_mutex_lock(&g_hudlog_lock);
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    pthread_mutex_unlock(&g_hudlog_lock);
}
