#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 app/Sources/Kernel/kfd 下 [MF PATCH] 的 unified diff。

用法:
    python scripts/gen_kfd_patches.py

对照关系:
    vendor/<name>.orig   <->   app/Sources/Kernel/kfd/<path>

输出:
    docs/patches/01-...patch  (按 MF PATCH 编号)
"""
import difflib
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
KFD = os.path.join(ROOT, "app", "Sources", "Kernel", "kfd")
OUT = os.path.join(ROOT, "docs", "patches")

# (patch 编号, 原始文件绝对路径, 工作副本相对路径, 说明)
ENTRIES = [
    ("01-libkfd-common-assert-hook.patch",
     os.path.join(KFD, "vendor", "common.h.orig"),
     "libkfd/common.h",
     "assert 失败：sleep(30)+exit(1)  ->  调用宿主失败钩子 mf_kfd_fail_hook()；并补 <string.h>"),
    ("02-libkfd-krkw-no-exit.patch",
     os.path.join(KFD, "vendor", "krkw.h.orig"),
     "libkfd/krkw.h",
     "patchfinder 失败：printf + exit(1)  ->  print_failure + 失败钩子"),
    ("03-libdimentio-host-kread.patch",
     os.path.join(KFD, "vendor", "libdimentio.m.orig"),
     "fun/kpf/libdimentio.m",
     "去掉 fun/krw.h 依赖，改用 MFLibkfdKRead4()（宿主直通 libkfd kread）"),
    ("04-libkfd-config-ifndef.patch",
     os.path.join(KFD, "vendor", "libkfd.h.orig"),
     "libkfd.h",
     "CONFIG_ASSERT/PRINT/TIMER 加 #ifndef 守卫，允许命令行覆盖"),
    ("05-kpf-patchfinder-drop-krw-include.patch",
     os.path.join(KFD, "vendor", "patchfinder.m.orig"),
     "fun/kpf/patchfinder.m",
     "删掉解析不到的 #import \"krw.h\"（本工程不编 fun/），并显式补 <stdbool.h>/<stdlib.h>/<string.h>"),
]


def read_bytes(p):
    try:
        with open(p, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def main():
    os.makedirs(OUT, exist_ok=True)
    missing = []
    for name, orig, rel, desc in ENTRIES:
        cur = os.path.join(KFD, rel.replace("/", os.sep))
        a = read_bytes(orig)
        b = read_bytes(cur)
        if a is None:
            missing.append(orig)
            print("MISSING ORIG: %s" % orig)
            continue
        if b is None:
            missing.append(cur)
            print("MISSING CUR : %s" % cur)
            continue

        alines = a.decode("utf-8", "replace").splitlines(keepends=True)
        blines = b.decode("utf-8", "replace").splitlines(keepends=True)

        diff = difflib.unified_diff(
            alines, blines,
            fromfile="a/%s" % rel,
            tofile="b/%s" % rel,
            n=3,
        )
        body = "".join(diff)
        hdr = ("# %s\n# %s\n#\n# 原始版本保留在 app/Sources/Kernel/kfd/vendor/ 下，\n"
               "# 本 patch 是「从上游原样文件 -> 本工程工作副本」的完整差异。\n#\n"
               % (name, desc))
        with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(hdr)
            f.write(body)
        n_add = sum(1 for l in body.splitlines() if l.startswith("+") and not l.startswith("+++"))
        n_del = sum(1 for l in body.splitlines() if l.startswith("-") and not l.startswith("---"))
        print("%-46s  +%-4d -%-4d  %s" % (name, n_add, n_del, desc))

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
