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

/*
 * 由 [MF PATCH 01] 打进 libkfd/common.h 的 assert 宏调用。
 * 上游行为：print -> sleep(30) -> exit(1)。
 * 现在：记录诊断 ->（若已 armed）longjmp 回 mf_kopen。
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

    if (g_fail_armed) {
        g_fail_armed = 0;
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

int mf_kread(uint64_t kaddr, void *uaddr, uint64_t size)
{
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kread: not open");
        return -1;
    }
    if (size == 0) {
        return 0;
    }

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

int mf_kwrite(void *uaddr, uint64_t kaddr, uint64_t size)
{
    if (g_kfd == NULL) {
        mf_strlcpy(g_err, sizeof(g_err), "mf_kwrite: not open");
        return -1;
    }
    if (size == 0) {
        return 0;
    }

    if (setjmp(g_fail_jmp) == 0) {
        g_fail_armed = 1;
        kwrite((u64)(uintptr_t)g_kfd, uaddr, kaddr, size);
        g_fail_armed = 0;
    } else {
        g_fail_armed = 0;
        return -1;
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
            kread((u64)(uintptr_t)g_kfd, kaddr, out, sizeof(*out));
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
/* 5) 诊断                                                           */
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
 * 与 fun/krw.m 的 early_kreadbuf()（L51-70）逐字节等价：
 *   从 kaddr 起每 4 字节调一次 libkfd 的 kread()，
 *   按小端铺进输出缓冲，末尾不足 4 字节按需截断。
 *
 * 之所以不一次读完整 size：sem_open 后端的 64-bit 读法在页边界会连带
 * 读到上一页（writeups/exploiting-puafs.md L182-188）。逐 4 字节能把
 * 每次读限制在同一个 16K 页内。libdimentio 的 pfinder_* 全靠它
 * 在内核内存里遍历 __TEXT_EXEC.__text 与 __TEXT.__cstring。
 */
void MFLibkfdKRead4(uint64_t kfd, uint64_t kaddr, void *buf, size_t size)
{
    if (kfd == 0 || buf == NULL || size == 0) {
        return;
    }

    unsigned char *out = (unsigned char *)buf;
    size_t written = 0;

    for (uint64_t cur = kaddr; written < size; cur += 4) {
        uint32_t chunk = 0;
        kread((u64)kfd, cur, &chunk, sizeof(chunk));

        /* 小端铺字节（iOS 目标为 little-endian，与上游一致）。 */
        const unsigned char *b = (const unsigned char *)&chunk;
        for (int i = 0; i < 4 && written < size; i++) {
            out[written++] = b[i];
        }
    }
}
