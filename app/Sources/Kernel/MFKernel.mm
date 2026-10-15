//
//  MFKernel.mm — 内核会话（实现）
//
#import "MFKernel.h"
#import "MFKernelBridge.h"

#import <UIKit/UIKit.h>          // forceRestartWithReason 弹窗用
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/task_special_ports.h>
#import <sys/stat.h>
#import <sys/resource.h>       // getrlimit / struct rlimit
#import <sys/sysctl.h>         // sysctlbyname
#import <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

//
// iOS 公开 SDK 【没有】 libproc.h（那是私有头）——
// 但 proc_pidpath / proc_pidinfo 的符号在 libSystem 里是稳定存在的。
// 所以自己声明原型，不 #import <libproc.h>。
//
// ★ 本文件是 .mm（ObjC++），必须用 extern "C" 包住，
//   否则 C++ 会做名字改编，链接期找不到 _proc_pidpath（构建 #14 就是这么挂的）。
//
extern "C" {
    int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
    int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
}

// 分析里已证的两个常量
#ifndef TASK_KERNEL_PORT
#define TASK_KERNEL_PORT 4
#endif
#ifndef HOST_PRIV_PORT
#define HOST_PRIV_PORT 1
#endif
#ifndef HOST_NODENAME
#define HOST_NODENAME 0
#endif
// mach/task_special_ports.h 里 host 端口那一项（不同 SDK 命名不一，用数字兜底）
#ifndef TASK_HOST_PORT
#define TASK_HOST_PORT 3
#endif

@implementation MFProcessInfo
- (NSString *)description {
    return [NSString stringWithFormat:@"<%d %@ (%@) port=%u>", self.pid, self.name, self.path, self.taskPort];
}
@end

@interface MFKernel ()
@property (nonatomic, assign) MFKernelState state;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, assign) uint64_t kbase;
@property (nonatomic, assign) uint64_t kslide;
@property (nonatomic, assign) uint64_t puafPages;
@property (nonatomic, assign) uint32_t kernelTaskPort;
@property (nonatomic, assign) uint32_t hostPrivPort;
@property (nonatomic, assign) MFEnumRoute cachedRoute;
@end

@implementation MFKernel

+ (instancetype)shared {
    static MFKernel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFKernel alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = MFKernelStateIdle;
        _puafPages = 2048;
        _cachedRoute = MFEnumRouteNone;
    }
    return self;
}

#pragma mark - 状态

- (BOOL)isOpen { return mf_is_open() != 0; }

- (NSString *)statusText {
    switch (self.state) {
        case MFKernelStateIdle:
            return @"未启动";
        case MFKernelStateRunning:
            return [NSString stringWithFormat:@"已启动 · kbase 0x%llx · kslide 0x%llx",
                    self.kbase, self.kslide];
        case MFKernelStateFailed:
            return [NSString stringWithFormat:@"失败：%@", self.lastError ?: @"未知"];
    }
    return @"未知";
}

- (MFEnumRoute)availableRoute {
    if (self.cachedRoute != MFEnumRouteNone) return self.cachedRoute;
    return [self detectRoute];
}

#pragma mark - 启动

- (void)startWithPuafPages:(uint64_t)pages
                completion:(void (^)(BOOL, NSString *))completion {
    if (self.state == MFKernelStateRunning && [self isOpen]) {
        if (completion) completion(YES, @"内核已在运行");
        return;
    }
    self.puafPages = pages;
    self.state = MFKernelStateRunning;
    self.lastError = @"";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 顺序严格对齐 kfd 上游：先做机型/环境预检，再 kopen
        NSString *ver = [NSString stringWithUTF8String:mf_kernel_version() ?: "?"];
        NSLog(@"[MF][Kernel] kern.version = %@", ver);

        // ── 环境预检：fd 上限 ──
        // 依据 kfd-移植清单.md §9.4：
        //   kread_sem_open 要为每个 id 开一个 sem_open → 一个 fd，
        //   峰值用量 ≈ maxfilesperproc - 100。iOS 上通常 10240。
        //   若 hard limit 被压低，setrlimit 抬高会 EPERM → 断言失败。
        //   这是第一次装机最该先看的一行日志。
        struct rlimit rl = {0, 0};
        if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
            NSLog(@"[MF][Kernel] RLIMIT_NOFILE  soft=%llu hard=%llu（KFD 需要 ~10000+）",
                  (unsigned long long)rl.rlim_cur, (unsigned long long)rl.rlim_max);
        } else {
            NSLog(@"[MF][Kernel] getrlimit 失败 errno=%d", errno);
        }
        int mfp = 0;
        size_t mfpSize = sizeof(mfp);
        if (sysctlbyname("kern.maxfilesperproc", &mfp, &mfpSize, NULL, 0) == 0) {
            NSLog(@"[MF][Kernel] kern.maxfilesperproc = %d → KFD 批量分配约需 %d 个 fd",
                  mfp, mfp > 100 ? mfp - 100 : 0);
        }
        NSLog(@"[MF][Kernel] 身份 %@", [self identityText]);

        BOOL isM = [ver containsString:@"T8103"] || [ver containsString:@"T8112"];
        NSLog(@"[MF][Kernel] 机型判定：%@（arm64_link_addr 将由 patchfinder 定）",
              isM ? @"M 系列" : @"A 系列");

        // 16.6.1 上唯一可用：landa + sem_open 组合
        int rc = mf_kopen(pages,
                          2,   // puaf_landa
                          1,   // kread_sem_open
                          1);  // kwrite_sem_open

        dispatch_async(dispatch_get_main_queue(), ^{
            if (rc != 0) {
                self.state = MFKernelStateFailed;
                self.lastError = [NSString stringWithUTF8String:mf_last_error() ?: "kopen 失败"];
                NSLog(@"[MF][Kernel] kopen 失败: %@", self.lastError);
                if (completion) completion(NO, self.lastError);
                return;
            }
            self.state = MFKernelStateRunning;
            self.kbase  = mf_get_kbase();
            self.kslide = mf_get_kslide();
            NSLog(@"[MF][Kernel] kopen 成功 kbase=0x%llx kslide=0x%llx", self.kbase, self.kslide);

            // 顺带把内核端口也拿了（原实现第 2 层）
            [self fetchKernelTaskPort];

            NSString *msg = [NSString stringWithFormat:
                             @"内核已启动\n\nkbase  = 0x%llx\nkslide = 0x%llx\npuaf_pages = %llu\n"
                             @"内核任务端口 = 0x%x",
                             self.kbase, self.kslide, pages, self.kernelTaskPort];
            if (completion) completion(YES, msg);
        });
    });
}

- (void)stop {
    mf_kclose();
    self.state = MFKernelStateIdle;
    self.kbase = self.kslide = 0;
    NSLog(@"[MF][Kernel] 已关闭");
}

#pragma mark - 提权（原实现第 1 层）

- (BOOL)gainRootWithError:(NSString **)err {
    // 对齐 sub_1009BAF8C：整组执行两遍
    for (int pass = 0; pass < 2; pass++) {
        setgid(0);
        setregid(0, 0);
        setuid(0);
        setreuid(0, 0);
    }
    if (getuid() != 0 && geteuid() != 0) {
        if (err) {
            *err = [NSString stringWithFormat:@"提权未生效（uid=%d euid=%d errno=%d）",
                    getuid(), geteuid(), errno];
        }
        return NO;
    }
    NSLog(@"[MF][Kernel] 提权成功 uid=%d euid=%d", getuid(), geteuid());
    return YES;
}

- (NSString *)identityText {
    return [NSString stringWithFormat:@"uid=%d euid=%d gid=%d egid=%d",
            getuid(), geteuid(), getgid(), getegid()];
}

#pragma mark - 内核端口（原实现第 2 层）

/// 对齐 sub_1008F0290：task_get_special_port(task_self, 4, &port)
- (uint32_t)fetchKernelTaskPort {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = task_get_special_port(mach_task_self(), TASK_KERNEL_PORT, &port);
    if (kr != KERN_SUCCESS || port == MACH_PORT_NULL) {
        NSLog(@"[MF][Kernel] 取内核端口失败 kr=0x%x（非越狱/无 tfp0 时的正常结果）", kr);
        return 0;
    }
    self.kernelTaskPort = port;
    NSLog(@"[MF][Kernel] 内核任务端口 = 0x%x", port);

    // 拿 host_priv：两条路都试，哪条通用哪条
    mach_port_t hp = MACH_PORT_NULL;

    // ① 先从内核任务端口要 host 端口，再拿 host_priv
    kern_return_t kr2 = task_get_special_port(port, TASK_HOST_PORT, &hp);
    if (kr2 == KERN_SUCCESS && hp != MACH_PORT_NULL) {
        mach_port_t priv = MACH_PORT_NULL;
        if (host_get_special_port(hp, HOST_NODENAME, HOST_PRIV_PORT, &priv) == KERN_SUCCESS
            && priv != MACH_PORT_NULL) {
            self.hostPrivPort = priv;
            NSLog(@"[MF][Kernel] host_priv（经内核任务端口）= 0x%x", priv);
            return port;
        }
    }

    // ② 直接向自己的 host 端口要（已 root / 已带 platform-application 时可能成功）
    hp = MACH_PORT_NULL;
    kr2 = host_get_special_port(mach_host_self(), HOST_NODENAME, HOST_PRIV_PORT, &hp);
    if (kr2 == KERN_SUCCESS && hp != MACH_PORT_NULL) {
        self.hostPrivPort = hp;
        NSLog(@"[MF][Kernel] host_priv（直接） = 0x%x", hp);
    } else {
        NSLog(@"[MF][Kernel] 两条路都没拿到 host_priv（kr=0x%x）—— 路 A 不可用，走免特权路 B", kr2);
    }
    return port;
}

#pragma mark - 枚举路由探测

- (MFEnumRoute)detectRoute {
    // 路 B 优先探测（免特权，纯巨魔也能走）
    processor_set_t pset = MACH_PORT_NULL;
    if (processor_set_default(mach_host_self(), &pset) == KERN_SUCCESS && pset != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), pset);
        self.cachedRoute = MFEnumRouteDefault;
        return MFEnumRouteDefault;
    }
    // 路 A
    if (self.hostPrivPort != MACH_PORT_NULL) {
        self.cachedRoute = MFEnumRoutePrivileged;
        return MFEnumRoutePrivileged;
    }
    self.cachedRoute = MFEnumRouteNone;
    return MFEnumRouteNone;
}

- (void)probeCapabilitiesWithCompletion:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *r = [NSMutableString string];

        [r appendFormat:@"内核编译串：\n%s\n\n", mf_kernel_version() ?: "?"];
        [r appendFormat:@"身份：%@\n", [self identityText]];
        [r appendFormat:@"kfd 是否已开：%@\n\n", mf_is_open() ? @"是" : @"否"];

        // 内核端口
        mach_port_t kp = MACH_PORT_NULL;
        kern_return_t kr = task_get_special_port(mach_task_self(), TASK_KERNEL_PORT, &kp);
        [r appendFormat:@"task_get_special_port(TASK_KERNEL_PORT)：\n  kr=0x%x port=0x%x %@\n\n",
         kr, kp, (kr == KERN_SUCCESS && kp) ? @"✓ 有 tfp0" : @"× 无（非越狱/权限不足）"];

        // 路 B
        processor_set_t ps = MACH_PORT_NULL;
        kern_return_t kr2 = processor_set_default(mach_host_self(), &ps);
        [r appendFormat:@"路 B  processor_set_default：\n  kr=0x%x %@\n\n",
         kr2, (kr2 == KERN_SUCCESS && ps) ? @"✓ 可用（免特权）" : @"× 不可用"];
        if (ps) mach_port_deallocate(mach_task_self(), ps);

        // 路 A（要 host_priv）
        mach_port_t host = mach_host_self();
        processor_set_name_array_t sets = NULL;
        natural_t setCnt = 0;
        kern_return_t kr3 = host_processor_sets(host, &sets, &setCnt);
        [r appendFormat:@"路 A  host_processor_sets：\n  kr=0x%x 集合数=%u %@\n\n",
         kr3, setCnt, kr3 == KERN_SUCCESS ? @"✓" : @"×"];
        if (sets) vm_deallocate(mach_task_self(), (vm_address_t)sets, setCnt * sizeof(mach_port_t));

        // 实际试枚举一次
        NSString *err = nil;
        NSArray<MFProcessInfo *> *procs = [self enumerateProcessesWithRoute:MFEnumRouteNone error:&err];
        if (procs.count) {
            [r appendFormat:@"枚举结果：✓ 拿到 %lu 个进程（走 %@）\n",
             (unsigned long)procs.count,
             self.cachedRoute == MFEnumRoutePrivileged ? @"路 A" : @"路 B"];
            for (MFProcessInfo *p in [procs subarrayWithRange:NSMakeRange(0, MIN(5, procs.count))]) {
                [r appendFormat:@"  %d  %@\n", p.pid, p.name];
            }
        } else {
            [r appendFormat:@"枚举结果：× 失败\n  %@\n", err ?: @"未知"];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(r);
        });
    });
}

#pragma mark - 进程枚举（原实现第 3 层）

- (NSArray<MFProcessInfo *> *)enumerateProcessesWithRoute:(MFEnumRoute)route
                                                    error:(NSString **)err {
    if (route == MFEnumRouteNone) {
        route = [self detectRoute];
    }
    processor_set_t pset = MACH_PORT_NULL;
    kern_return_t kr;

    if (route == MFEnumRoutePrivileged) {
        // 路 A：host_processor_sets → host_processor_set_priv → processor_set_tasks
        mach_port_t host = mach_host_self();
        processor_set_name_array_t sets = NULL;
        natural_t setCnt = 0;
        kr = host_processor_sets(host, &sets, &setCnt);
        if (kr != KERN_SUCCESS || !sets || setCnt == 0) {
            if (err) *err = [NSString stringWithFormat:@"host_processor_sets kr=0x%x", kr];
            return @[];
        }
        mach_port_t hostPriv = self.hostPrivPort;
        if (hostPriv == MACH_PORT_NULL) {
            // 再试一次直接要
            host_get_special_port(mach_host_self(), HOST_NODENAME, HOST_PRIV_PORT, &hostPriv);
            self.hostPrivPort = hostPriv;
        }
        if (hostPriv == MACH_PORT_NULL) {
            vm_deallocate(mach_task_self(), (vm_address_t)sets, setCnt * sizeof(mach_port_t));
            if (err) *err = @"路 A 拿不到 host_priv（权限门槛）";
            return @[];
        }
        kr = host_processor_set_priv(hostPriv, sets[0], &pset);
        vm_deallocate(mach_task_self(), (vm_address_t)sets, setCnt * sizeof(mach_port_t));
        if (kr != KERN_SUCCESS || pset == MACH_PORT_NULL) {
            if (err) *err = [NSString stringWithFormat:@"host_processor_set_priv kr=0x%x", kr];
            return @[];
        }
    } else {
        // 路 B：processor_set_default（免特权）
        kr = processor_set_default(mach_host_self(), &pset);
        if (kr != KERN_SUCCESS || pset == MACH_PORT_NULL) {
            if (err) *err = [NSString stringWithFormat:@"processor_set_default kr=0x%x", kr];
            return @[];
        }
    }

    // processor_set_tasks（两条路共用）
    mach_port_array_t tasks = NULL;
    natural_t taskCnt = 0;
    kr = processor_set_tasks(pset, &tasks, &taskCnt);
    mach_port_deallocate(mach_task_self(), pset);

    if (kr != KERN_SUCCESS || !tasks) {
        if (err) *err = [NSString stringWithFormat:@"processor_set_tasks kr=0x%x", kr];
        return @[];
    }

    NSMutableArray<MFProcessInfo *> *out = [NSMutableArray arrayWithCapacity:taskCnt];
    char path[0x400];
    for (natural_t i = 0; i < taskCnt; i++) {
        memset(path, 0, sizeof(path));
        // 对标原实现：proc_pidpath + strrchr('/') + strncmp
        if (proc_pidpath(tasks[i], path, sizeof(path)) <= 0) {
            mach_port_deallocate(mach_task_self(), tasks[i]);
            continue;
        }
        char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (base[0] == '\0') {
            mach_port_deallocate(mach_task_self(), tasks[i]);
            continue;
        }
        int pid = 0;
        pid_for_task(tasks[i], &pid);

        MFProcessInfo *pi = [[MFProcessInfo alloc] init];
        pi.pid = pid;
        pi.name = [NSString stringWithUTF8String:base] ?: @"?";
        pi.path = [NSString stringWithUTF8String:path] ?: @"?";
        pi.taskPort = tasks[i];
        [out addObject:pi];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)tasks, taskCnt * sizeof(mach_port_t));

    NSLog(@"[MF][Kernel] 枚举到 %lu 个进程（路 %@）", (unsigned long)out.count,
          route == MFEnumRoutePrivileged ? @"A" : @"B");
    [out sortUsingComparator:^NSComparisonResult(MFProcessInfo *a, MFProcessInfo *b) {
        return a.pid < b.pid ? NSOrderedAscending : (a.pid > b.pid ? NSOrderedDescending : NSOrderedSame);
    }];
    return out;
}

- (MFProcessInfo *)findProcessNamed:(NSString *)name {
    NSArray<MFProcessInfo *> *all = [self enumerateProcessesWithRoute:MFEnumRouteNone error:NULL];
    size_t want = name.length;
    for (MFProcessInfo *p in all) {
        if (strncmp(p.name.UTF8String, name.UTF8String, want) == 0) return p;
    }
    return nil;
}

#pragma mark - 诊断

+ (NSString *)kernelLog {
    char *raw = mf_read_klog();
    if (raw == NULL) {
        return @"（还没有内核日志 —— 先去跑一次「启动内核」）";
    }
    NSString *s = [NSString stringWithUTF8String:raw];
    free(raw);
    return s.length ? s : @"（日志为空）";
}

+ (void)forceRestartWithReason:(NSString *)reason {
    NSLog(@"[MF][Kernel] 准备重启 App：%@", reason);

    UIViewController *top = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { top = w.rootViewController; break; }
        }
    }
    while (top.presentedViewController) top = top.presentedViewController;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"需要重启 App"
                         message:[NSString stringWithFormat:
                                  @"%@\n\n"
                                  @"为什么必须重启：\n"
                                  @"· KFD 失败时已在进程里占住约 1 万个文件描述符，无法安全回收\n"
                                  @"· 内核态可能残留未清理的 PUAF 页\n"
                                  @"· 原地重试会导致 kernel panic（你已经遇到过了）\n\n"
                                  @"点「现在退出」后重新打开本 App 即可。",
                                  reason ?: @""]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"现在退出"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *_) {
        NSLog(@"[MF][Kernel] 用户确认退出，exit(0)");
        exit(0);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *_) {
        NSLog(@"[MF][Kernel] 用户选择稍后 —— 再试有 panic 风险");
    }]];

    if (top) {
        [top presentViewController:a animated:YES completion:nil];
    } else {
        NSLog(@"[MF][Kernel] 没有可用 VC，直接退出");
        exit(0);
    }
}

#pragma mark - 内核读写

- (BOOL)kreadAddress:(uint64_t)kaddr into:(void *)out size:(uint64_t)size {
    if (![self isOpen]) return NO;
    return mf_kread(kaddr, out, size) == 0;
}

- (BOOL)kwriteValue:(const void *)in toAddress:(uint64_t)kaddr size:(uint64_t)size {
    if (![self isOpen]) return NO;
    return mf_kwrite((void *)in, kaddr, size) == 0;
}

@end
