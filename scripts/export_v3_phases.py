# -*- coding: utf-8 -*-
import pandas as pd
from pathlib import Path
p = Path(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v3.xlsx")
df = pd.read_excel(p, sheet_name=0)
for c in ["L1","L2","L3"]: df[c] = df[c].ffill()
lines = []
for ph in ["阶段1","阶段2","阶段3"]:
    sub = df[df["阶段"]==ph]
    lines.append(f"\n{ph} ({len(sub)}项, {sub['总工作量(人月)'].sum():.1f}人月)")
    for l1, g in sub.groupby("L1", sort=False):
        l4s = "、".join(g["L4"].tolist())
        lines.append(f"  {l1}: {l4s}")
Path(r"d:\hamisoft\hami-vnpu-core\scripts\phase_v3_detail.txt").write_text("\n".join(lines), encoding="utf-8")
