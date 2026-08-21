#!/usr/bin/env bash
set -euo pipefail
FT=/mnt/local/m00953550/FinalTest/kylin
PY=$FT/vllm-extract/python3.11.13/bin/python3
docker run --rm kylin-server:v11-2503-arm64 -v $FT/vllm-extract/python3.11.13:/opt/py:ro $PY --version 2>&1 || true
