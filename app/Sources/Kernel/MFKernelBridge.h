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
 * 目标机默认参数。
 *
 * ★ [M5.113] 改回 physpuppet + 1024。
 *
 * 这里原来按"iPad Pro M2 / 16.6.1"写的 landa + 3072，但真机是
 * iPad14,4 / **iPadOS 16.1 (20B82)** —— 在 16.1 上：
 *     landa + 3072   → 卡在 grab_free_pages（历史最好 0/256，12 分钟不返回）
 *     physpuppet + 1024 → 235~261 ms 成功（M5.95 起三种版本反复验证）
 * M5.112 的自动挂载走的就是 mf_kopen_default()，于是第一次自动连接直接
 * 报 `assertion failed: (false) at krkw.h:412`。
 *
 * 依据：physpuppet = CVE-2023-23536，iOS 16.4 才修复 → 16.1 在范围内。
 * kread/kwrite 仍必须是 sem_open（成对，krkw.h 里有 assert 拦）。
 */
#define MF_DEFAULT_PUAF_PAGES          1024
#define MF_DEFAULT_PUAF_METHOD         MF_PUAF_PHYSPUPPET
#define MF_DEFAULT_KREAD_METHOD        MF_KREAD_SEM_OPEN
#define MF_DEFAULT_KWRITE_METHOD       MF_KWRITE_SEM_OPEN

#include "MFDeviceCompatibility.h"
/* Device policy shared by console and HUD. Does not start a kernel session. */
MFDeviceConfiguration mf_current_device_configuration(void);
/* pages == 0 chooses the device recommendation; nonzero keeps the caller's allocation. */
int mf_kopen_for_device(uint64_t pages);

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
 * [M5.135] 失败码：
 *    -1  kopen 内部失败（断言/参数/驱动层）
 *    -2  本进程已经打开
 *    -3  参数非法（puaf_pages / puaf_method / kread / kwrite）
 *    -4  另一个进程已持有内核（跨进程 flock 哨兵）。
 *        这个码表示【内核一个字节都没动】，调用方可以放心重试，
 *        不要像 -1 那样把进程锁死。
 *    -5  系统、芯片或方法不在现有偏移/方法范围；未执行内核操作。
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

/* 按当前设备选择参数；不再固定为旧系统的 physpuppet。 */
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

/*
 * 内核关键地址快照（给 MFCalibrate 用）。
 *
 * 为什么要有这个：校准需要 kernel_proc / current_task / current_map / current_pmap
 * 这些只在 struct kfd 里存在的地址。以前是从外部脚本扫内存找 struct kfd 句柄，
 * 结果把用户地址当成 kaddr 送进内核 → copy_validate panic。
 * 现在由桥接层在自己模块里直接取，外部拿不到错的东西。
 *
 * 任一指针传 NULL 表示不关心。返回 0 成功，-1 表示内核未打开。
 */
int mf_kaddr_snapshot(uint64_t *kernel_proc, uint64_t *kernel_task,
                      uint64_t *current_proc, uint64_t *current_task,
                      uint64_t *current_map, uint64_t *current_pmap,
                      uint64_t *gVirtBase, uint64_t *gPhysBase,
                      uint64_t *gPhysSize);

/*
 * 当前 pmap 的 TTBR 快照（kfd 在 perf_run 里存下来的）。
 *
 * 这是【可信】的页表根：它由内核给出，不是我们在堆里猜的字段。
 * 用它当根去翻译自己的用户地址，读通后再用「值相等」把 pmap 结构里
 * 对应字段对出来 —— 全程只比较，不拿未知地址去读。
 *
 * 返回 0 成功；-1 未打开内核。
 */
int mf_ttbr_snapshot(uint64_t *ttbr0_pa, uint64_t *ttbr0_va,
                     uint64_t *ttbr1_pa, uint64_t *ttbr1_va);

/*
 * [M5.107] physmap 不是单一线性窗口 —— ptov_table 快照 + 正确的 PA→KVA。
 *
 * 真机证据（M5.106 校准输出）：
 *      ttbr0 pa = 0x9aacb8000      （页表页的物理地址）
 *      ttbr0 va = 0xfffffdf1ccd10000（同一个页的内核虚拟地址）
 *      gVirtBase= 0xfffffe001261c000 / gPhysBase = 0x80261c000
 * 用 gVirtBase+(pa-gPhysBase) 换算得到 0xfffffe01bacb8000，与 libkfd 记下的
 * va 完全不是一个地址 —— 说明这一页不在主 physmap 窗口里，而在 ptov_table
 * 的另一段。libkfd 的 phystokv()（kfd/libkfd/perf.h:232-248）正是先查这张表，
 * 查不到才退回 gVirtBase/gPhysBase。
 *
 * 我们这个函数照抄那个顺序。**所有从页表描述符里取出来的表基址，都必须走它**，
 * 否则第二级开始就在读另一个窗口，返回的 descriptor 是别的物理页的内容 →
 * 遍历"看起来在跑"，实际每一步都是垃圾。
 *
 * mf_ptov_snapshot: 拷出 8 项 {pa, va, len}，len==0 表示后面没内容了。
 *                   pa/va/len 任一可为 NULL。返回有效项数；-1 表示内核未打开。
 * mf_phys_to_kv:    PA → 内核 VA。返回 0 表示这个 PA 不在任何已知窗口内。
 */
int      mf_ptov_snapshot(uint64_t *pa, uint64_t *va, uint64_t *len);
uint64_t mf_phys_to_kv(uint64_t pa);

/*
 * [M5.108] pid -> 目标进程的页表根（跨进程读的入口）。
 *
 *     pid --allproc--> proc --[+0x18]--> proc_ro --[+0x08]--> task
 *          --[+0x28]--> vm_map --[+0x40]--> pmap --[+0x00]--> tte(root)
 *
 * 这五个偏移在 M5.103 就在自己进程上逐项校验过（== libkfd 的 current_*），
 * M5.107 又把 pmap+0 与 ttbr0.va 逐位比对过。这里只是把它套到别的 pid 上。
 *
 * 目标进程没有 current_* 可对照，所以用两条自证代替：
 *   ① 每一跳都必须是内核地址；
 *   ② pmap+0x00(tte) 必须等于 mf_phys_to_kv(pmap+0x08(ttep)) —— 这正是
 *      libkfd 在 kopen 时对自己断言的不变量（perf.h:168），对任何 pmap 都成立。
 *
 * 返回 0 成功；-1 内核未打开；-2 找不到该 pid；-3..-8 某一跳失败。
 * 任一输出指针可为 NULL。report 给出中文原因。
 */
int mf_pid_chain(int pid, uint64_t *proc, uint64_t *task, uint64_t *map,
                 uint64_t *pmap, uint64_t *root, char *report, size_t report_len);

/*
 * [M5.135] 串行化锁。
 *
 * kfd 的 KRKW 后端是有状态的，且本桥接用一对全局 setjmp 落点兜断言 ——
 * 同一进程里两个线程同时读，后果是 longjmp 跳到别人的栈帧，或者直接 abort()。
 * 所有 mf_kread / mf_kwrite 入口已经内部加锁（递归锁，可嵌套）。
 *
 * 这里额外暴露一对，是给"需要多次 kread 保持原子"的调用方用的：
 * 例如页表遍历（mfpt_translate / mfpt_read）和跨进程取链，它们内部会反复
 * 调 mf_kread32；只有在外层再套一把，整次遍历才不会被别的线程插进来。
 *
 * 规则：成对调用，不要跨线程持有，不要在里面调 sleep。
 */
void mf_lock_kernel(void);
void mf_unlock_kernel(void);

/* 被地址闸拒绝的次数与最近一个被拒地址（用于诊断，不参与逻辑）。 */
int      mf_kaddr_denied_count(void);
uint64_t mf_kaddr_denied_last(void);

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
/* proc patch：不需要 tfp0 就绕开 taskgated 的 CS_HARD 拒绝            */
/* ------------------------------------------------------------------ */
/*
 * 背景：真机上 task_for_pid(游戏) 恒 kr=0x5，processor_set_tasks 恒 kr=0x4。
 * 这是 taskgated 按**目标进程**的 proc->p_csflags 里的 CS_HARD 拒绝的
 * （我们的 task_for_pid-allow entitlement 本身是生效的）。
 *
 * 有了 KFD 的内核读写，就不必走 tfp0 那条路：直接把目标 proc 的
 * CS_HARD / CS_RESTRICT / CS_REQUIRE_LV 位清掉，taskgated 就没有理由再拒。
 *
 * struct proc 的 p_pid / p_csflags 偏移是版本相关的，工程里没有现成值，
 * 所以下面这两个函数都做**运行时自适应扫描**：
 *     p_pid 用「kernel_proc pid==0 / launchd pid==1」自校准
 *     p_csflags 用「值里带 CS_HARD 位」定位，命中多个就逐个清（只清位）
 *
 * 安全约定：所有函数默认**只诊断不写**，必须显式 apply/scan_only=0 才动内核。
 * 最坏情况是没效果（偏移没扫到），不会把无关字段写坏。
 */

/*
 * 按 pid 在 proc 链表里找 struct proc 地址。
 * 返回 0 表示没找到；report 里会写清卡在哪（链表空 / p_pid 偏移没定出来 / pid 不在链里）。
 */
uint64_t mf_find_proc_by_pid(int pid, char *report, size_t report_len);

/*
 * [M5.207] 以下三个入口已删除，不要加回来：
 *   · mf_clear_proc_csflags        —— 只为 task_for_pid 清目标进程 csflags
 *   · mf_try_tf_platform           —— 只为 task_for_pid 置自身 TF_PLATFORM
 *   · mf_locate_tf_platform_offset —— 随 TF_PLATFORM 路一起退场
 *
 * 读取链现在是 pid → pmap 根表 → 目标页表 → 物理读，全链没有 task_for_pid，
 * 因此这三个写内核的入口同时失去意义。内核侧现在没有任何写入点。
 */

/*
 * 内核写入审计。
 *
 * 整场会话里 mf_kwrite / mf_kwrite32 / mf_kwrite64 成功写入的次数与字节数。
 * 读取走页表，正确配置下这个计数应恒为 0；被动状态文件会带上它，
 * 现场可以直接核对这一轮到底有没有写过内核，不用相信注释。
 */
uint64_t mf_kernel_write_count(void);
uint64_t mf_kernel_write_bytes(void);
void mf_kernel_write_audit_reset(void);

/*
 * [M5.208] 内核初始化与痕迹清理的可观测证据。
 *
 * kfd 的漏洞触发是一次性的，触发后 libkfd 会在 kopen 内部（info_run 之后）
 * 立刻执行 puaf_cleanup，把被改坏的 vm_map_entry 链接与红黑树指针还原 ——
 * 也就是「焊完把焊渣清掉」。这一步我们没法单独计时，但 kopen 返回 0
 * 就说明它跑完了，所以这里暴露两件事：
 *   · mf_kernel_open_ms()     —— 整个 kopen（含内部 cleanup）耗时，毫秒；
 *                                 -1 表示还没成功跑过一次
 *   · mf_kernel_cleanup_done() —— 1 = 本次会话已走过「触发 + 清痕」
 *
 * 注意：清理的是页表项伪装，不是被重叠的物理页 —— 后者是读写通道本体，
 * 只有 kclose 时的 puaf_free 才释放。别把它当痕迹清掉，清了就读不了。
 */
double mf_kernel_open_ms(void);
int mf_kernel_cleanup_done(void);

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
