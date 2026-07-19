<#
.SYNOPSIS
    Run full diskspd benchmark comparison between master and patched drivers.

.DESCRIPTION
    Installs each driver, runs the full benchmark suite, and produces a comparison report.
    Equivalent to the fio-full-comparison.ps1 but using diskspd with IoMeter-style parameters.

.PARAMETER Disk
    Target path for benchmarking (e.g., "D:\testfile.dat")

.PARAMETER Driver
    Driver type: "viostor" or "vioscsi"

.PARAMETER Duration
    Test duration per combination in seconds (default: 60)

.PARAMETER Warmup
    Warmup in seconds (default: 30)

.PARAMETER QuickMode
    Use shortened timings for validation (30s test, 10s warmup)
#>
param(
    [string]$Disk = "#1",
    [string]$Driver = "viostor",
    [int]$Duration = 60,
    [int]$Warmup = 30,
    [switch]$QuickMode,
    [switch]$SkipIsrDpc
)

if ($QuickMode) {
    $Duration = 30
    $Warmup = 10
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputBase = "C:\benchmark-results\comparison-$timestamp"

Write-Host "=" * 70
Write-Host "DISKSPD FULL DRIVER COMPARISON"
Write-Host "=" * 70
Write-Host "Driver:    $Driver"
Write-Host "Disk:      $Disk"
Write-Host "Duration:  ${Duration}s + ${Warmup}s warmup per test"
Write-Host "Mode:      $(if ($QuickMode) { 'QUICK (validation)' } else { 'FULL (production)' })"
Write-Host "Output:    $outputBase"
Write-Host "=" * 70
Write-Host ""

$drivers = @("master", "new", "new-multi-iterate")

foreach ($drv in $drivers) {
    Write-Host ""
    Write-Host ("#" * 70)
    Write-Host "DRIVER: $drv"
    Write-Host ("#" * 70)
    Write-Host ""

    # Switch driver
    $switchArgs = @{ Action = $drv }
    if ($Driver -ne "viostor") { $switchArgs.Driver = $Driver }
    & C:\switch-driver.ps1 @switchArgs

    # Run benchmark (both writes and reads)
    $drvOutput = Join-Path $outputBase $drv
    & C:\diskspd-benchmark.ps1 `
        -Disk $Disk `
        -OutputDir $drvOutput `
        -Duration $Duration `
        -Warmup $Warmup `
        -SkipIsrDpc:$SkipIsrDpc
}

# Generate comparison
Write-Host ""
Write-Host "=" * 70
Write-Host "GENERATING COMPARISON REPORT"
Write-Host "=" * 70

$masterCsv = Get-ChildItem (Join-Path $outputBase "master") -Filter "summary.csv" -Recurse | Select-Object -First 1
$newCsv = Get-ChildItem (Join-Path $outputBase "new") -Filter "summary.csv" -Recurse | Select-Object -First 1
$iterateCsv = Get-ChildItem (Join-Path $outputBase "new-multi-iterate") -Filter "summary.csv" -Recurse | Select-Object -First 1

if ($masterCsv -and $newCsv) {
    $masterData = Import-Csv $masterCsv.FullName
    $newData = Import-Csv $newCsv.FullName
    $iterateData = if ($iterateCsv) { Import-Csv $iterateCsv.FullName } else { $null }

    $comparison = @()
    for ($i = 0; $i -lt $masterData.Count; $i++) {
        $m = $masterData[$i]
        $n = $newData[$i]

        $newDelta = if ([double]$m.IOPS_Avg -gt 0) {
            [math]::Round(([double]$n.IOPS_Avg - [double]$m.IOPS_Avg) / [double]$m.IOPS_Avg * 100, 1)
        } else { 0 }

        $row = [ordered]@{
            Test         = $m.TestNum
            BlockSize    = $m.BlockSize
            QueueDepth   = $m.QueueDepth
            Pattern      = if ($m.WritePercent -eq "100") { "write" } else { "read" }
            Master_IOPS  = $m.IOPS_Avg
            New_IOPS     = $n.IOPS_Avg
            New_Delta    = "${newDelta}%"
            Master_CPU   = $m.CPU_Avg
            New_CPU      = $n.CPU_Avg
        }

        if ($iterateData) {
            $it = $iterateData[$i]
            $itDelta = if ([double]$m.IOPS_Avg -gt 0) {
                [math]::Round(([double]$it.IOPS_Avg - [double]$m.IOPS_Avg) / [double]$m.IOPS_Avg * 100, 1)
            } else { 0 }
            $row.Iterate_IOPS = $it.IOPS_Avg
            $row.Iterate_Delta = "${itDelta}%"
            $row.Iterate_CPU = $it.CPU_Avg
        }

        $comparison += [PSCustomObject]$row
    }

    $reportPath = Join-Path $outputBase "comparison-report.csv"
    $comparison | Export-Csv $reportPath -NoTypeInformation
    Write-Host "Comparison saved: $reportPath"

    # Print top improvements and regressions (new vs master)
    $sorted = $comparison | Sort-Object { [double]($_.New_Delta -replace '%','') } -Descending

    Write-Host ""
    Write-Host "TOP 5 IMPROVEMENTS (new vs master):"
    $sorted | Select-Object -First 5 | Format-Table Test, BlockSize, QueueDepth, Pattern, Master_IOPS, New_IOPS, New_Delta -AutoSize

    Write-Host "TOP 5 REGRESSIONS (new vs master):"
    $sorted | Select-Object -Last 5 | Format-Table Test, BlockSize, QueueDepth, Pattern, Master_IOPS, New_IOPS, New_Delta -AutoSize
}

Write-Host ""
Write-Host "=" * 70
Write-Host "COMPARISON COMPLETE: $outputBase"
Write-Host "=" * 70
