# -*- coding: utf-8 -*-
import pandas as pd
import json

v2 = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v2.xlsx", sheet_name=0)
v4 = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]:
    v2[c]=v2[c].ffill(); v4[c]=v4[c].ffill()

l2 = set(v2["L4"].astype(str))
l4 = set(v4["L4"].astype(str))
extra = sorted(l4 - l2)
missing = sorted(l2 - l4)
print("v4 extra vs v2:", len(extra), extra)
print("v2 missing in v4:", len(missing), missing)

print("\nv2 L1:", v2.groupby("L1").size().to_dict())
print("v4 L1:", v4.groupby("L1").size().to_dict())
