# -*- coding: utf-8 -*-
import pandas as pd
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

def cnt(col):
    return df[df[col].fillna("").astype(str).str.strip()!=""].shape[0]

for col in ["招行对应","MA对应","MM对应","openfuyao对应","MindCluster对应"]:
    print(col, cnt(col))

s1=df[df["阶段"]=="阶段1"]
for col in ["招行对应","MA对应","MM对应"]:
    n=s1[s1[col].fillna("").astype(str).str.strip()!=""].shape[0]
    print("stage1", col, n)

# sample L4 names per module for PPT
for l1 in ["算力调度","指标监控","权限管理"]:
    items=df[df["L1"]==l1]["L4"].tolist()[:6]
    print(l1, "->", "、".join(str(x) for x in items))

tool=df[df["L1"].isin(["模型推理","模型训练","资产管理"])]
print("工具链 samples:", "、".join(tool["L4"].head(8).tolist()))
