/*
 * Copyright (c) 2023 Félix Poulin-Bélanger. All rights reserved.
 */

#ifndef common_h
#define common_h

/*
 * [MF PATCH 01b] 补 <string.h>：上游 common.h 用了 memcmp/memcpy/strerror/bzero
 * 却只靠 <stdio.h> 间接带入，在 iOS SDK 上不保证；显式包含避免隐式声明。
 */
#include <string.h>

#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define pages(number_of_pages) ((number_of_pages) * (ARM_PGBYTES))

#define min(a, b) (((a) < (b)) ? (a) : (b))
#define max(a, b) (((a) > (b)) ? (a) : (b))

typedef int8_t i8;
typedef int16_t i16;
typedef int32_t i32;
typedef int64_t i64;
typedef intptr_t isize;

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uintptr_t usize;

/*
 * Helper print macros.
 */

#if CONFIG_PRINT

#define print(args...) printf(args)

#else /* CONFIG_PRINT */

#define print(args...)

#endif /* CONFIG_PRINT */

#define print_bool(name) print("[%s]: %s = %s\n", __FUNCTION__, #name, name ? "true" : "false")

#define print_i8(name) print("[%s]: %s = %hhi\n", __FUNCTION__, #name, name)
#define print_u8(name) print("[%s]: %s = %hhu\n", __FUNCTION__, #name, name)
#define print_x8(name) print("[%s]: %s = %02hhx\n", __FUNCTION__, #name, name)

#define print_i16(name) print("[%s]: %s = %hi\n", __FUNCTION__, #name, name)
#define print_u16(name) print("[%s]: %s = %hu\n", __FUNCTION__, #name, name)
#define print_x16(name) print("[%s]: %s = %04hx\n", __FUNCTION__, #name, name)

#define print_i32(name) print("[%s]: %s = %i\n", __FUNCTION__, #name, name)
#define print_u32(name) print("[%s]: %s = %u\n", __FUNCTION__, #name, name)
#define print_x32(name) print("[%s]: %s = %08x\n", __FUNCTION__, #name, name)

#define print_i64(name) print("[%s]: %s = %lli\n", __FUNCTION__, #name, name)
#define print_u64(name) print("[%s]: %s = %llu\n", __FUNCTION__, #name, name)
#define print_x64(name) print("[%s]: %s = %016llx\n", __FUNCTION__, #name, name)

#define print_isize(name) print("[%s]: %s = %li\n", __FUNCTION__, #name, name)
#define print_usize(name) print("[%s]: %s = %lu\n", __FUNCTION__, #name, name)
#define print_xsize(name) print("[%s]: %s = %016lx\n", __FUNCTION__, #name, name)

#define print_string(name) print("[%s]: %s = %s\n", __FUNCTION__, #name, name)

#define print_message(args...) do { print("[%s]: ", __FUNCTION__); print(args); print("\n"); } while (0)
#define print_success(args...) do { print("[%s]: 🟢 ", __FUNCTION__); print(args); print("\n"); } while (0)
#define print_warning(args...) do { print("[%s]: 🟡 ", __FUNCTION__); print(args); print("\n"); } while (0)
#define print_failure(args...) do { print("[%s]: 🔴 ", __FUNCTION__); print(args); print("\n"); } while (0)

#define print_timer(tv)                                           \
    do {                                                          \
        u64 sec = ((tv)->tv_sec);                                 \
        u64 msec = ((tv)->tv_usec) / 1000;                        \
        u64 usec = ((tv)->tv_usec) % 1000;                        \
        print_success("%llus %llums %lluus", sec, msec, usec);    \
    } while (0)

#define print_buffer(uaddr, size)                                          \
    do {                                                                   \
        const u64 u64_per_line = 8;                                        \
        volatile u64* u64_base = (volatile u64*)(uaddr);                   \
        u64 u64_size = ((u64)(size) / sizeof(u64));                        \
        for (u64 u64_offset = 0; u64_offset < u64_size; u64_offset++) {    \
            if ((u64_offset % u64_per_line) == 0) {                        \
                print("[0x%04llx]: ", u64_offset * sizeof(u64));           \
            }                                                              \
            print("%016llx", u64_base[u64_offset]);                        \
            if ((u64_offset % u64_per_line) == (u64_per_line - 1)) {       \
                print("\n");                                               \
            } else {                                                       \
                print(" ");                                                \
            }                                                              \
        }                                                                  \
        if ((u64_size % u64_per_line) != 0) {                              \
            print("\n");                                                   \
        }                                                                  \
    } while (0)

/*
 * Helper assert macros.
 */

/*
 * [MF PATCH 01a] 把「失败 = sleep(30) + exit(1)」改成「失败 = 调用宿主失败钩子」。
 *
 * 上游行为（原样保留在下面 #else 分支里，作为无 App 环境下的兜底）会让进程
 * 卡 30 秒后闪退。在「白米饭复刻」里这既不可接受也无法向用户解释。
 *
 * 现在：断言失败 -> print 诊断 -> 调用 mf_kfd_fail_hook()。
 *   - 宿主（MFKernelBridge.c）把该符号实现为 longjmp 回 mf_kopen()，
 *     于是断言变成「返回错误码 + 错误字符串」，进程存活。
 *   - 若宿主从未 setjmp（g_fail_armed == 0），钩子自身退化为上游的
 *     sleep(30)+exit(1)，保证 libkfd 单独拿去编译（例如 macos_kfd.c）时行为不变。
 */
#if CONFIG_ASSERT

extern void mf_kfd_fail_hook(const char* what, const char* file, int line);

/*
 * [MF PATCH 08] 登记「当前正在跑的 kfd 实例」，供失败钩子在 longjmp 之前回收。
 *
 * 起因（2026-10-15 真机紫屏）：
 *   失败 = mf_kfd_fail_hook() -> longjmp 回 mf_kopen()。
 *   longjmp 绕过了 kopen 后半段所有清理 —— puaf_run 制造的悬空页、
 *   krkw_run 开的约一万个 fd，全都留在原地。用户一重试就再叠一份，
 *   累积几轮后内核 panic。
 *
 * 现在 kopen() 在 kfd_init 之后调用本函数登记指针，
 * 钩子在 longjmp 前调 kfd_free() 尽力回收（用嵌套 setjmp 兜住回收自身的断言）。
 * 传 NULL 表示解登记。
 */
extern void mf_kfd_register_active(void* kfd);

#define assert(condition)                                                   \
    do {                                                                    \
        if (!(condition)) {                                                 \
            print_failure("assertion failed: (%s)", #condition);            \
            print_failure("file: %s, line: %d", __FILE__, __LINE__);        \
            mf_kfd_fail_hook(#condition, __FILE__, __LINE__);               \
        }                                                                   \
    } while (0)

#else /* CONFIG_ASSERT */

#define assert(condition)

#endif /* CONFIG_ASSERT */

#define assert_false(message)                   \
    do {                                        \
        print_failure("error: %s", message);    \
        assert(false);                          \
    } while (0)

#define assert_bsd(statement)                                                                        \
    do {                                                                                             \
        kern_return_t kret = (statement);                                                            \
        if (kret != KERN_SUCCESS) {                                                                  \
            print_failure("bsd error: kret = %d, errno = %d (%s)", kret, errno, strerror(errno));    \
            assert(kret == KERN_SUCCESS);                                                            \
        }                                                                                            \
    } while (0)

#define assert_mach(statement)                                                             \
    do {                                                                                   \
        kern_return_t kret = (statement);                                                  \
        if (kret != KERN_SUCCESS) {                                                        \
            print_failure("mach error: kret = %d (%s)", kret, mach_error_string(kret));    \
            assert(kret == KERN_SUCCESS);                                                  \
        }                                                                                  \
    } while (0)

/*
 * Helper timer macros.
 */

#if CONFIG_TIMER

#define timer_start()                                 \
    struct timeval tv_start;                          \
    do {                                              \
        assert_bsd(gettimeofday(&tv_start, NULL));    \
    } while (0)

#define timer_end()                                 \
    do {                                            \
        struct timeval tv_end, tv_diff;             \
        assert_bsd(gettimeofday(&tv_end, NULL));    \
        timersub(&tv_end, &tv_start, &tv_diff);     \
        print_timer(&tv_diff);                      \
    } while (0)

#else /* CONFIG_TIMER */

#define timer_start()
#define timer_end()

#endif /* CONFIG_TIMER */

/*
 * Helper allocation macros.
 */

#define malloc_bzero(size)               \
    ({                                   \
        void* pointer = malloc(size);    \
        assert(pointer != NULL);         \
        bzero(pointer, size);            \
        pointer;                         \
    })

#define bzero_free(pointer, size)    \
    do {                             \
        bzero(pointer, size);        \
        free(pointer);               \
        pointer = NULL;              \
    } while (0)

#endif /* common_h */
