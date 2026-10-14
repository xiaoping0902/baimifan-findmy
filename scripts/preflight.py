#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本机预检 — 在没有 Xcode 的 Windows 上，把「推 GitHub 之前」能验的全部验掉。

检查项：
  1. 所有 .plist 可被 plistlib 解析
  2. 所有 .json 可被 json 解析
  3. .yml / .yaml 基础结构可读（有 PyYAML 则严格解析）
  4. project.yml 引用的目录/资源真实存在
  5. Assets.xcassets 里每个条目在磁盘上有对应文件，且每个图片都在 Contents.json 里登记
  6. .mm / .m / .h / .c 源文件括号配平 + #import 引号路径存在
  7. 伪装身份字段一致性（Info.plist / project.yml / build.yml / README）
  8. entitlements 关键权限是否齐全

用法：python scripts/preflight.py
"""
import json
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")

ERRORS, WARNS, OKS = [], [], []


def ok(msg):
    OKS.append(msg)


def err(msg):
    ERRORS.append(msg)


def warn(msg):
    WARNS.append(msg)


# ---------------------------------------------------------------- 1. plist
def check_plists():
    for dirpath, dirnames, filenames in os.walk(APP):
        for fn in filenames:
            if not fn.endswith(".plist"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "rb") as f:
                    plistlib.load(f)
                ok(f"plist 可解析: {os.path.relpath(p, ROOT)}")
            except Exception as e:
                err(f"plist 解析失败: {os.path.relpath(p, ROOT)} → {e}")


# ---------------------------------------------------------------- 2. json
def check_jsons():
    skip = {"imgui", "kfd", "kfund"}
    for dirpath, dirnames, filenames in os.walk(APP):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(".json"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                with open(p, encoding="utf-8") as f:
                    json.load(f)
                ok(f"json 可解析: {os.path.relpath(p, ROOT)}")
            except Exception as e:
                err(f"json 解析失败: {os.path.relpath(p, ROOT)} → {e}")


# ---------------------------------------------------------------- 3/4. yml
def check_yml():
    paths = [
        os.path.join(APP, "project.yml"),
        os.path.join(ROOT, ".github", "workflows", "build.yml"),
    ]
    need_yaml = False
    try:
        import yaml  # type: ignore
    except ImportError:
        need_yaml = True

    for p in paths:
        if not os.path.exists(p):
            err(f"缺失文件: {os.path.relpath(p, ROOT)}")
            continue
        if need_yaml:
            warn(f"未装 PyYAML，跳过严格解析: {os.path.relpath(p, ROOT)}")
            continue
        try:
            with open(p, encoding="utf-8") as f:
                yaml.safe_load(f)
            ok(f"yaml 可解析: {os.path.relpath(p, ROOT)}")
        except Exception as e:
            err(f"yaml 解析失败: {os.path.relpath(p, ROOT)} → {e}")


# ------------------------------------------------------------ 5. asset cat
def check_assets():
    ac = os.path.join(APP, "Resources", "Assets.xcassets")
    if not os.path.isdir(ac):
        err("Assets.xcassets 不存在")
        return
    for setname in os.listdir(ac):
        setdir = os.path.join(ac, setname)
        if not os.path.isdir(setdir) or not setname.endswith(".appiconset"):
            continue
        cj = os.path.join(setdir, "Contents.json")
        if not os.path.exists(cj):
            err(f"{setname} 缺 Contents.json")
            continue
        with open(cj, encoding="utf-8") as f:
            data = json.load(f)
        declared = {img.get("filename") for img in data.get("images", []) if img.get("filename")}
        on_disk = {f for f in os.listdir(setdir) if f.lower().endswith((".png", ".jpg"))}

        missing = declared - on_disk
        extra = on_disk - declared
        if missing:
            err(f"{setname}: Contents.json 登记但磁盘缺失 → {sorted(missing)}")
        if extra:
            err(f"{setname}: 磁盘有图但未登记（Xcode 会告警/报错） → {sorted(extra)}")
        if not missing and not extra:
            ok(f"{setname}: {len(on_disk)} 张图，登记与磁盘一致")


# ------------------------------------------------------------ 6. 源码粗检
BRACKETS = {")": "(", "]": "[", "}": "{"}


def strip_code(src):
    """去掉注释与字符串字面量，但【保留换行】以便报错行号仍然准确"""
    def keep_newlines(m):
        return "\n" * m.group(0).count("\n")
    src = re.sub(r'/\*.*?\*/', keep_newlines, src, flags=re.S)   # 块注释
    src = re.sub(r'//[^\n]*', '', src)                            # 行注释
    src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)                 # 字符串
    src = re.sub(r"'(?:\\.|[^'\\])*'", "''", src)                 # 字符
    return src


def header_search_dirs():
    """从 project.yml 读 HEADER_SEARCH_PATHS，把 $(SRCROOT) 解析成 app/"""
    proj = os.path.join(APP, "project.yml")
    dirs = []
    try:
        with open(proj, encoding="utf-8") as f:
            txt = f.read()
    except Exception:
        return dirs
    in_block = False
    base_indent = 0
    for line in txt.splitlines():
        if "HEADER_SEARCH_PATHS:" in line:
            in_block = True
            base_indent = len(line) - len(line.lstrip())
            continue
        if in_block:
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            if not stripped.startswith("-") or indent <= base_indent:
                in_block = False
                continue
            val = stripped.lstrip("- ").strip().strip('"').strip("'")
            val = val.replace("$(SRCROOT)", APP)
            dirs.append(os.path.normpath(val))
    return dirs


def check_sources():
    exts = (".mm", ".m", ".h", ".c", ".cpp", ".hpp")
    skip = {"imgui", "kfd", "kfund"}
    incdirs = header_search_dirs()
    n = 0
    for dirpath, dirnames, filenames in os.walk(os.path.join(APP, "Sources")):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(exts):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            n += 1
            with open(p, encoding="utf-8", errors="replace") as f:
                raw = f.read()
            body = strip_code(raw)

            # 括号配平
            stack, bad = [], False
            for i, ch in enumerate(body):
                if ch in "([{":
                    stack.append(ch)
                elif ch in ")]}":
                    if not stack or stack[-1] != BRACKETS[ch]:
                        err(f"{rel}: 括号不配平（第 {body[:i].count(chr(10)) + 1} 行附近）")
                        bad = True
                        break
                    stack.pop()
            if not bad and stack:
                err(f"{rel}: 有 {len(stack)} 个未闭合的括号")
            elif not bad:
                ok(f"{rel}: 括号配平")

            # ★ ObjC++ 陷阱：不能对 property 表达式取地址（&obj.prop 是编译错误）
            #   先收集本文件里声明为【指针】的变量名，再找 &<ptr>.<name>
            #   注意：要排除 && / &= / & 后跟 & 的情况（逻辑与不是取地址）
            ptr_vars = set()
            for pm in re.finditer(r'\b([A-Za-z_]\w*)\s*\*\s*([A-Za-z_]\w*)\s*(?=[;=,)])', body):
                ptr_vars.add(pm.group(2))
            for am in re.finditer(r'(?<![&])&(?![&=])\s*([A-Za-z_]\w*)\s*\.\s*([A-Za-z_]\w*)', body):
                base, field = am.group(1), am.group(2)
                if base in ptr_vars:
                    line_no = body[:am.start()].count("\n") + 1
                    err(f"{rel}:{line_no}: 对 property 取地址 &{base}.{field} "
                        f"—— ObjC++ 编译错误，改用局部变量中转")

            # 本地 #import "x" 路径存在性（含 HEADER_SEARCH_PATHS）
            for m in re.finditer(r'#(?:import|include)\s+"([^"]+)"', raw):
                inc = m.group(1)
                base = os.path.dirname(p)
                cands = [os.path.join(base, inc), os.path.join(APP, "Sources", inc)]
                cands += [os.path.join(d, inc) for d in incdirs]
                if not any(os.path.exists(c) for c in cands):
                    err(f"{rel}: #import \"{inc}\" 找不到"
                        f"（已查 同级目录 / Sources/ / HEADER_SEARCH_PATHS {len(incdirs)} 项）")
    ok(f"源码粗检完成，共 {n} 个文件")


# ------------------------------------------------------- 7. 伪装身份一致性
def check_identity():
    info = os.path.join(APP, "Support", "Info.plist")
    proj = os.path.join(APP, "project.yml")
    with open(info, "rb") as f:
        d = plistlib.load(f)

    checks = [
        ("CFBundleDisplayName", "查找", d.get("CFBundleDisplayName")),
        ("CFBundleIdentifier", "com.apple.findmy", d.get("CFBundleIdentifier")),
        ("CFBundleName", "FindMy", d.get("CFBundleName")),
        ("MinimumOSVersion", "15.0", d.get("MinimumOSVersion")),
    ]
    for name, want, got in checks:
        if got == want:
            ok(f"Info.plist {name} = {want}")
        else:
            err(f"Info.plist {name} = {got!r}，期望 {want!r}")

    with open(proj, encoding="utf-8") as f:
        yml = f.read()
    for want in ("PRODUCT_NAME: FindMy",
                 "PRODUCT_BUNDLE_IDENTIFIER: com.apple.findmy",
                 "INFOPLIST_FILE: Support/Info.plist"):
        if want in yml:
            ok(f"project.yml 含 {want}")
        else:
            err(f"project.yml 缺 {want}")

    # build.yml / README 的应用名
    for rel, needles in [
        (".github/workflows/build.yml", ["FindMy.xcodeproj", "FindMy-unsigned.ipa", "scheme FindMy"]),
        ("README.md", ["com.apple.findmy", "查找"]),
    ]:
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            err(f"缺文件 {rel}")
            continue
        with open(p, encoding="utf-8") as f:
            txt = f.read()
        for nd in needles:
            if nd in txt:
                ok(f"{rel} 含 {nd!r}")
            else:
                err(f"{rel} 缺 {nd!r}")

    # entitlements
    ent = os.path.join(APP, "Support", "entitlements.plist")
    with open(ent, "rb") as f:
        e = plistlib.load(f)
    need = [
        "platform-application",
        "com.apple.private.security.no-sandbox",
        "com.apple.private.security.storage.AppBundles",
        "com.apple.private.persona-mgmt",
        "com.apple.springboard.accessibility-window-hosting",
        "task_for_pid-allow",
        "com.apple.security.exception.iokit-user-client-class",
    ]
    for k in need:
        if k in e:
            ok(f"entitlements 含 {k}")
        else:
            err(f"entitlements 缺 {k}")


# ------------------------------------------------- 7.5 框架链接完整性
def check_frameworks():
    """
    扫源码里的 <Framework/Header.h> 引用，核对 project.yml 是否声明了对应 sdk 依赖。
    XcodeGen 不会自动链接系统框架 —— 漏了就会在【链接阶段】才炸（编译能过）。
    """
    proj = os.path.join(APP, "project.yml")
    with open(proj, encoding="utf-8") as f:
        yml = f.read()

    # 常见的 C 标准库 / libSystem / SDK 头目录，不需要显式 framework
    IGNORE = {"mach", "mach-o", "sys", "unistd", "stdlib", "string", "errno",
              "stdio", "pthread", "semaphore", "libkern", "os", "spawn",
              "objc", "objc-runtime", "dispatch", "uuid", "signal", "stdint",
              "time", "math", "netinet", "arpa", "net", "dlfcn", "fcntl"}

    exts = (".mm", ".m", ".h", ".c", ".cpp", ".hpp")
    skip = {"imgui", "kfd", "kfund"}
    used = set()

    for dirpath, dirnames, filenames in os.walk(os.path.join(APP, "Sources")):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(exts):
                continue
            with open(os.path.join(dirpath, fn), encoding="utf-8", errors="replace") as f:
                raw = f.read()
            for m in re.finditer(r'#(?:import|include)\s+<([A-Za-z0-9_]+)/', raw):
                fw = m.group(1)
                if fw not in IGNORE:
                    used.add(fw)

    if not used:
        ok("未发现需要显式链接的系统框架")
        return

    missing = []
    for fw in sorted(used):
        if f"{fw}.framework" in yml:
            ok(f"框架已声明: {fw}.framework")
        else:
            missing.append(fw)

    for fw in missing:
        err(f"源码用到 {fw}，但 project.yml 未声明 `- sdk: {fw}.framework`（会在链接阶段炸）")


# ------------------------------------------------------------ 8. 结构完整性
def check_layout():
    must = [
        "app/project.yml",
        "app/Support/Info.plist",
        "app/Support/entitlements.plist",
        "app/Sources/main.mm",
        "app/Sources/App/AppDelegate.h",
        "app/Sources/App/AppDelegate.mm",
        "app/Sources/App/RootViewController.h",
        "app/Sources/App/RootViewController.mm",
        "app/Resources/Assets.xcassets/Contents.json",
        "app/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
        ".github/workflows/build.yml",
        "scripts/make_icon.py",
        "docs/复刻总方案.md",
    ]
    for rel in must:
        p = os.path.join(ROOT, rel)
        if os.path.exists(p):
            ok(f"存在 {rel}")
        else:
            err(f"缺失 {rel}")

    for rel in ["HUD", "Render", "Kernel", "Read", "Game", "Features"]:
        p = os.path.join(APP, "Sources", rel)
        if os.path.isdir(p):
            ok(f"模块目录存在 Sources/{rel}")
        else:
            err(f"缺模块目录 Sources/{rel}")


def main():
    print("=" * 64)
    print("白米饭复刻 · 本机预检")
    print("=" * 64)
    check_layout()
    check_plists()
    check_jsons()
    check_yml()
    check_assets()
    check_sources()
    check_frameworks()
    check_identity()

    print(f"\n通过 {len(OKS)} 项")
    if WARNS:
        print(f"\n提醒 {len(WARNS)} 项：")
        for w in WARNS:
            print(f"  ! {w}")
    if ERRORS:
        print(f"\n❌ 错误 {len(ERRORS)} 项：")
        for e in ERRORS:
            print(f"  ✗ {e}")
        print("\n预检未通过。")
        return 1
    print("\n✅ 预检全部通过，可以推 GitHub 触发云构建。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
