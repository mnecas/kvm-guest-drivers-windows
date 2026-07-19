param(
    [string]$Disk = "\\.\PhysicalDrive1",
    [int]$Runtime = 30,
    [int]$NumJobs = 0,
    [string]$LogDir = "C:\fio-results"
)

if ($NumJobs -le 0) {
    $NumJobs = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
}

if (-not (Test-Path $LogDir)) { mkdir $LogDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = "$LogDir\fio-run-$timestamp.txt"

function Run-FioTest {
    param(
        [string]$Name,
        [string]$Description,
        [string]$FioArgs
    )

    $separator = "=" * 70
    $header = @"

$separator
TEST: $Name
DESC: $Description
ARGS: fio $FioArgs
TIME: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$separator

"@

    Write-Output $header
    $header | Out-File -Append $logFile

    $output = Invoke-Expression "fio $FioArgs" 2>&1 | Out-String
    Write-Output $output
    $output | Out-File -Append $logFile

    $footer = "`n--- Completed: $Name ---`n"
    Write-Output $footer
    $footer | Out-File -Append $logFile

    Start-Sleep -Seconds 5
}

Write-Output "FIO Edge Case Test Suite"
Write-Output "Disk: $Disk | Runtime: ${Runtime}s | NumJobs: $NumJobs | Log: $logFile"
Write-Output ""

# Test 1: Verify mode (data integrity)
Run-FioTest -Name "01-verify-integrity" `
    -Description "Write+verify with CRC32C - catches data corruption from queue routing bugs" `
    -FioArgs "--name=verify --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=64 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --thread --size=1G --direct=1 --verify=crc32c --do_verify=1 --offset_increment=1G"

# Test 2: Single thread deep iodepth (overflow stress)
Run-FioTest -Name "02-single-deep-overflow" `
    -Description "1 thread iodepth=1024 - forces overflow from q0 to q1-q3" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=1024 --numjobs=1 --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1"

# Test 3: Exceed total capacity (StorPortBusy path)
Run-FioTest -Name "03-exceed-capacity" `
    -Description "$NumJobs threads x iodepth=512 - tests StorPortBusy fallback" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=512 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1"

# Test 4: Many threads low iodepth (distribution)
Run-FioTest -Name "04-many-threads-low-depth" `
    -Description "$(4 * $NumJobs) threads x iodepth=4 - tests queue selection without overflow" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=4 --numjobs=$(4 * $NumJobs) --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1"

# Test 5: CPU-pinned baseline (optimal multi-queue)
$cpuList = (0..($NumJobs - 1)) -join ","
Run-FioTest -Name "05-cpu-pinned-baseline" `
    -Description "$NumJobs threads pinned to $NumJobs CPUs - optimal multi-queue distribution" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=256 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1 --cpus_allowed_policy=split --cpus_allowed=$cpuList"

# Test 6: No CPU pinning (tests overflow under imbalance)
Run-FioTest -Name "06-no-pinning" `
    -Description "$NumJobs threads no pinning iodepth=256 - StorPort routes, overflow when needed" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=256 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1"

# Test 7: Mixed read/write
Run-FioTest -Name "07-mixed-rw" `
    -Description "70% read 30% write - tests both read and write paths with multi-queue" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randrw --rwmixread=70 --bs=4k --iodepth=256 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1"

# Test 8: Large block size (scatter-gather stress)
Run-FioTest -Name "08-large-blocksize" `
    -Description "128K blocks - more descriptors per IO, tests scatter-gather limits" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=128k --iodepth=128 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1"

# Test 9: Flush-heavy (data integrity path)
Run-FioTest -Name "09-flush-heavy" `
    -Description "fsync every 8 writes - tests RhelDoFlush with multi-queue" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=32 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1 --end_fsync=1"

# Test 10: Asymmetric CPU pinning (partial overflow)
$halfCpus = [math]::Max(1, [math]::Floor($NumJobs / 2))
$asymCpuList = ((0..($halfCpus - 1)) | ForEach-Object { "$_,$_" }) -join ","
Run-FioTest -Name "10-asymmetric-cpus" `
    -Description "$NumJobs threads on $halfCpus CPUs - forces overflow on overloaded queues" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=256 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1 --cpus_allowed_policy=split --cpus_allowed=$asymCpuList"

# Test 11: Sequential write (ordering test)
Run-FioTest -Name "11-sequential-write" `
    -Description "Sequential 4K writes - tests ordering across queues" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=write --bs=4k --iodepth=256 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1"

# Test 12: Burst pattern (thinktime)
Run-FioTest -Name "12-burst-pattern" `
    -Description "Submit burst then pause 200ms - tests queue drain and refill" `
    -FioArgs "--name=test --ioengine=windowsaio --rw=randwrite --bs=4k --iodepth=256 --numjobs=$NumJobs --filename=$Disk --runtime=$Runtime --time_based --thread --size=1G --direct=1 --thinktime=200ms --thinktime_blocks=64"

# Summary
$summary = @"

$(("=" * 70))
ALL TESTS COMPLETE
Time: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Log saved to: $logFile
$(("=" * 70))
"@

Write-Output $summary
$summary | Out-File -Append $logFile

Write-Output "Results saved to: $logFile"
