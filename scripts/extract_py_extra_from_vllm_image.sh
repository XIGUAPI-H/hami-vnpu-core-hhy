#!/usr/bin/env bash
set -euo pipefail
OE="/mnt/local/m00953550/FinalTest/openeuler"
SP="/usr/local/python3.11.13/lib/python3.11/site-packages"
IMG="quay.io/ascend/vllm-ascend:v0.13.0rc1"
DEST="${OE}/py-extra"
rm -rf "$DEST"
mkdir -p "$DEST"
cid=$(docker create "$IMG")
mapfile -t items < <(docker run --rm "$IMG" ls "$SP" | grep -E '^(openai_harmony|llguidance|pybase64|einops|msgspec|partial_json)')
for x in "${items[@]}"; do
  docker cp "${cid}:${SP}/${x}" "${DEST}/"
done
docker rm "$cid" >/dev/null
echo "extracted: $(ls "$DEST" | wc -l) -> $DEST"
ls "$DEST"
