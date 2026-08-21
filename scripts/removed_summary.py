# -*- coding: utf-8 -*-
import pandas as pd
path = r"C:\Users\d00804096\Desktop\功能项分析2026_招行完整版_v6.xlsx"
rm = pd.read_excel(path, sheet_name="已剔除重复项")
lines = [f"共剔除 {len(rm)} 项\n"]
for src, g in rm.groupby("输入来源"):
    lines.append(f"\n{src}: {len(g)} 项")
    for _, r in g.iterrows():
        lines.append(f"  - {r['L4']} ({r['剔除原因']})")
with open(r"d:\hamisoft\hami-vnpu-core\scripts\removed_summary.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
