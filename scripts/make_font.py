#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
中文子集化 — 给 ImGui 准备体积可控的字体。

字符集来源（并集）：
  1. 项目全部源码（.mm/.h/.c/.cpp）里的每一个字符
  2. 项目全部文档（.md/.txt/.json/.plist）里的每一个字符
  3. 基础集：ASCII 可打印 + 常用中英标点 + 全角符号 + 常用符号/箭头/圆圈数字

为什么从"项目里现有文本"抽：ImGui 1.93 是动态字体，缺字形会画成豆腐块。
只要 UI 文案是从这些文件里来的，就不会缺字。
向 UI 加新文案后，重新跑一遍本脚本即可。

用法：
    python scripts/make_font.py
输出：
    app/Resources/fonts/NotoSansSC-subset.ttf
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_DIR = os.path.join(ROOT, "app", "Resources", "fonts")
SRC_FONT = os.path.join(FONT_DIR, "NotoSansSC-Regular.otf")
OUT_FONT = os.path.join(FONT_DIR, "NotoSansSC-subset.ttf")

SCAN_EXTS = (".mm", ".m", ".h", ".c", ".cpp", ".hpp",
             ".md", ".txt", ".json", ".plist", ".yml", ".yaml", ".py", ".sh")
SKIP_DIRS = {"imgui", "kfd", "kfund", ".git", "build", "dist", "__pycache__"}

# ★ 计划内的全部 UI 文案（含尚未写进代码的 M2/M3/M4 菜单）
#   一次吃进来，避免以后加文案时缺字变豆腐块
UI_TEXT = """
主功能 外观 其他 总开关 启用 人机显示 名字 头甲 射线 队伍 手持 距离 血量
物资 盒子 物资名字 物资统计窗口 物资等级 物资价值 显示等级价值大于等于阈值的
盒子绘制距离 物资绘制距离 骨骼绘制距离 米
背敌 背敌半径 背敌绘制颜色 背敌样式 背敌提示
人物距离字号 盒子字号 信息字号 头甲字号 骨骼粗细 人物信息颜色
物资颜色 队伍颜色 头甲颜色 真人骨骼颜色 骨骼连接 骨骼矩阵
观战模式 直播模式 头甲英雄交换 刷新率 血条样式 骨骼 平滑度
高级设置 清理系统残留 环境检测 防封设置 内核选择 极速卸载巨魔 极速安装巨魔 取消
选择版本 国服 国际服 台服 启动内核 修复无效 防追封设置 内核设置 启动悬浮窗 停止悬浮窗
执行成功 修复完成 已复制 已保存
自动 纯巨魔模式 漏洞方法 页数 重试 失败 成功 错误 未知 正在 完成
扫描 删除 选中 保护 跳过 规则 目录 条 项目 条规则 黑名单 白名单 默认规则
权限 已开启 已关闭 高级游戏模式已经开启 高级游戏模式已经关闭
文件 不存在 读取 写入 备份 恢复 重置 应用 生效 重启
标识符 广告标识 供应商标识 统一值 生成 替换
钥匙串 清理 条目 命中 合计
进程 模块 基址 偏移 相机 实体 坐标 投影 屏幕 世界 角度 视场
目标 内存 读取 内核 提权 端口 枚举 缓存 门条件 就绪 未就绪
日志 诊断 自检 状态 构建 版本 身份 伪装 里程碑 运行
清理系统残留 清理 Key 高级游戏模式 防封设置 内核设置
扫描完成 未发现符合规则的残留条目 没有可清理项 删除选中项 重新扫描 全不选 全选
确认删除 不可撤销 其中包含本应用之外的系统目录条目
规则来源 默认规则 目录 文件 大小
统计结果 关闭 好 确定 确认 取消
白米饭 复刻版 控制台 悬浮窗 绘制层 菜单
"""


def base_charset() -> str:
    """基础集：ASCII + 常用标点 + 全角 + 已验证字体里存在的符号"""
    chars = set()

    # ASCII 可打印
    for c in range(0x20, 0x7F):
        chars.add(chr(c))

    # Latin-1 补充
    chars.update("°±×÷·—–…‘’“”")

    # CJK 标点
    chars.update("　、。〈〉《》「」『』【】〔〕〖〗！？，．：；（）［］｛｝％＋－＝／＊＆＾～｜＼")

    # 全角字母数字
    for c in range(0xFF01, 0xFF5F):
        chars.add(chr(c))

    # ★ 已实测确认存在的符号（✗ ✔ ✘ 不在 Noto Sans SC 里，别用）
    chars.update("✓×●○◆◇■□▲▼◀▶→←↑↓★☆§…⚠≤≥±≈")

    # 圆圈数字 / 罗马
    chars.update("①②③④⑤⑥⑦⑧⑨⑩ⅠⅡⅢⅣⅤ")

    return "".join(chars)



def collect_from_project() -> set:
    out = set()
    nfiles = 0
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(SCAN_EXTS):
                continue
            p = os.path.join(dirpath, fn)
            try:
                with open(p, encoding="utf-8", errors="ignore") as f:
                    txt = f.read()
            except Exception:
                continue
            nfiles += 1
            out.update(txt)
    print(f"  扫描 {nfiles} 个文件")
    return out


def main():
    if not os.path.exists(SRC_FONT):
        print(f"✗ 找不到源字体: {SRC_FONT}")
        print("  先下载 NotoSansSC-Regular.otf 到该目录")
        return 1

    print("收集字符集…")
    chars = collect_from_project()
    chars.update(base_charset())
    chars.update(UI_TEXT)          # ★ 计划内文案，一次吃进来
    print(f"  UI_TEXT 预置文案 {len(set(UI_TEXT))} 字")

    # 去掉控制字符与代理区
    chars = {c for c in chars if ord(c) >= 0x20 and not (0xD800 <= ord(c) <= 0xDFFF)}
    text = "".join(sorted(chars))
    print(f"  合计 {len(chars)} 个唯一字符")

    cjk = sum(1 for c in chars if 0x4E00 <= ord(c) <= 0x9FFF)
    print(f"  其中汉字 {cjk} 个")

    chars_file = os.path.join(FONT_DIR, "_charset.txt")
    with open(chars_file, "w", encoding="utf-8") as f:
        f.write(text)

    print("子集化…")
    cmd = [
        sys.executable, "-m", "fontTools.subset",
        SRC_FONT,
        f"--text-file={chars_file}",
        f"--output-file={OUT_FONT}",
        "--layout-features=",          # 去掉 OpenType 特性，HUD 用不到
        "--no-hinting",
        "--desubroutinize",            # CFF 去子程序化，规避 stb_truetype 解析差异
        "--drop-tables+=DSIG",
        "--name-IDs=*",
        "--recalc-bounds",
        "--flavor=",                   # 不压缩，直接给 ImGui 读
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("✗ 子集化失败：")
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        return 1

    src_mb = os.path.getsize(SRC_FONT) / 1024 / 1024
    dst_mb = os.path.getsize(OUT_FONT) / 1024 / 1024
    print(f"\n✅ 完成")
    print(f"   源字体  : {src_mb:.2f} MB")
    print(f"   子集字体: {dst_mb:.2f} MB  （压缩到 {dst_mb/src_mb*100:.1f}%）")
    print(f"   输出    : {OUT_FONT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
