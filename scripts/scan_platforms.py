# -*- coding: utf-8 -*-
"""Scan all platform L4 items for mapping reference."""
import re
import pandas as pd
from pathlib import Path

INPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx")

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
    df["功能描述"] = df.get("功能描述", pd.Series([""]*len(df))).fillna("")
    df["平台"] = sheet
    return df

all_df = pd.concat([load(s) for s in ["招行","MM","MA","openfuyao","MindCluster"]], ignore_index=True)
lines = [f"total: {len(all_df)}"]
for p in ["招行","MM","MA","openfuyao","MindCluster"]:
    sub = all_df[all_df["平台"]==p]
    lines.append(f"\n{p} L1: {sub['L1'].value_counts().to_dict()}")
    lines.append(f"sample L4: {list(sub['L4'].head(8))}")

with open(Path(__file__).parent / "platform_l4_dump.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
