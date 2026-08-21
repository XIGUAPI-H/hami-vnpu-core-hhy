# -*- coding: utf-8 -*-
import pandas as pd
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()
sub = df[df["L4"].astype(str).str.contains("PD|Prefill|Decode|KVCache|AIBrix|OME SGLang", regex=True, na=False)]
lines = []
for _, r in sub.iterrows():
    lines.append(f"{r['L1']} | {r['L2']} | {r['L3']} | {r['L4']}")
open(r"d:\hamisoft\hami-vnpu-core\scripts\pd_l4_fixed.txt","w",encoding="utf-8").write("\n".join(lines))
