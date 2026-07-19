param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("new", "new-multi", "new-multi-iterate", "old", "master", "status")]
    [string]$Action,

    [ValidateSet("viostor", "vioscsi")]
    [string]$Driver = "viostor"
)

$DriverDirs = @{
    viostor = @{
        New          = "C:\mnecas-drivers"
        Multi        = "C:\mnecas-multi-drivers"
        MultiIterate = "C:\mnecas-multi-drivers-iterate"
        Master       = "C:\master-drivers"
        Iso          = "D:\viostor\2k19\amd64"
    }
    vioscsi = @{
        New          = "C:\mnecas-drivers-scsi"
        Multi        = "C:\mnecas-multi-drivers-scsi"
        MultiIterate = "C:\mnecas-multi-drivers-scsi-iterate"
        Master       = "C:\master-drivers-scsi"
        Iso          = "D:\vioscsi\2k19\amd64"
    }
}

$cfg = $DriverDirs[$Driver]
$InfName = "$Driver.inf"
$SysName = "$Driver.sys"
$CatName = "$Driver.cat"

function Get-CurrentOemName {
    $output = pnputil /enum-drivers 2>&1 | Out-String
    $lines = $output -split "`n"
    $oemNames = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "Original Name:\s+$([regex]::Escape($InfName))") {
            for ($j = $i - 1; $j -ge 0; $j--) {
                if ($lines[$j] -match "Published Name:\s+(oem\d+\.inf)") {
                    $oemNames += $Matches[1]
                    break
                }
            }
        }
    }
    return $oemNames
}

function Ensure-Certificate {
    $cert = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue
    if (-not $cert) {
        Write-Host "Creating test signing certificate..." -ForegroundColor Yellow
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=Test Driver" -CertStoreLocation "Cert:\LocalMachine\My"
        Export-Certificate -Cert $cert -FilePath C:\test-driver.cer | Out-Null
        Import-Certificate -FilePath C:\test-driver.cer -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
        certutil -addstore TrustedPublisher C:\test-driver.cer | Out-Null
        Write-Host "Certificate created and trusted." -ForegroundColor Green
    }
    return $cert
}

function Show-Status {
    Write-Host "`n=== $Driver Driver Status ===" -ForegroundColor Cyan
    $driverFile = Get-Item "C:\Windows\System32\drivers\$SysName" -ErrorAction SilentlyContinue
    if ($driverFile) {
        Write-Host "File:     $($driverFile.FullName)"
        Write-Host "Date:     $($driverFile.LastWriteTime)"
        Write-Host "Size:     $($driverFile.Length) bytes"
    }
    Write-Host "`nInstalled packages:"
    $oems = Get-CurrentOemName
    if ($oems.Count -eq 0) {
        Write-Host "  (none)"
    } else {
        foreach ($oem in $oems) { Write-Host "  $oem" }
    }
    Write-Host "`nVirtIO disks:"
    Get-Disk | Where-Object { $_.FriendlyName -match "VirtIO" } | Format-Table Number, FriendlyName, Size, OperationalStatus -AutoSize
}

function Install-DriverFrom {
    param([string]$DriverDir, [string]$Label)

    if (-not (Test-Path "$DriverDir\$SysName")) {
        Write-Host "ERROR: $SysName not found in $DriverDir" -ForegroundColor Red
        Write-Host "Copy the built driver files ($SysName + $InfName) there first." -ForegroundColor Red
        return
    }
    if (-not (Test-Path "$DriverDir\$InfName")) {
        Write-Host "ERROR: $InfName not found in $DriverDir" -ForegroundColor Red
        return
    }

    $cert = Ensure-Certificate
    Write-Host "Signing driver..."
    try {
        if (Test-Path "$DriverDir\$CatName") { Remove-Item "$DriverDir\$CatName" -Force }
        New-FileCatalog -Path $DriverDir -CatalogFilePath "$DriverDir\$CatName" -CatalogVersion 2.0 | Out-Null
        Set-AuthenticodeSignature -FilePath "$DriverDir\$CatName" -Certificate $cert | Out-Null
        Write-Host "Catalog signed." -ForegroundColor Green
    } catch {
        Write-Host "Catalog generation failed, signing files directly..." -ForegroundColor Yellow
        Set-AuthenticodeSignature -FilePath "$DriverDir\$SysName" -Certificate $cert | Out-Null
        Set-AuthenticodeSignature -FilePath "$DriverDir\$InfName" -Certificate $cert | Out-Null
        Write-Host "Files signed." -ForegroundColor Green
    }

    Write-Host "Removing old driver packages..."
    foreach ($oem in Get-CurrentOemName) {
        Write-Host "  Removing $oem"
        pnputil /delete-driver $oem /force 2>&1 | Out-Null
    }

    Write-Host "Installing $Label $Driver driver from $DriverDir..."
    pnputil /add-driver "$DriverDir\$InfName" /install

    Show-Status
}

switch ($Action) {
    "new" {
        Write-Host "`n=== Installing NEW $Driver driver ===" -ForegroundColor Green
        Install-DriverFrom -DriverDir $cfg.New -Label "patched"
    }

    "new-multi" {
        Write-Host "`n=== Installing NEW-MULTI $Driver driver ===" -ForegroundColor Magenta
        Install-DriverFrom -DriverDir $cfg.Multi -Label "multiqueue-patched"
    }

    "new-multi-iterate" {
        Write-Host "`n=== Installing NEW-MULTI-ITERATE $Driver driver ===" -ForegroundColor DarkCyan
        Install-DriverFrom -DriverDir $cfg.MultiIterate -Label "multiqueue-iterate-patched"
    }

    "master" {
        Write-Host "`n=== Installing MASTER $Driver driver (upstream) ===" -ForegroundColor Cyan
        Install-DriverFrom -DriverDir $cfg.Master -Label "master"
    }

    "old" {
        Write-Host "`n=== Restoring OLD $Driver driver (ISO distributed) ===" -ForegroundColor Yellow

        if (-not (Test-Path $cfg.Iso)) {
            Write-Host "ERROR: virtio-win ISO not found at $($cfg.Iso)" -ForegroundColor Red
            Write-Host "Mount the virtio-win ISO first." -ForegroundColor Red
            return
        }

        Write-Host "Removing current driver packages..."
        foreach ($oem in Get-CurrentOemName) {
            Write-Host "  Removing $oem"
            pnputil /delete-driver $oem /force 2>&1 | Out-Null
        }

        Write-Host "Installing original driver from ISO..."
        pnputil /add-driver "$($cfg.Iso)\$InfName" /install

        Show-Status
    }

    "status" {
        Show-Status
    }
}
