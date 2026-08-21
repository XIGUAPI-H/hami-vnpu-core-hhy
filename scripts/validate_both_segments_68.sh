#!/usr/bin/env bash
# 68 两段式验证：① openEuler 容器代理  ② vLLM + Ubuntu so
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OE="/mnt/local/m00953550/FinalTest/openeuler"

echo "########## 第一段：openEuler 容器 + Ubuntu so ##########"
bash "${OE}/validate_ubuntu_so_openeuler_proxy.sh"

echo ""
echo "########## 第二段：vLLM + Ubuntu so ##########"
bash "${OE}/verify_segment2_ubuntu_so_e2e.sh"

echo ""
echo "########## 全部完成 ##########"
