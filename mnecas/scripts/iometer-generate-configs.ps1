<#
.SYNOPSIS
    Generate IoMeter .icf configuration files for all test combinations.

.DESCRIPTION
    Creates one .icf file per test combination that can be loaded into IoMeter GUI
    or run via command line: iometer.exe /c <config.icf> /r <results.csv>

    IoMeter .icf format reference:
    - Access specifications define the IO pattern
    - Manager/Worker sections define the test execution
    - Results are saved as CSV with per-interval data (min/max IOPS)

.PARAMETER OutputDir
    Directory to write .icf files (default: C:\iometer-configs)

.PARAMETER DiskTarget
    Disk target for IoMeter (e.g., "PHYSICALDRIVE:1" or a volume letter)

.PARAMETER NumWorkers
    Number of workers (default: number of logical CPUs)

.PARAMETER Duration
    Test duration in seconds (default: 600)

.PARAMETER RampUp
    Ramp-up time in seconds (default: 300)
#>
param(
    [string]$OutputDir = "C:\iometer-configs",
    [string]$DiskTarget = "PHYSICALDRIVE:1",
    [int]$NumWorkers = 0,
    [int]$Duration = 600,
    [int]$RampUp = 300
)

if ($NumWorkers -le 0) {
    $NumWorkers = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$blockSizes = @(512, 4096, 16384, 65536, 262144, 1048576, 2097152)
$blockLabels = @("512B", "4K", "16K", "64K", "256K", "1M", "2M")
$queueDepths = @(1, 2, 4, 8, 16, 32, 64)
$patterns = @(
    @{ Name = "read";  ReadPct = 100; WritePct = 0 },
    @{ Name = "write"; ReadPct = 0;   WritePct = 100 }
)

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

    $accessName = "$TestName"
    $hostname = $env:COMPUTERNAME

    # IoMeter ICF format
    $icf = @"
Version 2006.07.27
'TEST SETUP ====================================================================
'Test Description
	$TestName - Block=${BlockSize} QD=${QueueDepth} Read=${ReadPercent}%
'Run Time
'	hours      minutes    seconds
	0          $([math]::Floor($RunTime / 60))          $($RunTime % 60)
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
	$accessName,NONE
'size,% of size,% reads,% random,delay,burst,align,reply
	$BlockSize,100,$ReadPercent,100,0,1,0,0
'END access specifications

'MANAGER LIST ==================================================================
'Manager ID, manager name
	1,$hostname
'Manager network address
	
'END manager list

'Worker
'Worker ID, worker name
'Default target settings for worker
'Number of targets
	1
'Target assignments
'Target
'Target type,target name
	DISK,$Target
'Access specification name
	$accessName
'# of outstanding IOs
	$QueueDepth
'END target

'END worker
"@

    # Add additional workers
    for ($w = 2; $w -le $Workers; $w++) {
        $icf += @"

'Worker
'Worker ID, worker name
'Default target settings for worker
'Number of targets
	1
'Target assignments
'Target
'Target type,target name
	DISK,$Target
'Access specification name
	$accessName
'# of outstanding IOs
	$QueueDepth
'END target

'END worker
"@
    }

    $icf += "`n'END manager`n"

    $icf | Out-File $FilePath -Encoding ASCII
}

# Generate batch runner script
$batchScript = @"
@echo off
REM IoMeter batch runner - runs all generated .icf configs sequentially
REM Usage: run-all-iometer.bat [path-to-iometer.exe]

set IOMETER=%1
if "%IOMETER%"=="" set IOMETER=C:\Program Files (x86)\Iometer.org\Iometer 1.1\IOmeter.exe

set RESULTS_DIR=$OutputDir\results
if not exist "%RESULTS_DIR%" mkdir "%RESULTS_DIR%"

echo ======================================================================
echo IoMeter Benchmark Suite
echo Tests: $($blockSizes.Count * $queueDepths.Count * $patterns.Count)
echo Duration: ${Duration}s + ${RampUp}s ramp per test
echo Workers: $NumWorkers
echo ======================================================================
echo.

"@

$testNum = 0
foreach ($pattern in $patterns) {
    foreach ($i in 0..($blockSizes.Count - 1)) {
        $bs = $blockSizes[$i]
        $bsLabel = $blockLabels[$i]
        foreach ($qd in $queueDepths) {
            $testNum++
            $testName = "{0:D3}-rand-{1}-bs{2}-qd{3}" -f $testNum, $pattern.Name, $bsLabel, $qd
            $icfPath = Join-Path $OutputDir "$testName.icf"
            $csvResult = Join-Path $OutputDir "results" "$testName.csv"

            Generate-IcfFile `
                -FilePath $icfPath `
                -TestName $testName `
                -BlockSize $bs `
                -QueueDepth $qd `
                -ReadPercent $pattern.ReadPct `
                -Workers $NumWorkers `
                -Target $DiskTarget `
                -RunTime $Duration `
                -Ramp $RampUp

            $batchScript += @"

echo [%date% %time%] Running test $testNum : $testName
"%IOMETER%" /c "$icfPath" /r "$csvResult"
echo   Done.

"@
        }
    }
}

$batchScript += @"

echo.
echo ======================================================================
echo ALL TESTS COMPLETE
echo Results in: %RESULTS_DIR%
echo ======================================================================
"@

# Write batch runner
$batchScript | Out-File (Join-Path $OutputDir "run-all-iometer.bat") -Encoding ASCII

Write-Host "Generated $testNum IoMeter .icf files in: $OutputDir"
Write-Host "Batch runner: $OutputDir\run-all-iometer.bat"
Write-Host ""
Write-Host "To run manually:"
Write-Host "  iometer.exe /c $OutputDir\001-rand-read-bs512B-qd1.icf /r results.csv"
Write-Host ""
Write-Host "To run all tests:"
Write-Host "  $OutputDir\run-all-iometer.bat ""C:\Program Files\Iometer\iometer.exe"""
