$logLocal = "d:\hamisoft\hami-vnpu-core\reference\monitor_68_snapshots.log"
$key = "C:\Users\d00804096\.ssh\id_ed25519_cursor"
$host68 = "root@10.143.2.68"
while ($true) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $snap = & ssh -i $key -o BatchMode=yes -o ConnectTimeout=20 $host68 "tail -35 /tmp/monitor_mhw_pod.log 2>/dev/null; echo '---LIVE---'; kubectl logs mhw-hami-soft-1split4-a -n default --tail=5 2>&1" 2>&1
    "`n===== $ts =====`n$snap`n" | Add-Content -Path $logLocal -Encoding utf8
    Start-Sleep -Seconds 90
}
