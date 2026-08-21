# -*- coding: utf-8 -*-
import pandas as pd
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()
s1 = df[df["阶段"]=="阶段1"]
print("stage1 招行有对应:", s1[s1["招行对应"].fillna("").astype(str).str.strip()!=""].shape[0])
print("stage1 total:", len(s1))

# V1 module mapping for PPT right table (full 99 items)
sched = df[df["L1"]=="算力调度"]
mon = df[df["L1"]=="指标监控"]
perm = df[df["L1"]=="权限管理"]
tool = df[df["L1"].isin(["模型推理","模型训练","资产管理"])]
ops = df[df["L1"]=="运维"]

print(f"调度 {len(sched)} {sched['总工作量(人月)'].sum():.0f}")
print(f"指标监控 {len(mon)} {mon['总工作量(人月)'].sum():.0f}")
print(f"权限 {len(perm)} {perm['总工作量(人月)'].sum():.0f}")
print(f"工具链(推训资) {len(tool)} {tool['总工作量(人月)'].sum():.0f}")
print(f"运维 {len(ops)} {ops['总工作量(人月)'].sum():.0f}")

# V1 = phase1 only workload as "轻量版投入"
print("V1 phase1 only:", s1["总工作量(人月)"].sum())

# module split phase1
for name, sub in [
    ("指标监控", s1[s1["L1"]=="指标监控"]),
    ("权限", s1[s1["L1"]=="权限管理"]),
    ("工具链", s1[s1["L1"].isin(["模型推理","模型训练","资产管理"])]),
]:
    print(name, len(sub), round(sub["总工作量(人月)"].sum(),1))
