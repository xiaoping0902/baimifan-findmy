/*
 * MFKernelBridge.c —— 白米饭复刻 / KFD 内核链唯一入口
 * =============================================================
 * 【本文件是整个工程里唯一 include "libkfd.h" 的编译单元】
 *
 * 为什么必须唯一（见 docs/kfd-移植清单.md 第 1 节）：
 *   libkfd.h 是 header-only。里面的
 *     struct kfd* kfd_init(...)      libkfd.h L148
 *     void       kfd_free(...)       libkfd.h L158
 *     u64        kopen(...)          libkfd.h L167
 *     void       kread/kwrite/kclose libkfd.h L207/212/217
 *   以及 libkfd/info/dynamic_info.h 里的
 *     struct dynamic_info kern_versions[];   L34
 *   全都是【没有 static 的普通外部定义】。被两个 .c/.m 同时包含
 *   = 链接期 duplicate symbol。
 *
 *   kfund 上游自己的工程里，只有 fun/krw.m 一个 TU 包含它
 *   （kfd-Bridging-Header.h 只 include fun/{fun,krw}.h 和 fun/kpf/patchfinder.h，
 *    不含 libkfd.h）——这是读 kfd.xcodeproj/project.pbxproj 的
 *   PBXSourcesBuildPhase + 全树 grep 得到的事实，不是推测。
 *
 * 本文件的三件事：
 *   1. 把上游「断言失败 = sleep(30) + exit(1)」截获成
 *      「返回错误码 + 错误字符串」（longjmp 回 mf_kopen）。
 *   2. 导出 mf_* 一族纯 C 接口（见 MFKernelBridge.h）。
 *   3. 提供 MFLibkfdKRead4()，替代被丢弃的 fun/krw.m（供 libdimentio.m 用）。
 */

/* ── 公共接口头（纯 C，不含 libkfd.h）────────────────────────────── */
#include "MFKernelBridge.h"
#import <Foundation/Foundation.h>
#include <sys/sysctl.h>

/* [M5.87] proc patch 段用到 snprintf / memcpy：显式带上，不指望 libkfd 间接引入 */
#include <stdio.h>
#include <string.h>
#include <stddef.h>
/* [M5.208] struct timeval / gettimeofday 用于给 kopen（含内部 puaf_cleanup）计时 */
#include <sys/time.h>

/*
 * [M5.89] TF_PLATFORM 段直接调 task_for_pid / mach_port_deallocate。
 * 必须显式 include <mach/mach.h> —— libkfd 只是"碰巧"带进来一部分声明，
 * 不保证这两个可见。构建 #40 就是因为缺这个头报 undeclared identifier。
 */
#include <mach/mach.h>
#include <mach/mach_port.h>

/* ── libkfd 宿主支撑层（ffi: MFLibkfdKRead4 原型）────────────────── */
#include "MFLibkfdHost.h"

/*
 * 运行时链路校准的两个依赖：
 *   MFChainCalib.h —— 链形状（15 一跳 / 16 两跳）的枚举顺序/预算/去重
 *                     （纯 C，Windows 上可回归）
 *   MFPageTable.h  —— 判据要用真页表走一遍：能读回 Mach-O 头才算数
 */
#include "MFChainCalib.h"
#include "MFPageTable.h"

/* ── libkfd 配置开关：必须在 include libkfd.h 之前定义 ───────────────
 * CONFIG_ASSERT 必须保持 1：本桥接把断言改造成了可恢复失败
 *   （libkfd/common.h 的 assert 宏 -> mf_kfd_fail_hook）。
 * CONFIG_PRINT / CONFIG_TIMER 默认关掉：上游打开时会在
 *   krkw_helper_run_allocate 里逐页 print_buffer，在 App 里既卡又刷屏。
 *   调试时用 -DCONFIG_PRINT=1 -DCONFIG_TIMER=1 重新编译即可。
 *   （libkfd.h 已被 [MF PATCH 04] 加上 #ifndef 守卫。）
 */
#ifndef CONFIG_ASSERT
#define CONFIG_ASSERT 1
#endif
#ifndef CONFIG_PRINT
#define CONFIG_PRINT 0
#endif
#ifndef CONFIG_TIMER
#define CONFIG_TIMER 1
#endif

#include "kfd/libkfd.h"          /* ← 全工程唯一一处 */

/* ── fun/kpf 符号（无 fun/ 目录，仍需要这几个）────────────────────── */
#include "kfd/fun/kpf/patchfinder.h"

/* ── 标准库 ───────────────────────────────────────────────────── */
#include <dlfcn.h>       /* dladdr —— 取本进程 executable 的 Mach-O 基址 */
#include <errno.h>
#include <fcntl.h>       /* open / O_CREAT —— 给 mf_redirect_klog 用 */
#include <unistd.h>      /* dup2 / getpid */
#include <setjmp.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/file.h>    /* flock —— 跨进程内核哨兵 */
#include <sys/stat.h>    /* mkdir */
#include <unistd.h>

/* ================================================================ */
/* 内部状态                                                          */
/* ================================================================ */

/* libkfd 的句柄。0 = 未打开。 */
static struct kfd *g_kfd = NULL;

/* 失败跳转。mf_kopen 用 setjmp 落点，断言宏 longjmp 回来。 */
static jmp_buf g_fail_jmp;
static volatile int g_fail_armed = 0;

/*
 * ── 串行化锁（[M5.135]）─────────────────────────────────────────────
 *
 * 为什么必须有：libkfd 的 kread/kwrite 后端（sem_open / dup）是有状态的
 *   （对象喷洒 → 搜索 → 释放），【禁止并发调用】；本文件又用一对
 *     static jmp_buf g_fail_jmp;  static volatile int g_fail_armed;
 *   做失败落点 —— 那是【每进程一份】。两个线程同时进来时后果是：
 *     · 后到的 setjmp 覆盖落点，先到的断言 longjmp 跳到别人的栈帧（崩溃）；
 *     · 或者一个线程把 g_fail_armed 清 0，另一个线程的断言直接 abort()。
 *
 * 以前没暴露，是因为读取只在一个线程上跑；M5.124 之后 HUD 里同时有
 *   持续读取（3 秒一次，global queue）和绘制（60Hz，_drawableQueue）。
 *
 * 用【递归】锁：mf_kwrite32 → mf_kread64、mfpt_translate → mf_kread32
 * 这类嵌套调用必须能重入。
 */
static pthread_mutex_t g_mf_lock;
static pthread_once_t  g_mf_lock_once = PTHREAD_ONCE_INIT;

static void mf_lock_init(void)
{
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_mf_lock, &attr);
    pthread_mutexattr_destroy(&attr);
}

void mf_lock_kernel(void)
{
    pthread_once(&g_mf_lock_once, mf_lock_init);
    pthread_mutex_lock(&g_mf_lock);
}

void mf_unlock_kernel(void)
{
    pthread_mutex_unlock(&g_mf_lock);
}

/* 诊断缓冲。 */
static char g_err[768];
static char g_site[192];
static char g_stage[512];
static int  g_verbose = 0;

#define MF_MARK_FAILED()  do { g_kfd = NULL; } while (0)

static void mf_strlcpy(char *dst, size_t cap, const char *src)
{
    if (cap == 0) return;
    if (src == NULL) src = "(null)";
    size_t n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* ================================================================ */
/* 1c) 跨进程内核哨兵（[M5.135]）                                    */
/* ================================================================ */
/*
 * 主 App 与 HUD 是两个进程：各自的 mf_is_open() 只看自己的 g_kfd。
 * 于是"主 App 点了启动内核 → 再开悬浮窗"这种顺序会让第二个进程直接撞
 *     assertion failed: (kfd->perf.dev.fd > 0)
 * 而按交接报告 §8.2，这个状态重试和换参数都无效，只能重启设备。
 *
 * 用共享文件上的 flock 做互斥（close 即释放，进程被杀也不会残留）：
 *   · 拿不到 → 返回 -4，一个字节都不碰内核；
 *   · 文件开不了（沙盒/权限）→ 降级放行，不因为诊断设施挡住主线。
 *
 * 注意：它只能防"同时开"，防不了"上一个进程被硬杀、perfmon 还脏"——
 * 那种情况只有重启设备能清。
 */
#define MF_KERNEL_SENTINEL "/var/mobile/Media/mf-debug/kernel.owner"

static int g_mf_sentinel_fd = -1;

static int mf_sentinel_acquire(void)
{
    if (g_mf_sentinel_fd >= 0) return 0;

    mkdir("/var/mobile/Media/mf-debug", 0755);
    int fd = open(MF_KERNEL_SENTINEL, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        if (g_verbose) {
            fprintf(stderr, "[mf] 哨兵文件打不开（errno=%d），降级放行\n", errno);
        }
        return 0;
    }

    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        char owner[64] = {0};
        ssize_t n = read(fd, owner, sizeof(owner) - 1);
        close(fd);
        if (n > 0) {
            char *nl = strchr(owner, '\n');
            if (nl) *nl = '\0';
            snprintf(g_err, sizeof(g_err),
                     "内核已被另一个进程持有（owner pid=%s）。"
                     "先把那个进程的内核关掉（悬浮窗菜单「退出」/ 主 App「关闭内核」）再试。",
                     owner);
        } else {
            mf_strlcpy(g_err, sizeof(g_err),
                       "内核已被另一个进程持有（哨兵文件已被锁）");
        }
        return -1;
    }

    ftruncate(fd, 0);
    lseek(fd, 0, SEEK_SET);
    char line[32];
    int len = snprintf(line, sizeof(line), "%d\n", (int)getpid());
    if (len > 0) {
        ssize_t w = write(fd, line, (size_t)len);
        (void)w;
    }
    g_mf_sentinel_fd = fd;
    return 0;
}

static void mf_sentinel_release(void)
{
    if (g_mf_sentinel_fd < 0) return;
    close(g_mf_sentinel_fd);      /* close 即释放 flock */
    g_mf_sentinel_fd = -1;
}

static void mf_set_stage(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_stage, sizeof(g_stage), fmt, ap);
    va_end(ap);
    if (g_verbose) fprintf(stderr, "[kfd] %s\n", g_stage);
}

/* ================================================================ */
/* 1) 失败钩子 —— 把上游的 exit(1) 变成可恢复的错误                 */
/* ================================================================ */

/* 正在跑的 kfd 实例，供失败钩子回收（[MF PATCH 08]）*/
static void *g_active_kfd = NULL;

/* 回收用的嵌套跳转点：kfd_free() 自己也可能断言 */
static jmp_buf g_cleanup_jmp;
static volatile int g_cleanup_armed = 0;

void mf_kfd_register_active(void *kfd)
{
    g_active_kfd = kfd;
}

/*
 * ★★ 为什么只能做「安全回收」（[MF PATCH 08b]，真机崩溃报告实锤）★★
 *
 * 第一版我在这里调的是 kfd_free()，想法是「把四样全还回去」。
 * 真机直接 SIGSEGV，两次，栈完全一致：
 *
 *     kopen → krkw_helper_free → kwrite_sem_open_free
 *           → kwrite_sem_open_deallocate → assert 失败
 *           → mf_kfd_fail_hook → mf_kfd_cleanup_active → kfd_free → 💥
 *
 * 原因：KFD 失败时初始化链是【断的】。以 kopen 的顺序为例 ——
 *     1. kfd_init   ✅
 *     2. puaf_run   ✅
 *     3. krkw_run   ❌ ← 失败点
 *     4. info_run   （没到）
 *     5. perf_run   （没到）
 * 对 3/4/5 调 free = 释放没建好的东西 → 断言 / 野指针。
 *
 * 所以改成只释放【确定成功过】的两样：
 *     · puaf_free —— 本分支成功过，上游重试路径也是这么调的
 *     · info_free —— info_init 在 kfd_init 里做过
 *
 * fd 泄漏不主动处理：失败后闸门会锁死不让重试（不叠加），
 * 用户退出 App 时所有 fd 由内核自动关闭 —— 比冒着崩溃风险去关安全得多。
 */
static void mf_kfd_cleanup_active(void)
{
    if (g_active_kfd == NULL) return;

    void *k = g_active_kfd;
    g_active_kfd = NULL;      /* 先摘掉，避免钩子重入时无限递归 */

    if (setjmp(g_cleanup_jmp) == 0) {
        g_cleanup_armed = 1;
        mf_kfd_safe_cleanup(k);
        g_cleanup_armed = 0;
        fprintf(stderr, "[mf] 🔧 安全回收完成（悬空页已归还；fd 由退出 App 兜底）\n");
    } else {
        g_cleanup_armed = 0;
        fprintf(stderr, "[mf] ⚠️ 回收过程中又踩断言 —— 已尽力，请重启 App\n");
    }
}

/*
 * 由 [MF PATCH 01] 打进 libkfd/common.h 的 assert 宏调用。
 * 上游行为：print -> sleep(30) -> exit(1)。
 * 现在：记录诊断 -> 尽力回收 ->（若已 armed）longjmp 回 mf_kopen。
 *
 * 若没有 armed（例如有人把 libkfd 单独拿去编译），退化为上游行为，
 * 不静默吞掉错误。
 */
void mf_kfd_fail_hook(const char *what, const char *file, int line)
{
    const char *base = (file != NULL) ? strrchr(file, '/') : NULL;
    base = (base != NULL) ? (base + 1) : file;

    snprintf(g_site, sizeof(g_site), "%s:%d", (base != NULL) ? base : "?", line);
    snprintf(g_err, sizeof(g_err), "assertion failed: (%s) at %s:%d",
             (what != NULL) ? what : "?", (base != NULL) ? base : "?", line);

    if (g_verbose) fprintf(stderr, "[kfd] 🔴 %s\n", g_err);

    /*
     * 回收阶段自己踩断言：跳回 cleanup 的落点，让 kfd_free 那条路收尾。
     * 不这么处理的话，cleanup 里的断言会一路走到 sleep(30)+exit(1)。
     */
    if (g_cleanup_armed) {
        g_cleanup_armed = 0;
        longjmp(g_cleanup_jmp, 1);
    }

    if (g_fail_armed) {
        g_fail_armed = 0;
        /* ★ 关键：先尽力回收，再跳走 —— 跳走之后就没机会了 */
        mf_kfd_cleanup_active();
        longjmp(g_fail_jmp, 1);
    }

    /* 无宿主接管：保持上游的可见失败行为。 */
    fprintf(stderr, "[kfd] no host handler, sleep(30) before exit(1)\n");
    sleep(30);
    exit(1);
}

/* ================================================================ */
/* 1b) __assert_rtn 兜底                                             */
/* ================================================================ */

/*
 * ★ 为什么需要这一层（真机崩溃报告实锤）：
 *
 *   [MF PATCH 01] 把 libkfd/common.h 的 assert 宏改成走 mf_kfd_fail_hook，
 *   但 <assert.h> 是【无 include guard 且内部会 #undef assert】的头文件。
 *   kread_sem_open.h 里 #include "libdimentio.h" / "patchfinder.h" 会拐进
 *   Foundation → <assert.h>，于是我们的宏被顶回系统版本。
 *
 *   结果（设备上的真实崩溃报告 FindMy-2026-10-15-115826.ips）：
 *     __assert_rtn -> abort
 *     kread_sem_open_allocate.cold.1   ← 卡在这里直接闪退
 *   而不是弹出可读的错误框。
 *
 *   修法：不从宏层拦，改从【符号层】拦。
 *   整个进程里所有 assert 失败都要经过 __assert_rtn，我们在这里接管。
 *   这是 libSystem 的公开 ABI 符号，本镜像内的引用会优先解析到我们的定义。
 */
void __assert_rtn(const char *func, const char *file, int line, const char *expr)
{
    (void)func;
    mf_kfd_fail_hook((expr != NULL) ? expr : "assert", file, line);

    /*
     * 走到这里说明钩子没 longjmp（g_fail_armed == 0，没人 setjmp 落点）。
     * 保持上游语义：真的中断，不静默吞错。
     */
    abort();
}

/* ================================================================ */
/* 1c) 把 kfd 内部的 printf 诊断重定向到文件                          */
/* ================================================================ */

static int g_klog_fd = -1;

/*
 * kfd 内部大量用 printf 输出诊断，形如：
 *     defeated kaslr, kbase: 0xfffffe0007...
 *     pfinder_init: success!
 *     cdevsw: 0x...
 *     gPhysBase: 0x...
 * 但 iOS 上 App 的 stdout 既不进 syslog、也没人接着 —— 失败时我们只
 * 看到最后那句 "run_kfd_patchfinder failed"，不知道它死在 9 个偏移里的哪一个。
 *
 * 这里把 stdout/stderr 重定向到沙盒里的 mf_kfd.log，
 * 界面「内核日志」页能读回来（见 mf_read_klog）。
 *
 * 只重定向一次；任何失败都静默 —— 日志不是关键路径。
 */
static void mf_redirect_klog(void)
{
    if (g_klog_fd >= 0) return;

    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    if (docs == nil) return;

    NSString *path = [docs stringByAppendingPathComponent:@"mf_kfd.log"];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;

    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    g_klog_fd = fd;

    printf("[mf] ==== kfd log opened  pid=%d  puaf/landa 前置日志 ====\n", getpid());
    fflush(stdout);
}

/* 读回内核日志（UI 用）。返回 malloc 的字符串，调用方 free；没有则 NULL。 */
char *mf_read_klog(void)
{
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    if (docs == nil) return NULL;

    NSString *path = [docs stringByAppendingPathComponent:@"mf_kfd.log"];
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d == nil || d.length == 0) return NULL;

    char *out = (char *)malloc(d.length + 1);
    if (out == NULL) return NULL;
    memcpy(out, d.bytes, d.length);
    out[d.length] = '\0';
    return out;
}

/* ================================================================ */
/* 2) 生命周期                                                       */
/* ================================================================ */

MFDeviceConfiguration mf_current_device_configuration(void)
{
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    uint32_t family = 0;
    uint64_t memory = 0;
    size_t family_size = sizeof(family), memory_size = sizeof(memory);
    sysctlbyname("hw.cpufamily", &family, &family_size, NULL, 0);
    sysctlbyname("hw.memsize", &memory, &memory_size, NULL, 0);
    return mf_device_configuration((int)os.majorVersion, (int)os.minorVersion,
                                   (int)os.patchVersion, family, memory);
}

static int mf_kopen_locked(uint64_t puaf_pages, int puaf_method, int kread_method, int kwrite_method)
{
    MFDeviceConfiguration device = mf_current_device_configuration();
    if (device.status != MF_DEVICE_SUPPORTED || !mf_device_method_allowed(device, puaf_method)) {
        const char *reason = device.status == MF_DEVICE_UNSUPPORTED_OS
            ? "unsupported OS: this backend targets iOS/iPadOS 15.0-16.6.1"
            : device.status == MF_DEVICE_UNSUPPORTED_CHIP
            ? "unsupported chip: bundled kernel offsets require A12-A16 / M1-M2"
            : "PUAF method is patched or unreliable on this OS; use device automatic startup";
        mf_strlcpy(g_err, sizeof(g_err), reason);
        return -5; /* Before redirect, allocations, sentinel or any KFD operation. */
    }
    /* 先把 kfd 内部的 printf 诊断接进文件，失败时才能看出死在 9 个偏移里的哪一个 */
    mf_redirect_klog();

    if (g_kfd != NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "already open (call mf_kclose first)");
        return -2;
    }

    /* 打开前自检：把上游的 assert 前置成显式错误，错误信息更友好。 */
    if (puaf_pages < MF_PUAF_PAGES_MIN || puaf_pages > MF_PUAF_PAGES_MAX) {
        snprintf(g_err, sizeof(g_err),
                 "bad puaf_pages: %llu (valid range %d..%d)",
                 (unsigned long long)puaf_pages, MF_PUAF_PAGES_MIN, MF_PUAF_PAGES_MAX);
        return -3;
    }
    if (puaf_method < MF_PUAF_PHYSPUPPET || puaf_method > MF_PUAF_LANDA) {
        snprintf(g_err, sizeof(g_err), "bad puaf_method: %d", puaf_method);
        return -3;
    }
    if (kread_method < MF_KREAD_KQUEUE_WORKLOOP_CTL || kread_method > MF_KREAD_SEM_OPEN) {
        snprintf(g_err, sizeof(g_err), "bad kread_method: %d", kread_method);
        return -3;
    }
    if (kwrite_method < MF_KWRITE_DUP || kwrite_method > MF_KWRITE_SEM_OPEN) {
        snprintf(g_err, sizeof(g_err), "bad kwrite_method: %d", kwrite_method);
        return -3;
    }
    /* krkw.h L77-79：kread_sem_open 必须配 kwrite_sem_open，上游用 assert 拦。 */
    if (kread_method == MF_KREAD_SEM_OPEN && kwrite_method != MF_KWRITE_SEM_OPEN) {
        mf_strlcpy(g_err, sizeof(g_err),
                   "kread_sem_open requires kwrite_sem_open (libkfd krkw.h assert)");
        return -3;
    }
    /* krkw.h L73-75：16.3+ 的 kqueue_workloop_ctl 已废。 */
    if (kread_method == MF_KREAD_KQUEUE_WORKLOOP_CTL) {
        mf_strlcpy(g_err, sizeof(g_err),
                   "kread_kqueue_workloop_ctl is disabled on iOS 16.3+ (libkfd krkw.h)");
        return -3;
    }

    mf_strlcpy(g_err, sizeof(g_err), "no error");

    /*
     * [M5.135] 先拿跨进程哨兵：主 App 和 HUD 是两个进程，mf_is_open() 互相看不见。
     * 拿不到就返回 -4 —— 这一步失败时内核一个字节都没动，调用方可以安全重试。
     */
    if (mf_sentinel_acquire() != 0) {
        mf_set_stage("kopen: REFUSED（另一个进程持有内核）");
        return -4;
    }

    mf_set_stage("kopen: start (puaf_pages=%llu, puaf_method=%d, kread=%d, kwrite=%d)",
                 (unsigned long long)puaf_pages, puaf_method, kread_method, kwrite_method);

    struct kfd *kfd = NULL;

    /*
     * setjmp 落点。libkfd 内部任何 assert 失败都会 longjmp 回到这里，
     * 于是「卡 30 秒闪退」变成「返回错误码」。
     */
    if (setjmp(g_fail_jmp) == 0) {
        g_fail_armed = 1;
        kfd = (struct kfd *)(uintptr_t)kopen(puaf_pages,
                                             (u64)puaf_method,
                                             (u64)kread_method,
                                             (u64)kwrite_method);
        g_fail_armed = 0;
    } else {
        /* 从 libkfd 内部跳回来：g_err / g_site 已由钩子填好。 */
        g_fail_armed = 0;
        MF_MARK_FAILED();
        mf_sentinel_release();
        mf_set_stage("kopen: FAILED (%s)", g_err);
        return -1;
    }

    if (kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "kopen returned NULL");
        mf_sentinel_release();
        mf_set_stage("kopen: FAILED (kopen returned NULL)");
        return -1;
    }

    g_kfd = kfd;

    mf_set_stage("kopen: OK  kbase=0x%llx  kslide=0x%llx",
                 (unsigned long long)(ARM64_LINK_ADDR + (uint64_t)g_kfd->perf.kernel_slide),
                 (unsigned long long)g_kfd->perf.kernel_slide);

    if (g_verbose) {
        fprintf(stderr, "[kfd] kbase    = 0x%llx\n", (unsigned long long)mf_get_kbase());
        fprintf(stderr, "[kfd] kslide   = 0x%llx\n", (unsigned long long)mf_get_kslide());
        fprintf(stderr, "[kfd] kernproc = 0x%llx\n", (unsigned long long)g_kfd->info.kaddr.kernel_proc);
        fprintf(stderr, "[kfd] selfproc = 0x%llx\n", (unsigned long long)g_kfd->info.kaddr.current_proc);
    }

    return 0;
}

int mf_kopen_for_device(uint64_t pages)
{
    const MFDeviceConfiguration device = mf_current_device_configuration();
    return mf_kopen(pages ? pages : device.pages,
                    device.method,
                    MF_DEFAULT_KREAD_METHOD,
                    MF_DEFAULT_KWRITE_METHOD);
}

int mf_kopen_default(void) { return mf_kopen_for_device(0); }

static void mf_kclose_locked(void)
{
    if (g_kfd == NULL) {
        return;
    }

    /*
     * 清理路径同样可能断言失败（例如 perf_free 还原 si_rdev、关闭 fd）。
     * 用同一套 setjmp 兜住，避免用户点「关闭」时闪退。
     */
    if (setjmp(g_fail_jmp) == 0) {
        g_fail_armed = 1;
        kclose((u64)(uintptr_t)g_kfd);
        g_fail_armed = 0;
    } else {
        g_fail_armed = 0;
        mf_set_stage("kclose: FAILED (%s)", g_err);
        MF_MARK_FAILED();
        mf_sentinel_release();
        return;
    }

    MF_MARK_FAILED();
    mf_sentinel_release();
    mf_set_stage("kclose: done");
}

int mf_is_open(void)
{
    return (g_kfd != NULL) ? 1 : 0;
}

/* ================================================================ */
/* 3) 读写                                                           */
/* ================================================================ */

/*
 * ★★ kread/kwrite 的 size 必须是 8 的倍数 ★★
 *
 * 原因见 MFLibkfdKRead4 上方那段注释：
 *   kread 落到 kread_from_method(u64, ...)，
 *   type_size = size / sizeof(u64)。
 *   size < 8 或不是 8 的倍数时，尾数部分【会被静默丢弃】，
 *   甚至 size=4 时一次循环都不进（缓冲区原封不动）。
 *
 * 这是最阴的一类 bug：不报错、不崩溃，只是数据不对。
 * 所以这两个入口做兜底：把非 8 倍数的情况显式处理掉，绝不静默。
 */

/*
 * [M5.105] 内核地址硬闸 —— 放在唯一入口，而不是指望每个调用方自觉。
 *
 * arm64 内核地址的判据是「高 16 位全 1」。任何低于 0xffff000000000000 的地址
 * 一旦送进 kread/kwrite，内核会在 copyio.c:184 的 copy_validate 里直接 panic，
 * 整机重启。这个坑已经踩了两次：
 *     panic-full-2026-10-24-200013.ips   copy_validate(0x16b8bcfb8, -1, 8)
 *     panic-full-2026-10-24-235009.ips   copy_validate(0x16d882c68, -1, 8)
 * 两次都是 8 字节读、kaddr 是用户地址。
 *
 * 所以：非法地址不发 syscall，只记账 + 返回错误。
 */
static uint64_t g_mf_denied_kaddr;
static int      g_mf_denied_count;

static int mf_addr_guard(uint64_t kaddr, uint64_t size, const char *who)
{
    if (kaddr < 0xffff000000000000ULL ||
        size > (1ULL << 28) ||
        kaddr > 0xffffffffffffffffULL - size) {
        g_mf_denied_kaddr = kaddr;
        g_mf_denied_count++;
        snprintf(g_err, sizeof(g_err),
                 "%s: refused non-kernel address %#llx (size %llu, denied=%d)",
                 who, (unsigned long long)kaddr,
                 (unsigned long long)size, g_mf_denied_count);
        return -1;
    }
    return 0;
}

int mf_kaddr_denied_count(void)
{
    return g_mf_denied_count;
}

uint64_t mf_kaddr_denied_last(void)
{
    return g_mf_denied_kaddr;
}

/*
 * 当前 pmap 的 TTBR 快照。kfd 的 perf_run() 会把 TTBR0/TTBR1 的 (pa, va)
 * 都存进 kfd->perf.ttbr[]，这是内核给的【可信】页表根；用它翻译自己的
 * 用户地址，才能验证页表遍历本身是对的，而不是拿堆里的随机字段去试。
 */
int mf_ttbr_snapshot(uint64_t *ttbr0_pa, uint64_t *ttbr0_va,
                     uint64_t *ttbr1_pa, uint64_t *ttbr1_va)
{
    if (g_kfd == NULL) {
        return -1;
    }
    if (ttbr0_pa) *ttbr0_pa = (uint64_t)g_kfd->perf.ttbr[0].pa;
    if (ttbr0_va) *ttbr0_va = (uint64_t)g_kfd->perf.ttbr[0].va;
    if (ttbr1_pa) *ttbr1_pa = (uint64_t)g_kfd->perf.ttbr[1].pa;
    if (ttbr1_va) *ttbr1_va = (uint64_t)g_kfd->perf.ttbr[1].va;
    return 0;
}

/*
 * [M5.107] ptov_table 快照 + PA→KVA。
 *
 * libkfd 的 phystokv()（kfd/libkfd/perf.h:232-248）是唯一权威：
 *     先按 ptov_table[] 逐段匹配（pa..pa+len），命中就 pa-pa_ent+va_ent；
 *     全部不命中才断言 pa 落在 [gPhysBase, gPhysBase+gPhysSize) 并用
 *     gVirtBase 平移。
 * 只做后半段（我们 M5.106 之前的做法）会让某些物理页落到错误的窗口里：
 * M5.106 实测 ttbr0 页 pa=0x9aacb8000，正确 VA 是 0xfffffdf1ccd10000，
 * 而单窗口公式给的是 0xfffffe01bacb8000 —— 两个地址指向不同的映射，
 * 从这一页读出来的"页表项"自然全是垃圾。
 */
int mf_ptov_snapshot(uint64_t *pa, uint64_t *va, uint64_t *len)
{
    if (g_kfd == NULL) {
        return -1;
    }
    int count = 0;
    for (int i = 0; i < 8; i++) {
        uint64_t p = (uint64_t)g_kfd->perf.ptov_table[i].pa;
        uint64_t v = (uint64_t)g_kfd->perf.ptov_table[i].va;
        uint64_t l = (uint64_t)g_kfd->perf.ptov_table[i].len;
        if (pa)  pa[i]  = p;
        if (va)  va[i]  = v;
        if (len) len[i] = l;
        if (l != 0) {
            count++;
        }
    }
    return count;
}

uint64_t mf_phys_to_kv(uint64_t pa)
{
    if (g_kfd == NULL) {
        return 0;
    }
    for (int i = 0; i < 8; i++) {
        uint64_t p = (uint64_t)g_kfd->perf.ptov_table[i].pa;
        uint64_t l = (uint64_t)g_kfd->perf.ptov_table[i].len;
        if (l == 0) {
            break;
        }
        if (pa >= p && pa < p + l) {
            return pa - p + (uint64_t)g_kfd->perf.ptov_table[i].va;
        }
    }
    uint64_t base = (uint64_t)g_kfd->perf.gPhysBase;
    uint64_t size = (uint64_t)g_kfd->perf.gPhysSize;
    if (size != 0 && pa >= base && pa < base + size) {
        return pa - base + (uint64_t)g_kfd->perf.gVirtBase;
    }
    return 0;
}

static int mf_kread_locked(uint64_t kaddr, void *uaddr, uint64_t size)
{
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kread: not open");
        return -1;
    }
    if (mf_addr_guard(kaddr, size, "mf_kread") != 0) {
        return -1;
    }
    if (uaddr == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kread: uaddr is NULL");
        return -2;
    }
    if (size == 0) {
        return 0;
    }

    /* 整 8 字节：直接走后端，最快 */
    if ((size & 7u) == 0) {
        if (setjmp(g_fail_jmp) == 0) {
            g_fail_armed = 1;
            kread((u64)(uintptr_t)g_kfd, kaddr, uaddr, size);
            g_fail_armed = 0;
        } else {
            g_fail_armed = 0;
            return -1;
        }
        return 0;
    }

    /*
     * 非 8 倍数：按【8 字节对齐单元】逐块读。
     *
     * ★ 审查修正（报告 S3）：第一版是 kread(kaddr+done, 8)，
     *   size=12 时会读到 kaddr+8..kaddr+16，比请求范围多读 4 字节，
     *   贴着页尾时可能跨页。改成先把地址对齐到 8 字节再读，
     *   然后按 shift 截取 —— 每次读都落在单个 8 字节单元内。
     */
    unsigned char *out = (unsigned char *)uaddr;
    uint64_t done = 0;
    while (done < size) {
        uint64_t addr    = kaddr + done;
        uint64_t aligned = addr & ~7ULL;
        uint64_t shift   = addr - aligned;          // 0..7

        uint64_t chunk = 0;
        if (setjmp(g_fail_jmp) == 0) {
            g_fail_armed = 1;
            kread((u64)(uintptr_t)g_kfd, aligned, &chunk, sizeof(chunk));
            g_fail_armed = 0;
        } else {
            g_fail_armed = 0;
            if (g_verbose) {
                fprintf(stderr, "[mf] mf_kread: 分块读失败 @ done=%llu/%llu\n",
                        (unsigned long long)done, (unsigned long long)size);
            }
            return -1;
        }

        uint64_t avail = 8 - shift;
        uint64_t take  = (size - done < avail) ? (size - done) : avail;
        memcpy(out + done, ((unsigned char *)&chunk) + shift, (size_t)take);
        done += take;
    }
    return 0;
}

static int mf_kwrite_locked(void *uaddr, uint64_t kaddr, uint64_t size)
{
    if (mf_addr_guard(kaddr, size, "mf_kwrite") != 0) {
        return -1;
    }
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kwrite: not open");
        return -1;
    }
    if (uaddr == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kwrite: uaddr is NULL");
        return -2;
    }
    if (size == 0) {
        return 0;
    }

    /*
     * ★ 审查修正（报告 S1）：上游 kwrite 后端有三条【静默 return】：
     *       new_value == 0   → 什么都不做
     *       old_value == 0   → 什么都不做（旧的为 0 也写不进去）
     *       old_value == new → 跳过
     *   而 kwrite() 返回 void —— 调用方根本看不出「其实没写」。
     *   我们的封装以前恒返回 0（成功），等于骗调用者。
     *
     *   现在加两道：
     *     ① 要写的数据全是 0 → 直接报错（这个上游铁定写不进去）
     *     ② 写完读回校验，不一致就报错
     */
    {
        const unsigned char *p = (const unsigned char *)uaddr;
        int allzero = 1;
        for (uint64_t i = 0; i < size; i++) {
            if (p[i] != 0) { allzero = 0; break; }
        }
        if (allzero) {
            mf_strlcpy(g_err, sizeof(g_err),
                       "mf_kwrite: 上游 kwrite 无法写 0（值靠 fd 槽表达）"
                       "—— 请改用非零哨兵、改指针，或改上层字段");
            return -3;
        }
    }

    /* 整 8 字节：直接写 */
    if ((size & 7u) == 0) {
        if (setjmp(g_fail_jmp) == 0) {
            g_fail_armed = 1;
            kwrite((u64)(uintptr_t)g_kfd, uaddr, kaddr, size);
            g_fail_armed = 0;
        } else {
            g_fail_armed = 0;
            return -1;
        }

        /* 读回校验（只对小尺寸做，避免大块写的额外开销） */
        if (size <= 64) {
            unsigned char back[64] = {0};
            if (mf_kread(kaddr, back, size) == 0 &&
                memcmp(back, uaddr, (size_t)size) != 0) {
                mf_strlcpy(g_err, sizeof(g_err),
                           "mf_kwrite: 写后校验不一致 —— 上游很可能静默跳过了"
                           "（值不变 / 目标原为 0 / 值为 0）");
                return -4;
            }
        }
        return 0;
    }

    /*
     * 非 8 倍数：读-改-写。
     * kwrite 后端是按 8 字节对象表达的，直接截断写会把尾部清零。
     * 所以先读回原 8 字节，只替换要改的字节，再整体写回。
     *
     * 注意：若目标原本是 0（kwrite 写 0 是上游已知的限制），
     *       这里会读回 0 再写回 0，可能失败 —— 如实返回错误。
     */
    unsigned char *in = (unsigned char *)uaddr;
    uint64_t done = 0;
    while (done < size) {
        uint64_t chunk = 0;
        uint64_t take = size - done;
        if (take > 8) take = 8;

        int partial = (take < 8);

        if (setjmp(g_fail_jmp) == 0) {
            g_fail_armed = 1;
            if (partial) {
                /* 先读回，再局部覆盖 */
                kread((u64)(uintptr_t)g_kfd, kaddr + done, &chunk, sizeof(chunk));
            }
            memcpy(&chunk, in + done, (size_t)take);
            kwrite((u64)(uintptr_t)g_kfd, &chunk, kaddr + done, sizeof(chunk));
            g_fail_armed = 0;
        } else {
            g_fail_armed = 0;
            if (g_verbose) {
                fprintf(stderr, "[mf] mf_kwrite: 非8倍数分块写失败 @ done=%llu/%llu (partial=%d)\n",
                        (unsigned long long)done, (unsigned long long)size, partial);
            }
            return -1;
        }
        done += take;
    }
    return 0;
}

/*
 * 4 字节对齐读。走 libkfd/krkw/kread/kread_sem_open.h 的
 * kread_sem_open_kread_u32()：它把 pinfo 指到 kaddr - offsetof(pseminfo, psem_usecount)，
 * 保证那 4 字节是被修改指针读到的【头 4 字节】，不会下溢到上一页。
 *
 * 注意：该函数要求当前 kread 后端确实是 sem_open；否则退回普通 kread。
 */
static int mf_kread32_locked(uint64_t kaddr, uint32_t *out)
{
    if (mf_addr_guard(kaddr, 4, "mf_kread32") != 0) {
        return -1;
    }
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kread32: not open");
        return -1;
    }
    if (out == NULL) {
        return -2;
    }

    if (setjmp(g_fail_jmp) == 0) {
        g_fail_armed = 1;
        if (g_kfd->kread.krkw_method_ops.kread == kread_sem_open_kread) {
            *out = kread_sem_open_kread_u32(g_kfd, kaddr);
        } else {
            /*
             * 兜底分支：读 8 字节再截断。
             * 【不能】写成 kread(..., sizeof(uint32_t)) —— size=4 会让
             * kread_from_method 的 type_size 算成 0，缓冲区原封不动。
             */
            uint64_t chunk = 0;
            kread((u64)(uintptr_t)g_kfd, kaddr, &chunk, sizeof(chunk));
            *out = (uint32_t)(chunk & 0xFFFFFFFFu);
        }
        g_fail_armed = 0;
    } else {
        g_fail_armed = 0;
        return -1;
    }
    return 0;
}

static int mf_kread64_locked(uint64_t kaddr, uint64_t *out)
{
    if (mf_addr_guard(kaddr, 8, "mf_kread64") != 0) {
        return -1;
    }
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kread64: not open");
        return -1;
    }
    if (out == NULL) {
        return -2;
    }

    if (setjmp(g_fail_jmp) == 0) {
        g_fail_armed = 1;
        kread((u64)(uintptr_t)g_kfd, kaddr, out, sizeof(*out));
        g_fail_armed = 0;
    } else {
        g_fail_armed = 0;
        return -1;
    }
    return 0;
}

/*
 * 32 位写。上游 kwrite 不能写 0（writeups/exploiting-puafs.md L189-192）；
 * 这里把「整 8 字节槽」读回来拼装，只有目标字段被替换，其余保留。
 */
static int mf_kwrite32_locked(uint64_t kaddr, uint32_t value)
{
    if (mf_addr_guard(kaddr, 4, "mf_kwrite32") != 0) {
        return -1;
    }
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kwrite32: not open");
        return -1;
    }

    uint64_t slot = 0;
    uint64_t aligned = kaddr & ~0x7ULL;
    int shift = (int)((kaddr - aligned) * 8);

    if (mf_kread64(aligned, &slot) != 0) {
        return -1;
    }
    slot = (slot & ~(0xffffffffULL << shift)) | (((uint64_t)value) << shift);

    if (setjmp(g_fail_jmp) == 0) {
        g_fail_armed = 1;
        kwrite((u64)(uintptr_t)g_kfd, &slot, aligned, sizeof(slot));
        g_fail_armed = 0;
    } else {
        g_fail_armed = 0;
        return -1;
    }
    return 0;
}

static int mf_kwrite64_locked(uint64_t kaddr, uint64_t value)
{
    if (mf_addr_guard(kaddr, 8, "mf_kwrite64") != 0) {
        return -1;
    }
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kwrite64: not open");
        return -1;
    }

    if (setjmp(g_fail_jmp) == 0) {
        g_fail_armed = 1;
        kwrite((u64)(uintptr_t)g_kfd, &value, kaddr, sizeof(value));
        g_fail_armed = 0;
    } else {
        g_fail_armed = 0;
        return -1;
    }
    return 0;
}

/* ================================================================ */
/* 4) 地址信息                                                       */
/* ================================================================ */

uint64_t mf_get_kbase(void)
{
    if (g_kfd == NULL) {
        return 0;
    }
    /*
     * libkfd 的 struct perf 只存 kernel_slide（perf.h L109）。
     * ARM64_LINK_ADDR 在 kfund 里已是运行时变量（static_info.h L12-13，
     * 由 info_init 用 get_vm_kernel_link_addr() 赋值）。
     */
    return ARM64_LINK_ADDR + (uint64_t)g_kfd->perf.kernel_slide;
}

/*
 * 内核关键地址快照 —— 给 MFCalibrate 用。
 *
 * 只做「哪个字段」，不做任何推断；地址语义（是 proc/task/map/pmap）
 * 由 libkfd 的 info_run() 在打开内核时填好，这里原样交出。
 * 外部（校准代码）会先校验每个地址落在内核 VA 域再使用。
 */
int mf_kaddr_snapshot(uint64_t *kernel_proc, uint64_t *kernel_task,
                      uint64_t *current_proc, uint64_t *current_task,
                      uint64_t *current_map, uint64_t *current_pmap,
                      uint64_t *gVirtBase, uint64_t *gPhysBase,
                      uint64_t *gPhysSize)
{
    if (g_kfd == NULL) {
        return -1;
    }
    if (kernel_proc)  *kernel_proc  = (uint64_t)g_kfd->info.kaddr.kernel_proc;
    if (kernel_task)  *kernel_task  = (uint64_t)g_kfd->info.kaddr.kernel_task;
    if (current_proc) *current_proc = (uint64_t)g_kfd->info.kaddr.current_proc;
    if (current_task) *current_task = (uint64_t)g_kfd->info.kaddr.current_task;
    if (current_map)  *current_map  = (uint64_t)g_kfd->info.kaddr.current_map;
    if (current_pmap) *current_pmap = (uint64_t)g_kfd->info.kaddr.current_pmap;
    if (gVirtBase)    *gVirtBase    = (uint64_t)g_kfd->perf.gVirtBase;
    if (gPhysBase)    *gPhysBase    = (uint64_t)g_kfd->perf.gPhysBase;
    if (gPhysSize)    *gPhysSize    = (uint64_t)g_kfd->perf.gPhysSize;
    return 0;
}

uint64_t mf_get_kslide(void)
{
    if (g_kfd == NULL) {
        return 0;
    }
    return (uint64_t)g_kfd->perf.kernel_slide;
}

uint64_t mf_get_vm_kernel_link_addr(void)
{
    /* 由 kpf/patchfinder.m 实现：T8103/T8112 -> 0xFFFFFE0007004000。 */
    return (uint64_t)get_vm_kernel_link_addr();
}

const char *mf_kernel_version(void)
{
    /*
     * 缓存：上游 get_kernversion() 每次 strdup（patchfinder.m L120），
     * UI 频繁轮询会漏内存，所以这里只取一次。
     */
    static char cached[512];
    static int  cached_ok = 0;

    if (!cached_ok) {
        const char *v = get_kernversion();
        if (v != NULL && v[0] != '\0') {
            mf_strlcpy(cached, sizeof(cached), v);
            cached_ok = 1;
        } else {
            /* 兜底：直接 sysctl，不依赖 patchfinder。 */
            char buf[512] = {};
            size_t sz = sizeof(buf);
            if (sysctlbyname("kern.version", buf, &sz, NULL, 0) == 0 && buf[0] != '\0') {
                mf_strlcpy(cached, sizeof(cached), buf);
                cached_ok = 1;
            }
        }
    }
    return cached;
}

static uint64_t mf_info_field(int which)
{
    if (g_kfd == NULL) {
        return 0;
    }
    switch (which) {
        case 0: return (uint64_t)g_kfd->info.kaddr.kernel_proc;
        case 1: return (uint64_t)g_kfd->info.kaddr.kernel_task;
        case 2: return (uint64_t)g_kfd->info.kaddr.kernel_map;
        case 3: return (uint64_t)g_kfd->info.kaddr.kernel_pmap;
        case 4: return (uint64_t)g_kfd->info.kaddr.current_proc;
        case 5: return (uint64_t)g_kfd->info.kaddr.current_task;
        default: return 0;
    }
}

uint64_t mf_get_kernel_proc(void)  { return mf_info_field(0); }
uint64_t mf_get_kernel_task(void)  { return mf_info_field(1); }
uint64_t mf_get_kernel_map(void)   { return mf_info_field(2); }
uint64_t mf_get_kernel_pmap(void)  { return mf_info_field(3); }
uint64_t mf_get_current_proc(void) { return mf_info_field(4); }
uint64_t mf_get_current_task(void) { return mf_info_field(5); }

/* ================================================================ */
/* 5) proc patch：绕开 taskgated 的 CS_HARD 拒绝                      */
/* ================================================================ */
/*
 * ── 为什么需要这一段 ──
 *
 * 真机实测（无越狱 / iPad14,4 / 16.1）：
 *     task_for_pid(game)   → kr=0x5 KERN_FAILURE
 *     task_for_pid(launchd)→ kr=0x5
 *     processor_set_tasks  → kr=0x4
 * 这是 taskgated 按**目标进程**的代码签名标志拒绝的（CS_HARD）。
 * 我们的 entitlement 没问题（task_for_pid-allow 就在 plist 里）。
 *
 * 常规解法是拿了 tfp0 之后从内核拿 task port。但那需要 dimentio，
 * 而本工程里 dimentio() 的实现是缺的（只有 patchfinder 部分）。
 *
 * ── 本段的做法：不需要 tfp0 ──
 *
 * 我们已经有内核读写（mf_kread / mf_kwrite，由 KFD 提供）。
 * 那就直接改**目标进程**的 proc->p_csflags，把 CS_HARD 位清掉。
 * 之后 taskgated 再看它就没有硬签名标志了，task_for_pid 自然放行。
 *
 * ── 唯一的难点：偏移 ──
 *
 * struct proc 的 p_pid / p_csflags 偏移是 iOS 版本相关的，
 * 工程里没有现成值（patchfinder 只算了 KFD 自己要用的 cdevsw / gPhysBase 等）。
 * 所以这里**运行时自适应扫描**，靠两个铁的已知事实自校准：
 *     · kernel_proc 的 pid 一定是 0
 *     · launchd    的 pid 一定是 1
 * 对每个候选偏移同时校验这两条，都对才算找到 p_pid。
 *
 * ── 安全约定 ──
 *
 * 默认 **dry-run**：只扫描、只报告，不写内核。
 * 必须显式传 apply=1 才真正改 p_csflags。
 * 改的时候只清位（不会把整个字段写 0），最坏情况是没效果，不会炸内核。
 */

/* CS_HARD / CS_RESTRICT / CS_REQUIRE_LV（bsd/sys/codesign.h） */
#define MF_CS_HARD        0x00000100u
#define MF_CS_RESTRICT    0x00000800u
#define MF_CS_REQUIRE_LV  0x00002000u

/* proc 链表遍历上限（正常机器几百个进程，512 足够且能防成环） */
#define MF_PROC_WALK_MAX  1024

/*
 * ★ [M5.111] p_list 链接字段偏移。
 *
 * MFCalibrate 的诊断用 +0x08 走这条链，M5.107 实测 walked=315（正好走到本进程），
 * kfdmemdump 的 off_p_list_le_prev 也是 0x8（kfd_bridge.c:222）。
 * 之前这里写成 +0x00，真机上链表只走出 1 个节点。
 */
#define MF_OFF_PROC_LIST_PREV 0x08ULL

/* 下面这两个 helper 的定义在 5b 段；这里先声明，供链表遍历使用。 */
static uint64_t mf_bridge_unsign(uint64_t p);
static int mf_bridge_is_kernel_va(uint64_t a);

/* p_pid 扫描范围：struct proc 开头这一段里它一定在 */
#define MF_PID_SCAN_START 0x10
#define MF_PID_SCAN_END   0x400

/* p_csflags 扫描范围 */
#define MF_CS_SCAN_START  0x100
#define MF_CS_SCAN_END    0x800

/*
 * 沿 p_list 把进程链表走一遍，把每个 proc 的地址收集出来。
 *
 * ★ [M5.111] 链接字段在 +0x08，不是 +0x00。
 *
 * 这里原来写的是"le_next 在 +0x00"，结果真机上链表只走了 1 个就停，
 * 导致 p_pid 自适应扫描失败（要 ≥2 个样本），跨进程读第一步就报
 * "没能定出 p_pid 偏移（链表中 1 个 proc）"。
 *
 * 证据：MFCalibrate 的诊断用 +0x08 走同一条链，M5.107 实测 walked=315
 * （第 315 个正好是本进程），所以 +0x08 才是这台机器上的有效链接；
 * kfdmemdump 的 off_p_list_le_prev = 0x8 也是同一个结论（kfd_bridge.c:222）。
 */
static int mf_collect_proc_chain(uint64_t *out, int max_out)
{
    uint64_t head = mf_get_kernel_proc();
    if (head == 0) {
        return 0;
    }

    int n = 0;
    uint64_t cur = head;
    for (int i = 0; i < 4000 && n < max_out; i++) {
        if (!mf_bridge_is_kernel_va(cur)) {
            break;
        }
        out[n++] = cur;

        uint64_t next = 0;
        if (mf_kread64(cur + MF_OFF_PROC_LIST_PREV, &next) != 0) {
            break;                       /* 读不到就停，不要把错误值当指针用 */
        }
        next = mf_bridge_unsign(next);
        if (next == 0 || next == cur) {
            break;                       /* 空链 / 自环 */
        }
        if (next == head) {
            break;                       /* 回到头，链表闭合 */
        }
        cur = next;
    }
    return n;
}

/*
 * 自适应找出 struct proc 里 p_pid 的偏移。
 *
 * 判据（两条同时满足）：
 *   ① 第 0 个 proc（kernel_proc）在该偏移上的值 == 0
 *   ② 链表中存在某个 proc 在该偏移上的值 == 1（launchd）
 *
 * 同时要求：所有样本读出来的值都 < 100000（pid 的量级），
 * 避免把一个恰好为 0/1 的无关字段误认成 pid。
 *
 * 返回偏移；找不到返回 0。
 */
static uint32_t mf_scan_p_pid_offset(const uint64_t *procs, int count,
                                     int *out_launchd_index)
{
    if (count < 2) {
        return 0;
    }

    /* 最多取前 64 个样本做校验，够用且快 */
    int sample = (count < 64) ? count : 64;

    for (uint32_t off = MF_PID_SCAN_START; off < MF_PID_SCAN_END; off += 4) {
        uint32_t v0 = 0;
        if (mf_kread32(procs[0] + off, &v0) != 0 || v0 != 0) {
            continue;                    /* ① kernel_proc 的 pid 必须是 0 */
        }

        int launchd_idx = -1;
        int plausible = 0;
        int ok = 1;
        for (int i = 1; i < sample; i++) {
            uint32_t v = 0;
            if (mf_kread32(procs[i] + off, &v) != 0) {
                ok = 0;
                break;
            }
            if (v > 100000) {            /* pid 不会这么大 → 这个偏移不是 pid */
                ok = 0;
                break;
            }
            if (v > 0) {
                plausible++;
            }
            if (v == 1 && launchd_idx < 0) {
                launchd_idx = i;         /* ② 找到 launchd */
            }
        }
        if (!ok) {
            continue;
        }
        /* 绝大多数进程 pid 应该非零；且必须能找到 pid==1 */
        if (launchd_idx > 0 && plausible >= sample / 2) {
            if (out_launchd_index) {
                *out_launchd_index = launchd_idx;
            }
            return off;
        }
    }
    return 0;
}

uint64_t mf_find_proc_by_pid(int pid, char *report, size_t report_len)
{
    if (g_kfd == NULL) {
        if (report && report_len) {
            snprintf(report, report_len, "KFD 未打开");
        }
        return 0;
    }

    static uint64_t procs[MF_PROC_WALK_MAX];
    int count = mf_collect_proc_chain(procs, MF_PROC_WALK_MAX);
    if (count <= 0) {
        if (report && report_len) {
            snprintf(report, report_len, "proc 链表为空（kernel_proc=0x%llx）",
                     (unsigned long long)mf_get_kernel_proc());
        }
        return 0;
    }

    /*
     * ★ [M5.111] 先用已验证的固定偏移 0x60 走一遍。
     *
     * p_pid = 0x60 是 M5.107 真机确认过的（kernel_proc 读出 0），
     * kfdmemdump 的 off_p_pid 也是 0x60。原来的做法是"先猜偏移再找 pid"，
     * 一旦链表节点数不足就直接放弃 —— 现在反过来了：先按已知偏移找，
     * 找不到才退回到自适应扫描。
     */
    for (int i = 0; i < count; i++) {
        uint32_t v = 0;
        if (mf_kread32(procs[i] + 0x60, &v) != 0) {
            continue;
        }
        if ((int)v == pid) {
            if (report && report_len) {
                snprintf(report, report_len,
                         "找到 pid=%d -> proc=0x%llx (p_pid 偏移=0x60, 链表 %d 个)",
                         pid, (unsigned long long)procs[i], count);
            }
            return procs[i];
        }
    }

    int launchd_idx = -1;
    uint32_t pid_off = mf_scan_p_pid_offset(procs, count, &launchd_idx);
    if (pid_off == 0) {
        if (report && report_len) {
            snprintf(report, report_len,
                     "链表中没有 pid=%d，且没能定出 p_pid 偏移"
                     "(扫了 0x%X..0x%X，链表中 %d 个 proc)",
                     pid, MF_PID_SCAN_START, MF_PID_SCAN_END, count);
        }
        return 0;
    }

    for (int i = 0; i < count; i++) {
        uint32_t v = 0;
        if (mf_kread32(procs[i] + pid_off, &v) != 0) {
            continue;
        }
        if ((int)v == pid) {
            if (report && report_len) {
                snprintf(report, report_len,
                         "找到 pid=%d → proc=0x%llx（p_pid 偏移=0x%X，链表 %d 个）",
                         pid, (unsigned long long)procs[i], pid_off, count);
            }
            return procs[i];
        }
    }

    if (report && report_len) {
        snprintf(report, report_len,
                 "链表里没有 pid=%d（p_pid 偏移=0x%X，链表中 %d 个 proc）",
                 pid, pid_off, count);
    }
    return 0;
}

/* ================================================================ */
/* 5b) 跨进程：pid -> 目标 pmap -> 目标页表根（M5.108 / M5.226）      */
/* ================================================================ */

/*
 * PAC strip —— 按**本机实测的内核 VA 布局**取掩码，不照 SoC 名猜。
 *
 * [M5.231] 上一版改成读 kfd 的 T1SZ_BOOT（本机被它判成 25）。但实测证据说明
 * 这台机器的内核 VA 是 47 位布局：
 *     gVirtBase  = 0xfffffe001261c000   （M5.107 校准输出）
 *     kernelbase = 0xfffffff01fa80000   （kfd.log，kslide = 0x18a7c000）
 * 两个值都在 0xfffffe00_00000000 之上、0xffffff80_00000000 之下 ——
 * 若真是 39 位（下界 0xffffff80…），它们根本不可能存在。
 * kfd 的 t1sz_boot 只服务它自己的 UNSIGN_PTR，而且是按内核版本串里的芯片名
 * 挑的（本机 RELEASE_ARM64_T8020 不在它的 17 名单里），与本机页表布局无关。
 */
static uint64_t mf_bridge_unsign(uint64_t p)
{
    if (p == 0) {
        return 0;
    }
    uint64_t ptr_mask = (1ULL << (64u - 17u)) - 1ULL;   /* 47 位 VA */
    uint64_t pac_mask = ~ptr_mask;
    if (p & (1ULL << 55)) {                             /* 与 static_info.h 的 SIGN(p) 一致 */
        return p | pac_mask;
    }
    return p & ~pac_mask;
}

/*
 * [M5.229] 内核 VA 域：高 16 位全 1。
 *
 * M5.226 把下界抬到 0xfffffe0000000000，但本机的实测值（gVirtBase =
 * 0xfffffe001261c000、kernelbase = 0xfffffff01fa80000）都在这个下界**之上**，
 * 所以那条下界在本机并不误杀；而 0xfffffdf0... 那个"被误杀"的记录（M5.100）
 * 与 t1sz=25 的 0xffffff80 下界同样矛盾，只能当成一次误读。
 *
 * [M5.231] 这里只做"高 16 位全 1"的粗筛，真正的门是下面的 mf_bridge_kaddr_mapped：
 * panic 里那个 0xffffff8d000002a4 也满足"高位全 1"，照样让内核 panic。
 * 换句话说，下界松紧不是安全边界，映射检查才是。
 */
static int mf_bridge_is_kernel_va(uint64_t a)
{
    return a >= 0xffff000000000000ULL;
}

/* 页表根一定是页对齐的；先用它挡掉扫描里的大量野指针。 */
static int mf_bridge_is_page_aligned(uint64_t a)
{
    return (a & 0xfffULL) == 0;
}

/*
 * [M5.231] 解引用前的最后一道闸：这个地址在内核自己的页表里到底映没映。
 *
 * 为什么必须有 —— 真机 panic 原文（panic-full-2026-10-27-162314.000.ips）：
 *     panic(cpu 2 caller ...): copy_validate(0x16f8c6258, 0xffffff8d000002a4, 8)
 *         - kaddr not in kernel @copyio.c:194
 * 那个地址高位全 1、看着像内核指针，但根本没有映射；kread 一碰，
 * copy_validate 直接 panic，设备重启。任何"只判高位/只判下界"的守卫都挡不住它。
 *
 * 所以：凡是**不是我们亲手派生出来的**指针（proc 里的字段、task/map/pmap 上一跳
 * 读到的值），读之前都要先问内核页表：能不能翻译？
 *   - 用 kfd 在 kopen 时抓到的 ttbr1（内核页表根，可信）做翻译；
 *   - 翻译只读页表页，不碰目标地址本身；
 *   - 拿不到根表就一律拒绝（宁可校准失败，也不拿设备赌）。
 */
static int mf_bridge_kaddr_mapped(uint64_t a)
{
    if (!mf_bridge_is_kernel_va(a)) {
        return 0;
    }
    uint64_t root = 0;
    if (mf_ttbr_snapshot(NULL, NULL, NULL, &root) != 0 || !mf_bridge_is_kernel_va(root)) {
        return 0;
    }
    uint64_t pa = 0;
    return mfpt_translate(root, a, &pa) == 0;
}

typedef struct {
    uint64_t proc;       /* 起点：kernel_proc、目标进程的 proc，或本进程 proc */
    uint64_t want_base;  /* 期望从这个根表读到的 Mach-O 基址；0 = 自动找最低映射页 */
    int auto_base;       /* want_base 为 0 时，第一次成功定位到基址就用它 */

    /* 最近一次探测的现场（诊断用） */
    uint64_t task, map, pmap, root;
    unsigned hop;        /* 这次探测的链形状：1 = task 内嵌，2 = 经 proc_ro */
    int stage;
    char why[220];
} mf_chain_probe;

static int g_chain_offsets_known;
static mfcal_offsets g_chain_offsets;

/*
 * 判据：这组偏移解出来的页表根，必须能读回 Mach-O 头 0xfeedfacf。
 * 这是整条链上唯一不可伪造的一步 —— 野指针能凑出"像内核地址"的值，
 * 但凑不出一张能翻译出 Mach-O 头的页表。
 */
static int mf_chain_root_reads_macho(uint64_t root, uint64_t want_base, uint64_t *base_out)
{
    if (!mf_bridge_is_kernel_va(root) || !mf_bridge_is_page_aligned(root)) {
        return 0;
    }
    mfpt_cache_reset();

    uint64_t base = want_base;
    if (base == 0) {
        if (mfpt_lowest_mapped_page(root, 0x100000000ULL, &base) != 0 || base == 0) {
            return 0;
        }
    }
    uint32_t magic = 0;
    if (mfpt_read(root, base, &magic, sizeof(magic)) != 0) {
        return 0;
    }
    if (magic != 0xfeedfacf) {
        return 0;
    }
    if (base_out) *base_out = base;
    return 1;
}

/*
 * [M5.231] 失败诊断：只报告 proc 里"映射在内核里"的指针偏移，**一次都不解引用它们**。
 *
 * 上一版（M5.229）为了找"task 形状"会顺着 proc 字段一路读到 task+0x28、map+0x40，
 * 每个候选要读 4 次内存。proc 里的字段是可被随意伪造的值（PAC 标签、计数器、
 * 长度字段都长得像指针），于是它们被当成地址去读 —— 内核在 copy_validate 里
 * 直接 panic（真机证据：copy_validate(..., 0xffffff8d000002a4, 8)）。
 *
 * 现在只做一次读：*(proc+off)，然后问内核页表"这个值映没映"。映射结果本身
 * 就是有用信息：区间够不够、proc 起点对不对，看"有没有映射指针、落在哪些偏移"，
 * 不需要拿设备去试探。
 */
static void mf_chain_describe_task_like(uint64_t proc, uint32_t limit,
                                        char *out, size_t cap)
{
    unsigned listed = 0;

    if (out == NULL || cap == 0) return;
    if (limit > 0x400u) limit = 0x400u;      /* 诊断同样有上界 */

    for (uint32_t off = 0; off <= limit; off += 8u) {
        uint64_t p = 0;
        if (mf_kread64(proc + off, &p) != 0) continue;
        p = mf_bridge_unsign(p);
        if (!mf_bridge_kaddr_mapped(p)) continue;

        if (listed < 3u) {
            size_t used = strlen(out);
            snprintf(out + used, cap - used, "%smapped@%#x", used ? " " : "", (unsigned)off);
        }
        ++listed;
    }

    if (listed == 0) {
        size_t used = strlen(out);
        snprintf(out + used, cap - used, "no-mapped-pointer-in-proc");
    }
}

static int mf_chain_probe_fn(void *ctx, const mfcal_offsets *offsets)
{
    mf_chain_probe *p = (mf_chain_probe *)ctx;
    uint64_t v = 0;

    p->task = p->map = p->pmap = p->root = 0;
    p->hop = offsets->proc_hop;

    /* 1) proc -> task
     *
     * iOS 15：task 内嵌在 proc 里（Dopamine 基线 proc.task = 0x10），一跳到底。
     * iOS 16：内嵌字段被移除，proc+0x18 是 p_ro，pr_task 在 proc_ro+0x08
     *         （xnu proc_ro.h 的头两个字段就是 pr_proc / pr_task）。
     * 这一跳是整条链上唯一随系统版本换形状的地方，所以形状本身要进搜索空间。
     */
    if (mf_kread64(p->proc + offsets->proc_task, &v) != 0) {
        snprintf(p->why, sizeof(p->why), "read proc+0x%x failed", (unsigned)offsets->proc_task);
        return 0;
    }
    v = mf_bridge_unsign(v);
    if (!mf_bridge_kaddr_mapped(v)) {
        snprintf(p->why, sizeof(p->why), "proc+0x%x -> %#llx unmapped",
                 (unsigned)offsets->proc_task, (unsigned long long)v);
        return 0;
    }

    if (offsets->proc_hop == 2u) {
        uint64_t t = 0;
        if (mf_kread64(v + offsets->proc_task2, &t) != 0) {
            snprintf(p->why, sizeof(p->why), "read proc_ro(%#llx)+0x%x failed",
                     (unsigned long long)v, (unsigned)offsets->proc_task2);
            return 0;
        }
        t = mf_bridge_unsign(t);
        if (!mf_bridge_kaddr_mapped(t)) {
            snprintf(p->why, sizeof(p->why), "proc_ro+0x%x -> %#llx unmapped",
                     (unsigned)offsets->proc_task2, (unsigned long long)t);
            return 0;
        }
        v = t;
    }
    p->task = v;

    /* 2) task -> vm_map */
    if (mf_kread64(p->task + offsets->task_map, &v) != 0) {
        snprintf(p->why, sizeof(p->why), "read task+0x%x failed", (unsigned)offsets->task_map);
        return 0;
    }
    v = mf_bridge_unsign(v);
    if (!mf_bridge_kaddr_mapped(v)) {
        snprintf(p->why, sizeof(p->why), "task+0x%x -> %#llx unmapped",
                 (unsigned)offsets->task_map, (unsigned long long)v);
        return 0;
    }
    p->map = v;

    /* 3) vm_map -> pmap
     *
     * 只要求"映射在内核里"：pmap 从 zone 分配，没有"必须页对齐"这条约束
     * （页表根本身才必须对齐，见下一跳）。
     */
    if (mf_kread64(p->map + offsets->map_pmap, &v) != 0) {
        snprintf(p->why, sizeof(p->why), "read map+0x%x failed", (unsigned)offsets->map_pmap);
        return 0;
    }
    v = mf_bridge_unsign(v);
    if (!mf_bridge_kaddr_mapped(v)) {
        snprintf(p->why, sizeof(p->why), "map+0x%x -> %#llx unmapped",
                 (unsigned)offsets->map_pmap, (unsigned long long)v);
        return 0;
    }
    p->pmap = v;

    /* 4) pmap -> tte（根表） */
    if (mf_kread64(p->pmap, &v) != 0) {
        snprintf(p->why, sizeof(p->why), "read pmap->tte failed");
        return 0;
    }
    v = mf_bridge_unsign(v);
    if (!mf_bridge_kaddr_mapped(v) || !mf_bridge_is_page_aligned(v)) {
        snprintf(p->why, sizeof(p->why), "pmap->tte %#llx unmapped or not page-aligned",
                 (unsigned long long)v);
        return 0;
    }
    p->root = v;

    uint64_t base = 0;
    if (!mf_chain_root_reads_macho(p->root, p->want_base, &base)) {
        snprintf(p->why, sizeof(p->why), "root %#llx cannot read a Mach-O header at %#llx",
                 (unsigned long long)p->root, (unsigned long long)p->want_base);
        return 0;
    }
    if (p->want_base == 0 && p->auto_base == 0 && base != 0) {
        p->auto_base = 1;
    }
    return 1;
}

/* 把命中的链形状写成一行可读文本（报告/落盘共用）。 */
static const char *mf_chain_shape_text(const mfcal_offsets *o, char *buf, size_t cap)
{
    if (o == NULL || buf == NULL || cap == 0) return "";
    if (o->proc_hop == 2u) {
        snprintf(buf, cap, "2hop %#x/%#x/%#x/%#x",
                 (unsigned)o->proc_task, (unsigned)o->proc_task2,
                 (unsigned)o->task_map, (unsigned)o->map_pmap);
    } else {
        snprintf(buf, cap, "1hop %#x/%#x/%#x",
                 (unsigned)o->proc_task, (unsigned)o->task_map, (unsigned)o->map_pmap);
    }
    return buf;
}

/*
 * 校准：先问本进程，再问内核。
 *
 * ① 本进程 + 自己的 Mach-O 基址：真值来自 dyld（dladdr），判据与等一下要用在
 *    游戏上的完全同构 —— 同一个用户地址空间、同一张用户 pmap、同一个
 *    0xfeedfacf。它不碰内核那一半页表，也不碰 patchfinder 的 kbase。
 * ② kernel_proc + kernelbase：两者都不依赖 proc 布局（kernproc 符号直读、
 *    kbase = ARM64_LINK_ADDR + slide），但要求"走内核那一半页表"可用；
 *    本工程的分级宏按 t1sz=17（47 位）写，而 A12X/A12Z 是 t1sz=25（39 位），
 *    这一条在非 A16/M1/M2 的设备上本来就是没被证过的，所以放在 ① 后面兜底。
 *
 * 注意不要用 kfd 的 current_task/current_map：kfd 的 iOS16 条目里
 * proc__object_size = 0，于是 current_task == current_proc，那两个值是错的。
 */
static uint64_t mf_self_image_base(void)
{
    Dl_info info;
    memset(&info, 0, sizeof(info));
    /* 用已经定义好的函数取地址即可：dladdr 要的是"本 image 里的任意符号"。 */
    if (dladdr((const void *)&mf_chain_probe_fn, &info) == 0 || info.dli_fbase == NULL) {
        return 0;
    }
    return (uint64_t)(uintptr_t)info.dli_fbase;
}

static int mf_chain_calibrate_locked(void)
{
    mf_chain_probe probe;
    mfcal_result r;

    /*
     * ① 本进程锚点（先跑）：自己的 executable 基址 + 自己的用户页表根。
     *
     * 为什么排第一：这条判据与等一下要用在游戏上的**完全同构** —— 同一个
     * 用户地址、同一张用户 pmap、同一个 0xfeedfacf。而内核锚点要走内核那一半
     * 页表（TTBR1），本工程的分级宏是按 t1sz=17（47 位）写的；A12X/A12Z 这类
     * t1sz=25（39 位）的机器上，"走内核那一半"本身就没被证过（M5.107 只在
     * A16 上验过）。先跑自己这一条，能把"偏移不对"和"锚点不对"分开。
     */
    uint64_t self_base = mf_self_image_base();
    if (self_base != 0) {
        uint64_t self_proc = mf_find_proc_by_pid((int)getpid(), NULL, 0);
        if (self_proc != 0 && mf_bridge_is_kernel_va(self_proc)) {
            memset(&probe, 0, sizeof(probe));
            probe.proc = self_proc;
            probe.want_base = self_base;
            r = mfcal_run(mf_chain_probe_fn, &probe, MFCAL_SAFE_BUDGET);
            if (r.found) {
                g_chain_offsets = r.offsets;
                g_chain_offsets_known = 1;
                return 1;
            }
        }
    }

    /*
     * ② 内核锚点（兜底）：kernel_proc + kernelbase。
     * 两者都不依赖 proc 布局（kernproc 符号直读、kbase = ARM64_LINK_ADDR + slide），
     * 前提是 patchfinder 算出的 kbase 恰好指向 Mach-O 头、且内核那一半页表走得通。
     */
    uint64_t kernel_proc = mf_get_kernel_proc();
    uint64_t kbase = mf_get_kbase();
    if (mf_bridge_is_kernel_va(kernel_proc) && mf_bridge_is_kernel_va(kbase)) {
        memset(&probe, 0, sizeof(probe));
        probe.proc = kernel_proc;
        probe.want_base = kbase;
        r = mfcal_run(mf_chain_probe_fn, &probe, MFCAL_SAFE_BUDGET);
        if (r.found) {
            g_chain_offsets = r.offsets;
            g_chain_offsets_known = 1;
            return 1;
        }
    }
    return 0;
}

/*
 * [M5.226] pid -> proc -> task -> vm_map -> pmap -> tte。
 *
 * 与 M5.225 的区别：不再依赖写死的三跳，也不靠"候选池猜"。
 * 校准优先走内核对自身（真值最硬），校准不到再用目标进程自己当锚点。
 * 命中结果缓存，同一内核下只付一次代价。
 */
static int mf_pid_chain_locked(int pid, uint64_t *proc_out, uint64_t *task_out, uint64_t *map_out,
                 uint64_t *pmap_out, uint64_t *root_out, char *report, size_t report_len)
{
    if (g_kfd == NULL) {
        if (report && report_len) {
            snprintf(report, report_len, "KFD 未打开");
        }
        return -1;
    }

    uint64_t proc = mf_find_proc_by_pid(pid, report, report_len);
    if (proc == 0) {
        return -2;
    }
    if (!mf_bridge_is_kernel_va(proc)) {
        if (report && report_len) {
            snprintf(report, report_len, "proc=%#llx 不在内核 VA 域", (unsigned long long)proc);
        }
        return -3;
    }

    mf_chain_probe probe;
    memset(&probe, 0, sizeof(probe));
    probe.proc = proc;

    /* ① 已有校准结果：直接套用，一次探测即可确认它对这个进程也成立 */
    if (g_chain_offsets_known) {
        mfcal_offsets cached = g_chain_offsets;
        if (mf_chain_probe_fn(&probe, &cached)) {
            if (proc_out) *proc_out = proc;
            if (task_out) *task_out = probe.task;
            if (map_out)  *map_out = probe.map;
            if (pmap_out) *pmap_out = probe.pmap;
            if (root_out) *root_out = probe.root;
            if (report && report_len) {
                char shape[64];
                snprintf(report, report_len,
                         "pid=%d proc=%#llx root=%#llx chain %s cached",
                         pid, (unsigned long long)proc, (unsigned long long)probe.root,
                         mf_chain_shape_text(&cached, shape, sizeof(shape)));
            }
            return 0;
        }
    }

    /* ② 首次（或校准失效）：先拿内核对自身校准 —— 真值最硬 */
    if (!g_chain_offsets_known) {
        (void)mf_chain_calibrate_locked();
        if (g_chain_offsets_known) {
            mfcal_offsets cached = g_chain_offsets;
            memset(&probe, 0, sizeof(probe));
            probe.proc = proc;
            if (mf_chain_probe_fn(&probe, &cached)) {
                if (proc_out) *proc_out = proc;
                if (task_out) *task_out = probe.task;
                if (map_out)  *map_out = probe.map;
                if (pmap_out) *pmap_out = probe.pmap;
                if (root_out) *root_out = probe.root;
                if (report && report_len) {
                    char shape[64];
                    snprintf(report, report_len,
                             "pid=%d proc=%#llx root=%#llx chain %s calibrated",
                             pid, (unsigned long long)proc, (unsigned long long)probe.root,
                             mf_chain_shape_text(&cached, shape, sizeof(shape)));
                }
                return 0;
            }
        }
    }

    /* ③ 内核校准不可用：退到"用目标进程自己当锚点"扫一遍 */
    {
        mf_chain_probe scan_probe;
        memset(&scan_probe, 0, sizeof(scan_probe));
        scan_probe.proc = proc;
        scan_probe.want_base = 0;   /* 自动取该进程最低映射页 */

        mfcal_result scan = mfcal_run(mf_chain_probe_fn, &scan_probe, MFCAL_SAFE_BUDGET);
        if (scan.found) {
            g_chain_offsets = scan.offsets;
            g_chain_offsets_known = 1;
            if (proc_out) *proc_out = proc;
            if (task_out) *task_out = scan_probe.task;
            if (map_out)  *map_out = scan_probe.map;
            if (pmap_out) *pmap_out = scan_probe.pmap;
            if (root_out) *root_out = scan_probe.root;
            if (report && report_len) {
                char shape[64];
                snprintf(report, report_len,
                         "pid=%d proc=%#llx root=%#llx chain %s stage=%d probes=%u",
                         pid, (unsigned long long)proc, (unsigned long long)scan_probe.root,
                         mf_chain_shape_text(&scan.offsets, shape, sizeof(shape)),
                         scan.stage, scan.probed);
            }
            return 0;
        }

        if (report && report_len) {
            /*
             * 失败现场要能回答四个问题而不是三个：
             *   proc 指针是多少、整轮扫了多少组、最后停在哪一组、
             *   以及 proc 里有没有"task 形状"的候选（有 → 形状/偏移问题；
             *   只有裸内核指针没有 task 形状 → proc 指针本身可疑）。
             */
            char shape[120];
            shape[0] = '\0';
            mf_chain_describe_task_like(proc, MFCAL_SWEEP_LAST, shape, sizeof(shape));
            snprintf(report, report_len,
                     "calib fail; proc=%#llx probes=%u stage=%d %s; %s",
                     (unsigned long long)proc, scan.probed, scan.stage,
                     shape, scan_probe.why);
        }
        return -4;
    }
}
// [M5.207] mf_clear_proc_csflags 已移除：它只为 task_for_pid 清目标 csflags。

// [M5.207] 5b) TF_PLATFORM 段整体移除。
//
// 这一段原本是给 task_for_pid 服务的：先清目标进程的 csflags（5 段），
// 再给自己的 task 置 TF_PLATFORM，让 task_conversion_eval 放行。
// 读取改走 KFD 页表之后，读取链上不再有 task_for_pid，两个写入口同时失去意义，
// 于是连同它们的扫描/试错逻辑一起删除 —— 内核侧现在没有任何写入点。
// 保留这段注释是为了让后来者知道：这里曾经有过代码，为什么被删，别再装回去。

/*
 * [M5.207] mf_prepare_task_for_pid 已移除。
 *
 * 它存在的唯一目的是「先把目标进程的 csflags 清掉，再试 task_for_pid」。
 * 读取改成纯 KFD 页表之后，这条链上就没有 task_for_pid 了，函数随之删除：
 * 保留下来的话，下一个接手的人很容易顺手把它接回绑定流程，
 * 等于把已经消掉的目标进程改动又装回去。
 */

/* ================================================================ */
/* 5e) 内核写入审计（清痕自证）                                       */
/* ================================================================ */
/*
 * 「清痕」最省事的做法是改完再回滚，但那本身就要求先改一次。
 * 这里改成：统计整场会话里到底往内核写了多少次。
 *
 * 期望值是 0 —— 读取走页表，目标进程与自身 task 都不需要写。
 * 被动状态文件会带上这两个计数，现场可以直接核对"这一轮有没有写过内核"，
 * 而不是靠代码注释声称自己很干净。
 */
static volatile uint64_t g_kernel_write_count = 0;
static volatile uint64_t g_kernel_write_bytes = 0;

/* [M5.208] 内核初始化（触发 + 内部清痕）的耗时与完成标志。-1 / 0 表示没走通。 */
static double g_kopen_ms = -1.0;
static int g_cleanup_done = 0;

uint64_t mf_kernel_write_count(void) { return g_kernel_write_count; }
uint64_t mf_kernel_write_bytes(void) { return g_kernel_write_bytes; }

void mf_kernel_write_audit_reset(void) {
    g_kernel_write_count = 0;
    g_kernel_write_bytes = 0;
}

/* ================================================================ */
/* 6) 诊断                                                           */
/* ================================================================ */

const char *mf_last_error(void)
{
    return (g_err[0] != '\0') ? g_err : "no error";
}

const char *mf_last_stage(void)
{
    return (g_stage[0] != '\0') ? g_stage : "(not started)";
}

const char *mf_last_error_site(void)
{
    return (g_site[0] != '\0') ? g_site : "n/a";
}

void mf_set_verbose(int enabled)
{
    g_verbose = enabled ? 1 : 0;
}

/* ================================================================ */
/* 6) libkfd 宿主支撑层：替代被丢弃的 fun/krw.m                     */
/* ================================================================ */

/*
 * ★★ 这里有一个曾经致命的细节，改之前务必看懂 ★★
 *
 * kread() 最终落到 krkw.h 的这个宏：
 *
 *     #define kread_from_method(type, method)                  \
 *         u64 type_size = ((size) / (sizeof(type)));           \
 *         for (u64 i = 0; i < type_size; i++) { ... }          \
 *
 *   kread_sem_open 后端用的 type 是 u64（sizeof = 8）。
 *   所以 size 必须是 8 的倍数，否则 type_size 会算成 0 ——
 *   【一次循环都不进，输出缓冲区原封不动】。
 *
 *   size=4  →  4/8 = 0  →  什么都没读，缓冲区保持调用者原值（通常是 0）
 *
 * 上游 fun/krw.m 的 early_kreadbuf 之所以正确，是因为它走
 *   early_kread32 → early_kread64 → kread(..., sizeof(uint64_t))
 * 也就是「读 8 字节，再截成 32 位」。
 *
 * 第一版移植直接写了 kread(..., 4)，结果整个 patchfinder 读到的全是 0，
 * pfinder_init_kernel 看到 mh64.magic != MH_MAGIC_64 直接失败 ——
 * 真机上表现为 "run_kfd_patchfinder failed at krkw.h:230"。
 *
 * 教训：在 header-only 的宏后端上，「等价实现」必须看宏展开，不能看调用名。
 */
void MFLibkfdKRead4(uint64_t kfd, uint64_t kaddr, void *buf, size_t size)
{
    if (kfd == 0 || buf == NULL || size == 0) {
        return;
    }

    unsigned char *out = (unsigned char *)buf;
    size_t written = 0;

    for (uint64_t cur = kaddr; written < size; cur += 4) {
        /*
         * [M5.106] 这里以前是裸 kread，绕过了 mf_kread* 的地址闸。
         * 补丁器在 kopen 阶段扫内核，一旦算错基址就会拿用户地址去读 8 字节，
         * 内核在 copy_validate 里直接 panic 重启：
         *     panic-full-2026-10-24-235936  copy_validate(0x16bf0ec68, -1, 8)
         * 现在越界一律填 0 并返回：patchfinder 会看到 magic 不对而正常失败，
         * 而不是把整机带走。
         */
        if (cur < 0xffff000000000000ULL ||
            cur > 0xffffffffffffffffULL - sizeof(uint64_t)) {
            g_mf_denied_kaddr = cur;
            g_mf_denied_count++;
            if (written < size) {
                memset(out + written, 0, size - written);
            }
            return;
        }

        /* 读 8 字节（必须），只取低 4 字节用 —— 与上游 early_kread32 等价 */
        uint64_t chunk64 = 0;
        kread((u64)kfd, cur, &chunk64, sizeof(chunk64));

        const unsigned char *b = (const unsigned char *)&chunk64;
        for (int i = 0; i < 4 && written < size; i++) {
            out[written++] = b[i];
        }
    }
}

/* ================================================================ */
/* 9) 串行化包装（[M5.135]）                                          */
/* ================================================================ */
/*
 * 所有会碰 g_kfd / KRKW 后端的入口都从这里进：拿锁 → 原始实现 → 放锁。
 * 加锁范围覆盖 setjmp 区域，所以断言 longjmp 回来时仍在同一线程持锁，
 * 返回前一定会解锁（不存在"跳到别人栈帧"的路径）。
 *
 * 注意：mf_kwrite32_locked 内部会调 mf_kread64（公开版），mfpt_* 里会调
 * mf_kread32 —— 都依赖递归锁，不能改成普通互斥量。
 */

int mf_kopen(uint64_t puaf_pages, int puaf_method, int kread_method, int kwrite_method)
{
    /*
     * [M5.208] 记录"触发 → 清痕"这一段到底发生了没有、花了多久。
     *
     * 为什么在这里计时：puaf_cleanup 是 libkfd 在 kopen 内部（info_run 之后）
     * 自己做完的（libkfd.h:338），我们拿不到那一步的独立计时，但可以证明
     * 整个 kopen 走完了 —— 走完就意味着 cleanup 执行过。把它作为被动状态里的
     * 一条现场证据，而不是让后来者只看到一句注释。
     */
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    mf_lock_kernel();
    int rc = mf_kopen_locked(puaf_pages, puaf_method, kread_method, kwrite_method);
    mf_unlock_kernel();
    gettimeofday(&t1, NULL);
    if (rc == 0) {
        g_kopen_ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_usec - t0.tv_usec) / 1000.0;
        g_cleanup_done = 1;      /* kopen 返回 0 = puaf_cleanup 已在内部执行 */
    } else {
        g_kopen_ms = -1.0;
        g_cleanup_done = 0;
    }
    return rc;
}

double mf_kernel_open_ms(void) { return g_kopen_ms; }
int mf_kernel_cleanup_done(void) { return g_cleanup_done; }

void mf_kclose(void)
{
    mf_lock_kernel();
    mf_kclose_locked();
    mf_unlock_kernel();
    /* [M5.208] 通道关闭：痕迹清理状态不再成立，重新初始化时再置位。 */
    g_cleanup_done = 0;
}

int mf_kread(uint64_t kaddr, void *uaddr, uint64_t size)
{
    mf_lock_kernel();
    int rc = mf_kread_locked(kaddr, uaddr, size);
    mf_unlock_kernel();
    return rc;
}

int mf_kwrite(void *uaddr, uint64_t kaddr, uint64_t size)
{
    mf_lock_kernel();
    int rc = mf_kwrite_locked(uaddr, kaddr, size);
    mf_unlock_kernel();
    if (rc == 0) { g_kernel_write_count++; g_kernel_write_bytes += size; }
    return rc;
}

int mf_kread32(uint64_t kaddr, uint32_t *out)
{
    mf_lock_kernel();
    int rc = mf_kread32_locked(kaddr, out);
    mf_unlock_kernel();
    return rc;
}

int mf_kread64(uint64_t kaddr, uint64_t *out)
{
    mf_lock_kernel();
    int rc = mf_kread64_locked(kaddr, out);
    mf_unlock_kernel();
    return rc;
}

int mf_kwrite32(uint64_t kaddr, uint32_t value)
{
    mf_lock_kernel();
    int rc = mf_kwrite32_locked(kaddr, value);
    mf_unlock_kernel();
    if (rc == 0) { g_kernel_write_count++; g_kernel_write_bytes += 4; }
    return rc;
}

int mf_kwrite64(uint64_t kaddr, uint64_t value)
{
    mf_lock_kernel();
    int rc = mf_kwrite64_locked(kaddr, value);
    mf_unlock_kernel();
    if (rc == 0) { g_kernel_write_count++; g_kernel_write_bytes += 8; }
    return rc;
}

int mf_pid_chain(int pid, uint64_t *proc_out, uint64_t *task_out, uint64_t *map_out,
                 uint64_t *pmap_out, uint64_t *root_out, char *report, size_t report_len)
{
    mf_lock_kernel();
    int rc = mf_pid_chain_locked(pid, proc_out, task_out, map_out,
                                 pmap_out, root_out, report, report_len);
    mf_unlock_kernel();
    return rc;
}
