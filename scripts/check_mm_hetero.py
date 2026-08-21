# -*- coding: utf-8 -*-
import pandas as pd

# MM sheet
orig = pd.read_excel(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx", sheet_name="MM")
for i in range(4):
    orig.iloc[:, i] = orig.iloc[:, i].ffill()

# search 异构 in MM
mask = orig.astype(str).apply(lambda row: row.str.contains('异构', na=False).any(), axis=1)
print("=== MM sheet rows with 异构 ===")
for _, r in orig[mask].iterrows():
    print(r.iloc[0], r.iloc[1], r.iloc[2], r.iloc[3])

# v4 matrix 异构 + MM对应
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

het = df[df["L4"].astype(str).str.contains("异构", na=False) | df["功能描述"].astype(str).str.contains("异构", na=False)]
print("\n=== v4 matrix 异构相关 ===")
for _, r in het.iterrows():
    mm = r.get("MM对应", "")
    ma = r.get("MA对应", "")
    print(f"L4={r['L4']} | MM={mm} | MA={ma}")
    print(f"  desc={str(r.get('功能描述',''))[:80]}")

# all MM对应 items under 算力调度
sched = df[df["L1"]=="算力调度"]
print("\n=== 算力调度 MM对应 ===")
for _, r in sched.iterrows():
    mm = str(r.get("MM对应","")).strip()
    if mm:
        print(f"{r['L4']}: {mm}")
