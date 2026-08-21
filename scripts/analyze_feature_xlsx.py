#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Analyze 功能项分析2026.xlsx and generate complete 招行 sheet."""
import re
from pathlib import Path

import pandas as pd
from openpyxl.styles import Alignment, Font, PatternFill, Border, Side

INPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx")
OUTPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026_招行完整版_v4.xlsx")

# --- workload & phase heuristics ---
PHASE1_KW = re.compile(
    r"创建|接入|纳管|部署|安装|基础|列表|查看|导入|导出|登录|权限|配额|监控|告警|日志|"
    r"API|Key|启动|停止|删除|编辑|配置|注册|发布|推理|训练|微调|对话|问答|检索|"
    r"资源池|节点|集群|镜像|模型加载|健康|认证|鉴权|租户|用户|角色"
)
PHASE2_KW = re.compile(
    r"优化|调度|弹性|扩缩|多租户|灰度|A/B|流水线|编排|自动化|批量|模板|"
    r"可视化|仪表盘|分析|统计|对比|评测|评估|压测|性能|成本|计费|"
    r"高可用|容灾|备份|恢复|迁移|联邦|分布式|RankTable|Volcano|Helm"
)
PHASE3_KW = re.compile(
    r"智能|推荐|预测|自治|自愈|自动调优|AI辅助|Copilot|Agent|RAG增强|"
    r"多模态|强化学习|RLHF|蒸馏|量化|剪枝|NAS|AutoML|"
    r"跨云|混合云|边缘|联邦学习|隐私计算|差分隐私"
)

# 输入来源：需求从哪来；极算=招行平台基线（原招行 sheet）
SOURCE_MAP = {
    "MM": "MM",
    "MA": "MA",
    "openfuyao": "openfuyao",
    "MindCluster": "MindCluster",
}
SOURCE_NOTE = {
    "招行": "招行原始需求（保持不变）",
    "openfuyao": "相对招行缺失，参考 openfuyao 补充",
    "MindCluster": "相对招行缺失，参考 MindCluster 补充",
    "MM": "相对招行缺失，参考 MM 补充",
    "MA": "相对招行缺失，参考 MA 补充",
}

SUPPLEMENT_SHEET_ORDER = ["MM", "MA", "openfuyao", "MindCluster"]


def load_sheet(path: Path, sheet: str) -> pd.DataFrame:
    df = pd.read_excel(path, sheet_name=sheet, header=1)
    cols = list(df.columns)
    rename = {
        cols[0]: "L1",
        cols[1]: "L2",
        cols[2]: "L3",
        cols[3]: "L4",
    }
    if len(cols) > 4:
        rename[cols[4]] = "功能描述"
    df = df.rename(columns=rename)
    keep = [c for c in ["L1", "L2", "L3", "L4", "功能描述"] if c in df.columns]
    df = df[keep].copy()
    df = df.dropna(how="all")
    for c in ["L1", "L2", "L3"]:
        if c in df.columns:
            df[c] = df[c].ffill()
    df = df[df["L4"].notna()].copy()
    df["功能描述"] = df.get("功能描述", pd.Series([""] * len(df))).fillna("")
    return df


def make_key(row) -> str:
    return "|".join(str(row[c]).strip() for c in ["L1", "L2", "L3", "L4"])


def norm_l4(l4) -> str:
    s = str(l4).strip().lower()
    return re.sub(r"\s+", "", s)


def row_text(row) -> str:
    return f"{row.get('L1','')}{row.get('L2','')}{row.get('L3','')}{row.get('L4','')}{row.get('功能描述','')}"


def classify_new_l1(row) -> str | None:
    """判断是否属于三个新增 L1 维度之一。"""
    text = row_text(row)
    src_l1 = str(row.get("L1", "")).strip()

    scores = {
        "权限管理": len(AUTH_STRONG.findall(text)),
        "指标监控": len(MON_STRONG.findall(text)),
        "运维": len(OPS_STRONG.findall(text)),
    }
    hint = SOURCE_L1_HINT.get(src_l1)
    if hint:
        scores[hint] += 2

    best = max(scores, key=scores.get)
    if scores[best] == 0:
        return None

    # 同分时：权限 > 监控 > 运维（按业务语义优先级）
    top = [k for k, v in scores.items() if v == scores[best]]
    if len(top) == 1:
        return top[0]
    if "权限管理" in top and AUTH_STRONG.search(text):
        return "权限管理"
    if "指标监控" in top and MON_STRONG.search(text):
        return "指标监控"
    return "运维"


def map_l2(new_l1: str, row) -> str:
    text = row_text(row)
    for l2, pat in L2_RULES.get(new_l1, []):
        if pat.search(text):
            return l2
    return L2_DEFAULT[new_l1]


def map_l3(row) -> str:
    l3 = str(row.get("L3", "")).strip()
    l2 = str(row.get("L2", "")).strip()
    if l3 and l3.lower() != "nan":
        return l3
    return l2 or str(row.get("L1", "")).strip()


def original_path(row, src: str) -> str:
    parts = [src, str(row["L1"]).strip(), str(row["L2"]).strip(), str(row["L3"]).strip()]
    return "/".join(p for p in parts if p and p.lower() != "nan")


def remap_to_new_l1(row, src: str, new_l1: str) -> dict:
    """将外部平台条目映射到新增 L1 下的 L1-L4 结构。"""
    l2 = map_l2(new_l1, row)
    l3 = map_l3(row)
    l4 = str(row["L4"]).strip()
    orig = original_path(row, src)
    return {
        "L1": new_l1,
        "L2": l2,
        "L3": l3,
        "L4": l4,
        "功能描述": row["功能描述"],
        "输入来源": src,
        "来源说明": f"新增L1维度补充 | 原[{orig}]",
        "条目类型": "L1维度补充",
        "_section": f"新增L1-{new_l1}",
        "原平台层级": orig,
    }


def make_separator(label: str, section: str, base_cols: list[str]) -> dict:
    sep = {c: "" for c in base_cols}
    sep["L1"] = label
    sep["_section"] = section
    sep["_is_separator"] = True
    return sep


def estimate_workload(desc: str, l4: str) -> tuple[float, float]:
    text = (desc or "") + (l4 or "")
    n = len(text)
    if n > 200 or any(k in text for k in ("分布式", "流水线", "多租户", "联邦", "AutoML")):
        dev = 2.0
    elif n > 80 or any(k in text for k in ("对接", "集成", "编排", "调度", "监控")):
        dev = 1.0
    elif n > 30:
        dev = 0.5
    else:
        dev = 0.3
    test = round(dev * 0.4, 2)
    return dev, test


OUTPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026_招行完整版_v7.xlsx")

# 新增 L1 维度：从 MM/MA/openfuyao/MindCluster 抽取并归类
NEW_L1_DIMS = ["权限管理", "指标监控", "运维"]

# 维度识别（强特征词）
AUTH_STRONG = re.compile(
    r"权限|角色|RBAC|ABAC|租户|配额|命名空间|多租户|隔离|OAuth|IAM|认证|鉴权|"
    r"API.?Key|登录|SSO|密钥|凭据|访问控制|成员管理|审批|审计|子系统.*权限|用户管理"
)
MON_STRONG = re.compile(
    r"监控|指标|告警|可观测|观测|Metrics|Prometheus|Grafana|仪表盘|"
    r"Exporter|利用率|显存|温度|功耗|调用统计|计量|卡时|话单|成本报表|"
    r"日志管理|日志查看|采集|NPU.*指标|性能测试报告|资源统计|资源可视"
)
OPS_STRONG = re.compile(
    r"运维|部署|安装|纳管|节点|集群部署|故障|恢复|快恢|自愈|备份|"
    r"迁移|升级|巡检|Helm|Chart|批量部署|装机|软件包|健康检查|"
    r"NodeAgent|CES|诊断|压测|兼容性检查|DFX|高可用|容灾|硬件质量"
)

SOURCE_L1_HINT = {
    "运维管理": "运维",
    "监控运维": "指标监控",
    "故障诊断": "运维",
    "安装部署": "运维",
    "性能测试": "运维",
    "DFX能力": "运维",
}

L2_RULES = {
    "权限管理": [
        ("租户与配额", re.compile(r"租户|配额|命名空间|多租户|隔离|借用|超配|层级配额")),
        ("认证与鉴权", re.compile(r"OAuth|IAM|认证|鉴权|API.?Key|登录|SSO|密钥|token|凭据")),
        ("用户与角色", re.compile(r"用户|角色|RBAC|成员|权限|子系统|审批")),
        ("审计与合规", re.compile(r"审计|操作记录|合规")),
    ],
    "指标监控": [
        ("资源指标", re.compile(r"利用率|显存|NPU|Exporter|温度|功耗|带宽|算力|资源统计|资源可视")),
        ("业务指标", re.compile(r"调用统计|训练.*监控|推理.*观测|EagleEye|作业.*查看|任务运行")),
        ("告警与日志", re.compile(r"告警|日志|采集|监控指标|异常告警")),
        ("成本计量", re.compile(r"成本|计量|卡时|话单|报表")),
    ],
    "运维": [
        ("集群部署", re.compile(r"部署|安装|纳管|Helm|Chart|K8s|Kubernetes|批量|装机|软件包|SSH|节点清单")),
        ("故障处置", re.compile(r"故障|恢复|快恢|自愈|隔离|剔除|重调度|断点|续训|Agent")),
        ("性能诊断", re.compile(r"压测|诊断|兼容性|DFX|性能测试|带宽测试")),
        ("日常运维", re.compile(r"升级|备份|迁移|巡检|镜像|仓库|路由容灾")),
    ],
}

L2_DEFAULT = {
    "权限管理": "访问控制",
    "指标监控": "平台监控",
    "运维": "运维保障",
}

PHASE_FINISH = {1: "2026年12月", 2: "2027年6月", 3: "2027年12月"}

# L1/L2 -> 阶段能力描述片段（按实际功能域归纳）
L1_CAPABILITY = {
    "模型训练": "模型训练与精调",
    "模型推理": "在线/批量推理服务",
    "模型部署（2.0）": "模型一键部署与版本管理",
    "模型资产": "模型/数据集资产全生命周期",
    "模型开发": "Notebook 与 IDE 交互式开发",
    "算力纳管": "NPU/GPU 资源池纳管与配额",
    "RAG": "知识库检索增强问答",
    "运维监控": "监控告警与日志审计",
    "资产中心": "统一资产目录与权限",
    "数据准备": "数据清洗、标注与质量治理",
    "强化学习": "RLHF/强化学习训练",
    "模型调度": "推理/训练作业智能调度",
    "集群部署": "K8s 集群与 MindCluster 部署",
    "训练作业": "分布式训练作业编排",
    "DFX设计": "性能压测、高可用与可观测",
    "一体机场景": "一体机/边缘无 K8s 部署",
    "模型管理": "模型注册、权限与多租户",
}

L2_CAPABILITY = {
    "Kubernetes": "容器编排与 K8s 原生调度",
    "模型调度": "多模型/多租户公平调度",
    "训练断点续训": "长训练断点续训与容错",
    "底层硬件虚拟化": "vNPU 虚拟化与资源隔离",
    "数据均衡": "训练数据均衡与采样策略",
    "异构训练": "异构算力混合训练",
    "集群故障感知和隔离": "故障域感知与自动隔离",
    "Notebook": "Notebook 开发环境",
    "精调训练": "LoRA/全参精调",
    "标准裸机集群": "裸机集群批量装机",
    "调度与公平": "算力公平调度与优先级",
    "模型评估": "自动评测与基准对比",
}


def _top_labels(sub: pd.DataFrame, col: str, n: int = 6) -> list[str]:
    from collections import Counter

    c = Counter(sub[col].dropna().astype(str))
    return [k for k, _ in c.most_common(n) if k.strip()]


def _capability_phrases(labels: list[str], mapping: dict, fallback: str) -> list[str]:
    out = []
    for lb in labels:
        phrase = mapping.get(lb)
        if phrase and phrase not in out:
            out.append(phrase)
    return out[:5] if out else [fallback]


def _phase_differentiators(phase: int, sub: pd.DataFrame) -> str:
    """从该阶段实际 L4/描述中提取「相对上一阶段新增价值」。"""
    texts = (sub["L4"].fillna("").astype(str) + sub["功能描述"].fillna("").astype(str)).tolist()
    blob = "\n".join(texts)

    def hit(keys):
        return [k for k in keys if k in blob]

    if phase == 2:
        clusters = []
        sched = hit(["Kubernetes", "K8s", "Gang", "PodGroup", "SLO", "调度", "Volcano", "MindCluster", "拓扑", "NUMA"])
        if sched:
            clusters.append("K8s/MindCluster 原生调度与 NPU 拓扑亲和")
        virt = hit(["MIG", "虚拟化", "vNPU", "隔离"])
        if virt:
            clusters.append("vNPU 虚拟化与多租户资源隔离")
        ckpt = hit(["断点", "续训", "Checkpoint", "MindIO", "TaskD", "快恢"])
        if ckpt:
            clusters.append("训练断点续训与推理/训练故障快恢")
        infer = hit(["PD 分离", "Mooncake", "KVCache", "EagleEye", "扩缩"])
        if infer:
            clusters.append("PD 分离推理、分布式 KVCache 与可观测")
        deploy = hit(["ascend-deployer", "批量部署", "Helm", "Chart", "裸机"])
        if deploy:
            clusters.append("集群批量装机与 Helm/Chart 标准化交付")
        nb = hit(["notebook", "Notebook", "十统一", "动态挂载"])
        if nb:
            clusters.append("Notebook 十统一与存储动态挂载")
        if not clusters:
            clusters = ["多业务并行调度", "集群化运维", "规模化交付"]
        return "；".join(clusters[:4])

    # phase 3
    clusters = []
    rl = hit(["RL", "RLHF", "rLLM", "VeRL", "Agentic", "奖励模型", "强化学习"])
    if rl:
        clusters.append("多场景 RL 训练（代码/搜索/数学/多模态 Agentic RL）")
    data = hit(["精炼", "标注", "多模态数据", "格式转换", "数据评估", "数据过滤", "文本数据合成"])
    if data:
        clusters.append("可视化数据精炼编排与多模态标注治理")
    fault = hit(["故障感知", "NodeAgent", "CES Agent", "隔离", "自愈"])
    if fault:
        clusters.append("集群故障域感知、NodeAgent 告警与自动隔离")
    hetero = hit(["异构", "Hermes", "智能路由"])
    if hetero:
        clusters.append("异构算力混训与 Hermes 智能路由")
    api = hit(["多模态接口", "向量化接口", "API-KEY", "IAM token"])
    if api:
        clusters.append("多模态/向量化推理接口与企业级认证")
    return "；".join(clusters[:4]) if clusters else "强化学习、数据治理与故障自愈等高阶能力"


def build_phase_narrative(phase: int, sub: pd.DataFrame) -> str:
    """基于该阶段实际功能分布生成分阶段目标描述。"""
    cnt = len(sub)
    total = round(sub["总工作量(人月)"].sum(), 1)
    finish = PHASE_FINISH[phase]

    l1s = _top_labels(sub, "L1", 8)
    l2s = _top_labels(sub, "L2", 10)
    cmb_cnt = len(sub[sub["输入来源"] == "招行"]) if "输入来源" in sub.columns else 0
    sup_cnt = cnt - cmb_cnt

    caps_l1 = _capability_phrases(l1s, L1_CAPABILITY, "核心 AI 平台能力")
    caps_l2 = _capability_phrases(l2s, L2_CAPABILITY, "")
    cap_text = "、".join(caps_l1)
    if caps_l2:
        cap_text += "，以及" + "、".join(caps_l2[:3])

    if phase == 1:
        return (
            f"阶段①能用，能够{cap_text}；"
            f"支撑招行 AI 平台单业务 PoC 上线（招行基线 {cmb_cnt} 项、差异补充 {sup_cnt} 项）；"
            f"开发 {cnt} 个功能点，预计耗时 {total} 人月，预计 {finish} 完成"
        )
    if phase == 2:
        extra = _phase_differentiators(2, sub)
        return (
            f"阶段②好用，在「能用」基础上，能够{cap_text}；"
            f"相较阶段①新增：{extra}（本阶段 {cnt} 项，调度/集群/DFX 占主导）；"
            f"预计耗时 {total} 人月，预计 {finish} 完成"
        )
    extra = _phase_differentiators(3, sub)
    return (
        f"阶段③更好用，在「好用」基础上，还能{cap_text}；"
        f"相较阶段②新增：{extra}（本阶段 {cnt} 项，以 MA/MindCluster 高阶能力为主）；"
        f"预计耗时 {total} 人月，预计 {finish} 完成"
    )


def row_phase_hint(phase: int, l1: str, l2: str, l4: str, desc: str) -> str:
    """单行阶段说明：说明该功能为何落在该阶段。"""
    text = f"{l1}{l2}{l4}{desc}"
    if phase == 1:
        if any(k in text for k in ("权限", "登录", "创建", "部署", "接入", "纳管", "API", "监控", "告警")):
            return f"阶段①基础必备：{l2 or l1}——{l4}"
        return f"阶段①核心链路：{l1} / {l4}"
    if phase == 3:
        return f"阶段③高阶能力：{l1} / {l4}"
    if any(k in text for k in ("调度", "K8s", "Kubernetes", "弹性", "分布式", "Helm")):
        return f"阶段②规模化：{l2 or l1}——{l4}"
    return f"阶段②增强能力：{l1} / {l4}"


def estimate_phase(l1: str, l2: str, l3: str, l4: str, desc: str) -> int:
    text = f"{l1}{l2}{l3}{l4}{desc}"
    if PHASE3_KW.search(text):
        return 3
    if PHASE2_KW.search(text):
        return 2
    if PHASE1_KW.search(text):
        return 1
    return 2


def blank_repeated_hierarchy(df: pd.DataFrame) -> pd.DataFrame:
    """Keep hierarchy label only on first row of each group (for merged-cell display)."""
    out = df.copy()
    for col, parents in [
        ("L1", []),
        ("L2", ["L1"]),
        ("L3", ["L1", "L2"]),
    ]:
        prev = None
        for i in out.index:
            key = tuple(str(df.at[i, p]) for p in parents + [col])
            if key == prev:
                out.at[i, col] = ""
            else:
                prev = key
    return out


def merge_hierarchy_cells(ws, df: pd.DataFrame, header_row: int = 1) -> None:
    """Vertically merge L1/L2/L3 within each section (不跨招行基线与差异补充)."""
    n = len(df)
    start = header_row + 1
    if n <= 1:
        return

    section = df["_section"].astype(str) if "_section" in df.columns else pd.Series(["all"] * n)

    def merge_ranges(col_letter: str, group_keys: pd.Series) -> None:
        i = 0
        while i < n:
            j = i + 1
            while j < n and group_keys.iloc[j] == group_keys.iloc[i]:
                j += 1
            if j - i > 1:
                ws.merge_cells(f"{col_letter}{start + i}:{col_letter}{start + j - 1}")
            i = j

    sk = section
    merge_ranges("A", sk + "\0" + df["L1"].astype(str))
    merge_ranges("B", sk + "\0" + df["L1"].astype(str) + "\0" + df["L2"].astype(str))
    merge_ranges(
        "C",
        sk + "\0" + df["L1"].astype(str) + "\0" + df["L2"].astype(str) + "\0" + df["L3"].astype(str),
    )

    center = Alignment(horizontal="center", vertical="center", wrap_text=True)
    thin = Side(style="thin", color="B4B4B4")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    for r in range(header_row, start + n):
        for c in range(1, ws.max_column + 1):
            cell = ws.cell(r, c)
            cell.alignment = center
            cell.border = border


def style_header(ws, header_row: int = 1) -> None:
    fill = PatternFill("solid", fgColor="B4C7E7")
    font = Font(bold=True)
    center = Alignment(horizontal="center", vertical="center", wrap_text=True)
    for c in range(1, ws.max_column + 1):
        cell = ws.cell(header_row, c)
        cell.fill = fill
        cell.font = font
        cell.alignment = center


def enrich_rows(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    dev_list, test_list, total_list, phase_list, phase_desc_list = [], [], [], [], []
    for _, row in out.iterrows():
        if row.get("条目类型") not in ("招行基线", "差异补充", "L1维度补充"):
            dev_list.append(None)
            test_list.append(None)
            total_list.append(None)
            phase_list.append(None)
            phase_desc_list.append(None)
            continue
        dev, test = estimate_workload(row["功能描述"], row["L4"])
        phase = estimate_phase(row["L1"], row["L2"], row["L3"], row["L4"], row["功能描述"])
        dev_list.append(dev)
        test_list.append(test)
        total_list.append(round(dev + test, 2))
        phase_list.append(f"阶段{phase}")
        phase_desc_list.append(row_phase_hint(phase, str(row["L1"]), str(row["L2"]), str(row["L4"]), str(row["功能描述"])))
    out["开发工作量(人月)"] = dev_list
    out["测试工作量(人月)"] = test_list
    out["总工作量(人月)"] = total_list
    out["阶段"] = phase_list
    out["阶段说明"] = phase_desc_list
    return out


def write_sheet_with_merge(writer, sheet_name: str, df: pd.DataFrame, merge_cols: bool = True) -> None:
    export_cols = [c for c in df.columns if not c.startswith("_")]
    display = blank_repeated_hierarchy(df[export_cols].copy()) if merge_cols else df[export_cols]
    # restore internal cols alignment for merge
    merge_df = df.copy()
    display.to_excel(writer, sheet_name=sheet_name, index=False)
    ws = writer.sheets[sheet_name]
    style_header(ws)
    if merge_cols and len(df) > 0:
        merge_hierarchy_cells(ws, merge_df)
    # column width
    widths = {
        "A": 14, "B": 16, "C": 16, "D": 22, "E": 48,
        "F": 10, "G": 28, "H": 12, "I": 12, "J": 12, "K": 12,
        "L": 10, "M": 36, "N": 28,
    }
    for letter, w in widths.items():
        ws.column_dimensions[letter].width = w


def main():
    xl = pd.ExcelFile(INPUT)
    print("Sheets:", xl.sheet_names)

    cmb = load_sheet(INPUT, "招行")
    cmb["key"] = cmb.apply(make_key, axis=1)
    cmb["输入来源"] = "招行"
    cmb["来源说明"] = SOURCE_NOTE["招行"]
    cmb["条目类型"] = "招行基线"
    cmb["_section"] = "招行基线"
    existing_keys = set(cmb["key"])
    existing_l4 = {norm_l4(x) for x in cmb["L4"]}

    supplements = []
    l1_dim_items = {d: [] for d in NEW_L1_DIMS}
    removed = []

    for sheet in SUPPLEMENT_SHEET_ORDER:
        if sheet not in xl.sheet_names:
            continue
        df = load_sheet(INPUT, sheet)
        df["key"] = df.apply(make_key, axis=1)
        src = SOURCE_MAP.get(sheet, sheet)
        note = SOURCE_NOTE.get(src, src)
        for _, row in df.iterrows():
            l4n = norm_l4(row["L4"])
            new_l1 = classify_new_l1(row)
            reason = None
            if row["key"] in existing_keys:
                reason = "与招行 L1-L4 完全相同"
            elif not new_l1 and l4n in existing_l4:
                reason = "L4 与招行已有功能重复（非三维度项）"

            if reason:
                removed.append(
                    {
                        "L1": row["L1"],
                        "L2": row["L2"],
                        "L3": row["L3"],
                        "L4": row["L4"],
                        "功能描述": row["功能描述"],
                        "输入来源": src,
                        "建议归属L1": new_l1 or "",
                        "剔除原因": reason,
                    }
                )
                continue

            if new_l1:
                mapped = remap_to_new_l1(row, src, new_l1)
                mapped["key"] = make_key(mapped)
                l1_dim_items[new_l1].append(mapped)
                existing_keys.add(row["key"])
                existing_l4.add(l4n)
                continue

            supplements.append(
                {
                    "L1": row["L1"],
                    "L2": row["L2"],
                    "L3": row["L3"],
                    "L4": row["L4"],
                    "功能描述": row["功能描述"],
                    "输入来源": src,
                    "来源说明": note,
                    "条目类型": "差异补充",
                    "_section": f"差异补充-{src}",
                    "原平台层级": original_path(row, src),
                    "key": row["key"],
                }
            )
            existing_keys.add(row["key"])
            existing_l4.add(l4n)

    # L1 维度内按 L2/L3/L4 排序，并二次 L4 去重
    dim_dfs = {}
    for dim in NEW_L1_DIMS:
        rows = l1_dim_items[dim]
        if not rows:
            dim_dfs[dim] = pd.DataFrame()
            continue
        ddf = pd.DataFrame(rows)
        ddf = ddf.sort_values(["L2", "L3", "L4", "输入来源"], kind="stable")
        seen_l4 = set()
        keep_idx = []
        for i, r in ddf.iterrows():
            l4n = norm_l4(r["L4"])
            if l4n in seen_l4:
                removed.append(
                    {
                        "L1": r["L1"],
                        "L2": r["L2"],
                        "L3": r["L3"],
                        "L4": r["L4"],
                        "功能描述": r["功能描述"],
                        "输入来源": r["输入来源"],
                        "建议归属L1": dim,
                        "剔除原因": "L1维度内 L4 重复",
                    }
                )
                continue
            seen_l4.add(l4n)
            keep_idx.append(i)
        dim_dfs[dim] = ddf.loc[keep_idx].reset_index(drop=True)
        for _, r in dim_dfs[dim].iterrows():
            existing_l4.add(norm_l4(r["L4"]))
            existing_keys.add(make_key(r))

    sup_df = pd.DataFrame(supplements)
    removed_df = pd.DataFrame(removed)
    if len(sup_df):
        sup_df = sup_df.sort_values(["输入来源", "L1", "L2", "L3", "L4"], kind="stable").reset_index(drop=True)

    dim_counts = {d: len(dim_dfs[d]) for d in NEW_L1_DIMS}
    print(
        f"招行原有: {len(cmb)} | L1维度补充: 权限{dim_counts['权限管理']} "
        f"监控{dim_counts['指标监控']} 运维{dim_counts['运维']} | "
        f"其他差异补充: {len(sup_df)} | 剔除: {len(removed_df)}"
    )

    base_cols = [
        "L1", "L2", "L3", "L4", "功能描述", "输入来源", "来源说明",
        "条目类型", "_section", "原平台层级",
    ]
    cmb_part = cmb[base_cols[:-1]].copy()
    cmb_part["原平台层级"] = "招行"

    parts = [cmb_part]
    for dim in NEW_L1_DIMS:
        ddf = dim_dfs[dim]
        if len(ddf) == 0:
            continue
        parts.append(
            pd.DataFrame([make_separator(f"—— {dim}（平台补充）——", f"分隔-{dim}", base_cols)])
        )
        parts.append(ddf[base_cols])

    if len(sup_df):
        parts.append(
            pd.DataFrame([make_separator("—— 其他差异补充功能 ——", "分隔-其他", base_cols)])
        )
        parts.append(sup_df[base_cols])

    full = pd.concat(parts, ignore_index=True)
    full = enrich_rows(full)

    # phase summary (exclude separator row)
    work = full[full["条目类型"].isin(["招行基线", "差异补充", "L1维度补充"])].copy()
    phase_summary = []
    phase_narratives = {}
    for p in [1, 2, 3]:
        sub = work[work["阶段"] == f"阶段{p}"]
        dev_sum = sub["开发工作量(人月)"].sum()
        test_sum = sub["测试工作量(人月)"].sum()
        total_sum = sub["总工作量(人月)"].sum()
        cnt = len(sub)
        narrative = build_phase_narrative(p, sub)
        phase_narratives[p] = narrative
        l1_top = "、".join(_top_labels(sub, "L1", 5))
        l2_top = "、".join(_top_labels(sub, "L2", 5))
        phase_summary.append(
            {
                "阶段": f"阶段{p}",
                "阶段目标（分析生成）": narrative,
                "主要L1域": l1_top,
                "主要L2模块": l2_top,
                "功能点数": cnt,
                "招行基线": len(sub[sub["输入来源"] == "招行"]),
                "差异补充": len(sub[sub["输入来源"] != "招行"]),
                "开发工作量(人月)": round(dev_sum, 1),
                "测试工作量(人月)": round(test_sum, 1),
                "总工作量(人月)": round(total_sum, 1),
                "预计完成": PHASE_FINISH[p],
            }
        )
    summary_df = pd.DataFrame(phase_summary)

    # 阶段明细：各阶段代表性功能示例
    phase_examples = []
    for p in [1, 2, 3]:
        sub = work[work["阶段"] == f"阶段{p}"]
        for _, r in sub.head(8).iterrows():
            phase_examples.append(
                {
                    "阶段": f"阶段{p}",
                    "L1": r["L1"],
                    "L2": r["L2"],
                    "L4": r["L4"],
                    "输入来源": r["输入来源"],
                    "总工作量(人月)": r["总工作量(人月)"],
                }
            )
    phase_examples_df = pd.DataFrame(phase_examples)

    # source breakdown
    src_summary = (
        work.groupby("输入来源")
        .agg(
            功能点数=("L4", "count"),
            开发工作量=("开发工作量(人月)", "sum"),
            测试工作量=("测试工作量(人月)", "sum"),
            总工作量=("总工作量(人月)", "sum"),
        )
        .reset_index()
        .round(1)
    )

    # L1 三维度汇总
    l1_dim_work = work[work["条目类型"] == "L1维度补充"].copy()
    l1_dim_summary = []
    for dim in NEW_L1_DIMS:
        sub = l1_dim_work[l1_dim_work["L1"] == dim]
        if len(sub) == 0:
            continue
        for l2, g in sub.groupby("L2", sort=False):
            l1_dim_summary.append(
                {
                    "L1": dim,
                    "L2": l2,
                    "功能点数": len(g),
                    "MM": len(g[g["输入来源"] == "MM"]),
                    "MA": len(g[g["输入来源"] == "MA"]),
                    "openfuyao": len(g[g["输入来源"] == "openfuyao"]),
                    "MindCluster": len(g[g["输入来源"] == "MindCluster"]),
                    "总工作量(人月)": round(g["总工作量(人月)"].sum(), 1),
                }
            )
        l1_dim_summary.append(
            {
                "L1": dim,
                "L2": "【小计】",
                "功能点数": len(sub),
                "MM": len(sub[sub["输入来源"] == "MM"]),
                "MA": len(sub[sub["输入来源"] == "MA"]),
                "openfuyao": len(sub[sub["输入来源"] == "openfuyao"]),
                "MindCluster": len(sub[sub["输入来源"] == "MindCluster"]),
                "总工作量(人月)": round(sub["总工作量(人月)"].sum(), 1),
            }
        )
    l1_dim_summary_df = pd.DataFrame(l1_dim_summary)

    # supplements detail sheet（L1维度 + 其他差异）
    all_sup_rows = []
    for dim in NEW_L1_DIMS:
        if len(dim_dfs[dim]):
            all_sup_rows.append(dim_dfs[dim])
    if len(sup_df):
        all_sup_rows.append(sup_df)
    sup_detail = pd.concat(all_sup_rows, ignore_index=True) if all_sup_rows else pd.DataFrame()
    if len(sup_detail):
        lookup = work.copy()
        lookup["key"] = lookup.apply(make_key, axis=1)
        lookup = lookup.set_index("key")
        for col in ["开发工作量(人月)", "测试工作量(人月)", "总工作量(人月)", "阶段", "阶段说明"]:
            sup_detail[col] = [
                lookup.loc[k, col] if k in lookup.index else "" for k in sup_detail.get("key", sup_detail.apply(make_key, axis=1))
            ]

    with pd.ExcelWriter(OUTPUT, engine="openpyxl") as writer:
        write_sheet_with_merge(writer, "招行完整版", full, merge_cols=True)
        if len(l1_dim_work):
            dim_export = l1_dim_work[
                ["L1", "L2", "L3", "L4", "功能描述", "输入来源", "来源说明", "原平台层级",
                 "开发工作量(人月)", "测试工作量(人月)", "总工作量(人月)", "阶段", "阶段说明"]
            ].copy()
            dim_export["_section"] = dim_export["L1"]
            write_sheet_with_merge(writer, "三维度补充明细", dim_export, merge_cols=True)
        if len(l1_dim_summary_df):
            l1_dim_summary_df.to_excel(writer, sheet_name="三维度汇总", index=False)
            style_header(writer.sheets["三维度汇总"])
        summary_df.to_excel(writer, sheet_name="阶段汇总", index=False)
        style_header(writer.sheets["阶段汇总"])
        phase_examples_df.to_excel(writer, sheet_name="阶段功能示例", index=False)
        style_header(writer.sheets["阶段功能示例"])
        src_summary.to_excel(writer, sheet_name="来源汇总", index=False)
        style_header(writer.sheets["来源汇总"])
        if len(sup_detail):
            write_sheet_with_merge(writer, "本次补充项", sup_detail, merge_cols=True)
        if len(removed_df):
            removed_df.sort_values(["输入来源", "L1", "L2", "L4"], kind="stable").to_excel(
                writer, sheet_name="已剔除重复项", index=False
            )
            style_header(writer.sheets["已剔除重复项"])
        # keep originals for reference
        for s in xl.sheet_names:
            pd.read_excel(INPUT, sheet_name=s, header=None).to_excel(
                writer, sheet_name=f"原始_{s}"[:31], index=False, header=False
            )

    print(f"Written: {OUTPUT}")
    print(f"Total rows: {len(full)}")
    print(summary_df[["阶段", "功能点数", "总工作量(人月)", "预计完成"]].to_string(index=False))
    for p in [1, 2, 3]:
        print(f"\n--- 阶段{p} 目标 ---")
        print(phase_narratives[p][:300], "...")
    print("\nSource breakdown:")
    print(src_summary.to_string(index=False))


if __name__ == "__main__":
    main()
