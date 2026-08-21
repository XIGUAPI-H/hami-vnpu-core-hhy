#!/usr/bin/env python3
import sys, shutil, re

path = "/mnt/local/m00953550/FinalTest/hamiJobVllm.yaml"
bak  = path + ".bak"
shutil.copyfile(path, bak)

with open(path, "r", encoding="utf-8") as f:
    src = f.read()

repls = [
    (r"--gpu-memory-utilization 0\.5",        "--gpu-memory-utilization 0.9"),
    (r"--max-num-seqs 4\b",                   "--max-num-seqs 16"),
    (r"--max_model_len 4096",                 "--max_model_len 32768"),
    (r"--max-num-batched-tokens 4096",        "--max-num-batched-tokens 40960"),
    (r'cudagraph_capture_sizes":\[1,2,4,8,16\]',
                                              'cudagraph_capture_sizes":[1]'),
]
for pat, rep in repls:
    new = re.sub(pat, rep, src)
    if new == src:
        sys.stderr.write(f"WARN: no match for {pat}\n")
    src = new

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("PATCHED")
