#!/bin/bash
echo '################ Node 61 ################'
echo '--- ascend driver ---'
cat /usr/local/Ascend/driver/version.info 2>/dev/null || echo NA
echo '--- ascend toolbox/CANN ---'
cat /usr/local/Ascend/ascend-toolkit/latest/version.cfg 2>/dev/null | head -5 || ls /usr/local/Ascend/ 2>/dev/null
echo '--- kernel ---'
uname -r
echo '--- npu-smi info -t common ---'
npu-smi info -t common -i 0 2>&1 | head -25
echo
echo '################ Node 68 (via ssh) ################'
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash -s' <<'EOF'
echo '--- ascend driver ---'
cat /usr/local/Ascend/driver/version.info 2>/dev/null || echo NA
echo '--- ascend toolbox/CANN ---'
cat /usr/local/Ascend/ascend-toolkit/latest/version.cfg 2>/dev/null | head -5 || ls /usr/local/Ascend/ 2>/dev/null
echo '--- kernel ---'
uname -r
echo '--- npu-smi info -t common ---'
npu-smi info -t common -i 0 2>&1 | head -25
EOF
