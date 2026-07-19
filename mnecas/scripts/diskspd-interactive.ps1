$DiskSpdPath = "C:\DiskSpd\diskspd.exe"
$Disk = "#2"
$Duration = 60
$Warmup = 60
$Threads = 4

$blockSizes = @("512", "4K", "16K", "64K", "256K", "1M", "2M")
$qds = @(16, 32, 64, 128, 256)

$startTime = Get-Date
Write-Host "=============================================="
Write-Host " DiskSpd Full Test - 4 vCPU, 4 queues"
Write-Host " INTERACTIVE SESSION"
Write-Host " Disk: $Disk | Duration: ${Duration}s | Warmup: ${Warmup}s"
Write-Host " Started: $startTime"
Write-Host "=============================================="
Write-Host ""

Write-Host "=== WRITE TESTS ==="
Write-Host ""

foreach ($bs in $blockSizes) {
    foreach ($qd in $qds) {
        $perThread = [math]::Ceiling($qd / $Threads)
        $label = "${bs}-QD${qd}-write"

        Write-Host "--- $label (t=$Threads, o=$perThread) --- $(Get-Date -Format 'HH:mm:ss')"

        $argList = "-c2G -d$Duration -W$Warmup -t$Threads -o$perThread -b$bs -w100 -r -L -Sh `"$Disk`""
        $proc = Start-Process -FilePath $DiskSpdPath -ArgumentList $argList -NoNewWindow -Wait -PassThru -RedirectStandardOutput "C:\diskspd-out.txt" -RedirectStandardError "C:\diskspd-err.txt"
        $output = Get-Content "C:\diskspd-out.txt"

        $totalLines = @($output | Where-Object { $_ -match "^\s*total" -and $_ -match "\|" -and $_ -match "[1-9]" })
        $cpuLines = @($output | Where-Object { $_ -match "^\s*avg\." })

        if ($totalLines.Count -gt 0) {
            Write-Host "  IO:  $($totalLines[0].Trim())"
        }
        if ($cpuLines.Count -gt 0) {
            Write-Host "  CPU: $($cpuLines[-1].Trim())"
        }
        Write-Host ""
    }
}

Write-Host "=== READ TESTS ==="
Write-Host ""

foreach ($bs in $blockSizes) {
    foreach ($qd in $qds) {
        $perThread = [math]::Ceiling($qd / $Threads)
        $label = "${bs}-QD${qd}-read"

        Write-Host "--- $label (t=$Threads, o=$perThread) --- $(Get-Date -Format 'HH:mm:ss')"

        $argList = "-c2G -d$Duration -W$Warmup -t$Threads -o$perThread -b$bs -w0 -r -L -Sh `"$Disk`""
        $proc = Start-Process -FilePath $DiskSpdPath -ArgumentList $argList -NoNewWindow -Wait -PassThru -RedirectStandardOutput "C:\diskspd-out.txt" -RedirectStandardError "C:\diskspd-err.txt"
        $output = Get-Content "C:\diskspd-out.txt"

        $totalLines = @($output | Where-Object { $_ -match "^\s*total" -and $_ -match "\|" -and $_ -match "[1-9]" })
        $cpuLines = @($output | Where-Object { $_ -match "^\s*avg\." })

        if ($totalLines.Count -gt 0) {
            Write-Host "  IO:  $($totalLines[0].Trim())"
        }
        if ($cpuLines.Count -gt 0) {
            Write-Host "  CPU: $($cpuLines[-1].Trim())"
        }
        Write-Host ""
    }
}

$endTime = Get-Date
$elapsed = $endTime - $startTime
Write-Host "=============================================="
Write-Host " Completed: $endTime"
Write-Host " Total time: $($elapsed.TotalHours.ToString('F1')) hours"
Write-Host "=============================================="
