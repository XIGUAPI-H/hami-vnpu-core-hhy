# -*- coding: utf-8 -*-
import pandas as pd
from pathlib import Path
p = Path(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v3.xlsx")
df = pd.read_excel(p, sheet_name=0)
for c in ["L1","L2","L3","L4"]:
    df[c] = df[c].ffill()
# inference deploy section
sub = df[(df["L1"]=="模型推理") & (df["L2"]=="推理服务部署")]
Path(r"d:\hamisoft\hami-vnpu-core\scripts\v3_infer_sample.txt").write_text(
    sub[["L2","L3","L4","阶段","开发工作量(人月)","总工作量(人月)"]].to_string(), encoding="utf-8"
)
print(len(df))
