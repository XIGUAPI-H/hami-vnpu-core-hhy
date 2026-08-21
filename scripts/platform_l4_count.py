# -*- coding: utf-8 -*-
import pandas as pd

orig = pd.read_excel(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx", sheet_name=None)

def count_l4_items(df):
    """Count leaf function items in platform sheet (L1-L4 hierarchy)."""
    d = df.copy()
    # forward fill hierarchy cols (usually cols 0-3 are L1-L4)
    for i in range(min(4, len(d.columns))):
        d.iloc[:, i] = d.iloc[:, i].ffill()
    # L4 is typically col index 3
    l4 = d.iloc[:, 3]
    # drop header row if L4 equals 'L4' or '功能项'
    mask = l4.notna() & (~l4.astype(str).str.strip().isin(['L4', '功能项', 'nan', '']))
    # also require some description
    items = d[mask]
    return len(items), items.iloc[:, 3].tolist()[:3]

for sn in ['招行', 'MA', 'MM']:
    if sn in orig:
        n, samples = count_l4_items(orig[sn])
        print(f"{sn}: L4功能点 {n} 个, 样例: {samples}")

# v4 - count by 输入来源 if exists
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
if '输入来源' in df.columns:
    print("\n按输入来源(主来源):")
    print(df['输入来源'].value_counts().to_string())

# count primary source - first platform in 招行/MA/MM columns
for col, label, total in [('招行对应','招行极算',147), ('MA对应','MA',238), ('MM对应','MM',99)]:
    n = df[df[col].fillna('').astype(str).str.strip()!=''].shape[0]
    print(f"{label}: {total}项 -> 本方案选取 {n} 项")

# stage1 only
s1 = df[df['阶段']=='阶段1']
print("\n阶段1轻量化:")
for col, label, total in [('招行对应','招行极算',147), ('MA对应','MA',238), ('MM对应','MM',99)]:
    n = s1[s1[col].fillna('').astype(str).str.strip()!=''].shape[0]
    print(f"  {label}: {total}项 -> 选取 {n} 项")
