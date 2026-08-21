#!/bin/bash
set -euo pipefail

YAML=/mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
RELEASE=/mnt/local/m00953550/FinalTest/New/release
HAMI_CORE=/usr/local/hami-vnpu-core
NODE=b04-07-23u-at800t-node-16

echo "=== 1. Enable hami-vnpu-core on node (node-config CM) ==="
kubectl get cm hami-device-node-config -n kube-system -o yaml | \
  sed 's/hami-vnpu-core: false/hami-vnpu-core: true/' | \
  kubectl apply -f -

echo "=== 2. Enable hamiVnpuCore in device-config (soft split / vnpu-core path) ==="
kubectl get cm hami-scheduler-device -n kube-system -o yaml | \
  sed 's/hamiVnpuCore: false/hamiVnpuCore: true/' | \
  kubectl apply -f -

echo "=== 3. Sync standalone build to /usr/local/hami-vnpu-core ==="
cp -f "$RELEASE/libvnpu.so" "$RELEASE/limiter" "$HAMI_CORE/"
chmod +x "$HAMI_CORE/libvnpu.so" "$HAMI_CORE/limiter"
sha256sum "$HAMI_CORE/libvnpu.so" "$RELEASE/libvnpu.so"

echo "=== 4. Patch vLLM yaml: soft split + standalone env ==="
cp -a "$YAML" "${YAML}.bak-standalone-$(date +%Y%m%d-%H%M%S)"

python3 <<'PY'
from pathlib import Path
import re

p = Path("/mnt/local/m00953550/FinalTest/hamiNewVllm.yaml")
text = p.read_text()

# soft split annotation (HAMI soft memory/core path)
text = text.replace("huawei.com/vnpu-mode: hami-core", "huawei.com/vnpu-mode: soft")

# container env block — inject standalone vars after VLLM_PLATFORM
standalone_env = """        - name: VXPU_STANDALONE
          value: \"1\"
        - name: VXPU_MEM_LIMIT_MIB
          value: \"16000\"
        - name: VXPU_RT_RESERVE_MIB
          value: \"3072\"
        - name: VXPU_CORE_LIMIT_PERCENT
          value: \"25\"
"""
if "VXPU_STANDALONE" not in text:
    text = text.replace(
        "        - name: VLLM_PLATFORM\n          value: ascend\n",
        "        - name: VLLM_PLATFORM\n          value: ascend\n" + standalone_env,
    )

# mount hami-shared-region for limiter global registry
if "hami-shared-region" not in text:
    text = text.replace(
        "    - name: my-space\n      hostPath: { path: /mnt/local/m00953550/FinalTest/New/release}",
        "    - name: hami-shared-region\n      hostPath:\n        path: /usr/local/hami-shared-region\n        type: DirectoryOrCreate\n    - name: my-space\n      hostPath: { path: /mnt/local/m00953550/FinalTest/New/release}",
    )
if "mountPath: /hami-shared-region" not in text:
    text = text.replace(
        "        #- { name: dshm, mountPath: /hami-shared-region }",
        "        - { name: hami-shared-region, mountPath: /hami-shared-region }",
    )

p.write_text(text)
print("yaml patched")
PY

grep -n 'vnpu-mode\|VXPU_STANDALONE\|hami-shared-region' "$YAML" | head -15

echo "=== 5. Restart device-plugin on node $NODE ==="
kubectl delete pod -n kube-system -l app.kubernetes.io/component=hami-ascend-device-plugin --field-selector spec.nodeName="$NODE" --wait=true || true
sleep 5
kubectl get pods -n kube-system -l app.kubernetes.io/component=hami-ascend-device-plugin -o wide | grep "$NODE" || true

echo "=== 6. Recreate vLLM pod ==="
kubectl delete pod mhw-hami-soft-1split4-a -n default --ignore-not-found --wait=true
kubectl apply -f "$YAML"
echo "Waiting for pod..."
for i in $(seq 1 60); do
  phase=$(kubectl get pod mhw-hami-soft-1split4-a -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo Gone)
  echo "  [$i] phase=$phase"
  if [ "$phase" = "Running" ]; then break; fi
  sleep 10
done

echo "=== 7. Tail logs ==="
kubectl logs mhw-hami-soft-1split4-a -n default --tail=80 2>&1 | tail -80
