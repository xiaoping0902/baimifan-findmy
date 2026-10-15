#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dev.py — 白米饭复刻 · Windows 侧调试台

把「查设备 → 拉日志 → 看状态 → 读崩溃」这几件事收成一条命令。

依赖：pymobiledevice3（装在 Python 3.12 里，见 PY 常量）

用法：
    python scripts/dev.py status         设备 + App + 内核 + 读取链 一览
    python scripts/dev.py pull           把 /var/mobile/Media/mf-debug 全拉回来
    python scripts/dev.py log kfd        只看内核日志
    python scripts/dev.py log hud        只看 HUD 日志
    python scripts/dev.py shot           拉自截图并打开
    python scripts/dev.py crash          最近的崩溃报告
    python scripts/dev.py watch          实时日志（只显示 [MF] 开头）
    python scripts/dev.py export         让 App 导出一次（需要 App 在前台点过按钮）
    python scripts/dev.py install        打印装机地址（配合 serve_ipa.py）

设计说明（为什么不用 MCP）：
    MCP 的价值是「给我一个类型化工具接口」。但这里我本来就能直接跑命令 ——
    加一层 MCP 只是把 `python -m pymobiledevice3 xxx` 包一层，能力零增加，
    反而多一个会坏的东西。真正的痛点（读不到 App 沙盒、看不到屏幕）由
    MFDebugExport（App 主动写到 Media）+ 这个脚本解决。
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

# ── 路径 ────────────────────────────────────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "dev-out")          # 拉回来的东西都放这

# pymobiledevice3 装在 Python 3.12；系统默认的 3.14 里没有
PY_CANDIDATES = [
    r"C:\Users\xiaoping\AppData\Local\Programs\Python\Python312\python.exe",
    r"C:\Users\xiaoping\AppData\Local\Programs\Python\Python311\python.exe",
    "python", "py",
]

# 设备上的导出目录（由 MFDebugExport 写入）
DEVICE_DIR = "/mf-debug"          # AFC 根就是 /var/mobile/Media
BUNDLE_ID = "com.apple.findmy"

C = {
    "g": "\033[92m", "y": "\033[93m", "r": "\033[91m",
    "b": "\033[94m", "d": "\033[90m", "B": "\033[1m", "0": "\033[0m",
}
if os.name == "nt":
    os.system("")          # 打开 Windows 控制台的 ANSI 支持


def c(k, s):
    return f"{C.get(k,'')}{s}{C['0']}"


# ── pymobiledevice3 调用 ────────────────────────────────────────────
_PY = None


def py():
    global _PY
    if _PY:
        return _PY
    for cand in PY_CANDIDATES:
        try:
            r = subprocess.run([cand, "-c", "import pymobiledevice3"],
                               capture_output=True, timeout=20)
            if r.returncode == 0:
                _PY = cand
                return _PY
        except Exception:
            continue
    die("找不到带 pymobiledevice3 的 Python。\n"
        "  装了的话改一下脚本顶部的 PY_CANDIDATES。")


def pmd(*args, timeout=90, binary=False, check=False):
    cmd = [py(), "-m", "pymobiledevice3", *args]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        die(f"命令超时：pymobiledevice3 {' '.join(args)}")
    if r.returncode != 0 and check:
        die(f"命令失败：{' '.join(args)}\n{r.stderr.decode('utf-8','replace')[:400]}")
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


def die(msg):
    print(c("r", "✗ ") + msg)
    sys.exit(1)


# ── 前置检查 ────────────────────────────────────────────────────────
def device():
    """返回 (udid, 信息字典)；没连就退出"""
    try:
        raw = pmd("usbmux", "list", timeout=30)
        devs = json.loads(raw)
    except Exception as e:
        die(f"读设备列表失败：{e}")
    if not devs:
        die("设备没连。\n"
            "  · iPad 插好数据线、解锁屏幕\n"
            "  · 第一次连接要在 iPad 上点「信任本电脑」\n"
            "  · 优先主机后置 USB 口")
    d = devs[0]
    return d.get("UniqueDeviceID", ""), d


def need_app(udid):
    """确认我们的 App 装着，返回 (版本, 路径)"""
    try:
        raw = pmd("apps", "list", timeout=60)
        apps = json.loads(raw)
    except Exception:
        return None, None
    a = apps.get(BUNDLE_ID)
    if not a:
        return None, None
    return a.get("CFBundleVersion", "?"), a.get("Path", "?")


# ── 子命令 ──────────────────────────────────────────────────────────
def cmd_status():
    udid, d = device()
    print(c("B", "═" * 66))
    print(c("B", "  白米饭复刻 · 设备状态"))
    print(c("B", "═" * 66))
    print(f"  设备      {d.get('DeviceName','?')}  {d.get('ProductType','?')}")
    print(f"  系统      iPadOS {d.get('ProductVersion','?')}  ({d.get('BuildVersion','?')})")
    print(f"  UDID      {udid}")

    ver, path = need_app(udid)
    if ver:
        print(f"  App       {c('g','已安装')}  版本 {ver}")
        print(f"             {path}")
    else:
        print(f"  App       {c('r','未安装')}（{BUNDLE_ID}）")

    # 导出目录
    print()
    print(c("B", "─" * 66))
    print(c("B", "  导出数据（App 写到 /var/mobile/Media/mf-debug）"))
    print(c("B", "─" * 66))
    try:
        listing = pmd("afc", "ls", DEVICE_DIR, timeout=40)
    except Exception:
        listing = ""
    files = [x.strip() for x in listing.splitlines()
             if x.strip() and not x.strip().endswith("/")]
    files = [f for f in files if f.startswith("/") and f.count("/") >= 2
             and not f.rstrip("/").endswith("mf-debug")]
    if not files:
        print(c("y", "  （空的）"))
        print("  让 App 导出一次：打开「查找」→ 首页 → 「导出诊断」")
    else:
        for f in files:
            print(f"    {f}")
        print()
        print(c("d", "  拉回来：") + c("b", "python scripts/dev.py pull"))

    print()


def cmd_pull(quiet=False):
    udid, _ = device()
    os.makedirs(OUT, exist_ok=True)

    listing = pmd("afc", "ls", DEVICE_DIR, timeout=40)
    names = []
    for line in listing.splitlines():
        line = line.strip()
        if not line.startswith("/"):
            continue
        base = line.rstrip("/").split("/")[-1]
        if base and base != "mf-debug" and "." in base:
            names.append(base)

    if not names:
        if not quiet:
            print(c("y", "导出目录是空的。"))
            print("  打开「查找」→ 首页 → 点「导出诊断」，然后重跑本命令。")
        return []

    got = []
    for n in names:
        dst = os.path.join(OUT, n)
        pmd("afc", "pull", f"{DEVICE_DIR}/{n}", dst, timeout=120)
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            got.append(dst)
            if not quiet:
                print(f"  {c('g','✓')} {n:16s} {os.path.getsize(dst):>8d} 字节")

    if got and not quiet:
        print()
        print_state(os.path.join(OUT, "state.json"))
    return got


def print_state(p):
    if not os.path.exists(p):
        return
    try:
        d = json.load(open(p, encoding="utf-8"))
    except Exception:
        return

    print(c("B", "─" * 66))
    print(c("B", "  状态快照（App 侧写出）"))
    print(c("B", "─" * 66))

    k = d.get("kernel", {})
    opened = k.get("open")
    print(f"  内核      {c('g','已启动') if opened else c('y','未启动')}"
          f"    kbase={k.get('kbase',0):#x}")
    if not opened and k.get("lastErr"):
        print(f"            上次错误：{k['lastErr'][:70]}")

    rc = d.get("readchain", {})
    print(f"  读取链    port={rc.get('targetTaskPort',0):#x}"
          f"  门={'开' if rc.get('gateOpen') else '关'}")
    for key, label in (("rootObjectBase", "指针链根"), ("entityArrayBase", "实体数组"),
                       ("lootArrayBase", "物资数组")):
        v = rc.get(key, 0)
        print(f"            {label}  {c('g', hex(v)) if v else c('y','未校准')}")

    h = d.get("hud", {})
    print(f"  悬浮窗    {'运行中 PID ' + str(h.get('pid')) if h.get('running') else '未运行'}")

    cu = d.get("cleanup", {})
    print(f"  清理规则  {cu.get('dirs',0)} 个目录 · 黑 {cu.get('blacklist',0)}"
          f" / 白 {cu.get('whitelist',0)}")

    kc = d.get("keychain", {})
    print(f"  密钥库    {kc.get('mode','?')} · {kc.get('gameMode','?')}")

    ab = d.get("antiban", {})
    p = ab.get("plist", "未找到")
    print(f"  防封      {'找到' if p != '未找到' else c('y','未找到')}")

    e = d.get("export", {})
    print(f"  导出      {'可用' if e.get('available') else c('r','不可用')}")
    print()


def cmd_log(which):
    cmd_pull(quiet=True)
    fn = {"kfd": "kfd.log", "hud": "hud.log"}.get(which)
    if not fn:
        die("只支持 kfd / hud")
    p = os.path.join(OUT, fn)
    if not os.path.exists(p):
        die(f"{fn} 还没拉回来 —— 先在 App 里触发一次对应操作再导出")
    txt = open(p, encoding="utf-8", errors="replace").read()
    print(c("B", f"── {fn} ({len(txt)} 字节) " + "─" * 40))
    # 关键行高亮
    for line in txt.splitlines():
        if re.search(r"✓|success|成功|OK", line):
            print(c("g", line))
        elif re.search(r"✗|fail|失败|error|assert", line, re.I):
            print(c("r", line))
        elif re.search(r"⚠|warn|retry|警告", line):
            print(c("y", line))
        else:
            print(line)


def cmd_shot():
    cmd_pull(quiet=True)
    p = os.path.join(OUT, "screen.png")
    if not os.path.exists(p):
        die("还没拉到 screen.png —— 在 App 里点「导出诊断」时 App 必须在前台")
    print(f"{c('g','✓')} {p}  ({os.path.getsize(p)} 字节)")
    try:
        os.startfile(p)
    except Exception:
        print("  （自动打开失败，手动双击看）")


def cmd_crash():
    device()
    print(c("B", "── 最近崩溃报告 " + "─" * 48))
    out = pmd("crash", "ls", timeout=60)
    lines = [l.strip() for l in out.splitlines() if l.strip().endswith(".ips")]
    my = [l for l in lines if "FindMy" in l or "panic-full" in l]
    if not my:
        print(c("g", "  没有我们的崩溃/panic 记录"))
        return
    for l in my[:8]:
        tag = c("r", "PANIC") if "panic" in l else c("y", "CRASH")
        print(f"  {tag}  {l}")
    print()
    latest = my[0]
    print(c("d", f"  解析最近一条：{latest}"))
    txt = pmd("crash", "parse", latest, timeout=90)
    for line in txt.splitlines()[:40]:
        print("   " + line)
    # 存一份
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "last-crash.txt"), "w", encoding="utf-8") as f:
        f.write(txt)
    print()
    print(c("d", f"  完整内容已存 {os.path.join(OUT,'last-crash.txt')}"))


def cmd_watch():
    device()
    print(c("B", "── 实时日志（只显示 [MF] 开头的行，Ctrl+C 退出）" + "─" * 10))
    cmd = [py(), "-m", "pymobiledevice3", "syslog", "live"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        for raw in iter(p.stdout.readline, b""):
            line = raw.decode("utf-8", "replace").rstrip()
            if "[MF]" in line or "FindMy[" in line:
                if "🔴" in line or "✗" in line or "失败" in line:
                    print(c("r", line))
                elif "✓" in line or "成功" in line:
                    print(c("g", line))
                else:
                    print(line)
    except KeyboardInterrupt:
        pass
    finally:
        p.terminate()


def cmd_export():
    """提示用户在 App 上点按钮（我们没法远程点 UI）"""
    print(c("B", "让 App 导出一次诊断数据"))
    print()
    print("  我这边没法远程点 iPad 上的按钮，所以要你手动一下：")
    print()
    print(f"    1. 打开 {c('B','「查找」')}")
    print(f"    2. 首页找到 {c('B','「导出诊断」')}")
    print(f"    3. 点一下，等它弹出结果")
    print(f"    4. 回来跑：{c('b','python scripts/dev.py pull')}")
    print()
    print(c("d", "  （导出会写日志 + 状态快照 + 自截图到 /var/mobile/Media/mf-debug）"))


def cmd_install():
    _, d = device()
    print(c("B", "装机"))
    print()
    print(f"  1. 另开一个窗口跑：{c('b','python scripts/dev.py serve')}")
    print(f"     （或直接 {c('b','python scripts/serve_ipa.py')}）")
    print(f"  2. iPad Safari 打开提示的地址")
    print(f"  3. 下 {c('B','★最新版-查找')}.ipa")
    print(f"  4. TrollStore 安装")
    print()
    print(c("d", f"  当前设备：{d.get('DeviceName')} / iPadOS {d.get('ProductVersion')}"))


def cmd_serve():
    s = os.path.join(HERE, "serve_ipa.py")
    if not os.path.exists(s):
        die("找不到 scripts/serve_ipa.py")
    subprocess.run([sys.executable, s])


# ── 入口 ────────────────────────────────────────────────────────────
CMDS = {
    "status": cmd_status,
    "pull":   cmd_pull,
    "shot":   cmd_shot,
    "crash":  cmd_crash,
    "watch":  cmd_watch,
    "export": cmd_export,
    "install": cmd_install,
    "serve":  cmd_serve,
}


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd = args[0]
    if cmd == "log":
        if len(args) < 2:
            die("用法：dev.py log kfd|hud")
        cmd_log(args[1])
        return
    fn = CMDS.get(cmd)
    if not fn:
        die(f"未知命令 {cmd}\n可用：{', '.join(CMDS)} log")
    fn()


if __name__ == "__main__":
    main()
