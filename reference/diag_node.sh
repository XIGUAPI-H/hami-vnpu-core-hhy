#!/bin/bash
# Diagnostic snapshot of a node's CANN/Ascend toolchain & hami env.
# Args: $1 = label (e.g. "61" or "68")
LABEL=${1:-?}
echo "################ $LABEL ################"

echo '--- driver / dcmi / npu-smi paths & versions ---'
ls -la /usr/local/Ascend/driver/version.info 2>/dev/null && head -3 /usr/local/Ascend/driver/version.info
echo
echo 'dcmi files:'
ls -la /usr/local/dcmi/ 2>&1 | head -10
echo
echo 'toolbox files:'
ls -la /usr/local/Ascend/toolbox/ 2>&1 | head -10
echo
echo 'ascend-toolkit (latest):'
ls -la /usr/local/Ascend/ascend-toolkit/latest 2>&1 | head -5
cat /usr/local/Ascend/ascend-toolkit/latest/version.cfg 2>/dev/null

echo
echo '--- container runtime image sha ---'
(crictl images 2>/dev/null || docker images 2>/dev/null) | grep -E 'vllm-ascend|ascend.*vllm' | head -5

echo
echo '--- hami device-plugin pod env / config ---'
HAMI_POD=$(kubectl get pods -A -o name 2>/dev/null | grep hami-ascend-device-plugin | head -1)
echo "hami-pod=$HAMI_POD"
[ -n "$HAMI_POD" ] && kubectl describe $HAMI_POD 2>/dev/null | grep -E 'Image:|Memory|memory|cores|--|Args:|Command:|env|GLOBAL_MEMORY|VIRT' | head -30
echo
echo '--- hami scheduler config map (truncated) ---'
kubectl get cm -A 2>/dev/null | grep -i hami
echo
echo '--- hami-scheduler args ---'
kubectl get pods -n kube-system -o name 2>/dev/null | grep hami-scheduler | head -1 | xargs -I{} kubectl get {} -n kube-system -o jsonpath='{.spec.containers[*].args}' 2>/dev/null
echo

echo '--- node Ascend910B3 allocatable resources ---'
kubectl get nodes -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for n in data["items"]:
    nm = n["metadata"]["name"]
    cap = n.get("status",{}).get("allocatable",{})
    keep = {k:v for k,v in cap.items() if "Ascend" in k or "huawei" in k}
    if keep:
        print(f"{nm}: {keep}")
'

echo
echo '--- ascend kernel modules ---'
lsmod | grep -E 'davinci|ascend' | head -10

echo
echo '--- expandable_segments env (hostpath /etc/profile.d & global) ---'
grep -rh PYTORCH_NPU_ALLOC_CONF /etc/profile.d/ /etc/environment 2>/dev/null | head -5

echo
echo '--- HCCL_BUFFSIZE / runtime tunings (host-level) ---'
grep -rhE 'HCCL_|ASCEND_RT_|PYTORCH_NPU|ACL_OP_' /etc/profile.d/ /etc/environment 2>/dev/null | head -10
