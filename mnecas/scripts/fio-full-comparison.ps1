# Full FIO comparison: master vs patched on both disks
# All output goes to a single log file

param(
    [int]$NumJobs = 0
)

$LogFile = "C:\fio-results\fio-full-comparison-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

Write-Host "Full comparison log: $LogFile"

& {
    Write-Output "======================================================================"
    Write-Output "FULL FIO COMPARISON RUN"
    Write-Output "Time: $(Get-Date)"
    Write-Output "NumJobs: $NumJobs"
    Write-Output "======================================================================"

    # --- Master driver ---
    Write-Output ""
    Write-Output "######################################################################"
    Write-Output "DRIVER: master"
    Write-Output "######################################################################"
    C:\switch-driver.ps1 master

    Write-Output ""
    Write-Output "=== master on PhysicalDrive1 ==="
    C:\fio-tests.ps1 -Disk "\\.\PhysicalDrive1" -NumJobs $NumJobs

    Write-Output ""
    Write-Output "=== master on PhysicalDrive2 ==="
    C:\fio-tests.ps1 -Disk "\\.\PhysicalDrive2" -NumJobs $NumJobs

    # --- Patched driver ---
    Write-Output ""
    Write-Output "######################################################################"
    Write-Output "DRIVER: new-multi-iterate"
    Write-Output "######################################################################"
    C:\switch-driver.ps1 new-multi-iterate

    Write-Output ""
    Write-Output "=== new-multi-iterate on PhysicalDrive1 ==="
    C:\fio-tests.ps1 -Disk "\\.\PhysicalDrive1" -NumJobs $NumJobs

    Write-Output ""
    Write-Output "=== new-multi-iterate on PhysicalDrive2 ==="
    C:\fio-tests.ps1 -Disk "\\.\PhysicalDrive2" -NumJobs $NumJobs

    Write-Output ""
    Write-Output "======================================================================"
    Write-Output "ALL DONE - $(Get-Date)"
    Write-Output "======================================================================"
} *>&1 | Tee-Object -FilePath $LogFile

Write-Host "Results saved to: $LogFile"
