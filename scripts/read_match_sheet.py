# -*- coding: utf-8 -*-
import pandas as pd
from pathlib import Path

INPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx")
xl = pd.ExcelFile(INPUT)
match_name = xl.sheet_names[0]
df = pd.read_excel(INPUT, sheet_name=match_name, header=None)
with open(r"d:\hamisoft\hami-vnpu-core\scripts\match_sheet.txt", "w", encoding="utf-8") as f:
    f.write(f"shape: {df.shape}\n\n")
    f.write(df.head(20).to_string())
    f.write("\n\n--- row0 ---\n")
    f.write(str(list(df.iloc[0])))
    f.write("\n\n--- row1 ---\n")
    f.write(str(list(df.iloc[1])))
