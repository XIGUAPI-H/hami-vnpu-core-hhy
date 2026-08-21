$logFile = "d:\hamisoft\hami-vnpu-core\reference\monitor_68_pod.log"
$sshKey = "C:\Users\d00804096\.ssh\id_ed25519_cursor"
$remote = "root@10.143.2.68"
$remoteCmd = @'
POD=mhw-hami-soft-1split4-a
NS=default
echo "=== TS:$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
kubectl get pod $POD -n $NS -o jsonpath='phase={.status.phase} restarts={.status.containerStatuses[0].restartCount} age={.metadata.creationTimestamp}'
echo
kubectl logs $POD -n $NS --tail=12 2>&1
echo ---PORT---
kubectl exec $POD -n $NS -- bash -c 'netstat -tlnp 2>/dev/null | grep 8000 || echo down' 2>&1
echo ---ERR---
kubectl logs $POD -n $NS 2>&1 | grep -iE 'error|failed|oom|traceback|killed|segfault' | tail -5 || echo none
'@

while ($true) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "===== local $ts =====" | Add-Content -Path $logFile
    $out = & ssh -i $sshKey -o BatchMode=yes -o ConnectTimeout=20 $remote $remoteCmd 2>&1
    $out | Add-Content -Path $logFile
    "" | Add-Content -Path $logFile
    Start-Sleep -Seconds 60
}
