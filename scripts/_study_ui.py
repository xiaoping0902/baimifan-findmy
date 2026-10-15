import re, io, os

P = r"C:\Users\xiaoping\Desktop\小玉源码\jni\src\ios_ui.h"
t = io.open(P, encoding="utf-8", errors="replace").read()
print("=" * 70)
print("ios_ui.h  (%d 行)" % t.count("\n"))
print("=" * 70)

# 1) 颜色常量
print("\n---- 颜色 / 调色板 ----")
for m in re.finditer(r'^\s*(?:static\s+)?(?:constexpr\s+)?(?:ImU32|ImVec4|unsigned int|uint32_t|u32)\s+(\w+)\s*=\s*([^;]{1,90});', t, re.M):
    print("   %-28s = %s" % (m.group(1), m.group(2).strip()))

# 2) 结构体里的数值参数（半径 / 间距 / 尺寸）
print("\n---- 尺寸 / 圆角 / 间距 ----")
for m in re.finditer(r'^\s*(?:static\s+)?(?:constexpr\s+)?(?:float|int|f32|i32)\s+(\w*(?:radius|round|pad|spac|gap|width|height|size|margin|indent|h_|_h|w_|_w)\w*)\s*=\s*([^;]{1,60});', t, re.M | re.I):
    print("   %-28s = %s" % (m.group(1), m.group(2).strip()))

# 3) 主题表
print("\n---- 主题相关 ----")
for m in re.finditer(r'(theme\w*|Theme\w*)\s*\[[^\]]*\]\s*=\s*\{', t):
    print("   找到主题数组:", m.group(1))
for m in re.finditer(r'^\s*//\s*主题.*$', t, re.M):
    print("   ", m.group(0).strip()[:100])

# 4) 页签
print("\n---- 导航页 ----")
for m in re.finditer(r'"([\u4e00-\u9fff]{2,6})"\s*,?\s*//?.*?page|page.*?"([\u4e00-\u9fff]{2,6})"', t):
    print("   ", m.group(0)[:80])
for m in re.finditer(r'\{\s*"([\u4e00-\u9fff]{2,4})"\s*,', t):
    print("   页名:", m.group(1))

# 5) 关键函数名，看有哪些 UI 组件
print("\n---- 自绘组件函数 ----")
for m in re.finditer(r'^\s*(?:static\s+)?(?:inline\s+)?(?:bool|void|float|ImVec2|ImRect|int)\s+(\w+)\s*\(', t, re.M):
    n = m.group(1)
    if not n.startswith("Im"):
        print("   ", n)

# 6) 背景色 / 主色（找 ImVec4 或 hex）
print("\n---- 十六进制色值 ----")
hexes = {}
for m in re.finditer(r'ImU32\s*\(\s*(\w+)\s*\)|0x([0-9A-Fa-f]{8})|IM_COL32\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)', t):
    s = m.group(0)
    hexes[s] = hexes.get(s, 0) + 1
for k, v in sorted(hexes.items(), key=lambda x: -x[1])[:25]:
    print("   %-52s x%d" % (k, v))
