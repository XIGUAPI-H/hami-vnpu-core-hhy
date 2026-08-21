# -*- coding: utf-8 -*-
import pandas as pd
import re
from pathlib import Path

INPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx")
OUT = Path(r"d:\hamisoft\hami-vnpu-core\scripts\dup_analysis2.txt")

def norm(s):
    s = str(s).strip().lower()
    return re.sub(r"\s+", "", s)

def load(sheet):
    df = pd.read_excel(INPUT, sheet_name=sheet, header=1)
    cols = list(df.columns)
    rename = {cols[0]: "L1", cols[1]: "L2", cols[2]: "L3", cols[3]: "L4"}
    if len(cols) > 4:
        rename[cols[4]] = "功能描述"
    df = df.rename(columns=rename)
    for c in ["L1", "L2", "L3"]:
        if c in df.columns:
            df[c] = df[c].ffill()
    return df[df["L4"].notna()].copy()

xl = pd.ExcelFile(INPUT)
match = pd.read_excel(INPUT, sheet_name=xl.sheet_names[0], header=1)
match_cols = list(match.columns)
lines = [f"match columns: {match_cols}"]

# 招行 L4 sets
cmb = load("招行")
cmb_l4 = {norm(r["L4"]) for _, r in cmb.iterrows()}
cmb_l4_raw = {str(r["L4"]).strip() for _, r in cmb.iterrows()}

# openfuyao L4 dups detail
of = load("openfuyao")
dups = []
for _, r in of.iterrows():
    l4 = str(r["L4"]).strip()
    if norm(l4) in cmb_l4:
        dups.append(l4)
lines.append(f"\nopenfuyao L4 dups vs 招行 ({len(dups)}):")
for d in sorted(set(dups)):
    lines.append(f"  - {d}")

# cross supplement L4 overlap with cmb using broader: L4 substring?
lines.append("\n--- fuzzy: supplement L4 contained in cmb L4 or vice versa ---")
for sheet in ["MM", "MA", "openfuyao", "MindCluster"]:
    df = load(sheet)
    fuzzy = 0
    for _, r in df.iterrows():
        l4 = norm(r["L4"])
        if l4 in cmb_l4:
            fuzzy += 1
            continue
        for cl in cmb_l4:
            if len(l4) >= 4 and (l4 in cl or cl in l4):
                fuzzy += 1
                break
    lines.append(f"{sheet}: fuzzy overlap {fuzzy}/{len(df)}")

# count match sheet 匹配 rows
if len(match_cols) >= 8:
    for col in match_cols[5:]:
        m = match[match[col].astype(str).str.contains("匹配", na=False) & ~match[col].astype(str).str.contains("不匹配", na=False)]
        lines.append(f"\n招行 rows where {col}=匹配: {len(m)}")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
