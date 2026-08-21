# -*- coding: utf-8 -*-
import pandas as pd
import sys
sys.stdout.reconfigure(encoding='utf-8')
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

# all L4 lists
for l1 in ["算力调度","指标监控","权限管理"]:
    items=df[df["L1"]==l1]["L4"].tolist()
    print(l1, len(items), "、".join(str(x) for x in items))

tool=df[df["L1"].isin(["模型推理","模型训练","资产管理"])]
print("工具链", len(tool), "、".join(tool["L4"].tolist()[:12])+"...")

# stage narratives - list L4 by stage
for st in ["阶段1","阶段2","阶段3"]:
    sub=df[df["阶段"]==st]
    print(f"\n{st} {len(sub)}项 {sub['总工作量(人月)'].sum():.1f}人月")
    for l1 in sub["L1"].unique():
        n=len(sub[sub["L1"]==l1])
        print(f"  {l1}: {n}")

# original platform totals from 功能项分析
try:
    orig = pd.read_excel(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx", sheet_name=None)
    for sn in orig:
        if sn in ["招行","MA","MM","极算"]:
            print(f"sheet {sn} rows:", len(orig[sn]))
except Exception as e:
    print("orig err", e)
