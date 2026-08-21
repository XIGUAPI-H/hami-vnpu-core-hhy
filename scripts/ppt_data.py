# -*- coding: utf-8 -*-
import pandas as pd
from pathlib import Path
p = Path(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx")
df = pd.read_excel(p, sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

print("total", len(df), "work", df["总工作量(人月)"].sum())
for ph in ["阶段1","阶段2","阶段3"]:
    sub=df[df["阶段"]==ph]
    print(ph, len(sub), sub["总工作量(人月)"].sum())

print("\nL1 breakdown all:")
for l1,g in df.groupby("L1"):
    print(l1, len(g), round(g["总工作量(人月)"].sum(),1))

# map to PPT modules
# 指标监控 -> 指标监控 L1
# 工具链 -> 模型训练+模型推理+资产管理 部分?
# 调度 -> 算力调度
# 权限管控 -> 权限管理

# PPT V1 table modules - need to classify by user's slide logic
# From slide: 指标监控8, 工具链15, 调度15, 权限4 = 42? but total 91

# Let's count by L1 for stages
print("\n=== Stage1 L1 ===")
for l1,g in df[df["阶段"]=="阶段1"].groupby("L1"):
    print(l1, len(g))

print("\n=== Stage2 L1 ===")
for l1,g in df[df["阶段"]=="阶段2"].groupby("L1"):
    print(l1, len(g))

# platform coverage - count items with 招行对应 non-empty
for plat in ["招行对应","MA对应","MM对应","openfuyao对应","MindCluster对应"]:
    if plat in df.columns:
        n = df[plat].fillna("").astype(str).str.strip().ne("").sum()
        print(plat, n)

# sample L4 per L1 for main functions text
for l1 in df["L1"].unique():
    sub=df[df["L1"]==l1]
    l4s = sub["L4"].head(8).tolist()
    print(f"\n{l1} examples:", "、".join(l4s[:6]))
