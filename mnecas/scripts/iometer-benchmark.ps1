<#
.SYNOPSIS
    IoMeter benchmark automation - generates configs and runs all tests sequentially.

.DESCRIPTION
    Runs the full IoMeter test matrix:
      7 block sizes × 5 queue depths × 2 patterns = 70 tests
    Each test: 1-minute duration + 30s ramp-up = 90s
    Total runtime: ~1.75 hours (or ~35 min with 30s quick mode)

    Standard setup:
      - Workers = number of CPUs = number of virtqueues
      - IoMeter assigns one dedicated worker thread per CPU automatically
      - 4 vCPUs / 4 queues / 4 workers is the typical configuration

.PARAMETER Disk
    IoMeter disk target (e.g., "PHYSICALDRIVE:1")

.PARAMETER IoMeterPath
    Path to iometer.exe

.PARAMETER OutputDir
    Directory for configs and results

.PARAMETER NumWorkers
    Number of workers (default: number of logical CPUs = number of queues)

.PARAMETER Duration
    Test duration in seconds (default: 600 = 10 minutes)

.PARAMETER RampUp
    Ramp-up time in seconds (default: 300 = 5 minutes)

.PARAMETER TestFilter
    Run only specific test numbers (e.g., "1,5,10")

.PARAMETER SkipIsrDpc
    Skip ISR/DPC capture via xperf
#>
param(
    [string]$Disk = "PHYSICALDRIVE:1",
    [string]$IoMeterPath = "C:\Program Files (x86)\Iometer.org\Iometer 1.1\IOmeter.exe",
    [string]$OutputDir = "C:\iometer-results",
    [int]$NumWorkers = 0,
    [int]$Duration = 60,
    [int]$RampUp = 30,
    [string]$TestFilter = "",
    [switch]$SkipIsrDpc
)

$ErrorActionPreference = "Stop"

if ($NumWorkers -le 0) {
    $NumWorkers = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
}

if (-not (Test-Path $IoMeterPath)) {
    Write-Error "IoMeter not found at '$IoMeterPath'. Please install IoMeter or specify -IoMeterPath."
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $OutputDir "run-$timestamp"
$configDir = Join-Path $runDir "configs"
$resultsDir = Join-Path $runDir "results"
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

$blockSizes = @(512, 4096, 16384, 65536, 262144, 1048576, 2097152)
$blockLabels = @("512B", "4K", "16K", "64K", "256K", "1M", "2M")
$queueDepths = @(16, 32, 64, 128, 256)
$patterns = @(
    @{ Name = "read";  ReadPct = 100 },
    @{ Name = "write"; ReadPct = 0 }
)

$totalTests = $blockSizes.Count * $queueDepths.Count * $patterns.Count

# Parse test filter
$filterSet = @()
if ($TestFilter -ne "") {
    $filterSet = $TestFilter -split "," | ForEach-Object { [int]$_.Trim() }
}

Write-Host "=" * 70
Write-Host "IOMETER BENCHMARK SUITE"
Write-Host "=" * 70
Write-Host "IoMeter:     $IoMeterPath"
Write-Host "Disk:        $Disk"
Write-Host "Workers:     $NumWorkers"
Write-Host "Duration:    ${Duration}s + ${RampUp}s ramp-up"
Write-Host "Tests:       $totalTests combinations"
Write-Host "Est. time:   $([math]::Round($totalTests * ($Duration + $RampUp) / 3600, 1)) hours (or $([math]::Round($totalTests * 1.5 / 60, 1))h in quick 1-min mode)"
Write-Host "Output:      $runDir"
Write-Host "ISR/DPC:     $(if ($SkipIsrDpc) { 'DISABLED' } else { 'ENABLED (xperf)' })"
Write-Host "=" * 70
Write-Host ""

function Generate-IcfFile {
    param(
        [string]$FilePath,
        [string]$TestName,
        [int]$BlockSize,
        [int]$QueueDepth,
        [int]$ReadPercent,
        [int]$Workers,
        [string]$Target,
        [int]$RunTime,
        [int]$Ramp
    )

    $hostname = $env:COMPUTERNAME
    $runMinutes = [math]::Floor($RunTime / 60)
    $runSeconds = $RunTime % 60

    $icf = @"
Version 2006.07.27
'TEST SETUP ====================================================================
'Test Description
	$TestName
'Run Time
'	hours      minutes    seconds
	0          $runMinutes          $runSeconds
'Ramp Up Time (s)
	$Ramp
'Default Disk Workers to Spawn
	$Workers
'Default Network Workers to Spawn
	0
'Record Results
	ALL
'Worker Cycling
'	start      step       step type
	1          1          LINEAR
'Target Cycling
'	start      step       step type
	1          1          LINEAR
'Queue Depth Cycling
'	start      end        step       step type
	$QueueDepth          $QueueDepth          1          LINEAR
'Test Type
	NORMAL
'END test setup

'RESULTS DISPLAY ===============================================================
'Update Frequency,Update Type
	1,WHOLE_TEST
'Bar chart 1 statance,Bar chart 1 statistic
	0,0
'END results display

'ACCESS SPECIFICATIONS =========================================================
'Access specification name,default assignment
	$TestName,NONE
'size,% of size,% reads,% random,delay,burst,align,reply
	$BlockSize,100,$ReadPercent,100,0,1,0,0
'END access specifications

'MANAGER LIST ==================================================================
'Manager ID, manager name
	1,$hostname
'Manager network address
	
'END manager list
"@

    for ($w = 1; $w -le $Workers; $w++) {
        # IoMeter automatically assigns one worker per CPU when workers == CPUs.
        # No explicit CPU binding needed.
        $icf += @"

'Worker
'Worker ID, worker name
	$w,Worker $w
'Default target settings for worker
'Number of targets
	1
'Target assignments
'Target
'Target type,target name
	DISK,$Target
'Access specification name
	$TestName
'# of outstanding IOs,test connection rate,transactions per connection,use fixed seed,fixed seed value
	$QueueDepth,DISABLED,1,DISABLED,0
'END target

'END worker
"@
    }

    $icf += "`n'END manager`n"
    $icf | Out-File $FilePath -Encoding ASCII
}

function Start-IsrDpcTrace {
    param([string]$etlPath)
    if ($SkipIsrDpc) { return }
    try {
        Start-Process -FilePath "xperf" -ArgumentList "-on PROC_THREAD+INTERRUPT+DPC+PROFILE -f `"$etlPath`" -buffersize 1024 -minbuffers 64 -maxbuffers 128" -NoNewWindow -Wait:$false
        Start-Sleep -Seconds 2
    }
    catch {
        Write-Warning "xperf not available, skipping ISR/DPC capture."
    }
}

function Stop-IsrDpcTrace {
    param([string]$etlPath, [string]$reportDir)
    if ($SkipIsrDpc) { return }
    try {
        Start-Process -FilePath "xperf" -ArgumentList "-stop" -NoNewWindow -Wait
        if (Test-Path $etlPath) {
            $reportFile = Join-Path $reportDir "isr-dpc-summary.txt"
            Start-Process -FilePath "xperf" -ArgumentList "-i `"$etlPath`" -o `"$reportFile`" -a dpcisr" -NoNewWindow -Wait
        }
    }
    catch {
        Write-Warning "Failed to stop xperf trace."
    }
}

# Summary CSV
$summaryPath = Join-Path $runDir "summary.csv"
"TestNum,BlockSize,QueueDepth,Pattern,Workers,IOPS_Avg,IOPS_Min,IOPS_Max,MBps_Avg,AvgLatency_ms,MaxLatency_ms,CPU_Pct" |
    Out-File $summaryPath -Encoding UTF8

$startTime = Get-Date
$testNum = 0

foreach ($pattern in $patterns) {
    foreach ($i in 0..($blockSizes.Count - 1)) {
        $bs = $blockSizes[$i]
        $bsLabel = $blockLabels[$i]
        foreach ($qd in $queueDepths) {
            $testNum++

            if ($filterSet.Count -gt 0 -and $testNum -notin $filterSet) {
                continue
            }

            $testName = "{0:D3}-rand-{1}-bs{2}-qd{3}" -f $testNum, $pattern.Name, $bsLabel, $qd
            $icfPath = Join-Path $configDir "$testName.icf"
            $csvPath = Join-Path $resultsDir "$testName.csv"
            $etlPath = Join-Path $resultsDir "$testName.etl"

            $elapsed = (Get-Date) - $startTime
            $testsRun = if ($filterSet.Count -gt 0) { [math]::Min($testNum, $filterSet.Count) } else { $testNum }
            $eta = if ($testsRun -gt 1) {
                $remaining = ($totalTests - $testNum) * ($Duration + $RampUp)
                [TimeSpan]::FromSeconds($remaining).ToString("hh\:mm\:ss")
            } else { "calculating..." }

            Write-Host ""
            Write-Host ("=" * 70)
            Write-Host "TEST $testNum/$totalTests : $testName"
            Write-Host "  Block=$bsLabel ($bs B)  QueueDepth=$qd  ${($pattern.Name)}  Workers=$NumWorkers"
            Write-Host "  Duration: ${Duration}s + ${RampUp}s ramp-up"
            Write-Host "  ETA remaining: $eta"
            Write-Host ("=" * 70)

            # Generate .icf
            Generate-IcfFile `
                -FilePath $icfPath `
                -TestName $testName `
                -BlockSize $bs `
                -QueueDepth $qd `
                -ReadPercent $pattern.ReadPct `
                -Workers $NumWorkers `
                -Target $Disk `
                -RunTime $Duration `
                -Ramp $RampUp

            # Start ISR/DPC trace
            Start-IsrDpcTrace -etlPath $etlPath

            # Start CPU monitoring
            $cpuJob = Start-Job -ScriptBlock {
                param($seconds)
                $samples = @()
                $end = (Get-Date).AddSeconds($seconds)
                while ((Get-Date) -lt $end) {
                    try {
                        $v = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
                        $samples += $v
                    } catch {}
                    Start-Sleep -Seconds 5
                }
                return $samples
            } -ArgumentList ($Duration + $RampUp + 60)

            # Run IoMeter
            Write-Host "  Starting IoMeter: /c `"$icfPath`" /r `"$csvPath`""
            $ioProc = Start-Process -FilePath $IoMeterPath -ArgumentList "/c `"$icfPath`" /r `"$csvPath`"" -PassThru -NoNewWindow
            $ioProc | Wait-Process

            # Stop ISR/DPC trace
            Stop-IsrDpcTrace -etlPath $etlPath -reportDir $resultsDir

            # Collect CPU
            $cpuSamples = Receive-Job -Job $cpuJob -Wait -AutoRemoveJob 2>$null
            $cpuAvg = if ($cpuSamples -and $cpuSamples.Count -gt 0) {
                [math]::Round(($cpuSamples | Measure-Object -Average).Average, 2)
            } else { -1 }

            # Parse IoMeter CSV results
            $iopsAvg = 0; $iopsMin = 0; $iopsMax = 0; $mbpsAvg = 0
            $latAvg = 0; $latMax = 0

            if (Test-Path $csvPath) {
                $csvContent = Get-Content $csvPath | Where-Object { $_ -match "ALL" -or $_ -match "^\d" }
                # IoMeter CSV format: the results section contains per-interval rows
                # Columns typically: TimeStamp, Target, IOps, Read IOps, Write IOps, MBps, ...
                $dataRows = Import-Csv $csvPath -ErrorAction SilentlyContinue

                if ($dataRows) {
                    $iopsValues = @()
                    foreach ($row in $dataRows) {
                        $iops = 0
                        if ($row.'IOps' -and $row.'IOps' -ne '') {
                            $iops = [double]$row.'IOps'
                        }
                        elseif ($row.'Total I/Os per Second' -and $row.'Total I/Os per Second' -ne '') {
                            $iops = [double]$row.'Total I/Os per Second'
                        }
                        if ($iops -gt 0) { $iopsValues += $iops }

                        if ($row.'MBps Read' -or $row.'MBs per Second') {
                            $mb = if ($row.'MBs per Second') { [double]$row.'MBs per Second' }
                                  elseif ($row.'MBps Read') { [double]$row.'MBps Read' + [double]$row.'MBps Write' }
                                  else { 0 }
                            if ($mb -gt $mbpsAvg) { $mbpsAvg = $mb }
                        }

                        if ($row.'Average Response Time' -and $row.'Average Response Time' -ne '') {
                            $lat = [double]$row.'Average Response Time'
                            if ($lat -gt 0) { $latAvg = $lat }
                        }
                        if ($row.'Maximum Response Time' -and $row.'Maximum Response Time' -ne '') {
                            $lat = [double]$row.'Maximum Response Time'
                            if ($lat -gt $latMax) { $latMax = $lat }
                        }
                    }

                    if ($iopsValues.Count -gt 0) {
                        $iopsAvg = [math]::Round(($iopsValues | Measure-Object -Average).Average, 0)
                        $iopsMin = [math]::Round(($iopsValues | Measure-Object -Minimum).Minimum, 0)
                        $iopsMax = [math]::Round(($iopsValues | Measure-Object -Maximum).Maximum, 0)
                    }
                }
            }

            # Append to summary
            "$testNum,$bsLabel,$qd,$($pattern.Name),$NumWorkers,$iopsAvg,$iopsMin,$iopsMax,$([math]::Round($mbpsAvg,2)),$([math]::Round($latAvg,3)),$([math]::Round($latMax,3)),$cpuAvg" |
                Out-File $summaryPath -Append -Encoding UTF8

            Write-Host ""
            Write-Host "  RESULTS:"
            Write-Host "    IOPS:    avg=$iopsAvg  min=$iopsMin  max=$iopsMax"
            Write-Host "    BW:      $([math]::Round($mbpsAvg, 2)) MB/s"
            Write-Host "    Latency: avg=${latAvg}ms  max=${latMax}ms"
            Write-Host "    CPU:     ${cpuAvg}%"
            Write-Host ""
        }
    }
}

$endTime = Get-Date
$totalElapsed = $endTime - $startTime

Write-Host ""
Write-Host ("=" * 70)
Write-Host "ALL IOMETER TESTS COMPLETE"
Write-Host "  Total time:  $($totalElapsed.ToString('hh\:mm\:ss'))"
Write-Host "  Summary CSV: $summaryPath"
Write-Host "  Full data:   $runDir"
Write-Host ("=" * 70)
