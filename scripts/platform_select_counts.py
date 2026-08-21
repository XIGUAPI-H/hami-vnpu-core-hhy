# -*- coding: utf-8 -*-
import pandas as pd

orig = pd.read_excel(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx", sheet_name=None)

def count_sheet(df, name):
    # drop fully empty rows
    d = df.dropna(how='all')
    # try find L4 or 功能列
    cols = [c for c in d.columns if 'L4' in str(c) or '功能' in str(c) or '特性' in str(c)]
    n = len(d)
    # subtract header if first row looks like header duplicate
    return n, list(d.columns[:8])

for sn in ['招行', '极算', 'MA', 'MM', 'openfuyao', 'MindCluster']:
    if sn in orig:
        n, cols = count_sheet(orig[sn], sn)
        print(f"orig sheet [{sn}]: {n} rows, cols sample: {cols}")

# v4 matrix mapping
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

print("\n=== v4 matrix total:", len(df))

for col, label in [("招行对应","招行"), ("MA对应","MA"), ("MM对应","MM"), ("openfuyao对应","openfuyao"), ("MindCluster对应","MindCluster")]:
  if col in df.columns:
    mapped = df[df[col].fillna("").astype(str).str.strip()!=""]
    print(f"{label}: 矩阵中选取 {len(mapped)} 项 (有{col}内容)")

# also count by 输入来源 column if exists
if "输入来源" in df.columns:
    print("\n输入来源分布:")
    print(df["输入来源"].value_counts(dropna=False).to_string())

# per-stage platform mapping
for st in ["阶段1","阶段2","阶段3"]:
    sub = df[df["阶段"]==st]
    print(f"\n{st} ({len(sub)}项):")
    for col, label in [("招行对应","招行"), ("MA对应","MA"), ("MM对应","MM")]:
        n = sub[sub[col].fillna("").astype(str).str.strip()!=""].shape[0]
        print(f"  {label}: {n}")

# count unique source items referenced in 招行对应 (might be comma separated)
print("\n招行 sheet detail - non-empty L4 count:")
if '招行' in orig:
    d = orig['招行'].dropna(how='all')
  # count rows with L4 filled
    l4cols = [c for c in d.columns if 'L4' in str(c)]
    if l4cols:
        filled = d[d[l4cols[0]].notna() & (d[l4cols[0]].astype(str).str.strip()!='')]
        print(f"  L4 filled rows: {len(filled)}")
    print(f"  total data rows (excl header): {len(d)-1 if len(d)>0 else 0}")
