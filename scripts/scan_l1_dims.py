# -*- coding: utf-8 -*-
import pandas as pd
import re
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
    return df

# sample L1 values per sheet
lines = []
for sheet in ["招行", "MM", "MA", "openfuyao", "MindCluster"]:
    df = load(sheet)
    lines.append(f"\n=== {sheet} L1 unique ({df['L1'].nunique()}) ===")
    for v, c in df["L1"].value_counts().head(15).items():
        lines.append(f"  {v}: {c}")

# keyword hits for 3 new L1
KW = {
    "权限管理": re.compile(
        r"权限|角色|RBAC|ABAC|认证|鉴权|IAM|token|API.?Key|租户|多租户|隔离|配额|"
        r"用户管理|成员|审批|审计|登录|SSO|OAuth|密钥|凭据|访问控制|ACL|子系统"
    ),
    "指标监控": re.compile(
        r"监控|指标|告警|可观测|观测|Metrics|Prometheus|Grafana|仪表盘|"
        r"日志|审计|采集|Exporter|性能|利用率|显存|温度|功耗|NPU.*指标|"
        r"调用统计|统计|报表|成本|计量|卡时"
    ),
    "运维": re.compile(
        r"运维|部署|安装|纳管|节点|集群|故障|恢复|快恢|自愈|隔离|备份|"
        r"迁移|升级|巡检|DFX|高可用|容灾|Helm|Chart|批量|装机|"
        r"硬件质量|诊断|压测|健康检查|NodeAgent|CES"
    ),
}

for sheet in ["MM", "MA", "openfuyao", "MindCluster"]:
    df = load(sheet)
    lines.append(f"\n=== {sheet} keyword hits ===")
    for l1_new, pat in KW.items():
        hit = df[df.apply(lambda r: bool(pat.search(f"{r['L1']}{r['L2']}{r['L3']}{r['L4']}{r['功能描述']}")), axis=1)]
        lines.append(f"  {l1_new}: {len(hit)}")
        for _, r in hit.head(5).iterrows():
            lines.append(f"    [{r['L1']}/{r['L2']}] {r['L4']}")

# 招行 items that might belong to new L1
cmb = load("招行")
lines.append("\n=== 招行 hits for new L1 ===")
for l1_new, pat in KW.items():
    hit = cmb[cmb.apply(lambda r: bool(pat.search(f"{r['L1']}{r['L2']}{r['L3']}{r['L4']}{r['功能描述']}")), axis=1)]
    lines.append(f"  {l1_new}: {len(hit)}")

with open(r"d:\hamisoft\hami-vnpu-core\scripts\l1_scan.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
