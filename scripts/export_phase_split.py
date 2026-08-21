# -*- coding: utf-8 -*-
import pandas as pd
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("rp", Path(__file__).parent / "rephase_matrix.py")
rp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rp)

df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v3.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c] = df[c].ffill()
lines = []
for p in [1,2,3]:
    sub = df[df["阶段"]==f"阶段{p}"]
    lines.append(f"\n=== 阶段{p} ({len(sub)}项) ===")
    for l1, g in sub.groupby("L1", sort=False):
        lines.append(f"  [{l1}]")
        for _, r in g.iterrows():
            lines.append(f"    - {r['L4']}")
Path(__file__).parent.joinpath("phase_split.txt").write_text("\n".join(lines), encoding="utf-8")
