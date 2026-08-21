# -*- coding: utf-8 -*-
import pandas as pd
path = r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v1.xlsx"
df = pd.read_excel(path, sheet_name="功能设计总表")
gap = pd.read_excel(path, sheet_name="无平台参考项")
lines = [f"total {len(df)}", f"gap {len(gap)}"]
if len(gap):
    lines.append(gap.to_string())
lines.append("\n--- sample no match rows ---")
for _, r in df[df["平台覆盖数"]<=1].head(5).iterrows():
    lines.append(f"{r['L1']}/{r['L4']}: 招行={r['招行对应'][:30] if r['招行对应'] else '空'}")
lines.append("\n--- full gap cover=0 ---")
for _, r in df[df["平台覆盖数"]==0].iterrows():
    lines.append(f"{r['L1']}/{r['L4']}")
with open(r"d:\hamisoft\hami-vnpu-core\scripts\matrix_check.txt","w",encoding="utf-8") as f:
    f.write("\n".join(lines))
