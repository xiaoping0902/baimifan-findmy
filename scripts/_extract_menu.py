import re, io, os, sys

ROOT = r"C:\Users\xiaoping\Desktop\白米饭复刻"
p = os.path.join(ROOT, "app/Sources/HUD/MFMenuUI.mm")
t = io.open(p, encoding="utf-8").read()

print("===== HUD 菜单里所有含中文的字面量（按出现顺序）=====")
seen = []
for m in re.finditer(r'"([^"\n]{1,60})"', t):
    s = m.group(1)
    if re.search(r"[\u4e00-\u9fff]", s) and s not in seen:
        seen.append(s)
for s in seen:
    print("   " + s)

print()
print("===== 缩进结构（看哪些是分页/分组）=====")
for i, line in enumerate(t.split("\n"), 1):
    if re.search(r"TabItem|BeginTab|BeginChild|SeparatorText|CollapsingHeader|TreeNode", line):
        print("   %4d | %s" % (i, line.strip()[:110]))
