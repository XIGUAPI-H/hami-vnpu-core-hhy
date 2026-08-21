# -*- coding: utf-8 -*-
import pandas as pd
from collections import Counter

path = r"C:\Users\d00804096\Desktop\功能项分析2026_招行完整版_v5.xlsx"
work = pd.read_excel(path, sheet_name="招行完整版")

def norm(x):
    return "" if pd.isna(x) else str(x).strip()

def phase_items(p):
    sub = work[work["阶段"] == f"阶段{p}"].copy()
    keys = set((norm(r["L1"]), norm(r["L2"]), norm(r["L4"])) for _, r in sub.iterrows())
    return sub, keys

s1, k1 = phase_items(1)
s2, k2 = phase_items(2)
s3, k3 = phase_items(3)

only2 = k2 - k1
only3 = k3 - k2

lines = []
lines.append(f"阶段2独有 (相对阶段1): {len(only2)} 项")
for l1, l2, l4 in sorted(only2)[:25]:
    lines.append(f"  [{l1}/{l2}] {l4}")
if len(only2) > 25:
    lines.append(f"  ... 还有 {len(only2)-25} 项")

lines.append(f"\n阶段3独有 (相对阶段2): {len(only3)} 项")
for l1, l2, l4 in sorted(only3)[:25]:
    lines.append(f"  [{l1}/{l2}] {l4}")
if len(only3) > 25:
    lines.append(f"  ... 还有 {len(only3)-25} 项")

lines.append("\n=== 阶段2 L1分布 ===")
for k, v in Counter(s2["L1"]).most_common():
    lines.append(f"  {k}: {v}")

lines.append("\n=== 阶段3 L1分布 ===")
for k, v in Counter(s3["L1"]).most_common():
    lines.append(f"  {k}: {v}")

lines.append("\n=== 阶段3 代表性 L4 ===")
for _, r in s3.iterrows():
    lines.append(f"  [{r['L1']}/{r['L2']}] {r['L4']}")

with open(r"d:\hamisoft\hami-vnpu-core\scripts\phase_diff.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
