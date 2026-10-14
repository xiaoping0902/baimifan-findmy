//
//  krw.h — 最小兼容桩（本工程自写，非上游文件）
//
//  背景（依据 docs/kfd-移植清单.md §7.5）：
//    `fun/kpf/patchfinder.m` 第 13 行有一句 `#import "krw.h"`，
//    但经逐函数核实，patchfinder.m【全文没有调用任何 krw 层的函数】——
//    那行 include 是冗余依赖（原树里 fun/krw.h 存在所以能解析）。
//
//    本工程不编 fun/ 目录（理由见清单 §2.1：krw.m 会 include libkfd.h，
//    与桥接层产生重复符号），所以必须提供这个桩，否则 patchfinder.m 编译失败。
//
//  为什么不直接删 patchfinder.m 那一行：
//    见清单 §7.5 的选项 A/B 对比 —— 选项 B（本文件）是**零风险**方案，
//    不需要改动上游文件一个字符。
//
//  本文件刻意【不】声明任何 krw 层函数：如果将来真有人调 do_kread/kread64，
//  会立刻编译报错，而不是悄悄走错层。
//
#ifndef MF_KRW_STUB_H
#define MF_KRW_STUB_H

// patchfinder.m 用到的类型来源（与上游 fun/krw.h → fun/fun.h 等效的最小集）
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

#endif /* MF_KRW_STUB_H */
