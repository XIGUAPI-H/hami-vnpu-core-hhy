# -*- coding: utf-8 -*-
import pandas as pd
from collections import Counter

path = r"C:\Users\d00804096\Desktop\功能项分析2026_招行完整版_v5.xlsx"
work = pd.read_excel(path, sheet_name="招行完整版")
for p in [1, 2, 3]:
    sub = work[work["阶段"] == f"阶段{p}"]
    print(f"\n=== 阶段{p} L2 Top10 ===")
    for k, v in Counter(sub["L2"].dropna()).most_common(10):
        print(f"  {k}: {v}")
