#!/bin/bash
docker run --rm quay.io/ascend/vllm-ascend:v0.13.0rc1 bash -c '
SO=/usr/local/python3.11.13/lib/python3.11/site-packages/torch_npu/lib/libtorch_npu.so
strings "$SO" | grep -i halGet | sort -u
echo "---"
strings "$SO" | grep -i total_mem | sort -u
echo "---"
strings "$SO" | grep -i DeviceProp | sort -u | head -20
'
