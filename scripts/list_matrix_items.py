# -*- coding: utf-8 -*-
from pathlib import Path
import pandas as pd
path = r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v2.xlsx"
df = pd.read_excel(path, sheet_name=0)
for c in ["L1","L2","L3"]: df[c] = df[c].ffill()
lines = []
for _, r in df.iterrows():
    lines.append(f"{r['L1']}|{r['L2']}|{r['L4']}|{r.get('阶段','')}")
Path(r"d:\hamisoft\hami-vnpu-core\scripts\matrix_items.txt").write_text("\n".join(lines), encoding="utf-8")
print(len(df))
