<#
.SYNOPSIS
    Comprehensive disk benchmark using diskspd with ISR/DPC and CPU monitoring.
    Equivalent to IoMeter methodology: all block sizes × queue depths × read/write.

.DESCRIPTION
    Runs 70 test combinations (7 block sizes × 5 queue depths × 2 access patterns).
    Captures: IOPS (avg/min/max), latency, CPU utilization, ISR/DPC times.
    Total runtime: ~1.75 hours (90s per test × 70 tests) in default mode.

.PARAMETER Disk
    Target path. Use "#N" for raw physical drive (e.g., "#1" for PhysicalDrive1),
    "D:" for a drive letter, or a file path (e.g., "D:\testfile.dat") with -c auto-creation.

.PARAMETER TestFileSize
    Size of test file to create (default: 1G). Only used with file-based targets.

.PARAMETER OutputDir
    Directory for results (default: C:\benchmark-results)

.PARAMETER NumWorkers
    Number of worker threads (default: number of logical CPUs)

.PARAMETER Duration
    Test duration in seconds (default: 60 = 1 minute)

.PARAMETER Warmup
    Warmup/ramp-up in seconds (default: 30)

.PARAMETER DiskSpdPath
    Path to diskspd.exe (default: chocolatey install path)

.PARAMETER BlockSizes
    Array of block sizes to test

.PARAMETER QueueDepths
    Array of queue depths to test

.PARAMETER SkipIsrDpc
    Skip ISR/DPC capture (faster, no xperf dependency)

.PARAMETER TestFilter
    Run only specific test numbers (e.g., "1,5,10")

.PARAMETER Random
    Use random IO (default). Set to $false for sequential.
#>
param(
    [string]$Disk = "#1",
    [string]$TestFileSize = "1G",
    [string]$OutputDir = "C:\benchmark-results",
    [int]$NumWorkers = 0,
    [int]$Duration = 60,
    [int]$Warmup = 30,
    [string]$DiskSpdPath = "C:\ProgramData\chocolatey\lib\diskspd\tools\amd64\diskspd.exe",
    [string[]]$BlockSizes = @("512", "4K", "16K", "64K", "256K", "1M", "2M"),
    [int[]]$QueueDepths = @(16, 32, 64, 128, 256),
    [int[]]$WritePercents = @(100, 0),
    [switch]$SkipIsrDpc,
    [string]$TestFilter = "",
    [switch]$Sequential
)

$ErrorActionPreference = "Stop"

if ($NumWorkers -le 0) {
    $NumWorkers = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $OutputDir "run-$timestamp"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$totalTests = $BlockSizes.Count * $QueueDepths.Count * $WritePercents.Count
$testNum = 0
$startTime = Get-Date

$config = @{
    Disk        = $Disk
    TestFileSize = $TestFileSize
    NumWorkers  = $NumWorkers
    Duration    = $Duration
    Warmup      = $Warmup
    BlockSizes  = $BlockSizes
    QueueDepths = $QueueDepths
    WritePercents = $WritePercents
    Random      = -not $Sequential
    StartTime   = $startTime.ToString("o")
    DiskSpdVersion = ""
}

# Verify diskspd
if (-not (Test-Path $DiskSpdPath)) {
    Write-Error "diskspd.exe not found at $DiskSpdPath. Download from https://github.com/microsoft/diskspd/releases"
    exit 1
}

$versionOutput = & $DiskSpdPath 2>&1 | Select-Object -First 3
$config.DiskSpdVersion = ($versionOutput | Where-Object { $_ -match "diskspd" }) -join " "

$config | ConvertTo-Json | Out-File (Join-Path $runDir "config.json") -Encoding UTF8

# Transcript log - captures all console output
$logFile = Join-Path $runDir "run.log"
Start-Transcript -Path $logFile -Append | Out-Null

Write-Host ("=" * 70)
Write-Host "DISKSPD BENCHMARK SUITE"
Write-Host ("=" * 70)
Write-Host "Disk:        $Disk"
Write-Host "Workers:     $NumWorkers"
Write-Host "Duration:    ${Duration}s + ${Warmup}s warmup"
Write-Host "Tests:       $totalTests combinations"
Write-Host "Est. time:   $([math]::Round($totalTests * ($Duration + $Warmup) / 3600, 1)) hours"
Write-Host "Output:      $runDir"
Write-Host "ISR/DPC:     $(if ($SkipIsrDpc) { 'DISABLED' } else { 'ENABLED (xperf)' })"
Write-Host ("=" * 70)
Write-Host ""

# Parse test filter
$filterSet = @()
if ($TestFilter -ne "") {
    $filterSet = $TestFilter -split "," | ForEach-Object { [int]$_.Trim() }
}

# Summary CSV header
$summaryPath = Join-Path $runDir "summary.csv"
"TestNum,BlockSize,QueueDepth,WritePercent,Pattern,Workers,IOPS_Avg,IOPS_Min,IOPS_Max,BW_MBps,Lat_Avg_us,Lat_P50_us,Lat_P99_us,Lat_P999_us,CPU_Avg" |
    Out-File $summaryPath -Encoding UTF8

function Start-IsrDpcCapture {
    param([string]$etlPath)
    if ($SkipIsrDpc) { return $null }
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & xperf -stop 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        $ErrorActionPreference = "Stop"
        & xperf -on PROC_THREAD+INTERRUPT+DPC+PROFILE -f $etlPath -buffersize 1024 -minbuffers 64 -maxbuffers 128 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "xperf start failed (exit code $LASTEXITCODE), skipping ISR/DPC for this test."
            return $null
        }
        Start-Sleep -Seconds 2
        return $true
    }
    catch {
        Write-Warning "xperf not available: $_"
        return $null
    }
}

function Stop-IsrDpcCapture {
    param($started, [string]$etlPath, [string]$outputDir)
    if ($null -eq $started) { return }
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & xperf -stop 2>&1 | Out-Null
        Start-Sleep -Seconds 1
        if (Test-Path $etlPath) {
            & xperf -i $etlPath -o (Join-Path $outputDir "isr-dpc-report.txt") -a dpcisr 2>&1 | Out-Null
        }
        $ErrorActionPreference = "Stop"
    }
    catch {
        Write-Warning "Failed to stop xperf: $_"
    }
}

function Get-CpuCounter {
    try {
        return (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
    }
    catch { return -1 }
}

# Main test loop
foreach ($writePercent in $WritePercents) {
    foreach ($bs in $BlockSizes) {
        foreach ($qd in $QueueDepths) {
            $testNum++

            if ($filterSet.Count -gt 0 -and $testNum -notin $filterSet) {
                continue
            }

            $pattern = if ($writePercent -eq 100) { "write" } else { "read" }
            $accessType = if ($Sequential) { "seq" } else { "rand" }
            $testName = "{0:D3}-{1}-{2}-bs{3}-qd{4}" -f $testNum, $accessType, $pattern, $bs, $qd

            $testDir = Join-Path $runDir $testName
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $elapsed = (Get-Date) - $startTime
            $eta = if ($testNum -gt 1) {
                $perTest = $elapsed.TotalSeconds / ($testNum - 1)
                $remaining = $perTest * ($totalTests - $testNum + 1)
                [TimeSpan]::FromSeconds($remaining).ToString("hh\:mm\:ss")
            } else { "calculating..." }

            Write-Host ""
            Write-Host ("=" * 70)
            Write-Host "TEST $testNum/$totalTests : $testName"
            Write-Host "  Block=$bs  QueueDepth=$qd  Write=${writePercent}%  Workers=$NumWorkers"
            Write-Host "  ETA: $eta remaining"
            Write-Host ("=" * 70)

            # Build diskspd command
            $txtOut = Join-Path $testDir "result.txt"
            $etlOut = Join-Path $testDir "isrdpc.etl"

            $dspdArgs = @(
                "-b$bs",
                "-d$Duration",
                "-W$Warmup",
                "-o$qd",
                "-t$NumWorkers",
                "-Sh",
                "-L"
            )

            # Add file creation flag for file-based targets (not raw devices or drive letters)
            if ($Disk -notmatch '^#\d+$' -and $Disk -notmatch '^\\\\.\\Physical' -and $Disk -notmatch '^[A-Z]:$') {
                $dspdArgs += "-c$TestFileSize"
            }

            if ($writePercent -eq 100) { $dspdArgs += "-w100" } else { $dspdArgs += "-w0" }
            if (-not $Sequential) { $dspdArgs += "-r" }

            $dspdArgs += $Disk

            # Start ISR/DPC capture
            $xperfProc = Start-IsrDpcCapture -etlPath $etlOut

            # Start CPU monitoring in background
            $cpuSamples = [System.Collections.ArrayList]::new()
            $cpuJob = Start-Job -ScriptBlock {
                param($dur)
                $samples = @()
                $end = (Get-Date).AddSeconds($dur + 30)
                while ((Get-Date) -lt $end) {
                    try {
                        $val = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
                        $samples += $val
                    } catch {}
                    Start-Sleep -Seconds 5
                }
                return $samples
            } -ArgumentList ($Duration + $Warmup)

            # Run diskspd
            $cmdLine = "$DiskSpdPath $($dspdArgs -join ' ')"
            Write-Host "  Running: diskspd $($dspdArgs -join ' ')"

            # Save command for reproducibility
            $cmdLine | Out-File (Join-Path $testDir "command.txt") -Encoding UTF8

            # Redirect to files so diskspd's CR-based progress bars do not
            # garble the console/transcript when RESULTS are printed.
            $dspdErr = Join-Path $testDir "diskspd-stderr.txt"
            $argLine = ($dspdArgs | ForEach-Object {
                if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
            }) -join ' '
            $p = Start-Process -FilePath $DiskSpdPath -ArgumentList $argLine `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $txtOut -RedirectStandardError $dspdErr
            if ((Test-Path $dspdErr) -and (Get-Item $dspdErr).Length -gt 0) {
                Add-Content -Path $txtOut -Value (Get-Content $dspdErr -Raw)
            }
            Remove-Item $dspdErr -Force -ErrorAction SilentlyContinue
            # Normalize lone CRs from progress updates into newlines
            if (Test-Path $txtOut) {
                $rawText = [System.IO.File]::ReadAllText($txtOut)
                $rawText = $rawText -replace "`r`n", "`n" -replace "`r", "`n"
                [System.IO.File]::WriteAllText($txtOut, $rawText)
                $dspdOutput = $rawText -split "`n"
            } else {
                $dspdOutput = @()
            }
            Write-Host ""  # ensure cursor is on a fresh line after any leaked progress

            # Stop ISR/DPC
            Stop-IsrDpcCapture -started $xperfProc -etlPath $etlOut -outputDir $testDir

            # Collect CPU samples
            $cpuJob | Stop-Job -PassThru | Remove-Job -Force 2>$null

            # Parse results from diskspd text output
            $results = @{
                IOPS_Avg  = 0; IOPS_Min = 0; IOPS_Max = 0
                BW_MBps   = 0; Lat_Avg = 0; Lat_P50 = 0
                Lat_P99   = 0; Lat_P999 = 0; CPU_Avg = 0
            }

            # Parse "Total IO" section's total line:
            # total:        1694408704 |       413674 |     322.53 |   82567.18 |    0.182 |     0.036
            $inTotalIO = $false
            foreach ($line in $dspdOutput) {
                if ($line -match "Total IO") { $inTotalIO = $true; continue }
                if ($inTotalIO -and $line -match "Read IO|Write IO") { $inTotalIO = $false }
                if ($inTotalIO -and $line -match "total:?\s+[\d]+\s*\|\s*([\d]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)") {
                    $results.BW_MBps = [double]$Matches[2]
                    $results.IOPS_Avg = [math]::Round([double]$Matches[3], 0)
                    $results.Lat_Avg = [math]::Round([double]$Matches[4] * 1000, 2)
                    break
                }
            }

            # Parse CPU: "avg.|  25.00%|   0.39%|   24.61%|  75.00%"
            foreach ($line in $dspdOutput) {
                if ($line -match "avg\.\s*\|\s*([\d.]+)%") {
                    $results.CPU_Avg = [double]$Matches[1]
                    break
                }
            }

            # Parse percentiles:
            #    50th |      0.180 |        N/A |      0.180
            #    99th |      0.265 |        N/A |      0.265
            # 3-nines |      0.304 |        N/A |      0.304
            $inPercentile = $false
            foreach ($line in $dspdOutput) {
                if ($line -match "%-ile\s*\|") { $inPercentile = $true; continue }
                if ($inPercentile) {
                    if ($line -match "50th\s*\|\s*([\d.]+|N/A)\s*\|\s*([\d.]+|N/A)\s*\|\s*([\d.]+)") {
                        $results.Lat_P50 = [math]::Round([double]$Matches[3] * 1000, 2)
                    }
                    if ($line -match "99th\s*\|\s*([\d.]+|N/A)\s*\|\s*([\d.]+|N/A)\s*\|\s*([\d.]+)") {
                        $results.Lat_P99 = [math]::Round([double]$Matches[3] * 1000, 2)
                    }
                    if ($line -match "3-nines\s*\|\s*([\d.]+|N/A)\s*\|\s*([\d.]+|N/A)\s*\|\s*([\d.]+)") {
                        $results.Lat_P999 = [math]::Round([double]$Matches[3] * 1000, 2)
                    }
                    if ($line -match "\bmax\b\s*\|") { $inPercentile = $false }
                }
            }

            # Min/Max IOPS: -D flag only provides stddev in text mode (full series needs XML).
            # Use avg as min/max since per-interval data isn't available in text output.
            $results.IOPS_Min = $results.IOPS_Avg
            $results.IOPS_Max = $results.IOPS_Avg

            # Write summary line
            $csvLine = "$testNum,$bs,$qd,$writePercent,$accessType,$NumWorkers," +
                       "$($results.IOPS_Avg),$($results.IOPS_Min),$($results.IOPS_Max)," +
                       "$($results.BW_MBps),$($results.Lat_Avg),$($results.Lat_P50)," +
                       "$($results.Lat_P99),$($results.Lat_P999),$($results.CPU_Avg)"
            $csvLine | Out-File $summaryPath -Append -Encoding UTF8

            # Console summary
            Write-Host ""
            Write-Host "  RESULTS:"
            Write-Host "    IOPS:    avg=$($results.IOPS_Avg)  min=$($results.IOPS_Min)  max=$($results.IOPS_Max)"
            Write-Host "    BW:      $($results.BW_MBps) MiB/s"
            Write-Host "    Latency: avg=$($results.Lat_Avg)us  p50=$($results.Lat_P50)us  p99=$($results.Lat_P99)us  p99.9=$($results.Lat_P999)us"
            Write-Host "    CPU:     $($results.CPU_Avg)%"
            Write-Host ""

            # Save per-test summary
            $results | ConvertTo-Json | Out-File (Join-Path $testDir "summary.json") -Encoding UTF8
        }
    }
}

# Final summary
$endTime = Get-Date
$totalElapsed = $endTime - $startTime

# Generate human-readable summary
$summaryTxt = Join-Path $runDir "summary.txt"
$header = @"
DISKSPD BENCHMARK RESULTS
$(("=" * 70))
Disk:        $Disk
Workers:     $NumWorkers
Duration:    ${Duration}s + ${Warmup}s warmup
Pattern:     $(if ($Sequential) { "Sequential" } else { "Random" })
Started:     $($startTime.ToString("yyyy-MM-dd HH:mm:ss"))
Finished:    $($endTime.ToString("yyyy-MM-dd HH:mm:ss"))
Total time:  $($totalElapsed.ToString('hh\:mm\:ss'))
$(("=" * 70))

$(("{0,-6} {1,-8} {2,-4} {3,-7} {4,10} {5,10} {6,10} {7,10} {8,6}" -f "Test", "Block", "QD", "Pattern", "IOPS", "BW(MiB)", "Lat_avg", "Lat_p99", "CPU%"))
$(("-" * 80))
"@
$header | Out-File $summaryTxt -Encoding UTF8

# Re-read CSV and format
$csvData = Import-Csv $summaryPath
foreach ($row in $csvData) {
    $line = "{0,-6} {1,-8} {2,-4} {3,-7} {4,10} {5,10} {6,10} {7,10} {8,6}" -f `
        $row.TestNum, $row.BlockSize, $row.QueueDepth, `
        $(if ($row.WritePercent -eq "100") { "write" } else { "read" }), `
        $row.IOPS_Avg, $row.BW_MBps, "$($row.Lat_Avg_us)us", "$($row.Lat_P99_us)us", "$($row.CPU_Avg)%"
    $line | Out-File $summaryTxt -Append -Encoding UTF8
}

Stop-Transcript | Out-Null

Write-Host ""
Write-Host ("=" * 70)
Write-Host "ALL TESTS COMPLETE"
Write-Host "  Total time: $($totalElapsed.ToString('hh\:mm\:ss'))"
Write-Host "  Summary:    $summaryTxt"
Write-Host "  CSV:        $summaryPath"
Write-Host "  Full data:  $runDir"
Write-Host "  Run log:    $logFile"
Write-Host ("=" * 70)
