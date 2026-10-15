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
    """
    去掉注释与字符串字面量，但保留换行以便报错行号准确。

    ★ 关键：必须【保留 #include / #import 后面的引号路径】。
      否则 `#include "../../fun/kpf/patchfinder.h"` 会被清成 `#include ""`，
      导致所有基于依赖链的检查（import 存在性、ObjC 传递闭包）全部失灵。
      （这个 bug 真实存在过一轮，靠反例测试才暴露出来。）
    """
    def keep_newlines(m):
        return "\n" * m.group(0).count("\n")

    # 块注释 → 用等量换行替换
    src = re.sub(r'/\*.*?\*/', keep_newlines, src, flags=re.S)

    out = []
    # 不依赖 startswith —— 文件可能有 UTF-8 BOM，会在行首多出 \ufeff
    inc_re = re.compile(r"^\s*\ufeff?\s*#\s*(?:include|import)\b")
    for line in src.split("\n"):
        # include / import 行：只清行注释，路径原样保留
        if inc_re.match(line):
            out.append(re.sub(r"//[^\n]*", "", line))
            continue
        line = re.sub(r"//[^\n]*", "", line)
        line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)      # 字符串
        line = re.sub(r"'(?:\\.|[^'\\])*'", "''", line)      # 字符
        out.append(line)
    return "\n".join(out)


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
            # 注意：必须用去注释后的 body —— 否则注释里举例子写一句
            #       #include "libkfd.h" 就会误报
            for m in re.finditer(r'#(?:import|include)\s+"([^"]+)"', body):
                inc = m.group(1)
                base = os.path.dirname(p)
                cands = [os.path.join(base, inc), os.path.join(APP, "Sources", inc)]
                cands += [os.path.join(d, inc) for d in incdirs]
                if not any(os.path.exists(c) for c in cands):
                    line_no = body[:m.start()].count("\n") + 1
                    err(f"{rel}:{line_no}: #import \"{inc}\" 找不到"
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


# ------------------------------------------------- 7.6 iOS SPI 直接调用
def check_ios_spi():
    """
    iOS 公开 SDK 头里【不声明】的一批 SPI / 私有头。
    直接写会得到 "use of undeclared identifier"（构建 #10）
    或 "fatal error: 'xxx.h' file not found"（构建 #12）。
    """
    # 【已证】iOS 公开 SDK 里不存在的头文件
    PRIVATE_HEADERS = {
        "libproc.h": "proc_pidpath / proc_pidinfo 自己 extern 声明即可",
        "spawn_private.h": "posix_spawnattr_set_persona_np 等需自声明或 dlsym",
        "rocketbootstrap.h": "越狱环境专有",
        "substrate.h": "Cydia Substrate 专有",
        "Kernel.framework": "内核框架，App 侧不可用",
    }
    # 【已证】iOS 公开 SDK 头里没有声明 —— 构建 #10 实测 mach_vm_deallocate 报
    #        "use of undeclared identifier"。直接调用必挂，一律 ERROR。
    SPI_HARD = {
        "mach_vm_remap", "mach_vm_deallocate", "mach_vm_read",
        "mach_vm_write", "mach_vm_region", "mach_vm_allocate",
        "mach_vm_protect", "mach_vm_read_overwrite", "mach_vm_machine_attribute",
    }
    # 【未证】可能公开也可能 SPI，只提醒不报错
    SPI_SOFT = {
        "task_for_pid", "host_processor_set_priv",
        "processor_set_tasks", "host_processor_sets", "host_get_special_port",
        "processor_set_default",
    }

    exts = (".mm", ".m", ".c", ".cpp")
    skip = {"imgui", "kfd"}
    checked = 0
    for dirpath, dirnames, filenames in os.walk(os.path.join(APP, "Sources")):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(exts):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            with open(p, encoding="utf-8", errors="replace") as f:
                body = strip_code(f.read())
            checked += 1

            # 私有 iOS 头：fatal error: 'xxx.h' file not found
            for hdr, hint in PRIVATE_HEADERS.items():
                m2 = re.search(r"#\s*(?:import|include)\s*[<\"]" + re.escape(hdr), body)
                if m2:
                    line_no = body[:m2.start()].count("\n") + 1
                    err(f"{rel}:{line_no}: `{hdr}` 在 iOS 公开 SDK 里不存在"
                        f"（fatal error: file not found）—— {hint}")

            for sym, hard in [(s, True) for s in SPI_HARD] + [(s, False) for s in SPI_SOFT]:
                # 直接调用形态： symbol(
                if not re.search(r"(?<![\w\"])" + re.escape(sym) + r"\s*\(", body):
                    continue
                # 已经 dlsym 包装过就不算
                if re.search(r"dlsym\s*\([^)]*\"" + re.escape(sym) + r"\"", body):
                    continue
                if hard:
                    err(f"{rel}: 直接调用了 iOS SPI `{sym}(...)` —— "
                        f"公开 SDK 头里没声明，会报 use of undeclared identifier；"
                        f"改用 dlsym + 函数指针")
                else:
                    warn(f"{rel}: 调用了 `{sym}(...)` —— 该符号在 iOS 上是否公开未证，"
                         f"若构建报 undeclared 就改 dlsym")
    ok(f"iOS SPI 检查完成，扫描 {checked} 个源文件")


# ------------------------------------------------- 7.7 ObjC++ 枚举参数 / 常量拼写
# 【已证】UIKit 里不存在、但很容易顺手写错的常量名
BAD_CONSTANTS = {
    "UIFontRegular": "UIFontWeightRegular",
    "UIFontBold": "UIFontWeightBold",
    "UIFontMedium": "UIFontWeightMedium",
    "UIFontSemibold": "UIFontWeightSemibold",
    "UIColorBlack": "UIColor.blackColor",
}


def check_objcxx_traps():
    """
    ObjC++ 比 ObjC 严格，两类常见硬错误：
      1) 把裸整数传给声明为枚举类型的参数（"cannot initialize a parameter of
         type 'MFEnumRoute' with an rvalue of type 'int'"）
      2) UIKit 常量名拼错（use of undeclared identifier）
    """
    src_exts = (".mm", ".m", ".c", ".cpp")
    hdr_exts = (".h", ".hpp")
    skip = {"imgui", "kfd"}

    # ---- 收集本工程的枚举类型名 ----
    enum_types = set()
    for dirpath, dirnames, filenames in os.walk(APP):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(hdr_exts):
                continue
            p = os.path.join(dirpath, fn)
            with open(p, encoding="utf-8", errors="replace") as f:
                txt = strip_code(f.read())
            # NS_ENUM(NSInteger, Name) —— 名字在括号【内】
            for m in re.finditer(r"(?:NS_ENUM|NS_OPTIONS)\s*\(\s*\w+\s*,\s*([A-Za-z_]\w*)\s*\)", txt):
                enum_types.add(m.group(1))
            # typedef enum {...} Name;  /  typedef NS_ENUM(...) Name;（少见）
            for m in re.finditer(r"typedef\s+enum\s*\w*\s*\{.*?\}\s*([A-Za-z_]\w*)\s*;", txt, re.S):
                enum_types.add(m.group(1))
    enum_types = {e for e in enum_types if e.startswith("MF") or e.endswith(("Route", "Style", "State", "Mode"))}

    # ---- 收集「参数类型是枚举」的选择器关键字 ----
    enum_keywords = set()
    for dirpath, dirnames, filenames in os.walk(APP):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(hdr_exts):
                continue
            p = os.path.join(dirpath, fn)
            with open(p, encoding="utf-8", errors="replace") as f:
                txt = strip_code(f.read())
            for et in enum_types:
                for m in re.finditer(r"(\w+)\s*:\s*\(?\s*" + re.escape(et) + r"\s*\)?\s*\w+", txt):
                    enum_keywords.add(m.group(1))
    enum_keywords.discard("typedef")

    checked = 0
    for dirpath, dirnames, filenames in os.walk(os.path.join(APP, "Sources")):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(src_exts):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            with open(p, encoding="utf-8", errors="replace") as f:
                body = strip_code(f.read())
            checked += 1

            # 1) 枚举参数传裸数字
            for kw in enum_keywords:
                for m in re.finditer(r"\b" + re.escape(kw) + r"\s*:\s*(\d+)\b", body):
                    line_no = body[:m.start()].count("\n") + 1
                    err(f"{rel}:{line_no}: 选择器 `{kw}:` 的参数是枚举类型，"
                        f"传了裸整数 {m.group(1)} —— ObjC++ 会报 cannot initialize "
                        f"a parameter of type enum with an rvalue of type 'int'；"
                        f"请改用枚举常量")

            # 2) UIKit 常量拼写
            for bad, good in BAD_CONSTANTS.items():
                if re.search(r"\b" + re.escape(bad) + r"\b", body):
                    line_no = body[:re.search(r"\b" + re.escape(bad) + r"\b", body).start()].count("\n") + 1
                    err(f"{rel}:{line_no}: `{bad}` 不存在 —— 应为 `{good}`")

    ok(f"ObjC++ 陷阱检查完成（枚举类型 {len(enum_types)} 个 · 枚举关键字 {len(enum_keywords)} 个 · 扫描 {checked} 个文件）")


# ------------------------------------------------- 7.8 编译单元语言边界
OBJC_HEADER_MARKERS = (r"#\s*(?:import|include)\s*<Foundation/",
                       r"#\s*(?:import|include)\s*<UIKit/",
                       r"#\s*(?:import|include)\s*<CoreGraphics/")


def check_language_boundaries():
    """
    两类「语言边界」硬错误：
      1) .c（纯 C）编译单元（含传递包含）吃到 ObjC 头（Foundation/UIKit）→
         "Module 'ObjectiveC.NSObject' requires feature 'objc'"
         （构建 #13）
      2) .mm（ObjC++）里 extern 声明 C 符号却没包 extern "C" →
         名字改编导致链接期找不到符号（构建 #14）
    """
    src_root = os.path.join(APP, "Sources")
    skip = {"imgui", "vendor"}

    # ---- 建一张「哪些头最终会拉进 ObjC」的传递闭包 ----
    # 先收集所有头文件 → 它直接包含的本地头 / 是否直接含 ObjC 标记
    headers = {}          # abs_path -> {"includes": set(), "objc": bool}
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if not fn.endswith((".h", ".hpp")):
                continue
            p = os.path.normpath(os.path.join(dirpath, fn))
            with open(p, encoding="utf-8", errors="replace") as f:
                body = strip_code(f.read())
            incs = set()
            for m in re.finditer(r'#\s*(?:import|include)\s+"([^"]+)"', body):
                incs.add(m.group(1))
            objc = any(re.search(pat, body) for pat in OBJC_HEADER_MARKERS)
            headers[p] = {"includes": incs, "objc": objc}

    def resolves_to(from_path, inc):
        base = os.path.dirname(from_path)
        for cand in (os.path.normpath(os.path.join(base, inc)),
                     os.path.normpath(os.path.join(src_root, inc)),
                     os.path.normpath(os.path.join(src_root, "Kernel", inc)),
                     os.path.normpath(os.path.join(src_root, "Kernel", "kfd", inc))):
            if cand in headers:
                return cand
        return None

    # 传递闭包（带记忆化 + 防环）
    memo = {}

    def reaches_objc(path, seen=None):
        if path in memo:
            return memo[path]
        if seen is None:
            seen = set()
        if path in seen:
            return False
        seen.add(path)
        info = headers.get(path)
        if not info:
            return False
        if info["objc"]:
            memo[path] = True
            return True
        for inc in info["includes"]:
            tgt = resolves_to(path, inc)
            if tgt and reaches_objc(tgt, seen):
                memo[path] = True
                return True
        memo[path] = False
        return False

    # ---- 检查 .c 文件 ----
    n_c = 0
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if not fn.endswith(".c"):
                continue
            p = os.path.normpath(os.path.join(dirpath, fn))
            rel = os.path.relpath(p, ROOT)
            n_c += 1
            with open(p, encoding="utf-8", errors="replace") as f:
                body = strip_code(f.read())
            for m in re.finditer(r'#\s*(?:import|include)\s+"([^"]+)"', body):
                tgt = resolves_to(p, m.group(1))
                if tgt and reaches_objc(tgt):
                    line_no = body[:m.start()].count("\n") + 1
                    err(f"{rel}:{line_no}: 纯 C 单元包含了最终会拉进 ObjC 头的 "
                        f"\"{m.group(1)}\" —— 会报 Module 'ObjectiveC.NSObject' "
                        f"requires feature 'objc'；把本文件改成 .m（ObjC）即可")

    # ---- 检查 .mm 文件的 extern "C" ----
    n_mm = 0
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if not fn.endswith(".mm"):
                continue
            p = os.path.normpath(os.path.join(dirpath, fn))
            rel = os.path.relpath(p, ROOT)
            n_mm += 1
            with open(p, encoding="utf-8", errors="replace") as f:
                body = strip_code(f.read())
            if 'extern "C"' in body:
                continue                      # 已经包了，跳过
            # \ufeff? —— 容忍文件头 BOM
            for m in re.finditer(r"^[ \t]*\ufeff?[ \t]*extern\s+[\w\s\*]+?\b(\w+)\s*\([^;]*\)\s*;",
                                 body, re.M):
                line_no = body[:m.start()].count("\n") + 1
                err(f"{rel}:{line_no}: .mm 里声明了外部 C 函数 `{m.group(1)}` 但没包 "
                    f"extern \"C\" —— ObjC++ 会做名字改编，链接期找不到 _"
                    f"{m.group(1)}；用 extern \"C\" {{ ... }} 包住")

    ok(f"语言边界检查完成（.c {n_c} 个 · .mm {n_mm} 个 · 头文件 {len(headers)} 个）")


# ------------------------------------------------- 7.9 project.yml 路径存在性
def check_project_paths():
    """
    project.yml 的 sources 里每个 `- path:` 都必须在磁盘上真实存在。
    XcodeGen 遇到不存在的路径会直接报错，构建就废了。
    （这个检查本该早就有 —— MFLibkfdHost.c 被列进工程却不存在，就是这么漏掉的。）
    同时核对 excludes 通配符是否至少匹配到了东西，避免写出无效排除。
    """
    proj = os.path.join(APP, "project.yml")
    if not os.path.exists(proj):
        err("project.yml 不存在")
        return
    with open(proj, encoding="utf-8") as f:
        lines = f.readlines()

    n_path = 0
    for i, line in enumerate(lines):
        m = re.match(r"\s*-\s*path:\s*(.+?)\s*$", line)
        if not m:
            continue
        raw = m.group(1).strip().strip('"').strip("'")
        n_path += 1
        target = os.path.normpath(os.path.join(APP, raw))
        if os.path.exists(target):
            ok(f"project.yml 路径存在: {raw}")
        else:
            err(f"project.yml:{i+1}: 列出的路径不存在 → `{raw}`"
                f"（XcodeGen 会报错，构建必挂）")

    if n_path == 0:
        warn("project.yml 里没解析到任何 `- path:` 条目 —— 检查缩进格式是否变了")


# ------------------------------------------------- 7.10 kread/kwrite 的 size 粒度
def check_krw_size_granularity():
    """
    libkfd 的 kread/kwrite 落到：
        #define kread_from_method(type, method)
            u64 type_size = ((size) / (sizeof(type)));
            for (u64 i = 0; i < type_size; i++) { ... }

    sem_open 后端用的 type 是 u64（sizeof = 8）。
    所以 size < 8 或不是 8 的倍数时：
        · size = 4  →  4/8 = 0  →  【一次循环都不进，缓冲区原封不动】
        · size = 12 →  12/8 = 1 →  只读前 8 字节，后 4 字节静默丢失

    这是最阴的一类 bug：不报错、不崩溃，只是数据不对。
    真机上表现为 patchfinder 读到的全是 0，最后报 "run_kfd_patchfinder failed"。

    规则：本工程代码里直接调 kread()/kwrite() 时，size 必须是 8 的倍数，
          或显式走 mf_kread / kread_sem_open_kread_u32 这类已做兜底的封装。
    """
    FOUR_BYTE = {"uint32_t", "u32", "i32", "int", "int32_t", "float",
                 "unsigned int", "unsigned"}
    EIGHT_BYTE = {"uint64_t", "u64", "i64", "size_t", "double", "void*", "long",
                  "unsigned long"}

    exts = (".m", ".mm", ".c")
    skip = {"imgui", "vendor", "kfd"}          # kfd 是上游代码，本身是对的
    checked = 0
    for dirpath, dirnames, filenames in os.walk(os.path.join(APP, "Sources")):
        if any(s in dirpath.split(os.sep) for s in skip):
            continue
        for fn in filenames:
            if not fn.endswith(exts):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            with open(p, encoding="utf-8", errors="replace") as f:
                body = strip_code(f.read())
            checked += 1

            # 先建本文件的整型变量类型表，才能解析 sizeof(v) 里的 v 是什么类型
            var_types = {}
            for vm in re.finditer(
                r"\b(uint32_t|uint64_t|u32|u64|i32|i64|int32_t|int64_t|"
                r"uint16_t|u16|int|unsigned|float|double|size_t|long)\s+"
                r"\*?\s*(\w+)\s*[;=,)]", body):
                var_types[vm.group(2)] = vm.group(1)

            for m in re.finditer(r"\b(kread|kwrite)\s*\(((?:[^()]|\([^()]*\))*)\)\s*;", body):
                call, args = m.group(1), m.group(2)
                last = args.rsplit(",", 1)[-1].strip()
                line_no = body[:m.start()].count("\n") + 1

                sm = re.match(r"sizeof\s*\(\s*([^)]+?)\s*\)", last)
                if sm:
                    raw = sm.group(1).strip()
                    # sizeof(*out) → 取 out 的声明类型
                    ident = raw.lstrip("*").strip()
                    t = var_types.get(ident, raw)

                    if t in EIGHT_BYTE:
                        continue
                    if t in FOUR_BYTE:
                        err(f"{rel}:{line_no}: {call}(...) 的 size 是 "
                            f"sizeof({raw})（{t}，4 字节级）"
                            f"—— kread_from_method 按 sizeof(u64)=8 取整，"
                            f"4 字节时循环次数为 0，缓冲区不会被写！"
                            f"改走 mf_kread / kread_sem_open_kread_u32，或读 8 字节再截断")
                        continue
                    # 解析不出来：如果变量名对不上任何已知 8 字节类型，提醒一下
                    if ident not in var_types and not raw.startswith("*"):
                        warn(f"{rel}:{line_no}: {call}(...) 的 size 是 sizeof({raw})，"
                             f"无法确定 {ident} 的类型 —— 请人工确认它是 8 字节的")
                    continue

                nm = re.match(r"(\d+)\b", last)
                if nm:
                    n = int(nm.group(1))
                    if n % 8 != 0:
                        err(f"{rel}:{line_no}: {call}(...) 的 size 字面量 {n} "
                            f"不是 8 的倍数 —— 尾部字节会被静默丢弃"
                            f"（size=4 时甚至一次都不读）")
    ok(f"kread/kwrite 粒度检查完成，扫描 {checked} 个文件")


# ------------------------------------------- 7.11 源文件编码 / 乱码（防止被编辑器写坏）
def check_source_encoding():
    """
    2026-10-15 实际踩过：用 PowerShell 的 Get-Content -Raw + WriteAllText
    改一行中文注释，结果 PS 按 GBK 读、按 UTF-8 写 → 整个文件变乱码，
    更致命的是【换行被吃掉】，后面几行的 @property 被并进注释里，
    Xcode 报 "no visible @interface declares the selector" —— 完全看不出是编码问题。

    这里做两道检查：
      ① 文件必须能按 UTF-8 解码（不能有非法字节）
      ② 不出现典型的「UTF-8 被当 GBK 读」乱码字
    """
    MOJIBAKE = ["鈥", "锛", "鐨", "涓", "鏄", "鍒", "缁", "閫", "鎸", "瀹",
                "鐢", "姣", "杈", "鍑", "瀵", "鏂", "浠", "鍔", "鑿", "缂"]
    exts = (".h", ".m", ".mm", ".c", ".cpp", ".swift", ".plist", ".yml", ".yaml",
            ".md", ".json", ".py")
    bad_utf8, mojibake = [], []

    for dirpath, dirnames, filenames in os.walk(ROOT):
        low = dirpath.replace("/", os.sep).split(os.sep)
        if any(p in (".git", "build", "dist", "imgui", "node_modules") for p in low):
            continue
        for fn in filenames:
            if not fn.endswith(exts):
                continue
            if fn == "preflight.py":      # 本脚本自己写着乱码模式表，跳过
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            try:
                with open(p, "rb") as f:
                    raw = f.read()
            except OSError:
                continue
            try:
                txt = raw.decode("utf-8")
            except UnicodeDecodeError as e:
                bad_utf8.append(f"{rel}: 不是合法 UTF-8（字节偏移 {e.start}: {e.reason}）")
                continue
            hits = [m for m in MOJIBAKE if m in txt]
            if hits:
                mojibake.append(f"{rel}: 出现乱码字 {'/'.join(hits[:4])} "
                                f"—— 多半是用 PowerShell/记事本 按 GBK 读过又写回，"
                                f"换行可能已被吃掉，务必用 git 恢复")

    for m in bad_utf8:
        err(m)
    for m in mojibake:
        err(m)
    if not bad_utf8 and not mojibake:
        ok("源文件编码检查通过（UTF-8 合法、无乱码字）")


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
    check_ios_spi()
    check_objcxx_traps()
    check_language_boundaries()
    check_krw_size_granularity()
    check_source_encoding()
    check_project_paths()
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
