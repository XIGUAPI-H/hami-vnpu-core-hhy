# -*- coding: utf-8 -*-
import pandas as pd
import json
df = pd.read_excel(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx", sheet_name=0)
for c in ["L1","L2","L3"]: df[c]=df[c].ffill()

sched_ops = df[df["L1"].isin(["算力调度","运维"])]
tool = df[df["L1"].isin(["模型推理","模型训练","资产管理"])]

out = {
    "total_items": len(df),
    "total_work": round(df["总工作量(人月)"].sum(), 1),
    "stages": {},
    "modules": {
        "指标监控": {"n": len(df[df["L1"]=="指标监控"]), "work": round(df[df["L1"]=="指标监控"]["总工作量(人月)"].sum(),1),
            "funcs": df[df["L1"]=="指标监控"]["L4"].tolist()},
        "工具链": {"n": len(tool), "work": round(tool["总工作量(人月)"].sum(),1),
            "funcs": tool["L4"].tolist()},
        "调度": {"n": len(sched_ops), "work": round(sched_ops["总工作量(人月)"].sum(),1),
            "funcs": sched_ops["L4"].tolist()},
        "权限管控": {"n": len(df[df["L1"]=="权限管理"]), "work": round(df[df["L1"]=="权限管理"]["总工作量(人月)"].sum(),1),
            "funcs": df[df["L1"]=="权限管理"]["L4"].tolist()},
    },
    "v1_stage1": {},
    "platforms": {"招行总行": 149, "MA": 238, "MM": 99,
        "mapped": {"招行": 61, "MA": 48, "MM": 32},
        "stage1_mapped": {"招行": 26, "MA": 17, "MM": 15}}
}
for st in ["阶段1","阶段2","阶段3"]:
    sub=df[df["阶段"]==st]
    out["stages"][st] = {"n": len(sub), "work": round(sub["总工作量(人月)"].sum(),1)}

s1=df[df["阶段"]=="阶段1"]
out["v1_stage1"] = {
    "work": round(s1["总工作量(人月)"].sum(),1),
    "指标监控": len(s1[s1["L1"]=="指标监控"]),
    "工具链": len(s1[s1["L1"].isin(["模型推理","模型训练","资产管理"])]),
    "权限": len(s1[s1["L1"]=="权限管理"]),
}
with open(r"d:\hamisoft\hami-vnpu-core\scripts\ppt_json.json","w",encoding="utf-8") as f:
    json.dump(out,f,ensure_ascii=False,indent=2)
print("ok")
