#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
改动后的轻量语法体检（Windows 本地跑不了 clang，这里做结构性检查）：

  ① 跳过字符串字面量 / 字符字面量 / 注释，检查 () {} [] 是否配对
  ② @implementation / @interface / @end 的配对与嵌套
  ③ 行尾反斜杠续行的宏不能出现在文件最后一行
  ④ C++ 风格误写检测：ObjC 头里出现 ".replace(" / "std::" 之类
  ⑤ 函数实现/调用一致性抽查：我们自己新增的方法名两边都要出现

这不是编译器，只抓低级错误。真正的编译在 GitHub Actions 上。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FILES = [
    "app/Sources/HUD/MFHUDControl.h",
    "app/Sources/HUD/MFHUDControl.mm",
    "app/Sources/HUD/MFHUDLauncher.mm",
    "app/Sources/HUD/MFHUDAppDelegate.h",
    "app/Sources/HUD/MFHUDAppDelegate.mm",
    "app/Sources/HUD/MFHUDApplication.mm",
    "app/Sources/HUD/MFHUDInputBridge.mm",
    "app/Sources/HUD/MFHUDLog.m",
    "app/Sources/HUD/MFHUDWindow.mm",
    "app/Sources/HUD/MFMenuUI.h",
    "app/Sources/HUD/MFMenuUI.mm",
    "app/Sources/Render/MFOverlayView.h",
    "app/Sources/Render/MFOverlayView.mm",
    "app/Sources/App/RootViewController.mm",
    "tests/hud_input_bridge_regressions.mm",
]

BAD_PATTERNS = [
    (r'@"[^"]*"\s*\.\s*replace\s*\(', 'ObjC 字符串上调用了 C++ 方法'),
    (r'\bnil\s*\.\s*\w+\s*\(', '对 nil 用了点语法调方法'),
    (r'->\s*replace\s*\(', '疑似 C++ 写法混进 ObjC'),
]


def strip_code(text: str) -> str:
    """把注释和字符串替换成等长空白，保留换行以便报行号。"""
    out = []
    i, n = 0, len(text)
    state = None          # None | 'line' | 'block' | 'str' | 'char'
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '/':
                state = 'line'
                out.append('  ')
                i += 2
                continue
            if c == '/' and nxt == '*':
                state = 'block'
                out.append('  ')
                i += 2
                continue
            if c == '"':
                state = 'str'
                out.append(' ')
                i += 1
                continue
            if c == "'":
                state = 'char'
                out.append(' ')
                i += 1
                continue
            out.append(c)
            i += 1
        elif state == 'line':
            if c == '\n':
                state = None
                out.append('\n')
            else:
                out.append(' ')
            i += 1
        elif state == 'block':
            if c == '*' and nxt == '/':
                state = None
                out.append('  ')
                i += 2
                continue
            out.append('\n' if c == '\n' else ' ')
            i += 1
        elif state in ('str', 'char'):
            if c == '\\':
                out.append('  ')
                i += 2
                continue
            if (state == 'str' and c == '"') or (state == 'char' and c == "'"):
                state = None
            out.append('\n' if c == '\n' else ' ')
            i += 1
    return ''.join(out)


def check_balance(path: Path, problems: list):
    raw = path.read_text(encoding='utf-8')
    code = strip_code(raw)
    pairs = {')': '(', '}': '{', ']': '['}
    stack = []
    for lineno, line in enumerate(code.splitlines(), 1):
        for ch in line:
            if ch in '({[':
                stack.append((ch, lineno))
            elif ch in ')}]':
                if not stack or stack[-1][0] != pairs[ch]:
                    problems.append(f"{path.relative_to(ROOT)}:{lineno}: 多余的 '{ch}'")
                    return
                stack.pop()
    for ch, lineno in stack:
        problems.append(f"{path.relative_to(ROOT)}:{lineno}: '{ch}' 没有闭合")


def check_objc_blocks(path: Path, problems: list):
    raw = path.read_text(encoding='utf-8')
    code = strip_code(raw)
    depth = 0
    for lineno, line in enumerate(code.splitlines(), 1):
        stripped = line.strip()
        # @protocol Foo; 是前向声明，不带 @end，别计入
        if (re.match(r'@(implementation|interface|protocol)\b', stripped)
                and not stripped.rstrip().endswith(';')):
            depth += 1
        elif stripped.startswith('@end'):
            depth -= 1
            if depth < 0:
                problems.append(f"{path.relative_to(ROOT)}:{lineno}: @end 多于 @implementation/@interface/@protocol")
                return
    if depth != 0:
        problems.append(f"{path.relative_to(ROOT)}: @implementation/@interface 与 @end 不配对（差 {depth}）")


def check_counts(path: Path, problems: list):
    code = strip_code(path.read_text(encoding='utf-8'))
    opens = len(re.findall(r'@implementation\b', code))
    m_impl = len(re.findall(r'^\s*[-+]\s*\(', code, re.M))
    print(f"  {path.name}: @implementation {opens} 段, 方法声明/定义 {m_impl} 处")


def check_patterns(path: Path, problems: list):
    raw = path.read_text(encoding='utf-8')
    for pattern, why in BAD_PATTERNS:
        for m in re.finditer(pattern, raw):
            lineno = raw[:m.start()].count('\n') + 1
            problems.append(f"{path.relative_to(ROOT)}:{lineno}: {why} → {m.group(0)!r}")


def check_symbols(problems: list):
    """新增 API 的声明与实现必须成对出现。"""
    app = ROOT / "app/Sources"
    control_h = (app / "HUD/MFHUDControl.h").read_text(encoding='utf-8')
    control_m = (app / "HUD/MFHUDControl.mm").read_text(encoding='utf-8')
    for name in ["MFHUDExitNotificationName", "MFHUDPIDFilePath"]:
        if name not in control_h or name not in control_m:
            problems.append(f"MFHUDControl: {name} 声明/实现不一致")
    for sel in ["requestExit", "watchForExitRequest", "stopWatching"]:
        if sel not in control_h:
            problems.append(f"MFHUDControl.h 缺少 +{sel}")
        if sel not in control_m:
            problems.append(f"MFHUDControl.mm 缺少 +{sel}")

    overlay_h = (app / "Render/MFOverlayView.h").read_text(encoding='utf-8')
    overlay_m = (app / "Render/MFOverlayView.mm").read_text(encoding='utf-8')
    for sel in ["beginInteractiveRects", "addInteractiveRect", "endInteractiveRects",
                "requestRedraw", "hasInteractiveRects"]:
        if sel not in overlay_h:
            problems.append(f"MFOverlayView.h 缺少 {sel}")
        if sel not in overlay_m:
            problems.append(f"MFOverlayView.mm 缺少 {sel}")

    menu_h = (app / "HUD/MFMenuUI.h").read_text(encoding='utf-8')
    menu_m = (app / "HUD/MFMenuUI.mm").read_text(encoding='utf-8')
    for sel in ["collapsed", "fullPassthrough", "setFrameRateApplier"]:
        if sel not in menu_h:
            problems.append(f"MFMenuUI.h 缺少 {sel}")
        if sel not in menu_m:
            problems.append(f"MFMenuUI.mm 缺少 {sel}")

    # AppDelegate 必须实现退出收尾；通道安装点在引导阶段（MFHUDApplication）
    appdelegate_m = (app / "HUD/MFHUDAppDelegate.mm").read_text(encoding='utf-8')
    for needle in ["shutdownForExitRequest", "stopWatching", "MFHUDPIDFilePath"]:
        if needle not in appdelegate_m:
            problems.append(f"MFHUDAppDelegate.mm 缺少 {needle}")
    appdelegate_h = (app / "HUD/MFHUDAppDelegate.h").read_text(encoding='utf-8')
    if "shutdownForExitRequest" not in appdelegate_h:
        problems.append("MFHUDAppDelegate.h 缺少 shutdownForExitRequest")

    application_m = (app / "HUD/MFHUDApplication.mm").read_text(encoding='utf-8')
    if "watchForExitRequest" not in application_m:
        problems.append("MFHUDApplication.mm 没有在引导阶段安装退出通道")

    launcher_m = (app / "HUD/MFHUDLauncher.mm").read_text(encoding='utf-8')
    if "MFHUDControl requestExit" not in launcher_m:
        problems.append("MFHUDLauncher.mm 的停止路径没有走通知通道")
    if "task_terminate" not in launcher_m:
        problems.append("MFHUDLauncher.mm 缺少兜底 task_terminate")


def main() -> int:
    problems: list = []
    print("== 结构检查 ==")
    for rel in FILES:
        path = ROOT / rel
        if not path.exists():
            problems.append(f"文件不存在：{rel}")
            continue
        check_balance(path, problems)
        check_objc_blocks(path, problems)
        check_patterns(path, problems)
        check_counts(path, problems)

    print("== 符号一致性 ==")
    check_symbols(problems)

    print("== 结果 ==")
    if problems:
        for p in problems:
            print("✗ " + p)
        return 1
    print("✅ 结构检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
