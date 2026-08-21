# -*- coding: utf-8 -*-
import pandas as pd
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()
sub = df[(df["L2"]=="推理服务部署") & (df["L3"]=="多机多卡部署")]
lines = ["多机多卡部署 L3 下 L4:"]
for _, r in sub.iterrows():
    lines.append(f"  {r['L4']}")
lines.append("\n其他 L3 在推理服务部署下:")
other = df[(df["L2"]=="推理服务部署") & (df["L3"]!="多机多卡部署")]
for l3 in other["L3"].unique():
    l4s = other[other["L3"]==l3]["L4"].tolist()
    lines.append(f"  [{l3}] {', '.join(l4s)}")
open(r"d:\hamisoft\hami-vnpu-core\scripts\multicard_layout.txt","w",encoding="utf-8").write("\n".join(lines))
