#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IPA 验货 — 确认云构建产物真的是我们要的东西。

检查：
  1. 包结构（Payload/*.app）
  2. 主二进制 Mach-O 头：magic / cputype / cpusubtype
  3. Info.plist 伪装身份字段
  4. 是否有代码签名（embedded signature / CodeResources）
  5. 图标是否齐全
  6. 打包进 bundle 的资源

用法：python scripts/verify_ipa.py dist/FindMy-unsigned.ipa
"""
import os
import plistlib
import struct
import sys
import zipfile
from trollstore_entitlements import incompatible_entitlements

CPU = {0x0100000C: "ARM64", 0x0100000E: "ARM64_32", 0x01000007: "x86_64"}
SUB = {0: "ARM64_ALL", 1: "ARM64_V8", 2: "ARM64e"}


def main(ipa):
    print("=" * 68)
    print(f"IPA 验货: {os.path.basename(ipa)}")
    print("=" * 68)

    if not os.path.exists(ipa):
        print(f"✗ 文件不存在: {ipa}")
        return 1

    print(f"体积: {os.path.getsize(ipa) / 1024:.1f} KB\n")

    z = zipfile.ZipFile(ipa)
    names = z.namelist()

    apps = sorted({
        n.split("/")[1]
        for n in names
        if n.startswith("Payload/") and len(n.split("/")) > 1 and n.split("/")[1]
    })
    apps = [a for a in apps if a.endswith(".app")]
    app = apps[0] if apps else None
    print(f"1) 包结构 — Payload/ 下: {apps}")
    if not app:
        print("   ✗ 没有 .app")
        return 1

    appdir = f"Payload/{app}"
    files = [n for n in names if n.startswith(appdir + "/") and not n.endswith("/")]
    print(f"   {app} 内含 {len(files)} 个文件")

    # ---- Info.plist（先读，用来定位可执行文件名）----
    ip = f"{appdir}/Info.plist"
    exe_name = None
    if ip in names:
        d = plistlib.loads(z.read(ip))
        exe_name = d.get("CFBundleExecutable")

    # ---- 主二进制 ----
    exe = f"{appdir}/{exe_name}" if exe_name else None
    if not exe or exe not in names:
        for n in files:
            rel = n[len(appdir) + 1:]
            if "/" not in rel and "." not in rel:
                exe = n
                break
    print(f"\n2) 主二进制 — {exe}")
    if not exe:
        print("   ✗ 找不到可执行文件")
        return 1
    data = z.read(exe)
    magic, cputype, cpusub, ftype = struct.unpack("<IIII", data[:16])
    print(f"   大小      : {len(data):,} 字节")
    print(f"   magic     : 0x{magic:08X}  ({'MH_MAGIC_64 ✓' if magic == 0xFEEDFACF else '?'})")
    print(f"   cputype   : 0x{cputype:08X}  ({CPU.get(cputype, '?')})")
    print(f"   cpusubtype: {cpusub}  ({SUB.get(cpusub, '?')})")
    print(f"   filetype  : {ftype}  (2 = MH_EXECUTE)")

    # ---- Info.plist ----
    print(f"\n3) Info.plist — 伪装身份")
    if ip in names:
        d = plistlib.loads(z.read(ip))
        want = [
            ("CFBundleDisplayName", "查找"),
            ("CFBundleIdentifier", "com.apple.findmy"),
            ("CFBundleName", "FindMy"),
            ("CFBundleExecutable", "FindMy"),
            ("MinimumOSVersion", "15.0"),
        ]
        allok = True
        for k, expect in want:
            got = d.get(k, "（缺）")
            mark = "✓" if got == expect else "✗"
            if got != expect:
                allok = False
            print(f"   {mark} {k:26s} = {got!r}")
        print(f"   UIDeviceFamily = {d.get('UIDeviceFamily')}")
        print(f"   CFBundleIconName = {d.get('CFBundleIconName')}")
        if not allok:
            print("   ⚠️ 伪装身份字段有偏差")
    else:
        print("   ✗ 缺 Info.plist")

    # ---- 图标 ----
    icons = [n for n in files if n.lower().endswith(".png") and ("AppIcon" in n or "icon" in n.lower())]
    print(f"\n4) 图标 — {len(icons)} 个 PNG")
    for n in sorted(icons)[:6]:
        print(f"   {n[len(appdir)+1:]}")
    if len(icons) > 6:
        print(f"   ...（共 {len(icons)} 个）")

    # ---- 签名痕迹 ----
    print(f"\n5) 签名 / 资源旁证")
    has_sig = any("_CodeSignature" in n for n in names)
    print(f"   含 _CodeSignature 目录 : {has_sig}")

    # 从 Mach-O 里把 ldid 注入的 entitlements 抠出来
    lc = struct.unpack("<I", data[16:20])[0]
    print(f"   Mach-O load commands 数: {lc}")
    off = 32
    sig_off = sig_size = 0
    for _ in range(lc):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            sig_off, sig_size = struct.unpack("<II", data[off + 8:off + 16])
            break
        off += cmdsize

    if not sig_off:
        print("   ✗ 没有 LC_CODE_SIGNATURE —— ldid 签名没生效！")
        return 1

    print(f"   LC_CODE_SIGNATURE: off={sig_off} size={sig_size}")
    sb = data[sig_off:sig_off + sig_size]
    magic, length, count = struct.unpack(">III", sb[:12])
    print(f"   SuperBlob magic=0x{magic:08X} 条目数={count}"
          f"  ({'CSMAGIC_EMBEDDED_SIGNATURE ✓' if magic == 0xFADE0CC0 else '?'})")

    ent_xml = None
    for i in range(count):
        btype, boff = struct.unpack(">II", sb[12 + i * 8:20 + i * 8])
        if btype == 5:  # CS_ENTITLEMENTS
            bmagic, blen = struct.unpack(">II", sb[boff:boff + 8])
            ent_xml = sb[boff + 8:boff + blen]
            break

    print(f"\n5b) ★ 注入的 entitlements")
    if not ent_xml:
        print("   ✗ 签名里没有 entitlements blob！TrollStore 安装后权限不会生效")
        return 1
    ent = plistlib.loads(ent_xml)
    banned = incompatible_entitlements(ent)
    if banned:
        print("   ✗ 含 TrollStore 在 iOS 15+ / A12+ 禁止的权限，会导致启动失败：")
        for key in banned:
            print(f"     {key}")
        return 1
    for k, v in sorted(ent.items()):
        print(f"   ✓ {k} = {v}")

    need = [
        "platform-application",
        "com.apple.private.security.no-sandbox",
        "com.apple.private.security.storage.AppBundles",
        "com.apple.private.persona-mgmt",
        "com.apple.springboard.accessibility-window-hosting",
        "task_for_pid-allow",
        "com.apple.security.exception.iokit-user-client-class",
    ]
    miss = [k for k in need if k not in ent]
    if miss:
        print(f"   ⚠️ 缺少: {miss}")
    else:
        print(f"   ✅ 7 项权限全部注入成功")

    # ---- 资源 ----
    res = [n for n in files if n.endswith((".plist", ".ttf", ".otf", ".strings", ".car"))]
    print(f"\n6) 打包资源")
    for n in sorted(res):
        print(f"   {n[len(appdir)+1:]}")

    print("\n" + "=" * 68)
    print("结构验货完成。")
    print("=" * 68)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "dist/FindMy-unsigned.ipa"))
