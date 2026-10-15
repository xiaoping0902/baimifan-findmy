/*
 * MFKernelBridge.h —— 白米饭复刻 / KFD 内核链对外接口
 *
 * 设计约束（见 docs/kfd-移植清单.md 第 3 节）：
 *   1. 本头文件是【纯 C】且【不包含 libkfd.h】。
 *      原因：app/Sources/Kernel/kfd/libkfd/common.h 里
 *        #define min(a, b) (((a) < (b)) ? (a) : (b))
 *        #define max(a, b) (((a) > (b)) ? (a) : (b))
 *      会污染 C++ 标准库（std::min / std::max / <algorithm> / STL 头）。
 *      业务侧多为 .mm（ObjC++），一旦间接吃进 common.h 就编译报错。
 *   2. 整个工程【有且仅有】MFKernelBridge.c 一个编译单元包含 libkfd.h。
 *      libkfd 是 header-only，kopen/kread/kwrite/kclose/kfd_init/... 都是
 *      没有 static 的普通函数定义；被两个 TU 包含 = 重复符号链接错误。
 *      同理 libkfd/info/dynamic_info.h 里的 struct dynamic_info kern_versions[]
 *      也是无 static 的全局定义。
 *   3. 所以：业务代码（.mm / .m / .c）只 include 本文件。
 *
 * 线程安全：kfd 的 KRKW 后端（sem_open / dup）是有状态的
 *   （对象喷洒 -> 搜索 -> 释放），【禁止并发调用】kread/kwrite。
 *   本桥接不做加锁，建议调用方全程串行 + 单线程。
 */

#ifndef MF_KERNEL_BRIDGE_H
#define MF_KERNEL_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* 常量：与 libkfd.h 的枚举保持数值一致（此处不 include，故手写数值）   */
/* ------------------------------------------------------------------ */

/* enum puaf_method   { puaf_physpuppet, puaf_smith, puaf_landa }      */
#define MF_PUAF_PHYSPUPPET             0
#define MF_PUAF_SMITH                  1
#define MF_PUAF_LANDA                  2

/* enum kread_method  { kread_kqueue_workloop_ctl, kread_sem_open }    */
#define MF_KREAD_KQUEUE_WORKLOOP_CTL   0   /* iOS 16.5+ 被内核封堵，勿用 */
#define MF_KREAD_SEM_OPEN              1

/* enum kwrite_method { kwrite_dup, kwrite_sem_open }                  */
#define MF_KWRITE_DUP                  0
#define MF_KWRITE_SEM_OPEN             1

/*
 * 目标机默认参数：
 *   landa + kread_sem_open + kwrite_sem_open，3072 页
 *
 * 依据：
 *   · physpuppet 修复于 iOS 16.4、smith 修复于 iOS 16.5.1
 *     → 16.6.1 上只剩 landa（CVE-2023-41974，修复于 17.0）
 *   · kread_sem_open 必须与 kwrite_sem_open 成对（krkw.h 里有 assert 拦截）
 *   · 3072 页来自 Dopamine：它对 ≥5GB 设备的原话是
 *     "remarkably more reliable with 3072"
 */
#define MF_DEFAULT_PUAF_PAGES          3072
#define MF_DEFAULT_PUAF_METHOD         MF_PUAF_LANDA
#define MF_DEFAULT_KREAD_METHOD        MF_KREAD_SEM_OPEN
#define MF_DEFAULT_KWRITE_METHOD       MF_KWRITE_SEM_OPEN

/*
 * ★ [M5.14] 上下限 —— 上限从 2048 改成 3072，原因是 Dopamine。
 *
 * 三个来源的 kopen 边界对照（都是 const u64）：
 *     上游 felix-pb/kfd : min = 16, max = 2048
 *     Dopamine          : min = 16, max = 3072   ← ★ 它自己改大了
 *     我们（改前）       : min = 16, max = 2048
 *
 * Dopamine 的 exploit_init 原文：
 *     if (device_memory >= 5GB) {
 *         // These devices are remarkably more reliable with 3072
 *         puaf_pages = 3072;
 *     }
 * 它要用 3072，所以【把 kfd 自己的上限也抬到 3072】。
 * 上游的 2048 不允许 3072 —— 这就是上次
 *     "bad puaf_pages: 3072 (valid range 16..2048)"
 * 的来源。
 *
 * ⚠️ 本文件的上限必须与 libkfd.h 里 kopen 的 puaf_pages_max 一致。
 *    预检规则 check_puaf_limit_consistency() 会盯着这条不变量。
 */
#define MF_PUAF_PAGES_MIN              16
#define MF_PUAF_PAGES_MAX              3072

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */

/*
 * 打开内核读写通道。
 * 成功返回 0；失败返回负值（详细原因见 mf_last_error()）。
 *
 * 与上游 kopen() 的关键差别：上游断言失败会 sleep(30) + exit(1)，
 * 让 App 表现为「卡 30 秒后闪退」。本实现把断言转换成
 * longjmp 回到这里，于是变成「返回错误码 + 错误字符串」，进程存活。
 *
 * 注意：失败返回 -1 后内核态可能留有未清理的 PUAF 页，
 *       此时【不要】在同一进程内反复重试；建议记录错误后重启 App。
 */
int mf_kopen(uint64_t puaf_pages,
             int      puaf_method,
             int      kread_method,
             int      kwrite_method);

/* 用 iPad Pro M2 / 16.6.1 的推荐参数打开（见上方 MF_DEFAULT_*）。 */
int mf_kopen_default(void);

/* 释放内核通道（对应 libkfd 的 kclose）。未打开时是安全的空操作。 */
void mf_kclose(void);

/* 是否已打开。 */
int mf_is_open(void);

/* ------------------------------------------------------------------ */
/* 读写                                                                */
/* ------------------------------------------------------------------ */

/*
 * copyout：把内核地址 kaddr 的 size 字节读到用户缓冲 uaddr。
 * 返回 0 成功 / 负值失败。
 *
 * 页边界提醒（writeups/exploiting-puafs.md）：kread 在页边界可能连带读到
 * 上一页。若读单字段请优先用 mf_kread32() 这类 4 字节对齐读法。
 */
int mf_kread(uint64_t kaddr, void *uaddr, uint64_t size);

/*
 * copyin：把用户缓冲 uaddr 的 size 字节写到内核地址 kaddr。
 * 返回 0 成功 / 负值失败。
 *
 * 【已证】kwrite 不能写 0（底层靠 fd / 对象字段表达值，0 不可表达）——
 * 见 writeups/exploiting-puafs.md L189-192。
 * 需要「置 0」时用等价改法：写非零哨兵、改指针、或改上层字段。
 */
int mf_kwrite(void *uaddr, uint64_t kaddr, uint64_t size);

/* 便捷读写（内部保证不跨页边界的 4 字节读法）。 */
int      mf_kread32(uint64_t kaddr, uint32_t *out);
int      mf_kread64(uint64_t kaddr, uint64_t *out);
int      mf_kwrite32(uint64_t kaddr, uint32_t value);
int      mf_kwrite64(uint64_t kaddr, uint64_t value);

/* ------------------------------------------------------------------ */
/* 地址信息                                                            */
/* ------------------------------------------------------------------ */

/* 内核基址（KASLR 破开后的真实 kbase）。未打开返回 0。 */
uint64_t mf_get_kbase(void);

/* 内核滑动 = kbase - vm_kernel_link_addr。未打开返回 0。 */
uint64_t mf_get_kslide(void);

/*
 * M1/M2 的内核链接基址（T8103/T8112 = 0xFFFFFE0007004000，
 * 其它 = 0xFFFFFFF007004000）。由 kpf/patchfinder.m 运行时判定。
 */
uint64_t mf_get_vm_kernel_link_addr(void);

/* 目标机内核版本串（sysctl kern.version）。始终可调用，不依赖 kopen。 */
const char *mf_kernel_version(void);

/* KASLR 破开后的内核对象地址；未 open / 未跑到即返回 0。 */
uint64_t mf_get_kernel_proc(void);   /* struct proc  *  (kernel_proc)   */
uint64_t mf_get_kernel_task(void);   /* struct task  *  (kernel_task)   */
uint64_t mf_get_kernel_map(void);     /* struct _vm_map * (kernel_map)  */
uint64_t mf_get_kernel_pmap(void);    /* struct pmap  *  (kernel_pmap)   */
uint64_t mf_get_current_proc(void);   /* 本进程 struct proc *            */
uint64_t mf_get_current_task(void);   /* 本进程 struct task *            */

/* ------------------------------------------------------------------ */
/* 诊断                                                                */
/* ------------------------------------------------------------------ */

/*
 * 最近一次失败的原因（人类可读）。永不返回 NULL。
 * 触发点包括：断言失败（含 file:line）、patchfinder 失败、
 *             sem_open / setrlimit / sysctl 失败等。
 * 成功时返回上一次的错误文本或 "no error"。
 */
const char *mf_last_error(void);

/*
 * 给 UI 用的阶段摘要：记录 kopen 内部各里程碑（kaslr 破解 / patchfinder /
 * offsets 回填）的耗时与结果，失败时能看出卡在哪一步。
 * 永不返回 NULL。
 */
const char *mf_last_stage(void);

/* 最近一次失败发生的位置（"file:line"）；无则 "n/a"。 */
const char *mf_last_error_site(void);

/*
 * 读回 kfd 内部的 printf 诊断日志。
 * kfd 用 printf 输出 9 个偏移的查找过程，但 iOS 上 App 的 stdout 既不进
 * syslog 也没人接 —— 失败时只能看到最后那句 "run_kfd_patchfinder failed"。
 * 桥接层把它重定向到沙盒 Documents/mf_kfd.log，这里读回来给 UI 显示。
 *
 * 返回 malloc 的字符串，调用方负责 free()；没有日志时返回 NULL。
 */
char *mf_read_klog(void);

/* 打开日志：非 0 时内核链会把诊断打到 stderr（debug 用）。 */
void mf_set_verbose(int enabled);

#ifdef __cplusplus
}   /* extern "C" */
#endif

#endif /* MF_KERNEL_BRIDGE_H */
