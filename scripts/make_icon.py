#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成「查找」风格 App 图标（白底 + 绿→蓝对角渐变雷达脉冲）

设计：iOS Find My 图标的可辨识要素 = 白色背景 + 绿蓝渐变 + 同心脉冲环
产出：Assets.xcassets/AppIcon.appiconset/ 下全部尺寸 + 1024 主图

用法：
    python scripts/make_icon.py
"""
import os
import numpy as np
from PIL import Image

# ---------- 配置 ----------
MASTER = 1024                      # 主图边长
OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "app", "Resources", "Assets.xcassets", "AppIcon.appiconset",
)

BG = (255, 255, 255)               # 白底
GRAD_A = (52, 199, 89)             # 绿 #34C759（左上）
GRAD_B = (10, 132, 255)            # 蓝 #0A84FF（右下）

R_OUTER = 0.415                    # 最外环半径 / 画布边长
AA = 1.6                           # 抗锯齿羽化宽度（主图像素）

# 同心脉冲：中心点 + 两道环（在 40px 小图上仍可辨识）
DOT_R = 0.215                      # 中心点半径（相对 R_OUTER）
RINGS = [(0.360, 0.545), (0.690, 0.930)]

# 需要导出的尺寸（文件名 → 像素）
SIZES = {
    "ipad-20@1x.png": 20,
    "ipad-20@2x.png": 40,
    "ipad-29@1x.png": 29,
    "ipad-29@2x.png": 58,
    "ipad-40@1x.png": 40,
    "ipad-40@2x.png": 80,
    "ipad-76@1x.png": 76,
    "ipad-76@2x.png": 152,
    "ipad-83.5@2x.png": 167,
    "iphone-20@2x.png": 40,
    "iphone-20@3x.png": 60,
    "iphone-29@2x.png": 58,
    "iphone-29@3x.png": 87,
    "iphone-40@2x.png": 80,
    "iphone-40@3x.png": 120,
    "iphone-60@2x.png": 120,
    "iphone-60@3x.png": 180,
    "AppIcon-1024.png": 1024,
}


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def build_master():
    n = MASTER
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float64)

    cx = cy = (n - 1) / 2.0
    dx = xx - cx
    dy = yy - cy
    r = np.sqrt(dx * dx + dy * dy)
    R = R_OUTER * n

    # ---- 形状掩码 ----
    rn = r / R
    mask = 1.0 - smoothstep(DOT_R - AA / R, DOT_R + AA / R, rn)     # 中心点
    for rin, rout in RINGS:
        inner = smoothstep(rin - AA / R, rin + AA / R, rn)
        outer = 1.0 - smoothstep(rout - AA / R, rout + AA / R, rn)
        mask = np.maximum(mask, inner * outer)
    mask = np.clip(mask, 0.0, 1.0)

    # ---- 对角渐变（左上 → 右下）----
    diag = (dx + dy) / (2.0 * R) + 0.5
    t = np.clip(diag, 0.0, 1.0)[..., None]

    a = np.array(GRAD_A, dtype=np.float64)
    b = np.array(GRAD_B, dtype=np.float64)
    grad = a * (1.0 - t) + b * t

    # ---- 合成 ----
    bg = np.array(BG, dtype=np.float64)
    m = mask[..., None]
    out = bg * (1.0 - m) + grad * m

    return Image.fromarray(out.round().astype(np.uint8), "RGB")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    master = build_master()
    master.save(os.path.join(OUT_DIR, "_master-1024.png"))

    for name, px in sorted(SIZES.items(), key=lambda kv: kv[1]):
        img = master if px == MASTER else master.resize((px, px), Image.LANCZOS)
        img.save(os.path.join(OUT_DIR, name), optimize=True)
        print(f"  {name:24s} {px:>4}px")

    print(f"\n完成 → {OUT_DIR}")


if __name__ == "__main__":
    main()
