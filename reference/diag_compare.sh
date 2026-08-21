#!/bin/bash
# Run diag on both nodes (this script lives on 61).
cp /tmp/diag_node.sh /tmp/diag.local.sh
chmod +x /tmp/diag.local.sh

echo '======== 61 ========' > /tmp/diag61.txt
bash /tmp/diag.local.sh 61 >> /tmp/diag61.txt 2>&1

# Copy & run on 68.
scp -o BatchMode=yes -o StrictHostKeyChecking=no /tmp/diag.local.sh root@10.143.2.68:/tmp/diag.local.sh >/dev/null
echo '======== 68 ========' > /tmp/diag68.txt
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@10.143.2.68 'bash /tmp/diag.local.sh 68' >> /tmp/diag68.txt 2>&1

# Print side-by-side.
diff -u /tmp/diag61.txt /tmp/diag68.txt > /tmp/diag.diff 2>&1
echo '################ 61 OUTPUT ################'
cat /tmp/diag61.txt
echo
echo '################ 68 OUTPUT ################'
cat /tmp/diag68.txt
echo
echo '################ DIFF (61 vs 68) ################'
cat /tmp/diag.diff
