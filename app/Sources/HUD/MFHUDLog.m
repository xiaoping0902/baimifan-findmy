#import "MFHUDLog.h"

#import <unistd.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

/*
 * 两个进程（控制台 / HUD）会写同一个文件。
 * 用 O_APPEND + 单行单 write，跨进程不会互相截断；
 * 再加一把进程内锁避免同进程多线程交错。
 */
static pthread_mutex_t g_hudlog_lock = PTHREAD_MUTEX_INITIALIZER;

// 日志上限，超了从头截断（避免无限增长）
static const long long kMFHUDLogMaxBytes = 256 * 1024;

static NSString *MFHUDLogPath(void) {
    /*
     * main() 里最早就会调用（那时 App 还没完全起来），所以不能只依赖
     * NSSearchPathForDirectoriesInDomains。用 NSHomeDirectory() 兜底 ——
     * 沙盒 App 的 home 就是容器根，Documents 一定在它下面。
     */
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

void MFHUDLogLine(NSString *fmt, ...) {
    if (fmt == nil) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (body == nil) return;

    NSString *path = MFHUDLogPath();
    if (path == nil) return;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ [pid %d] %@\n",
                      [df stringFromDate:[NSDate date]], getpid(), body];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return;

    pthread_mutex_lock(&g_hudlog_lock);

    // 超限就先截断
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (attrs != nil && [attrs fileSize] > (unsigned long long)kMFHUDLogMaxBytes) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }

    int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd >= 0) {
        // 单次 write，O_APPEND 保证跨进程原子追加
        write(fd, data.bytes, data.length);
        close(fd);
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
