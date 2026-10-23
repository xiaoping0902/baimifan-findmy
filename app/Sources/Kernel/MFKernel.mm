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

/*
 * ★★★ [M5.78] 用 processor_set_tasks 拿 task port ★★★
 *
 * 为什么需要它：
 *   task_for_pid 对 App Store 正版应用（尤其带反作弊的游戏）会返回
 *   kr=0x5 KERN_FAILURE —— 这是 taskgated 按代码签名标志（CS_HARD/CS_RESTRICT）
 *   拒绝，跟我们的 entitlement 无关。三角洲行动带 ACE 反作弊，实测就是 0x5。
 *
 *   processor_set_tasks 走的是另一条内核路径：先拿 processor_set 端口，
 *   再让内核把**全系统 task 端口数组**一次性交出来，不经过 taskgated 的
 *   code-signing 检查。白米饭的「内核端口 → 枚举 task → 端口缓存」就是这条路。
 *
 * 注意：拿到的端口要自己 mach_port_deallocate；数组本身用 vm_deallocate。
 */
static uint32_t MFGetTaskPortViaProcessorSet(int targetPid, NSString **errOut) {
    #define MF_PS_FAIL(fmt, ...) do {                                        \
        if (errOut) *errOut = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
        return MACH_PORT_NULL;                                                \
    } while (0)

    // 先试免特权的 processor_set_default；失败再试 host_priv 那条
    processor_set_t pset = MACH_PORT_NULL;
    kern_return_t kr = processor_set_default(mach_host_self(), &pset);
    NSString *firstFailure = nil;

    if (kr != KERN_SUCCESS || pset == MACH_PORT_NULL) {
        firstFailure = [NSString stringWithFormat:@"processor_set_default kr=0x%x", kr];

        mach_port_t hostPriv = MACH_PORT_NULL;
        host_get_special_port(mach_host_self(), HOST_NODENAME, HOST_PRIV_PORT, &hostPriv);
        if (hostPriv != MACH_PORT_NULL) {
            processor_set_name_array_t sets = NULL;
            natural_t setCnt = 0;
            if (host_processor_sets(mach_host_self(), &sets, &setCnt) == KERN_SUCCESS && sets) {
                if (setCnt > 0) {
                    kr = host_processor_set_priv(hostPriv, sets[0], &pset);
                }
                vm_deallocate(mach_task_self(), (vm_address_t)sets, setCnt * sizeof(mach_port_t));
            }
            mach_port_deallocate(mach_task_self(), hostPriv);
            if (kr != KERN_SUCCESS || pset == MACH_PORT_NULL) {
                MF_PS_FAIL(@"%@；host_priv 路也失败 kr=0x%x", firstFailure, kr);
            }
        } else {
            MF_PS_FAIL(@"%@；且拿不到 host_priv", firstFailure);
        }
    }

    mach_port_array_t tasks = NULL;
    natural_t taskCnt = 0;
    kr = processor_set_tasks(pset, &tasks, &taskCnt);
    mach_port_deallocate(mach_task_self(), pset);
    if (kr != KERN_SUCCESS || tasks == NULL) {
        MF_PS_FAIL(@"processor_set_tasks kr=0x%x", kr);
    }

    uint32_t found = MACH_PORT_NULL;
    for (natural_t i = 0; i < taskCnt; i++) {
        if (tasks[i] == MACH_PORT_NULL) continue;
        int tpid = 0;
        if (pid_for_task(tasks[i], &tpid) == KERN_SUCCESS && tpid == targetPid) {
            found = tasks[i];
            tasks[i] = MACH_PORT_NULL;       // 归我们了，别在下面释放
            continue;
        }
        mach_port_deallocate(mach_task_self(), tasks[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)tasks, taskCnt * sizeof(mach_port_t));

    if (found == MACH_PORT_NULL) {
        MF_PS_FAIL(@"枚举了 %u 个 task，里面没有 pid=%d", (unsigned)taskCnt, targetPid);
    }
    #undef MF_PS_FAIL
    return found;
}
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
    uint64_t mem = 0;
    size_t sz = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &sz, NULL, 0) != 0) mem = 0;

    int cpuFamily = 0;
    size_t cs = sizeof(cpuFamily);
    sysctlbyname("hw.cpufamily", &cpuFamily, &cs, NULL, 0);

    // CPUFAMILY_ARM_TWISTER = A9 = 0x37b32da7
    const int kTwister = 0x37b32da7;
    // CPUFAMILY_ARM_TYPHOON = A8 = 0x37a09642
    const int kTyphoon = 0x37a09642;

    uint64_t pages = 512;
    if (mem >= 5ULL * 1024 * 1024 * 1024) {
        pages = 3072;                       // ★ 6GB+ 设备（Dopamine 的推荐值）
    } else if (cpuFamily == kTwister) {
        pages = 160;                        // A9 + iOS16（128 会被 sem_open 拒绝）
    } else if (cpuFamily == kTyphoon) {
        pages = 256;                        // A8
    }

    NSLog(@"[MF][Kernel] 自动 PUAF 页数：%llu  （RAM=%.2fGB cpufamily=0x%x）",
          (unsigned long long)pages, mem / 1073741824.0, cpuFamily);
    return pages;
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

        /*
         * [M5.11] PUAF 方法可切换
         *
         * 真机证据：landa 路径下 grab_free_pages 历史最好恒为 0/256，
         * 99999 轮一次都没命中 —— 这不是随机性问题，是【结构性】的，
         * 说明 landa 在这台机器上根本没建立悬空页。
         *
         * 所以把方法做成可切换，让用户能试另外两条：
         *   0 = physpuppet
         *   1 = smith
         *   2 = landa（默认）
         *
         * 注意：kread/kwrite 仍必须是 sem_open(1/1) —— 16.3+ 上 kqueue_workloop_ctl 已废。
         */
        NSInteger pm = [[NSUserDefaults standardUserDefaults] integerForKey:@"mf.kfd.puafMethod"];
        if (pm < 0 || pm > 2) pm = 2;      // 默认 landa

        NSLog(@"[MF][Kernel] 开始 kopen：pages=%llu method=%ld（0=physpuppet 1=smith 2=landa）",
              (unsigned long long)pages, (long)pm);

        int rc = mf_kopen(pages,
                          (int)pm,   // PUAF 方法（可切换）
                          1,         // kread_sem_open
                          1);        // kwrite_sem_open

        dispatch_async(dispatch_get_main_queue(), ^{
            if (rc != 0) {
                self.state = MFKernelStateFailed;
                /* ★ 上锁：本次运行内不允许再试，见 gMFKernelPoisoned 说明 */
                gMFKernelPoisoned = YES;
                self.lastError = [NSString stringWithUTF8String:mf_last_error() ?: "kopen 失败"];
                NSLog(@"[MF][Kernel] kopen 失败: %@ —— 已上锁，需重启 App", self.lastError);
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

/// 试探某个 processor_set 能不能真的拿出 task 列表
static kern_return_t MFTestProcessorSet(processor_set_t pset) {
    if (pset == MACH_PORT_NULL) return KERN_INVALID_ARGUMENT;
    mach_port_array_t tasks = NULL;
    natural_t cnt = 0;
    kern_return_t kr = processor_set_tasks(pset, &tasks, &cnt);
    if (kr == KERN_SUCCESS && tasks != NULL && cnt > 0) {
        vm_deallocate(mach_task_self(), (vm_address_t)tasks, cnt * sizeof(mach_port_t));
    }
    return kr;
}

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
    if (self.cachedRoute != MFEnumRouteNone) return self.cachedRoute;

    // 路 C：task_for_pid（靠 entitlement，最优先）
    if ([self taskForPidAvailable]) {
        self.cachedRoute = MFEnumRouteTaskForPid;
        NSLog(@"[MF][Kernel] 路由探测 → 路 C task_for_pid 可用");
        return MFEnumRouteTaskForPid;
    }

    // 路 A：host_priv
    if (self.hostPrivPort != MACH_PORT_NULL) {
        processor_set_name_array_t sets = NULL;
        natural_t setCnt = 0;
        if (host_processor_sets(mach_host_self(), &sets, &setCnt) == KERN_SUCCESS && sets) {
            processor_set_t pset = MACH_PORT_NULL;
            kern_return_t kr = host_processor_set_priv(self.hostPrivPort, sets[0], &pset);
            vm_deallocate(mach_task_self(), (vm_address_t)sets, setCnt * sizeof(mach_port_t));
            if (kr == KERN_SUCCESS) {
                kr = MFTestProcessorSet(pset);
                mach_port_deallocate(mach_task_self(), pset);
                if (kr == KERN_SUCCESS) {
                    self.cachedRoute = MFEnumRoutePrivileged;
                    NSLog(@"[MF][Kernel] 路由探测 → 路 A host_priv 可用");
                    return MFEnumRoutePrivileged;
                }
            }
            NSLog(@"[MF][Kernel] 路 A 试探失败 kr=0x%x", kr);
        }
    }

    // 路 B：processor_set_default（免特权）—— 必须真的测 processor_set_tasks
    processor_set_t pset = MACH_PORT_NULL;
    if (processor_set_default(mach_host_self(), &pset) == KERN_SUCCESS) {
        kern_return_t kr = MFTestProcessorSet(pset);
        mach_port_deallocate(mach_task_self(), pset);
        if (kr == KERN_SUCCESS) {
            self.cachedRoute = MFEnumRouteDefault;
            NSLog(@"[MF][Kernel] 路由探测 → 路 B 免特权可用");
            return MFEnumRouteDefault;
        }
        NSLog(@"[MF][Kernel] 路 B processor_set_tasks 失败 kr=0x%x —— 这条路其实不通", kr);
    }

    NSLog(@"[MF][Kernel] 三条枚举路全不通");
    return MFEnumRouteNone;
}

/// 路 C 可用性：能不能对一个真实 pid 拿到 task port
- (BOOL)taskForPidAvailable {
    mach_port_t t = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), getpid(), &t);
    if (kr == KERN_SUCCESS && t != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), t);
        return YES;
    }
    NSLog(@"[MF][Kernel] task_for_pid(self) kr=0x%x（task_for_pid-allow 未生效？）", kr);
    return NO;
}

/// 路 C：sysctl 拿 pid 列表（★ 不再逐个取 task port，见 acquireTaskPortForPid）
- (NSArray<MFProcessInfo *> *)enumerateViaTaskForPid:(NSString **)err {
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
    if (pid <= 0) {
        if (err) *err = @"pid 非法";
        return MACH_PORT_NULL;
    }

    // ── ① 首选 task_for_pid（有 entitlement 时最快、权限最全）──
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr == KERN_SUCCESS && task != MACH_PORT_NULL) {
        NSLog(@"[MF][Kernel] 按需取得 pid=%d 的 task port=0x%x（task_for_pid）", pid, task);
        return task;
    }
    NSLog(@"[MF][Kernel] task_for_pid(%d) kr=0x%x → 改试 processor_set_tasks", pid, kr);

    // ── ② 回退：processor_set_tasks（不走 taskgated 的代码签名检查）──
    NSString *psError = nil;
    uint32_t fallback = MFGetTaskPortViaProcessorSet(pid, &psError);
    if (fallback != MACH_PORT_NULL) {
        NSLog(@"[MF][Kernel] 按需取得 pid=%d 的 task port=0x%x（processor_set_tasks）", pid, fallback);
        return fallback;
    }

    // ── ③ 两条都不通，给出能区分原因的诊断 ──
    if (err) {
        NSString *hint;
        switch (kr) {
            case KERN_FAILURE:
                hint = @"kr=0x5 KERN_FAILURE —— 目标进程带反调试/CS_HARD 签名保护（ACE 反作弊），"
                       @"taskgated 拒绝，与我们的 entitlement 无关";
                break;
            case KERN_PROTECTION_FAILURE:
                hint = @"kr=0x2 KERN_PROTECTION_FAILURE —— 权限不足，检查 task_for_pid-allow 是否生效";
                break;
            case KERN_INVALID_ARGUMENT:
                hint = @"kr=0x4 KERN_INVALID_ARGUMENT —— pid 不存在或无此 task";
                break;
            default:
                hint = [NSString stringWithFormat:@"kr=0x%x", kr];
                break;
        }
        *err = [NSString stringWithFormat:@"task_for_pid(%d)：%@；processor_set 回退也失败：%@",
                pid, hint, psError ?: @"未知"];
    }
    return MACH_PORT_NULL;
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

    // ── 路 C：task_for_pid（不碰 processor_set，靠 entitlement）──
    if (route == MFEnumRouteTaskForPid) {
        NSArray<MFProcessInfo *> *list = [self enumerateViaTaskForPid:err];
        if (list.count == 0) {
            if (err && *err == nil) *err = @"路 C 未拿到任何 task port";
            return @[];
        }
        return list;
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

        /*
         * ★ 审查修正（报告 S4）：proc_pidpath 的第一个参数要的是 **pid**，
         *   不是 task port。第一版直接把 tasks[i]（task port）传进去，
         *   等于拿一个 Mach 端口号当 pid 用 —— 永远匹配不上真实进程。
         *   先 pid_for_task 换成 pid，再 proc_pidpath。
         */
        int pid = 0;
        if (pid_for_task(tasks[i], &pid) != KERN_SUCCESS || pid <= 0) {
            mach_port_deallocate(mach_task_self(), tasks[i]);
            continue;
        }

        // 对标原实现：proc_pidpath + strrchr('/') + strncmp
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) {
            mach_port_deallocate(mach_task_self(), tasks[i]);
            continue;
        }
        char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (base[0] == '\0') {
            mach_port_deallocate(mach_task_self(), tasks[i]);
            continue;
        }

        MFProcessInfo *pi = [[MFProcessInfo alloc] init];
        pi.pid = pid;
        pi.name = [NSString stringWithUTF8String:base] ?: @"?";
        pi.path = [NSString stringWithUTF8String:path] ?: @"?";
        /*
         * ★ 审查修正（P1-2）：processor_set_tasks 一次给了 taskCnt 个端口右，
         *   以前全部攥在列表里从不释放 —— 每次刷新泄漏 N 个右，
         *   而且持有别的进程的 task 端口会让那个 task 结构无法回收。
         *   现在只留 pid/名字，端口立刻归还；要读时再 acquireTaskPortForPid:。
         */
        pi.taskPort = MACH_PORT_NULL;
        mach_port_deallocate(mach_task_self(), tasks[i]);
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
