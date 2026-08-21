# -*- coding: utf-8 -*-
import pandas as pd
from pathlib import Path

INPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx")
OUT = Path(r"d:\hamisoft\hami-vnpu-core\scripts\dup_analysis.txt")

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
    df = df[df["L4"].notna()].copy()
    return df

def norm(s):
    import re
    s = str(s).strip().lower()
    s = re.sub(r"\s+", "", s)
    return s

cmb = load("招行")
cmb_full = set("|".join(str(r[c]).strip() for c in ["L1","L2","L3","L4"]) for _, r in cmb.iterrows())
cmb_l4 = set(norm(r["L4"]) for _, r in cmb.iterrows())
cmb_l4_raw = set(str(r["L4"]).strip() for _, r in cmb.iterrows())

lines = [f"招行: {len(cmb)} items"]

for sheet in ["MM", "MA", "openfuyao", "MindCluster"]:
    df = load(sheet)
    full_dup = 0
    l4_dup = 0
    l4_raw_dup = 0
    examples_full = []
    examples_l4 = []
    for _, r in df.iterrows():
        k = "|".join(str(r[c]).strip() for c in ["L1","L2","L3","L4"])
        l4n = norm(r["L4"])
        l4r = str(r["L4"]).strip()
        if k in cmb_full:
            full_dup += 1
            if len(examples_full) < 5:
                examples_full.append(l4r)
        if l4n in cmb_l4:
            l4_dup += 1
            if len(examples_l4) < 5:
                examples_l4.append(l4r)
        if l4r in cmb_l4_raw:
            l4_raw_dup += 1
    unique_full = len(df) - full_dup
    unique_l4 = len(df) - l4_dup
    lines.append(f"\n{sheet}: total={len(df)}")
    lines.append(f"  exact L1|L2|L3|L4 dup: {full_dup}, unique: {unique_full}")
    lines.append(f"  L4 normalized dup: {l4_dup}, unique: {unique_l4}")
    lines.append(f"  L4 raw dup: {l4_raw_dup}")
    if examples_full:
        lines.append(f"  full dup examples: {examples_full}")
    if examples_l4 and l4_dup > full_dup:
        lines.append(f"  extra L4-only dup examples: {[x for x in examples_l4 if x not in examples_full][:5]}")

# current v5 supplement count
lines.append("\n--- cross-source dup among supplements if only dedup vs cmb ---")
existing = set(cmb_full)
for sheet in ["MM", "MA", "openfuyao", "MindCluster"]:
    df = load(sheet)
    added = 0
    skipped_cmb = 0
    skipped_l4 = 0
    for _, r in df.iterrows():
        k = "|".join(str(r[c]).strip() for c in ["L1","L2","L3","L4"])
        l4n = norm(r["L4"])
        if k in existing:
            skipped_cmb += 1
        elif l4n in cmb_l4:
            skipped_l4 += 1
        else:
            added += 1
            existing.add(k)
    lines.append(f"{sheet}: would add {added}, skip exact {skipped_cmb}, skip L4-dup {skipped_l4}")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print("done")
