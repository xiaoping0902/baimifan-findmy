//
//  MFKernel.mm — 内核会话（实现）
//
#import "MFKernel.h"
#import "MFKernelBridge.h"
#import "../App/MFDebugExport.h"   // [M5.11] 内核失败时自动把日志镜像到 Media

#import <UIKit/UIKit.h>          // forceRestartWithReason 弹窗用
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/task_special_ports.h>
#import <sys/stat.h>
#import <sys/resource.h>       // getrlimit / struct rlimit
#import <sys/sysctl.h>         // sysctlbyname
#import <os/proc.h>            // os_proc_available_memory
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
// iOS SDK 的 <mach/host_special_ports.h> 可能没有被间接引入，
// HOST_NODENAME 是 host_get_special_port() 的 flavor 参数（值为 5）。
#ifndef HOST_NODENAME
#define HOST_NODENAME 5
#endif

// [M5.207] MFGetTaskPortViaProcessorSet 已删除：它走 processor_set_tasks
// 取 target task port，而端口不再参与任何读取路径。
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

/*
 * ★★ [M5.12] PUAF 页数应该按设备内存自动选 ★★
 *
 * 依据：Dopamine（久经考验的越狱工具）的 exploit_init 原文 ——
 *
 *     int puaf_pages = 512;
 *     if (device_memory >= 5GB) {                 // 6GB 及以上设备
 *         // These devices are remarkably more reliable with 3072
 *         puaf_pages = 3072;
 *     } else if (cpuFamily == CPUFAMILY_ARM_TWISTER) {   // A9
 *         puaf_pages = 128;
 *         if (@available(iOS 16.0, *)) { puaf_pages = 160; }   // sem_open 不喜欢 128
 *     } else if (cpuFamily == CPUFAMILY_ARM_TYPHOON) {   // A8
 *         puaf_pages = 256;
 *     }
 *
 * Dopamine 对 6GB 设备的原话是「remarkably more reliable with 3072」。
 *
 * 我们之前一直用 2048 —— grab_free_pages 的目标是 pages/4：
 *     2048 → 512      3072 → 768
 * 页数越多，悬空页越多，vm_copy 复用到其中某个的概率越高。
 * 这是 Dopamine 实测出来的结论，不是推测。
 *
 * 本机（iPad8,11 / A12Z）hw.memsize ≈ 6GB → 应该用 3072。
 */
+ (uint64_t)recommendedPuafPages {
    const MFDeviceConfiguration device = mf_current_device_configuration();
    NSLog(@"[MF][Kernel] 设备配置 status=%d method=%d pages=%llu", device.status,
          device.method, (unsigned long long)device.pages);
    return device.pages;
}

/// 当前进程可用内存 —— Dopamine 用它做 hog 决策，我们用它做诊断
+ (size_t)availableMemory {
    return os_proc_available_memory();
}

/*
 * ★ 进程级「已失败，禁止再试」闸门（[MF PATCH 10]）
 *
 * 2026-10-15 真机紫屏的教训：KFD 一旦失败一次，这个进程就已经不干净了 ——
 *   · fd 表被 kread_sem_open 占掉一大半（kpopen 失败路径也会留下残留）
 *   · 内核态可能还有没回收干净的 PUAF 页
 * 再点一次「启动内核」，等于往内核里再叠一份泄漏，几轮之后必然 panic。
 *
 * 所以：失败过一次就直接锁死，只允许退出 App 重来。
 * 这是一道【代码层】的闸门 —— 光靠弹窗提醒是不够的，用户会点「稍后」。
 */
static BOOL gMFKernelPoisoned = NO;

- (void)startWithPuafPages:(uint64_t)pages
                completion:(void (^)(BOOL, NSString *))completion {
    if (gMFKernelPoisoned) {
        NSString *msg =
            @"本次运行已经失败过一次，为安全起见【禁止再次尝试】。\n\n"
            @"原因：KFD 失败时会在内核里留下未回收的悬空页、并占住约 1 万个 fd。\n"
            @"原地重试会叠加泄漏，几次之后内核会崩（你已经遇到过紫屏）。\n\n"
            @"请完全退出本 App（上滑杀掉），再重新打开。";
        self.lastError = msg;
        NSLog(@"[MF][Kernel] ⛔ 已锁定，拒绝再次尝试");
        if (completion) completion(NO, msg);
        return;
    }

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

        /* Select one method for the current OS. Do not cycle through methods
         * after failure: partial attempts can leave kernel state behind. */
        // The old persisted selection can be invalid after moving devices.
        // Use the same OS/chip policy as HUD automatic startup.
        const MFDeviceConfiguration device = mf_current_device_configuration();
        NSInteger pm = device.method;

        NSLog(@"[MF][Kernel] 开始 kopen：pages=%llu method=%ld（0=physpuppet 1=smith 2=landa）",
              (unsigned long long)pages, (long)pm);

        int rc = mf_kopen_for_device(pages);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (rc != 0) {
                self.state = MFKernelStateFailed;
                /*
                 * [M5.135] rc == -4 = 另一个进程已经持有内核（跨进程哨兵）。
                 * 这种情况内核一个字节都没动，【不能】算成失败上锁 ——
                 * 否则用户关掉悬浮窗之后还得重启 App 才能再连。
                 */
                if (rc != -4 && rc != -5) {
                    gMFKernelPoisoned = YES;
                }
                self.lastError = [NSString stringWithUTF8String:mf_last_error() ?: "kopen 失败"];
                NSLog(@"[MF][Kernel] kopen 失败: %@ —— %@", self.lastError,
                      (rc == -4 || rc == -5) ? @"未执行内核操作"
                                 : @"已上锁，需重启 App");
                /* [M5.11] 自动把内核日志镜像到 Media —— 这样电脑侧一条命令就能拉，
                   不用再让用户「点按钮 → 复制全文 → 粘贴」 */
                [MFDebugExport syncLogs];
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

// [M5.207] MFTestProcessorSet 已删除：它只为探测 processor_set_tasks 是否可用，
// 而进程枚举已经改成纯 sysctl。

/*
 * ★ 审查修正（报告 S6）：
 *   第一版的 detectRoute 只测 processor_set_default —— 那是免特权调用，
 *   【必然成功】，于是永远返回「路 B」。而真机上 processor_set_tasks
 *   紧接着就报 kr=0x4（KERN_INVALID_ARGUMENT）。
 *   判断标准必须落在 processor_set_tasks 上，不是它的前置调用。
 *
 * ★ 另外新增路 C：task_for_pid。
 *   我们的 entitlements 里本来就有 task_for_pid-allow（从设备读出来核对过），
 *   这条路根本不需要 host_priv、也不需要 processor_set。
 *   配合 sysctl(KERN_PROC_ALL) 拿 pid 列表，是当前最可能走通的一条。
 */
- (MFEnumRoute)detectRoute {
    /*
     * [M5.207] 三条「取 task port」的路（task_for_pid / host_priv / processor_set_default）
     * 全部退出进程枚举：列表改成纯 sysctl(KERN_PROC_ALL)，只读 pid / 路径 / 名字，
     * 不碰系统 task 表，也不为任何进程预取端口。
     *
     * 恒返回 MFEnumRouteNone 是刻意的 —— 它的含义从「三条路都不通」变成
     * 「枚举不再需要任何一条」。调用方看到 None 时应理解为「无需端口」，
     * 不是「权限不足」。
     */
    return MFEnumRouteNone;
}

/// [M5.207] 路 C 可用性探测已删除：它会对自身调 task_for_pid，正是要消掉的动作。

/// 进程枚举：sysctl 拿 pid 列表（纯只读，不取任何 task port）
- (NSArray<MFProcessInfo *> *)enumerateViaSysctl:(NSString **)err {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) {
        if (err) *err = [NSString stringWithFormat:@"sysctl(KERN_PROC_ALL) 取长度失败 errno=%d", errno];
        return @[];
    }
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (procs == NULL) {
        if (err) *err = @"malloc 失败";
        return @[];
    }
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        if (err) *err = [NSString stringWithFormat:@"sysctl(KERN_PROC_ALL) 取值失败 errno=%d", errno];
        return @[];
    }

    size_t n = len / sizeof(struct kinfo_proc);
    NSMutableArray<MFProcessInfo *> *out = [NSMutableArray arrayWithCapacity:n];

    for (size_t i = 0; i < n; i++) {
        int pid = procs[i].kp_proc.p_pid;
        if (pid <= 0) continue;

        char path[0x400] = {0};
        proc_pidpath(pid, path, sizeof(path));
        char *base = strrchr(path, '/');
        base = base ? base + 1 : path;

        MFProcessInfo *pi = [[MFProcessInfo alloc] init];
        pi.pid = pid;
        pi.name = (base[0] != '\0') ? ([NSString stringWithUTF8String:base] ?: @"?")
                                    : [NSString stringWithFormat:@"pid%d", pid];
        pi.path = (path[0] != '\0') ? ([NSString stringWithUTF8String:path] ?: @"?") : @"?";
        pi.taskPort = MACH_PORT_NULL;    // ★ 不再预取，点击时才 acquire
        [out addObject:pi];
    }
    free(procs);

    NSLog(@"[MF][Kernel] 路 C：列出 %zu 个进程（未取端口）", n);
    return out;
}

+ (uint32_t)acquireTaskPortForPid:(int)pid error:(NSString **)err {
    /*
     * [M5.207] 停用。
     *
     * 这个函数原本干三件事：task_for_pid →（必要时）改目标 proc 的 csflags
     * 与自身 task 的 t_flags → processor_set_tasks 回退。三者都是「碰目标进程
     * 或系统 task 表」的动作，而读取链现在完全走 KFD 页表：
     *
     *     pid → proc → pmap 根表 → 目标页表，逐页翻译后物理读
     *
     * 也就是说，目标 task port 已经不在任何一条读取路径上。留着这条获取链只会
     * 让「游戏进程里存在一个被外部持有的 task port」这件事继续成立。
     *
     * 保留签名只为让调用点继续编译：一律返回 MACH_PORT_NULL，并明确说明原因，
     * 免得调用方误以为「端口失败 = 读取没准备好」而反复重试。
     */
    (void)pid;
    if (err) {
        *err = @"task_for_pid 已在 M5.207 停用：读取只走 KFD 页表，不需要目标 task port";
    }
    return MACH_PORT_NULL;
}

- (void)probeCapabilitiesWithCompletion:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *r = [NSMutableString string];

        [r appendFormat:@"内核编译串：\n%s\n\n", mf_kernel_version() ?: "?"];
        [r appendFormat:@"身份：%@\n", [self identityText]];
        [r appendFormat:@"kfd 是否已开：%@\n\n", mf_is_open() ? @"是" : @"否"];

        /*
         * [M5.207] 权限自检不再碰 processor_set / host_processor_sets。
         *
         * 那三个调用原来是为了回答"哪条路能枚举 task"，而枚举已经改成
         * sysctl(KERN_PROC_ALL) —— 不需要任何 processor_set，也不需要
         * task_get_special_port 之外的任何特权端口。留在这里只会让"自检"
         * 顺手去碰系统 task 表，与"读取链上没有受限 API"的目标相矛盾。
         *
         * 现在只报两件真正相关的事：本进程有没有内核端口（越狱态标志），
         * 以及 sysctl 枚举能不能列出进程。
         */
        mach_port_t kp = MACH_PORT_NULL;
        kern_return_t kr = task_get_special_port(mach_task_self(), TASK_KERNEL_PORT, &kp);
        [r appendFormat:@"task_get_special_port(TASK_KERNEL_PORT)：\n  kr=0x%x port=0x%x %@\n\n",
         kr, kp, (kr == KERN_SUCCESS && kp) ? @"✓ 有 tfp0" : @"× 无（非越狱/权限不足）"];
        if (kp) mach_port_deallocate(mach_task_self(), kp);

        [r appendString:@"进程枚举：sysctl(KERN_PROC_ALL)（不需要 task port / processor_set）\n\n"];

        // 实际试枚举一次
        NSString *err = nil;
        NSArray<MFProcessInfo *> *procs = [self enumerateProcessesWithRoute:MFEnumRouteNone error:&err];
        if (procs.count) {
            [r appendFormat:@"枚举结果：✓ 拿到 %lu 个进程\n", (unsigned long)procs.count];
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
    /*
     * [M5.207] 只留 sysctl 一条路。
     *
     * 原来的路 C（task_for_pid）、路 A（host_priv + processor_set_tasks）、
     * 路 B（processor_set_default + processor_set_tasks）都要求或返回 task port，
     * 而端口已经从读取链上整体退场。进程列表只需要 pid / 路径 / 名字 ——
     * sysctl(KERN_PROC_ALL) 全给，且不碰任何 task 表。
     *
     * route 参数保留只为兼容调用点：传什么都走同一条路。
     */
    (void)route;
    NSMutableArray<MFProcessInfo *> *out =
        [[self enumerateViaSysctl:err] mutableCopy] ?: [NSMutableArray array];
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

+ (NSString *)kernelVersion {
    const char *v = mf_kernel_version();
    return (v != NULL && v[0] != '\0') ? [NSString stringWithUTF8String:v] : @"";
}

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
