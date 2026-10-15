# -*- coding: utf-8 -*-
"""临时校验脚本：比对复刻版 cleanup_rules.plist 与逆向解出的原始 plist。
只读，不修改任何文件。"""
import plistlib, os, json, re, hashlib

REP = r"C:\Users\xiaoping\Desktop\白米饭复刻\app\Resources\cleanup_rules.plist"
ORI = r"C:\Users\xiaoping\Desktop\codex 项目\analysis\baimifan-20261013\evidence\followup-cleanup-config.plist"

def load(p):
    with open(p, "rb") as f:
        raw = f.read()
    return plistlib.loads(raw), raw

r, rraw = load(REP)
o, oraw = load(ORI)
print("sha256 replica :", hashlib.sha256(rraw).hexdigest())
print("sha256 original:", hashlib.sha256(oraw).hexdigest())
print("bytes equal    :", rraw == oraw)
print("dirs replica=%d original=%d" % (len(r), len(o)))
print("keys only in replica :", sorted(set(r) - set(o)))
print("keys only in original:", sorted(set(o) - set(r)))

def norm(x):
    """把 string/dict 规则归一化成可比较的元组"""
    if isinstance(x, str):
        return ("str", x)
    if isinstance(x, dict):
        return ("dict", x.get("match"), x.get("name"))
    return ("other", repr(x))

bl = wl = 0
problems = []
for k in sorted(set(r) | set(o)):
    a, b = r.get(k), o.get(k)
    if a is None or b is None:
        problems.append("KEY MISSING %s" % k)
        continue
    for field in ("blacklist", "whitelist"):
        la, lb = a.get(field, []), b.get(field, [])
        na, nb = [norm(i) for i in la], [norm(i) for i in lb]
        if field == "blacklist":
            bl += len(na)
        else:
            wl += len(na)
        if na != nb:
            # 找出差异（保序比较 + 集合比较）
            same_set = sorted(map(repr, na)) == sorted(map(repr, nb))
            problems.append("DIFF %s.%s order-sensitive=%s same_set=%s\n  replica :\n    %s\n  original:\n    %s"
                            % (k, field, na == nb, same_set,
                               "\n    ".join(repr(x) for x in na),
                               "\n    ".join(repr(x) for x in nb)))
    da, db = a.get("default"), b.get("default")
    if da != db:
        problems.append("DIFF %s.default replica=%r original=%r" % (k, da, db))

print("blacklist total replica=%d" % bl)
print("whitelist total replica=%d" % wl)
print("default=blacklist dirs :", sum(1 for k in r if r[k].get("default") == "blacklist"))
print("default=whitelist dirs :", sum(1 for k in r if r[k].get("default") == "whitelist"))
print("no default dirs        :", sum(1 for k in r if "default" not in r[k]))
print("---- 差异 ----")
print("\n".join(problems) if problems else "无差异（逐目录逐字段完全一致）")

# 正则能否被 ICU/py 编译（py 近似）
for k in sorted(r):
    for field in ("blacklist", "whitelist"):
        for item in r[k].get(field, []):
            if isinstance(item, dict) and item.get("match") == "regexp":
                try:
                    re.compile(item["name"])
                except re.error as e:
                    print("REGEX FAIL %s.%s %s -> %s" % (k, field, item["name"], e))
