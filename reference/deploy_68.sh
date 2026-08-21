#!/bin/bash
set -u
# Copy newly-built artifacts from 61 to 68 (assumes ssh root@10.143.2.68 works from 61).
SRC=/mnt/local/build/hami-vnpu-core/target/release

# 68's hostpath dir (matches hamiNewVllm.yaml: xpu-bin -> /opt/xpu/bin and xpu-lib -> /opt/xpu/lib)
DST_HOST=10.143.2.68
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== probe 68 binary locations ==="
ssh $SSH_OPTS root@$DST_HOST 'ls -la /opt/xpu/bin/limiter /opt/xpu/lib/libvnpu.so 2>&1'

echo
echo "=== upload to /tmp on 68 as .new ==="
scp $SSH_OPTS "$SRC/libvnpu.so" root@$DST_HOST:/tmp/libvnpu.so.new
scp $SSH_OPTS "$SRC/limiter"    root@$DST_HOST:/tmp/limiter.new

echo
echo "=== install on 68 (stop pod, swap files, restart) ==="
ssh $SSH_OPTS root@$DST_HOST 'bash -s' <<'EOF'
set -u
echo "current pod:"
kubectl get pods | grep -E 'mhw-hami-soft|mhw-normal' || true

echo "=== delete existing pod/job ==="
kubectl delete -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml --ignore-not-found=true 2>&1 | head -10
sleep 4
kubectl get pods | grep -E 'mhw-hami-soft' || echo "no remaining pod"

echo
echo "=== swap binaries ==="
cp -f /tmp/limiter.new    /opt/xpu/bin/limiter
cp -f /tmp/libvnpu.so.new /opt/xpu/lib/libvnpu.so
chmod +x /opt/xpu/bin/limiter /opt/xpu/lib/libvnpu.so
ls -la /opt/xpu/bin/limiter /opt/xpu/lib/libvnpu.so
sha256sum /opt/xpu/bin/limiter /opt/xpu/lib/libvnpu.so

echo
echo "=== re-apply yaml ==="
kubectl apply -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml
EOF
