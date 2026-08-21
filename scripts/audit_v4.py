# -*- coding: utf-8 -*-
import pandas as pd
import sys
sys.stdout.reconfigure(encoding='utf-8')

df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

print("=== Current totals ===")
print("items:", len(df))
print("work:", round(df["总工作量(人月)"].sum(),1))
for st in ["阶段1","阶段2","阶段3"]:
    sub=df[df["阶段"]==st]
    print(f"{st}: {len(sub)} items, {round(sub['总工作量(人月)'].sum(),1)} PM")

print("\n=== L1 counts ===")
for l1, g in df.groupby("L1", sort=False):
    print(f"{l1}: {len(g)} ({round(g['总工作量(人月)'].sum(),1)} PM)")

print("\n=== All rows ===")
for i,r in df.iterrows():
    print(f"{i+2}|{r['阶段']}|{r['L1']}|{r['L4']}|{r['总工作量(人月)']}")
