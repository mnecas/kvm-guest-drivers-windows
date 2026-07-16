param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("new", "old", "status")]
    [string]$Action
)

$NewDriverUrl = "https://github.com/mnecas/kvm-guest-drivers-windows/raw/refs/heads/fix_viostor_iodepth/mnecas-install"
$LocalDir = "C:\viostor-new"
$IsoPath = "E:\viostor\2k19\amd64"

function Get-CurrentOemName {
    $output = pnputil /enum-drivers 2>&1 | Out-String
    $lines = $output -split "`n"
    $oemNames = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "Original Name:\s+viostor\.inf") {
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
    Write-Host "`n=== viostor Driver Status ===" -ForegroundColor Cyan
    $driver = Get-Item C:\Windows\System32\drivers\viostor.sys -ErrorAction SilentlyContinue
    if ($driver) {
        Write-Host "File:     $($driver.FullName)"
        Write-Host "Date:     $($driver.LastWriteTime)"
        Write-Host "Size:     $($driver.Length) bytes"
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

switch ($Action) {
    "new" {
        Write-Host "`n=== Installing NEW driver (fix_viostor_iodepth) ===" -ForegroundColor Green

        if (-not (Test-Path $LocalDir)) { mkdir $LocalDir | Out-Null }

        Write-Host "Downloading driver files..."
        Invoke-WebRequest -Uri "$NewDriverUrl/viostor.inf" -OutFile "$LocalDir\viostor.inf"
        Invoke-WebRequest -Uri "$NewDriverUrl/viostor.sys" -OutFile "$LocalDir\viostor.sys"
        Invoke-WebRequest -Uri "$NewDriverUrl/viostor.pdb" -OutFile "$LocalDir\viostor.pdb"

        $cert = Ensure-Certificate
        Write-Host "Generating and signing catalog..."
        New-FileCatalog -Path $LocalDir -CatalogFilePath "$LocalDir\viostor.cat" -CatalogVersion 2.0 | Out-Null
        Set-AuthenticodeSignature -FilePath "$LocalDir\viostor.cat" -Certificate $cert | Out-Null

        Write-Host "Removing old driver packages..."
        foreach ($oem in Get-CurrentOemName) {
            Write-Host "  Removing $oem"
            pnputil /delete-driver $oem /force 2>&1 | Out-Null
        }

        Write-Host "Installing new driver..."
        pnputil /add-driver "$LocalDir\viostor.inf" /install

        Show-Status
    }

    "old" {
        Write-Host "`n=== Restoring OLD driver (distributed) ===" -ForegroundColor Yellow

        if (-not (Test-Path $IsoPath)) {
            Write-Host "ERROR: virtio-win ISO not found at $IsoPath" -ForegroundColor Red
            Write-Host "Mount the virtio-win ISO first." -ForegroundColor Red
            return
        }

        Write-Host "Removing current driver packages..."
        foreach ($oem in Get-CurrentOemName) {
            Write-Host "  Removing $oem"
            pnputil /delete-driver $oem /force 2>&1 | Out-Null
        }

        Write-Host "Installing original driver from ISO..."
        pnputil /add-driver "$IsoPath\viostor.inf" /install

        Show-Status
    }

    "status" {
        Show-Status
    }
}
