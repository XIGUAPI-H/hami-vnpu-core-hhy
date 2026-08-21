# -*- coding: utf-8 -*-
import pandas as pd, json
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

rows = []
for _, r in df.iterrows():
    if r["L4"] == "异构算力适配":
        continue
    mm = str(r.get("MM对应","")).strip()
    if mm and mm != "nan":
        rows.append({"L1": r["L1"], "L4": r["L4"], "MM": mm})

with open(r"d:\hamisoft\hami-vnpu-core\scripts\mm_col.json","w",encoding="utf-8") as f:
    json.dump(rows, f, ensure_ascii=False, indent=2)
