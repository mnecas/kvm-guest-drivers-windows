<#
.SYNOPSIS
    Run IoMeter benchmark comparison between master and patched drivers.

.DESCRIPTION
    For each driver: installs it, runs the full IoMeter benchmark suite, then
    produces a comparison summary CSV showing IOPS deltas across all tests.

.PARAMETER Disk
    IoMeter disk target (e.g., "PHYSICALDRIVE:1")

.PARAMETER Driver
    Driver type: "viostor" or "vioscsi"

.PARAMETER IoMeterPath
    Path to iometer.exe

.PARAMETER Duration
    Test duration per combination in seconds (default: 60)

.PARAMETER RampUp
    Ramp-up in seconds (default: 30)

.PARAMETER NumWorkers
    Number of workers (default: number of logical CPUs)

.PARAMETER SkipIsrDpc
    Skip ISR/DPC capture
#>
param(
    [string]$Disk = "PHYSICALDRIVE:1",
    [string]$Driver = "viostor",
    [string]$IoMeterPath = "C:\Program Files (x86)\Iometer.org\Iometer 1.1\IOmeter.exe",
    [int]$Duration = 60,
    [int]$RampUp = 30,
    [int]$NumWorkers = 0,
    [switch]$SkipIsrDpc
)

$ErrorActionPreference = "Stop"

if ($NumWorkers -le 0) {
    $NumWorkers = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputBase = "C:\iometer-results\comparison-$timestamp"
New-Item -ItemType Directory -Path $outputBase -Force | Out-Null

$logFile = Join-Path $outputBase "comparison.log"

function Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    $line | Out-File $logFile -Append -Encoding UTF8
}

Log "=" * 70
Log "IOMETER FULL DRIVER COMPARISON"
Log "=" * 70
Log "Driver:    $Driver"
Log "Disk:      $Disk"
Log "Workers:   $NumWorkers"
Log "Duration:  ${Duration}s + ${RampUp}s ramp-up per test"
Log "IoMeter:   $IoMeterPath"
Log "Output:    $outputBase"
Log "=" * 70

$drivers = @("master", "new-multi-iterate")

foreach ($drv in $drivers) {
    Log ""
    Log ("#" * 70)
    Log "DRIVER: $drv"
    Log ("#" * 70)
    Log ""

    # Switch driver
    Log "Installing $drv driver..."
    & C:\switch-driver.ps1 -Action $drv -Driver $Driver 2>&1 | Tee-Object -FilePath $logFile -Append

    # Run IoMeter benchmark
    $drvOutput = Join-Path $outputBase $drv
    Log "Starting IoMeter benchmark for $drv..."

    $benchArgs = @{
        Disk        = $Disk
        IoMeterPath = $IoMeterPath
        OutputDir   = $drvOutput
        NumWorkers  = $NumWorkers
        Duration    = $Duration
        RampUp      = $RampUp
    }
    if ($SkipIsrDpc) { $benchArgs.SkipIsrDpc = $true }

    & C:\iometer-benchmark.ps1 @benchArgs 2>&1 | Tee-Object -FilePath $logFile -Append

    Log "Completed benchmark for $drv."
}

# Generate comparison report
Log ""
Log "=" * 70
Log "GENERATING COMPARISON REPORT"
Log "=" * 70

$masterCsv = Get-ChildItem (Join-Path $outputBase "master") -Filter "summary.csv" -Recurse | Select-Object -First 1
$patchedCsv = Get-ChildItem (Join-Path $outputBase "new-multi-iterate") -Filter "summary.csv" -Recurse | Select-Object -First 1

if ($masterCsv -and $patchedCsv) {
    $masterData = Import-Csv $masterCsv.FullName
    $patchedData = Import-Csv $patchedCsv.FullName

    $comparison = @()
    $maxIndex = [math]::Min($masterData.Count, $patchedData.Count)

    for ($i = 0; $i -lt $maxIndex; $i++) {
        $m = $masterData[$i]
        $p = $patchedData[$i]

        $mIops = [double]$m.IOPS_Avg
        $pIops = [double]$p.IOPS_Avg

        $iopsChange = if ($mIops -gt 0) {
            [math]::Round(($pIops - $mIops) / $mIops * 100, 1)
        } else { 0 }

        $comparison += [PSCustomObject]@{
            Test            = $m.TestNum
            BlockSize       = $m.BlockSize
            QueueDepth      = $m.QueueDepth
            Pattern         = $m.Pattern
            Master_IOPS     = $m.IOPS_Avg
            Master_Min      = $m.IOPS_Min
            Master_Max      = $m.IOPS_Max
            Patched_IOPS    = $p.IOPS_Avg
            Patched_Min     = $p.IOPS_Min
            Patched_Max     = $p.IOPS_Max
            Delta_Pct       = "${iopsChange}%"
            Master_Lat_Avg  = $m.AvgLatency_ms
            Patched_Lat_Avg = $p.AvgLatency_ms
            Master_CPU      = $m.CPU_Pct
            Patched_CPU     = $p.CPU_Pct
        }
    }

    $reportPath = Join-Path $outputBase "comparison-report.csv"
    $comparison | Export-Csv $reportPath -NoTypeInformation
    Log "Comparison saved: $reportPath"

    # Print summary table
    Log ""
    Log "RESULTS SUMMARY (sorted by improvement):"
    Log "-" * 70

    $sorted = $comparison | Sort-Object { [double]($_.Delta_Pct -replace '%','') } -Descending

    Log ""
    Log "TOP IMPROVEMENTS:"
    $sorted | Select-Object -First 10 | ForEach-Object {
        Log ("  {0,-6} bs={1,-5} qd={2,-4} {3,-6} | master={4,8} patched={5,8} | {6,7}" -f
            $_.Test, $_.BlockSize, $_.QueueDepth, $_.Pattern,
            $_.Master_IOPS, $_.Patched_IOPS, $_.Delta_Pct)
    }

    Log ""
    Log "TOP REGRESSIONS:"
    $sorted | Select-Object -Last 5 | ForEach-Object {
        Log ("  {0,-6} bs={1,-5} qd={2,-4} {3,-6} | master={4,8} patched={5,8} | {6,7}" -f
            $_.Test, $_.BlockSize, $_.QueueDepth, $_.Pattern,
            $_.Master_IOPS, $_.Patched_IOPS, $_.Delta_Pct)
    }

    # Overall summary
    $avgDelta = [math]::Round(($comparison | ForEach-Object { [double]($_.Delta_Pct -replace '%','') } | Measure-Object -Average).Average, 1)
    $improvements = ($comparison | Where-Object { [double]($_.Delta_Pct -replace '%','') -gt 5 }).Count
    $regressions = ($comparison | Where-Object { [double]($_.Delta_Pct -replace '%','') -lt -5 }).Count
    $neutral = $comparison.Count - $improvements - $regressions

    Log ""
    Log "OVERALL:"
    Log "  Average delta:  ${avgDelta}%"
    Log "  Improvements:   $improvements (>5%)"
    Log "  Regressions:    $regressions (<-5%)"
    Log "  Neutral:        $neutral (within ±5%)"
}
else {
    Log "ERROR: Could not find summary.csv files for comparison."
    if (-not $masterCsv) { Log "  Missing: master summary.csv" }
    if (-not $patchedCsv) { Log "  Missing: new-multi-iterate summary.csv" }
}

Log ""
Log "=" * 70
Log "ALL DONE - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "  Results: $outputBase"
Log "  Report:  $(Join-Path $outputBase 'comparison-report.csv')"
Log "  Log:     $logFile"
Log "=" * 70
