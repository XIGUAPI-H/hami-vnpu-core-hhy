#!/bin/bash
# Prerequisites for the Qwen3-TTS 1cut4/1cut20 compute-only A/B on 68.
FT=/mnt/local/m00953550/FinalTest
KY="$FT/kylin"
echo "=== image"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -i 'vllm-omni' || echo MISSING_IMAGE
echo "=== model + reference audio"
ls -d /mnt/project/mhw/smallModels/models/models/Qwen3-TTS-12Hz-1.7B-Base 2>&1
ls -la /mnt/project/mhw/smallModels/zh.wav 2>&1
echo "=== bench + yaml + prepare script"
ls -la /mnt/local/m00953550/benchmark_qwen3_tts_http.py \
       /mnt/local/m00953550/qwen3-tts-omni-job-bench.yaml \
       "$KY/smallmodel_ab/robust_qwen/prepare_qwen_config.py" 2>&1
echo "=== already-prepared config (entrypoint)"
ls -la "$KY/smallmodel_ab/qwen_cut4_20/config/entrypoint.sh" 2>&1
echo "=== past qwen cut4_20 reports"
ls -t "$KY/smallmodel_ab/qwen_cut4_20/report_"*.txt 2>/dev/null | head -3
for r in $(ls -t "$KY/smallmodel_ab/qwen_cut4_20/report_"*.txt 2>/dev/null | head -1); do echo "--- $r"; cat "$r"; done
echo "=== port 18091 free?"
curl -sf -m 3 http://127.0.0.1:18091/v1/models >/dev/null 2>&1 && echo IN_USE || echo free
echo "=== npu4 hbm"
npu-smi info | grep -A1 '| 4 ' | head -4
