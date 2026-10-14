/*
 * MFKernelBridge.h (libkfd 宿主支撑层 / 纯 C)
 * =============================================================
 * 只为 fun/kpf/libdimentio.m 提供一个符号：MFLibkfdKRead4()。
 *
 * 背景（见 docs/kfd-移植清单.md 第 2 节）：
 *   libdimentio.m 全文只从 fun/krw.h 拿了【一个】函数 early_kreadbuf()，
 *   用在 kread_buf_kfd() 里。而 fun/krw.m 会 #include "libkfd.h"，
 *   与 MFKernelBridge.c 构成重复符号（libkfd 是 header-only，
 *   kopen/kread/kwrite/kclose 都是无 static 的普通定义）。
 *
 *   所以：不编 fun/ 目录，改由 MFKernelBridge.c 提供逐字节等价的
 *   kread 直通实现。这样依赖闭包从 30+ 文件收缩到 20 个文件。
 *
 * 本头文件【不包含 libkfd.h】（min/max 宏污染 C++），只声明原型。
 */

#ifndef MF_LIBKFD_HOST_H
#define MF_LIBKFD_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 从内核地址 kaddr 读 size 字节到 buf。
 *
 * 行为与 fun/krw.m 的 early_kreadbuf() 完全一致：
 *   逐 4 字节调用 libkfd 的 kread()，再按小端铺进 buf，
 *   末尾不足 4 字节的部分按需截断。
 *
 * 之所以不一次 kread() 读完整 size，是因为 sem_open 后端的 64-bit 读法
 * 在【页边界】会连带读到上一页（见 writeups/exploiting-puafs.md L182-188）；
 * 逐 4 字节能保证每个 4 字节读都落在同一个 16K 页内。
 *
 * kfd 取 MFKernelBridge.c 打开的那个句柄；kfd 为 0 时直接返回。
 */
void MFLibkfdKRead4(uint64_t kfd, uint64_t kaddr, void *buf, size_t size);

#ifdef __cplusplus
}   /* extern "C" */
#endif

#endif /* MF_LIBKFD_HOST_H */
