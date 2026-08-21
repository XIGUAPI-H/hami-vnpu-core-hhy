# -*- coding: utf-8 -*-
import pandas as pd
from collections import Counter

path = r"C:\Users\d00804096\Desktop\功能项分析2026_招行完整版_v5.xlsx"
out = r"d:\hamisoft\hami-vnpu-core\scripts\phase_out.txt"
lines = []

df = pd.read_excel(path, sheet_name="阶段汇总")
for _, r in df.iterrows():
    lines.append("=" * 60)
    lines.append(str(r["阶段"]))
    lines.append(str(r["阶段目标（分析生成）"]))
    lines.append(f"主要L1: {r['主要L1域']}")
    lines.append(f"主要L2: {r['主要L2模块']}")
    lines.append(
        f"功能点: {r['功能点数']} | 招行: {r['招行基线']} | 补充: {r['差异补充']} | "
        f"总工作量: {r['总工作量(人月)']}人月 | 完成: {r['预计完成']}"
    )

work = pd.read_excel(path, sheet_name="招行完整版")
for p in [1, 2, 3]:
    sub = work[work["阶段"] == f"阶段{p}"]
    lines.append(f"\n=== 阶段{p} L2 Top10 ===")
    for k, v in Counter(sub["L2"].dropna()).most_common(10):
        lines.append(f"  {k}: {v}")

with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
