#!/bin/bash
cp /tmp/diag_hami_mode.sh /tmp/diag_h.sh
chmod +x /tmp/diag_h.sh

echo '======== 61 ========' > /tmp/h61.txt
bash /tmp/diag_h.sh 61 >> /tmp/h61.txt 2>&1

scp -o BatchMode=yes -o StrictHostKeyChecking=no /tmp/diag_h.sh root@10.143.2.68:/tmp/diag_h.sh >/dev/null
echo '======== 68 ========' > /tmp/h68.txt
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash /tmp/diag_h.sh 68' >> /tmp/h68.txt 2>&1

echo '################ 61 ################'
cat /tmp/h61.txt
echo
echo '################ 68 ################'
cat /tmp/h68.txt
