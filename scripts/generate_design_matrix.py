#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 AI 服务管理平台七域功能设计矩阵，并与招行/MM/MA/openfuyao/MindCluster 对齐。
"""
from __future__ import annotations

import re
from pathlib import Path

import pandas as pd
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

INPUT = Path(r"C:\Users\d00804096\Desktop\功能项分析2026.xlsx")
OUTPUT = Path(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v1.xlsx")

PLATFORMS = ["招行", "openfuyao", "MM", "MA", "MindCluster"]
PHASE_FINISH = {1: "2026年12月", 2: "2027年6月", 3: "2027年12月"}

PHASE1_KW = re.compile(
    r"创建|接入|纳管|部署|安装|基础|列表|查看|导入|导出|登录|权限|配额|监控|告警|日志|"
    r"API|Key|启动|停止|删除|编辑|配置|注册|发布|推理|训练|微调|对话|问答|检索|"
    r"资源池|节点|集群|镜像|模型加载|健康|认证|鉴权|租户|用户|角色"
)
PHASE2_KW = re.compile(
    r"优化|调度|弹性|扩缩|多租户|灰度|流水线|编排|自动化|批量|模板|"
    r"可视化|仪表盘|分析|统计|对比|评测|评估|压测|性能|成本|计费|"
    r"高可用|容灾|备份|恢复|迁移|联邦|分布式|RankTable|Volcano|Helm"
)
PHASE3_KW = re.compile(
    r"智能|推荐|预测|自治|自愈|自动调优|Agent|RLHF|多模态|强化学习|"
    r"蒸馏|量化|NAS|AutoML|跨云|混合云|边缘|联邦学习"
)

# ---------------------------------------------------------------------------
# 业界参考：七域 L1-L2-L3-L4 功能设计（keywords 用于平台功能对齐）
# ---------------------------------------------------------------------------
def item(l1, l2, l3, l4, desc, kw: list[str]):
    return {"L1": l1, "L2": l2, "L3": l3, "L4": l4, "功能描述": desc, "kw": kw + [l4]}


CANONICAL = [
    # ===== 模型推理 =====
    item("模型推理", "推理服务部署", "服务生命周期", "在线推理服务部署", "支持单机/多副本在线推理服务创建、启动、停止与版本管理", ["标准化部署", "通用部署", "单机推理", "创建服务单元", "在线服务部署"]),
    item("模型推理", "推理服务部署", "服务生命周期", "多机多卡分布式推理", "支持张量并行/流水线并行等多机多卡分布式推理部署", ["多机多卡", "分布式推理", "大EP", "PD分离"]),
    item("模型推理", "推理服务部署", "服务生命周期", "批量异步推理", "支持离线批量推理任务提交、排队与结果拉取", ["批量异步推理", "批量推理", "异步推理"]),
    item("模型推理", "推理服务部署", "发布变更", "服务灰度与回滚", "支持灰度发布、变更审批、回滚与投产流程", ["灰度", "回滚", "变更", "投产", "测试到生产"]),
    item("模型推理", "推理服务部署", "弹性伸缩", "推理弹性扩缩容", "基于负载自动扩缩推理实例（HPA/自定义策略）", ["扩缩", "HPA", "弹性", "动态扩缩", "PD 分离动态扩缩"]),
    item("模型推理", "模型体验", "在线体验", "模型广场体验", "模型广场卡片展示、在线试用与体验入口", ["模型广场", "模型体验", "在线体验"]),
    item("模型推理", "模型体验", "在线体验", "在线对话", "Web 端多轮对话、流式输出与对话管理", ["在线对话", "对话管理", "流式", "深度思考"]),
    item("模型推理", "API服务", "接口开放", "对话推理API", "OpenAI 兼容对话/completions 推理 API", ["对话接口", "completions", "chat"]),
    item("模型推理", "API服务", "接口开放", "向量化API", "文本/多模态 Embedding 向量化接口", ["向量化接口", "embedding"]),
    item("模型推理", "API服务", "接口开放", "多模态推理API", "图文/语音等多模态理解与生成接口", ["多模态接口", "多模态"]),
    item("模型推理", "API服务", "接口开放", "Function Call", "工具调用/函数调用能力", ["Function Call", "function call", "工具调用"]),
    item("模型推理", "API服务", "网关路由", "推理网关与路由", "统一推理入口、路由转发、限流与容灾", ["网关", "路由", "Hermes", "InferNex", "限流"]),
    item("模型推理", "RAG增强", "知识库", "知识库创建与管理", "知识库创建、文档导入、切片与索引管理", ["知识库创建", "知识库", "向量数据库", "知识库管理"]),
    item("模型推理", "RAG增强", "检索增强", "RAG检索问答", "检索增强生成（RAG）对话与混合检索", ["RAG", "检索增强", "启用知识库", "混合检索"]),
    item("模型推理", "RAG增强", "检索增强", "重排与召回", "召回+重排（Rerank）提升检索精度", ["重排接口", "rerank", "重排"]),
    item("模型推理", "向量服务", "向量库", "向量数据库服务", "向量库实例创建、容量管理与 GaussDB/ACS 对接", ["向量数据库", "GaussDB", "向量库", "容量建议"]),
    item("模型推理", "可观测", "调用统计", "推理调用量统计", "按应用/模型/时间维度统计 Token 与调用量", ["调用量统计", "调用统计", "Token"]),
    item("模型推理", "可观测", "链路追踪", "推理链路可观测", "推理延迟、吞吐、错误率与链路追踪", ["EagleEye", "可观测", "推理可观测", "OFIXL"]),
    # ===== 模型训练 =====
    item("模型训练", "精调训练", "监督微调", "LoRA精调", "低秩适配（LoRA/QLoRA）精调训练", ["LoRA", "精调", "lora", "低秩"]),
    item("模型训练", "精调训练", "监督微调", "全参精调", "全参数微调（SFT）训练", ["全参", "SFT", "全量微调", "精调训练"]),
    item("模型训练", "精调训练", "作业管理", "精调作业提交", "精调任务配置、提交、停止与日志查看", ["精调", "作业提交", "任务提交", "训练任务"]),
    item("模型训练", "预训练", "分布式训练", "分布式预训练", "多机多卡大规模预训练（Megatron/MindSpeed 等）", ["预训练", "分布式训练", "MindSpeed", "分布式预训"]),
    item("模型训练", "预训练", "容错续训", "断点续训", "训练中断后从 Checkpoint 自动恢复", ["断点续训", "checkpoint", "续训", "MindIO"]),
    item("模型训练", "预训练", "分布式训练", "RankTable自动生成", "分布式作业 RankTable/hccl.json 自动生成", ["RankTable", "hccl", "rank table"]),
    item("模型训练", "强化学习", "对齐训练", "RLHF训练", "基于人类反馈的强化学习对齐训练", ["RLHF", "强化学习", "奖励模型"]),
    item("模型训练", "强化学习", "对齐训练", "DPO/偏好对齐", "DPO/拒绝采样等偏好对齐训练", ["DPO", "拒绝指令", "偏好"]),
    item("模型训练", "强化学习", "Agent训练", "Agentic RL", "Agent 场景强化学习训练", ["Agentic RL", "Agentic", "rLLM", "VeRL"]),
    item("模型训练", "开发环境", "Notebook", "Notebook交互开发", "云端 Notebook 交互式开发与十统一能力", ["Notebook", "notebook", "交互式"]),
    item("模型训练", "开发环境", "Notebook", "SSH远程开发", "Notebook SSH 远程连接与运行用户配置", ["SSH", "远程开发"]),
    item("模型训练", "开发环境", "高代码", "高代码训练流水线", "可视化/高代码训练流水线编排与运行", ["高代码", "流水线", "可视化编排", "工作流"]),
    item("模型训练", "作业运维", "训练监控", "训练作业监控", "训练 loss/资源利用率实时监控与告警", ["训练监控", "作业监控", "训练任务监控", "作业流程查看"]),
    item("模型训练", "模型评测", "自动评测", "模型自动评测", "基准数据集自动评测与报告", ["模型评测", "自动评测", "评测榜单", "模型测评"]),
    item("模型训练", "模型评测", "人工评测", "评测任务管理", "人工评测任务创建、分发与结果汇总", ["评测任务", "标注任务", "结果汇总"]),
    item("模型训练", "数据工程", "数据准备", "训练数据集管理", "训练数据集创建、版本、导入与发布", ["数据集", "数据管理", "纳为我的数据集"]),
    item("模型训练", "数据工程", "数据标注", "数据标注", "标注任务、模板与质检汇总", ["标注", "标注任务", "标注模板"]),
    # ===== 资产管理 =====
    item("资产管理", "模型资产", "模型注册", "模型注册与纳管", "模型元数据注册、标签与权限管理", ["模型注册", "我的模型", "模型纳管", "基座"]),
    item("资产管理", "模型资产", "版本管理", "模型版本管理", "模型多版本并存、发布与回退", ["版本", "发布与版本", "模型版本"]),
    item("资产管理", "模型资产", "模型市场", "模型广场与订阅", "模型广场浏览、订阅与取消订阅", ["模型广场", "订阅模型", "取消订阅"]),
    item("资产管理", "数据集资产", "数据集", "数据集全生命周期", "数据集创建、上传、版本与权限", ["数据集创建", "数据集管理", "发布与版本"]),
    item("资产管理", "数据集资产", "数据连接", "多源数据接入", "本地/OBS/数据库等多源数据连接导入", ["数据连接", "数据导入", "OBS", "多源数据"]),
    item("资产管理", "数据集资产", "数据精炼", "数据精炼与合成", "数据清洗、过滤、合成与质量评估", ["数据精炼", "数据过滤", "文本数据合成", "超级过滤"]),
    item("资产管理", "镜像资产", "镜像仓库", "镜像仓库管理", "公共/自定义/多芯片镜像仓库与同步", ["镜像仓库", "公共镜像", "自定义镜像", "多芯片镜像"]),
    item("资产管理", "知识库资产", "知识库", "知识库文档管理", "知识库文档上传、解析与切片管理", ["知识库", "文档", "切片"]),
    item("资产管理", "应用资产", "应用管理", "应用与API Key", "推理应用创建、环境隔离与 API Key 管理", ["创建应用", "API Key", "我的应用"]),
    item("资产管理", "协作空间", "空间管理", "工作空间管理", "团队空间创建、成员与审批", ["空间管理", "创建空间", "申请加入空间", "空间人员"]),
    item("资产管理", "协作空间", "子系统", "子系统与租户边界", "子系统/租户作为资源与协作管理边界", ["子系统", "租户", "命名空间"]),
    # ===== 算力调度 =====
    item("算力调度", "资源纳管", "集群节点", "集群与节点纳管", "计算节点/服务器/虚机统一纳管", ["节点纳管", "服务器纳管", "集群/节点纳管", "虚机纳管"]),
    item("算力调度", "资源纳管", "资源池", "资源池划分", "按业务/部门划分资源池与节点池", ["资源池", "节点池", "资源池划分", "资源池增"]),
    item("算力调度", "资源纳管", "异构算力", "异构算力适配", "NPU/GPU/CPU 异构算力统一调度", ["异构", "算力卡", "NPU", "GPU"]),
    item("算力调度", "调度策略", "作业调度", "AI作业调度", "训练/推理作业统一调度与排队", ["作业调度", "任务队列", "MindCluster 作业", "AI 分布式"]),
    item("算力调度", "调度策略", " gang调度", "Gang整组调度", "All-or-Nothing 整组资源分配", ["Gang", "PodGroup", "整组调度"]),
    item("算力调度", "调度策略", "优先级", "优先级与抢占", "PriorityClass 优先级与抢占调度", ["优先级", "PriorityClass", "抢占", "Preempt"]),
    item("算力调度", "调度策略", "公平调度", "公平共享DRF", "多租户 DRF/公平共享调度", ["DRF", "公平共享", "公平调度"]),
    item("算力调度", "调度策略", "拓扑亲和", "拓扑感知调度", "NVLink/RDMA/NUMA 拓扑亲和放置", ["拓扑", "NUMA", "拓扑感知", "NPU 拓扑"]),
    item("算力调度", "调度策略", "装箱优化", "装箱与回填", "Binpack 装箱与 Backfill 回填提升利用率", ["装箱", "Binpack", "回填", "Backfill"]),
    item("算力调度", "调度策略", "潮汐混部", "潮汐混部错峰", "按时段潮汐调度与混部错峰", ["潮汐", "混部", "错峰"]),
    item("算力调度", "虚拟化", "算力切分", "vNPU/显存切分", "vNPU、显存/算力软切分与多任务共享", ["vNPU", "显存切分", "算力切分", "vCANN", "软切分"]),
    item("算力调度", "虚拟化", "隔离", "多租户资源隔离", "MIG/虚拟化隔离与多租户硬隔离", ["MIG", "虚拟化隔离", "多租户隔离", "算力资源隔离"]),
    item("算力调度", "配额管理", "层级配额", "层级配额管理", "部门/项目/空间多级配额与限流", ["层级配额", "配额管理", "租户配额"]),
    item("算力调度", "配额管理", "超配借用", "超配与借用", "资源超配、借用与跨队列回收", ["超配", "借用", "Reclaim", "跨队列"]),
    item("算力调度", "弹性", "训练弹性", "训练作业弹性", "训练作业弹性扩缩与故障重调度", ["训练弹性", "重调度", "任务重调度"]),
    item("算力调度", "弹性", "推理弹性", "推理PD分离扩缩", "Prefill/Decode 分离与动态扩缩", ["PD 分离", "PD分离", "动态扩缩"]),
    # ===== 权限管理 =====
    item("权限管理", "租户与配额", "租户", "租户生命周期", "租户创建、禁用、删除与配置", ["租户增", "租户管理", "租户开通", "iData租户"]),
    item("权限管理", "租户与配额", "配额", "租户配额管理", "租户级算力/存储/API 配额", ["租户配额", "配额管理", "层级配额"]),
    item("权限管理", "租户与配额", "命名空间", "命名空间隔离", "K8s 命名空间/逻辑隔离域管理", ["命名空间"]),
    item("权限管理", "认证鉴权", "统一认证", "OAuth/IAM认证", "OAuth2/OIDC/IAM Token 统一认证", ["OAuth", "IAM", "token认证", "OAuth 认证"]),
    item("权限管理", "认证鉴权", "API访问", "API Key管理", "应用级 API Key 签发、轮换与吊销", ["API Key", "API-KEY", "获取 API Key"]),
    item("权限管理", "用户角色", "RBAC", "用户与角色管理", "用户、角色、权限组 RBAC 管理", ["用户管理", "角色权限", "角色", "RBAC"]),
    item("权限管理", "用户角色", "成员协作", "成员与审批", "空间/子系统成员邀请、权限变更与审批", ["成员管理", "申请子系统", "审批", "管理员审批"]),
    item("权限管理", "审计合规", "操作审计", "操作记录审计", "关键操作全链路审计与追溯", ["操作记录审计", "审计", "操作审计"]),
    item("权限管理", "审计合规", "安全合规", "内容安全审核", "模型输入输出安全审核与合规拦截", ["安全大模型", "Qwen3Guard", "内容安全"]),
    # ===== 指标监控 =====
    item("指标监控", "资源指标", "算力资源", "NPU/GPU利用率监控", "算力卡利用率、显存、温度、功耗采集", ["利用率", "显存", "NPU", "Exporter", "温度", "功耗"]),
    item("指标监控", "资源指标", "集群资源", "集群资源可视化", "集群/资源池/租户资源用量大盘", ["资源可视", "资源统计", "集群资源汇总", "计算集群资源"]),
    item("指标监控", "业务指标", "推理监控", "推理服务监控", "推理 QPS、延迟、错误率、Token 吞吐", ["推理监控", "调用量", "推理可观测", "EagleEye"]),
    item("指标监控", "业务指标", "训练监控", "训练任务监控", "训练 loss、step、吞吐与资源曲线", ["训练任务监控", "训练监控", "作业流程"]),
    item("指标监控", "告警日志", "告警", "异常告警", "阈值告警、事件告警与通知渠道", ["异常告警", "告警", "上报告警"]),
    item("指标监控", "告警日志", "日志", "日志采集与查询", "平台/作业/节点日志集中采集与检索", ["日志管理", "日志查看", "节点日志"]),
    item("指标监控", "成本计量", "计量", "算力卡时计量", "按卡时/Token/调用量计量计费", ["卡时计量", "话单", "计量", "计费"]),
    item("指标监控", "成本计量", "成本", "成本分析报表", "按租户/项目/模型成本分摊报表", ["成本报表", "成本", "资源使用统计"]),
    item("指标监控", "性能测试", "压测", "性能基准压测", "算力/带宽/网络压测与报告", ["压测", "性能测试", "带宽", "算力测试"]),
    # ===== 运维 =====
    item("运维", "集群部署", "安装部署", "集群批量部署", "K8s/MindCluster 批量装机与组件部署", ["ascend-deployer", "批量部署", "Kubernetes 集群", "集群部署"]),
    item("运维", "集群部署", "Helm交付", "Helm/Chart部署", "推理/训练组件 Helm Chart 一键部署", ["Helm", "Chart", "InferNex", "LLM-IF-Deployer"]),
    item("运维", "集群部署", "升级变更", "版本升级与变更", "平台/组件版本升级与变更窗口", ["版本升级", "升级", "变更"]),
    item("运维", "故障处置", "故障感知", "节点故障感知", "NodeAgent/CES 故障检测与告警上报", ["NodeAgent", "CES Agent", "故障感知", "故障检测"]),
    item("运维", "故障处置", "故障隔离", "故障节点隔离", "故障域隔离、节点剔除与流量切换", ["故障隔离", "节点剔除", "隔离", "故障节点"]),
    item("运维", "故障处置", "训练快恢", "训练故障快恢", "训练进程级/TaskD 故障恢复与重算控制", ["训练故障", "TaskD", "快恢", "重计算"]),
    item("运维", "故障处置", "推理快恢", "推理故障快恢", "推理服务故障自动重启与副本迁移", ["推理故障", "推理快恢", "路由容灾"]),
    item("运维", "故障处置", "断点续训运维", "Checkpoint运维", "临终 CKPT、ACP 加速与 CKPT 管理", ["MindIO", "Checkpoint", "临终 CKPT", "ACP"]),
    item("运维", "日常运维", "应用运维", "推理应用运维", "服务域名映射、端口、运维看板", ["应用运维", "域名端口", "一域名多服务"]),
    item("运维", "日常运维", "实例运维", "开发实例运维", "Notebook/实例自动关机、回收与持久化", ["自动关机", "持久化", "申请实例", "无卡"]),
    item("运维", "性能诊断", "兼容性", "硬件兼容性检查", "Atlas/NPU 兼容性预检与认证", ["兼容性检查", "Atlas", "DMI", "Ascend Cert"]),
    item("运维", "性能诊断", "诊断压测", "NPU性能诊断", "NPU/网络/集群性能诊断与压测", ["性能诊断", "NPU性能", "带宽/算力"]),
    item("运维", "可观测", "集群监控", "集群健康监控", "集群组件健康、孤儿任务清理", ["健康检测", "孤儿任务", "健康状态"]),
    item("运维", "一体机", "边缘部署", "一体机/无K8s部署", "一体机或边缘场景无 K8s 部署与恢复", ["一体机", "无 K8s", "边缘"]),
]

# fix typo in gang调度 key - space in l2
for c in CANONICAL:
    c["L2"] = c["L2"].replace(" gang调度", "Gang调度")


def norm(s: str) -> str:
    return re.sub(r"[\s\-_/（）()]", "", str(s).strip().lower())


def load_platform(path: Path, sheet: str) -> pd.DataFrame:
    df = pd.read_excel(path, sheet_name=sheet, header=1)
    cols = list(df.columns)
    rename = {cols[0]: "L1", cols[1]: "L2", cols[2]: "L3", cols[3]: "L4"}
    if len(cols) > 4:
        rename[cols[4]] = "功能描述"
    df = df.rename(columns=rename)
    for c in ["L1", "L2", "L3"]:
        if c in df.columns:
            df[c] = df[c].ffill()
    df = df[df["L4"].notna()].copy()
    df["功能描述"] = df.get("功能描述", pd.Series([""] * len(df))).fillna("")
    df["平台"] = sheet
    return df


def score_row(kw_list: list[str], row: pd.Series) -> int:
    text = norm(f"{row['L1']}{row['L2']}{row['L3']}{row['L4']}{row['功能描述']}")
    l4 = norm(row["L4"])
    score = 0
    for kw in kw_list:
        k = norm(kw)
        if not k:
            continue
        if k == l4:
            score += 20
        elif k in l4 or l4 in k:
            score += 12
        elif k in text:
            score += 4
    return score


def match_platforms(canonical: dict, platform_data: dict[str, pd.DataFrame], threshold: int = 10) -> dict[str, str]:
    out = {}
    for plat in PLATFORMS:
        df = platform_data[plat]
        best_score = 0
        matches = []
        for _, row in df.iterrows():
            s = score_row(canonical["kw"], row)
            if s >= threshold:
                matches.append((s, str(row["L4"]).strip()))
        matches.sort(key=lambda x: (-x[0], x[1]))
        seen = set()
        picked = []
        for s, l4 in matches:
            if l4 in seen:
                continue
            seen.add(l4)
            picked.append(l4)
            if len(picked) >= 3:
                break
        out[plat] = "；".join(picked) if picked else ""
    return out


def estimate_workload(desc: str, l4: str, matched: str) -> tuple[float, float]:
    text = (desc or "") + (l4 or "") + (matched or "")
    n = len(text)
    plat_count = matched.count("；") + (1 if matched else 0)
    base = 0.3
    if n > 120 or any(k in text for k in ("分布式", "流水线", "多租户", "RLHF", "PD分离")):
        base = 2.0
    elif n > 60 or any(k in text for k in ("调度", "编排", "监控", "部署", "对接")):
        base = 1.0
    elif n > 30:
        base = 0.5
    if not matched:
        base = round(base * 1.3, 2)  # 无平台参考，估算略增
    elif plat_count >= 3:
        base = round(base * 0.85, 2)
    test = round(base * 0.4, 2)
    return base, test


def estimate_phase(l1: str, l2: str, l3: str, l4: str, desc: str) -> int:
    text = f"{l1}{l2}{l3}{l4}{desc}"
    if PHASE3_KW.search(text):
        return 3
    if PHASE2_KW.search(text):
        return 2
    if l1 in ("算力调度", "运维") and PHASE1_KW.search(text):
        return 2
    if PHASE1_KW.search(text):
        return 1
    return 2


def row_phase_hint(phase: int, l1: str, l2: str, l4: str, desc: str) -> str:
    text = f"{l1}{l2}{l4}{desc}"
    if phase == 1:
        if l1 in ("模型推理", "模型训练", "资产管理"):
            return f"阶段①核心链路：{l2}——{l4}"
        return f"阶段①基础能力：{l1}——{l4}"
    if phase == 3:
        return f"阶段③高阶能力：{l1}——{l4}"
    if l1 in ("算力调度", "运维"):
        return f"阶段②规模化：{l2}——{l4}"
    if l1 in ("权限管理", "指标监控"):
        return f"阶段②平台增强：{l1}——{l4}"
    return f"阶段②增强能力：{l2}——{l4}"


def blank_hierarchy(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    for col, parents in [("L1", []), ("L2", ["L1"]), ("L3", ["L1", "L2"])]:
        prev = None
        for i in out.index:
            key = tuple(str(out.at[i, p]) for p in parents + [col])
            if key == prev:
                out.at[i, col] = ""
            else:
                prev = key
    return out


def merge_cells(ws, df: pd.DataFrame, header_row: int = 1) -> None:
    n = len(df)
    start = header_row + 1
    if n <= 1:
        return

    def merge_col(letter: str, keys: pd.Series) -> None:
        i = 0
        while i < n:
            j = i + 1
            while j < n and keys.iloc[j] == keys.iloc[i]:
                j += 1
            if j - i > 1:
                ws.merge_cells(f"{letter}{start + i}:{letter}{start + j - 1}")
            i = j

    merge_col("A", df["L1"].astype(str))
    merge_col("B", df["L1"].astype(str) + "\0" + df["L2"].astype(str))
    merge_col("C", df["L1"].astype(str) + "\0" + df["L2"].astype(str) + "\0" + df["L3"].astype(str))


def style_sheet(ws, header_row: int = 1) -> None:
    fill = PatternFill("solid", fgColor="B4C7E7")
    font = Font(bold=True)
    center = Alignment(horizontal="center", vertical="center", wrap_text=True)
    thin = Side(style="thin", color="B4B4B4")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    for c in range(1, ws.max_column + 1):
        cell = ws.cell(header_row, c)
        cell.fill = fill
        cell.font = font
        cell.alignment = center
    for r in range(header_row, ws.max_row + 1):
        for c in range(1, ws.max_column + 1):
            ws.cell(r, c).alignment = center
            ws.cell(r, c).border = border
    widths = {
        "A": 12, "B": 14, "C": 14, "D": 22, "E": 40,
        "F": 18, "G": 18, "H": 18, "I": 18, "J": 18,
        "K": 10, "L": 10, "M": 10, "N": 8, "O": 32,
    }
    for letter, w in widths.items():
        ws.column_dimensions[letter].width = w


def main():
    platform_data = {p: load_platform(INPUT, p) for p in PLATFORMS}

    rows = []
    for c in CANONICAL:
        plat_map = match_platforms(c, platform_data)
        matched_text = " ".join(plat_map.values())
        dev, test = estimate_workload(c["功能描述"], c["L4"], matched_text)
        phase = estimate_phase(c["L1"], c["L2"], c["L3"], c["L4"], c["功能描述"])
        cover = sum(1 for p in PLATFORMS if plat_map[p])
        rows.append(
            {
                "L1": c["L1"],
                "L2": c["L2"],
                "L3": c["L3"],
                "L4": c["L4"],
                "功能描述": c["功能描述"],
                **{f"{p}对应": plat_map[p] for p in PLATFORMS},
                "平台覆盖数": cover,
                "开发工作量(人月)": dev,
                "测试工作量(人月)": test,
                "总工作量(人月)": round(dev + test, 2),
                "阶段": f"阶段{phase}",
                "阶段说明": row_phase_hint(phase, c["L1"], c["L2"], c["L4"], c["功能描述"]),
            }
        )

    df = pd.DataFrame(rows)

    # 汇总 sheet
    l1_summary = []
    for l1, g in df.groupby("L1", sort=False):
        l1_summary.append(
            {
                "L1": l1,
                "设计功能点": len(g),
                "有平台参考": len(g[g["平台覆盖数"] > 0]),
                "无平台参考": len(g[g["平台覆盖数"] == 0]),
                "招行覆盖": len(g[g["招行对应"] != ""]),
                "openfuyao覆盖": len(g[g["openfuyao对应"] != ""]),
                "MM覆盖": len(g[g["MM对应"] != ""]),
                "MA覆盖": len(g[g["MA对应"] != ""]),
                "MindCluster覆盖": len(g[g["MindCluster对应"] != ""]),
                "总工作量(人月)": round(g["总工作量(人月)"].sum(), 1),
            }
        )
    summary_df = pd.DataFrame(l1_summary)

    gap_df = df[df["平台覆盖数"] == 0][["L1", "L2", "L3", "L4", "功能描述", "总工作量(人月)", "阶段"]]

    display = blank_hierarchy(df)
    with pd.ExcelWriter(OUTPUT, engine="openpyxl") as writer:
        display.to_excel(writer, sheet_name="功能设计总表", index=False)
        ws = writer.sheets["功能设计总表"]
        style_sheet(ws)
        merge_cells(ws, df)

        summary_df.to_excel(writer, sheet_name="L1覆盖汇总", index=False)
        style_sheet(writer.sheets["L1覆盖汇总"])

        gap_df.to_excel(writer, sheet_name="无平台参考项", index=False)
        style_sheet(writer.sheets["无平台参考项"])

        # 阶段汇总
        phase_sum = (
            df.groupby("阶段")
            .agg(功能点=("L4", "count"), 总工作量=("总工作量(人月)", "sum"))
            .reset_index()
            .round(1)
        )
        phase_sum.to_excel(writer, sheet_name="阶段汇总", index=False)
        style_sheet(writer.sheets["阶段汇总"])

    print(f"Written: {OUTPUT}")
    print(f"设计功能点: {len(df)}")
    print(summary_df.to_string(index=False))
    print(f"\n无平台参考: {len(gap_df)} 项")


if __name__ == "__main__":
    main()
