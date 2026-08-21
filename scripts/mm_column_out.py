# -*- coding: utf-8 -*-
import pandas as pd
import sys
sys.stdout.reconfigure(encoding='utf-8')

df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

l1_order = ["模型推理","模型训练","资产管理","算力调度","权限管理","指标监控","运维"]

for l1 in l1_order:
    sub = df[df["L1"]==l1]
    mapped = sub[sub["MM对应"].fillna("").astype(str).str.strip()!=""]
    total = len(sub)
    n = len(mapped)
    print(f"\n【{l1}】从{total}项中选取{n}项")
    for _, r in mapped.iterrows():
        mm = str(r["MM对应"]).strip()
        # fix 异构 - user confirmed MM has no hetero
        if r["L4"] == "异构算力适配":
            continue
        print(f"  ✔ {r['L4']}  ← {mm}")

# count corrected
mm_items = []
for _, r in df.iterrows():
    if r["L4"] == "异构算力适配":
        continue
    mm = str(r.get("MM对应","")).strip()
    if mm and mm != "nan":
        mm_items.append((r["L1"], r["L4"], mm))
print(f"\n=== MM列合计（已剔除异构算力适配）: {len(mm_items)} 项 ===")
