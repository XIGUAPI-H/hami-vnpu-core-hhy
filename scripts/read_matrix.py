# -*- coding: utf-8 -*-
import pandas as pd
from pathlib import Path

desktop = Path(r"C:\Users\d00804096\Desktop")
candidates = sorted(desktop.glob("AI*.xlsx"), key=lambda p: p.stat().st_mtime, reverse=True)
path = candidates[0]
print("using:", path, "mtime:", path.stat().st_mtime)

df = pd.read_excel(path, sheet_name=0)
# forward fill L1-L3 for reading
for c in ["L1", "L2", "L3"]:
    if c in df.columns:
        df[c] = df[c].ffill()

out = Path(__file__).parent / "matrix_current.txt"
lines = [f"path: {path}", f"rows: {len(df)}", ""]
for i, r in df.iterrows():
    lines.append(
        f"[{i}] {r['L1']}|{r['L2']}|{r['L3']}|{r['L4']}\n"
        f"  描述: {r.get('功能描述','')}\n"
        f"  招行: {r.get('招行对应','')}"
    )
out.write_text("\n".join(lines), encoding="utf-8")
print("written", out)
