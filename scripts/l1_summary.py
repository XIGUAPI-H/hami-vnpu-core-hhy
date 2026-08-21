# -*- coding: utf-8 -*-
import pandas as pd
import json

path = r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx"
# fallback v2
import os
if not os.path.exists(path):
    path = r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v2.xlsx"

df = pd.read_excel(path, sheet_name=0)
for c in ["L1","L2","L3"]: 
    if c in df.columns:
        df[c]=df[c].ffill()

l1_order = ["模型推理","模型训练","资产管理","算力调度","权限管理","指标监控","运维"]
result = []
for l1 in l1_order:
    sub = df[df["L1"]==l1]
    if len(sub)==0:
        continue
    work = round(sub["总工作量(人月)"].sum(), 1) if "总工作量(人月)" in sub.columns else 0
    funcs = sub["L4"].tolist()
    result.append({
        "L1": l1,
        "n": len(sub),
        "work": work,
        "funcs": funcs,
        "stage1": len(sub[sub["阶段"]=="阶段1"]) if "阶段" in sub.columns else None,
    })

out = {"file": path, "total": len(df), "total_work": round(df["总工作量(人月)"].sum(),1), "l1": result}
with open(r"d:\hamisoft\hami-vnpu-core\scripts\l1_summary.json","w",encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(json.dumps(out, ensure_ascii=False, indent=2))
