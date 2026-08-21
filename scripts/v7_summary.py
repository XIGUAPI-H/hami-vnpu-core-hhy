# -*- coding: utf-8 -*-
import pandas as pd
path = r"C:\Users\d00804096\Desktop\功能项分析2026_招行完整版_v7.xlsx"
dim = pd.read_excel(path, sheet_name="三维度汇总")
summary = pd.read_excel(path, sheet_name="三维度补充明细")
lines = ["=== 三维度汇总 ===", dim.to_string(index=False), ""]
for l1 in ["权限管理", "指标监控", "运维"]:
    sub = summary[summary["L1"] == l1]
    lines.append(f"\n=== {l1} 示例 (L2分布) ===")
    for l2, g in sub.groupby("L2"):
        lines.append(f"  [{l2}] {len(g)}项, 例: {g.iloc[0]['L4']}")
with open(r"d:\hamisoft\hami-vnpu-core\scripts\v7_summary.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
