#!/usr/bin/env bash
# Pure-python packages from vllm-ascend image -> py-extra (safe for py3.10).
set -euo pipefail
OE="/mnt/local/m00953550/FinalTest/openeuler"
IMG="quay.io/ascend/vllm-ascend:v0.13.0rc1"
SP="/usr/local/python3.11.13/lib/python3.11/site-packages"
DEST="${OE}/py-extra"
rm -rf "$DEST"
mkdir -p "$DEST"

list=$(docker run --rm "$IMG" python3.11 -c "
import os, site
sp='$SP'
skip={'torch','torch_npu','numpy','vllm','vllm_ascend','torchvision','torchaudio','triton'}
for name in sorted(os.listdir(sp)):
    path=os.path.join(sp,name)
    if not os.path.isdir(path) or name.endswith('.dist-info') or name in skip:
        continue
    if any(f.endswith('.so') for r,_,fs in os.walk(path) for f in fs):
        continue
    print(name)
")

cid=$(docker create "$IMG")
for name in $list; do
  docker cp "${cid}:${SP}/${name}" "${DEST}/" 2>/dev/null || true
  docker cp "${cid}:${SP}/${name}"*.dist-info "${DEST}/" 2>/dev/null || true
done
# dist-info for listed packages
for name in $list; do
  for d in $(docker run --rm "$IMG" ls "$SP" | grep "^${name}-.*dist-info"); do
    docker cp "${cid}:${SP}/${d}" "${DEST}/" 2>/dev/null || true
  done
done
docker rm "$cid" >/dev/null
echo "py-extra pure-python: $(ls "$DEST" | wc -l) entries"
