# ============================================================
# Windows 11 Windows Update + Windows Insider Repair
# Safe component reset - does not run SFC or DISM
# ============================================================

[CmdletBinding()]
param(
    [switch]$SkipInsiderReset
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $env:SystemDrive "WU_Repair_Backup_$timestamp"

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as administrator'." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

Write-Host "=== Windows 11 Windows Update + Windows Insider Repair ===" -ForegroundColor Cyan
Write-Host "Backup directory: $backupRoot" -ForegroundColor Gray
Write-Host "SFC/DISM are intentionally not used by this script." -ForegroundColor Gray

# ------------------------------------------------------------
# 1. Stop Windows Update-related services
# ------------------------------------------------------------
Write-Section "1. Stop Windows Update-related services"

$services = @(
    "wuauserv",
    "bits",
    "cryptsvc",
    "dosvc",
    "msiserver"
)

foreach ($svc in $services) {
    try {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        Write-Host "[OK] Stopped: $svc" -ForegroundColor Green
    }
    catch {
        Write-Host "[INFO] Could not stop or service is already stopped: $svc" -ForegroundColor DarkYellow
    }
}

# ------------------------------------------------------------
# 2. Reset Windows Update caches
#    Rename instead of deleting so the previous state is recoverable.
# ------------------------------------------------------------
Write-Section "2. Reset Windows Update caches"

$softwareDistribution = Join-Path $env:SystemRoot "SoftwareDistribution"
$catroot2 = Join-Path $env:SystemRoot "System32\catroot2"

$cacheItems = @(
    @{ Path = $softwareDistribution; BackupName = "SoftwareDistribution_$timestamp" },
    @{ Path = $catroot2;             BackupName = "catroot2_$timestamp" }
)

foreach ($item in $cacheItems) {
    if (Test-Path $item.Path) {
        $destination = Join-Path $backupRoot $item.BackupName

        try {
            Rename-Item -Path $item.Path -NewName $item.BackupName -ErrorAction Stop
            Write-Host "[OK] Renamed: $($item.Path)" -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not rename: $($item.Path)" -ForegroundColor Yellow
            Write-Host "       $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

# Windows Update and Cryptographic Services recreate these directories as needed.
New-Item -ItemType Directory -Path $softwareDistribution -Force | Out-Null
New-Item -ItemType Directory -Path $catroot2 -Force | Out-Null

# ------------------------------------------------------------
# 3. Clear the BITS transfer queue
# ------------------------------------------------------------
Write-Section "3. Clear the BITS transfer queue"

$qmgrPath = Join-Path $env:ProgramData "Microsoft\Network\Downloader"
$qmgrFiles = Get-ChildItem -Path $qmgrPath -Filter "qmgr*.dat" -File -ErrorAction SilentlyContinue

if ($qmgrFiles) {
    foreach ($file in $qmgrFiles) {
        try {
            Remove-Item -Path $file.FullName -Force -ErrorAction Stop
            Write-Host "[OK] Removed BITS queue file: $($file.Name)" -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not remove: $($file.FullName)" -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host "[INFO] No BITS queue files were found." -ForegroundColor Gray
}

# ------------------------------------------------------------
# 4. Do not manually delete WinSxS\pending.xml
#    Windows component servicing owns this file. Removing it
#    manually can make servicing problems harder to diagnose.
# ------------------------------------------------------------
Write-Section "4. Preserve Windows component servicing state"

$pendingXml = Join-Path $env:SystemRoot "WinSxS\pending.xml"

if (Test-Path $pendingXml) {
    Write-Host "[INFO] pending.xml exists. It was NOT deleted." -ForegroundColor Yellow
    Write-Host "       Windows servicing will manage this file during reboot/update processing." -ForegroundColor Gray
}
else {
    Write-Host "[OK] No pending.xml file is present." -ForegroundColor Green
}

# ------------------------------------------------------------
# 5. Re-register Windows Update components
#    This follows Microsoft's documented legacy component
#    re-registration procedure. Missing DLLs are skipped.
# ------------------------------------------------------------
Write-Section "5. Re-register Windows Update components"

$dlls = @(
    "atl.dll",
    "urlmon.dll",
    "mshtml.dll",
    "shdocvw.dll",
    "browseui.dll",
    "jscript.dll",
    "vbscript.dll",
    "scrrun.dll",
    "msxml.dll",
    "msxml3.dll",
    "msxml6.dll",
    "actxprxy.dll",
    "softpub.dll",
    "wintrust.dll",
    "dssenh.dll",
    "rsaenh.dll",
    "gpkcsp.dll",
    "sccbase.dll",
    "slbcsp.dll",
    "cryptdlg.dll",
    "oleaut32.dll",
    "ole32.dll",
    "shell32.dll",
    "initpki.dll",
    "wuapi.dll",
    "wuaueng.dll",
    "wuaueng1.dll",
    "wucltui.dll",
    "wups.dll",
    "wups2.dll",
    "wuweb.dll",
    "qmgr.dll",
    "qmgrprxy.dll",
    "wucltux.dll",
    "muweb.dll",
    "wuwebv.dll"
)

$regsvr32 = Join-Path $env:SystemRoot "System32\regsvr32.exe"

foreach ($dll in $dlls) {
    $path = Join-Path $env:SystemRoot "System32\$dll"

    if (Test-Path $path) {
        $process = Start-Process -FilePath $regsvr32 `
            -ArgumentList "/s `"$path`"" `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        if ($process.ExitCode -eq 0) {
            Write-Host "[OK] Registered: $dll" -ForegroundColor Green
        }
        else {
            Write-Host "[WARN] regsvr32 exit code $($process.ExitCode): $dll" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[SKIP] Not present: $dll" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------
# 6. Reset Windows Insider configuration
#    The default target is the current Canary branch format:
#    CanaryChannel / Mainline / External.
#
#    The registry is exported before modification.
#    Use -SkipInsiderReset to perform only the Windows Update
#    component reset.
# ------------------------------------------------------------
if (-not $SkipInsiderReset) {
    Write-Section "6. Reset Windows Insider configuration"

    $selfHost = "HKLM\SOFTWARE\Microsoft\WindowsSelfHost"
    $selfHostPs = "HKLM:\SOFTWARE\Microsoft\WindowsSelfHost"

    $regBackup = Join-Path $backupRoot "WindowsSelfHost.reg"
    & reg.exe export $selfHost $regBackup /y | Out-Null

    if (Test-Path $regBackup) {
        Write-Host "[OK] WindowsSelfHost registry backup created." -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] Could not create WindowsSelfHost registry backup." -ForegroundColor Yellow
    }

    # Remove only the Insider enrollment state.
    # Windows can recreate the required registry structure.
    if (Test-Path $selfHostPs) {
        try {
            Remove-Item -Path $selfHostPs -Recurse -Force -ErrorAction Stop
            Write-Host "[OK] Removed existing WindowsSelfHost configuration." -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not remove WindowsSelfHost: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    New-Item -Path "$selfHostPs\Applicability" -Force | Out-Null
    New-Item -Path "$selfHostPs\UI\Selection" -Force | Out-Null

    # Microsoft Insider configuration uses "CanaryChannel" rather than "Canary".
    New-ItemProperty -Path "$selfHostPs\Applicability" `
        -Name "BranchName" -Value "CanaryChannel" -PropertyType String -Force | Out-Null

    New-ItemProperty -Path "$selfHostPs\Applicability" `
        -Name "ContentType" -Value "Mainline" -PropertyType String -Force | Out-Null

    New-ItemProperty -Path "$selfHostPs\Applicability" `
        -Name "Ring" -Value "External" -PropertyType String -Force | Out-Null

    New-ItemProperty -Path "$selfHostPs\UI\Selection" `
        -Name "UIBranch" -Value "CanaryChannel" -PropertyType String -Force | Out-Null

    New-ItemProperty -Path "$selfHostPs\UI\Selection" `
        -Name "UIContentType" -Value "Mainline" -PropertyType String -Force | Out-Null

    New-ItemProperty -Path "$selfHostPs\UI\Selection" `
        -Name "UIRing" -Value "External" -PropertyType String -Force | Out-Null

    Write-Host "[OK] Windows Insider configuration set to CanaryChannel / Mainline / External." -ForegroundColor Green
}
else {
    Write-Section "6. Windows Insider configuration"
    Write-Host "[SKIP] Insider registry reset was disabled with -SkipInsiderReset." -ForegroundColor Gray
}

# ------------------------------------------------------------
# 7. Restore normal service startup modes
# ------------------------------------------------------------
Write-Section "7. Restore Windows Update service startup modes"

$startupModes = @{
    "wuauserv" = "Manual"
    "bits"     = "Manual"
    "cryptsvc" = "Automatic"
    "dosvc"    = "Manual"
    "msiserver" = "Manual"
}

foreach ($svc in $startupModes.Keys) {
    try {
        Set-Service -Name $svc -StartupType $startupModes[$svc] -ErrorAction Stop
        Write-Host "[OK] $svc -> $($startupModes[$svc])" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Could not set startup type for $svc" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# 8. Start services
# ------------------------------------------------------------
Write-Section "8. Start Windows Update-related services"

foreach ($svc in $services) {
    try {
        Start-Service -Name $svc -ErrorAction Stop
        Write-Host "[OK] Started: $svc" -ForegroundColor Green
    }
    catch {
        Write-Host "[INFO] Could not start or service is not required to run continuously: $svc" -ForegroundColor DarkYellow
    }
}

# ------------------------------------------------------------
# 9. Trigger a Windows Update scan
#    StartScan is used only to initiate detection.
#    Download/install are intentionally left to Windows Update
#    instead of forcing an immediate installation from a script.
# ------------------------------------------------------------
Write-Section "9. Trigger a Windows Update scan"

$uso = Join-Path $env:SystemRoot "System32\UsoClient.exe"

if (Test-Path $uso) {
    Start-Process -FilePath $uso -ArgumentList "StartScan" -WindowStyle Hidden
    Write-Host "[OK] Windows Update scan requested." -ForegroundColor Green
}
else {
    Write-Host "[WARN] UsoClient.exe was not found." -ForegroundColor Yellow
}

# ------------------------------------------------------------
# 10. Final status
# ------------------------------------------------------------
Write-Section "10. Repair completed"

Write-Host "[OK] Windows Update component reset completed." -ForegroundColor Green
Write-Host "[OK] Backup data is stored in:" -ForegroundColor Green
Write-Host "     $backupRoot" -ForegroundColor White
Write-Host ""
Write-Host "Recommended next step:" -ForegroundColor Yellow
Write-Host "1. Restart Windows." -ForegroundColor White
Write-Host "2. Open Settings -> Windows Update." -ForegroundColor White
Write-Host "3. Check for updates." -ForegroundColor White
Write-Host "4. If you use Windows Insider, verify the Insider channel after reboot." -ForegroundColor White
Write-Host ""
Write-Host "To repair Windows Update without changing Insider registry settings:" -ForegroundColor Gray
Write-Host "    .\WIN11_REPAIR_WU_WI.ps1 -SkipInsiderReset" -ForegroundColor Gray