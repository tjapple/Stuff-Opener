
# Contains helper functions for importing, installing, connecting to PowerShell modules.




function Import-OrInstallPowerShellModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [string]$InstallName = $ModuleName,

        [ValidateSet("CurrentUser", "AllUsers")]
        [string]$Scope = "CurrentUser"
    )

    try {
        Write-UiStatus -Status "LOADING..." -Message "Loading $ModuleName module." -Color Cyan
        Import-Module $ModuleName -ErrorAction Stop
        Write-UiStatus -Status "OK" -Message "Loaded $ModuleName module." -Color Green
        return
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not load PowerShell module '$ModuleName': $($_.Exception.Message)" -Color Yellow
    }

    $installAnswer = Read-UiInput -Prompt "Install '$InstallName' from PowerShell Gallery for $Scope?" -Options @("y=install", "blank=exit")
    if ($installAnswer -ne "y") {
        throw "Required PowerShell module '$ModuleName' is not loaded. Install '$InstallName' and rerun the script."
    }

    if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
        throw "Install-Module was not found. Install PowerShellGet or install '$InstallName' manually, then rerun the script."
    }

    try {
        Install-Module -Name $InstallName -Scope $Scope -Force -AllowClobber -ErrorAction Stop
        Import-Module $ModuleName -Force -ErrorAction Stop
        Write-UiStatus -Status "OK" -Message "Installed and loaded PowerShell module '$ModuleName'." -Color Green
    }
    catch {
        throw "Could not install or load PowerShell module '$InstallName': $($_.Exception.Message)"
    }
}


function Connect-M365ServicesExchangeOnline {
    Import-OrInstallPowerShellModule -ModuleName "ExchangeOnlineManagement"

    try {
        Write-UiStatus -Status "LOADING..." -Message "Disconnecting from any existing Exchange Online sessions." -Color Cyan
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {}

    Write-UiStatus -Status "LOADING..." -Message "Creating a fresh connection to Exchange Online." -Color Cyan
    Connect-ExchangeOnline -ShowBanner:$false -DisableWAM
    Write-UiStatus -Status "OK" -Message "Connected to Exchange Online." -Color Green
}

function Start-EntraConnectDeltaSync {
    $adSyncBin = Join-Path $env:ProgramFiles "Microsoft Azure AD Sync\Bin"
    if (Test-Path -LiteralPath $adSyncBin) {
        $env:PATH = "$adSyncBin;$env:PATH"
    }

    try {
        Import-Module ADSync -ErrorAction Stop
        Start-ADSyncSyncCycle -PolicyType Delta -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "Could not run ADSync in this PowerShell session: $($_.Exception.Message)"
    }

    $sysnativeWindowsPowerShell = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    $system32WindowsPowerShell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $windowsPowerShell = if (Test-Path -LiteralPath $sysnativeWindowsPowerShell) {
        $sysnativeWindowsPowerShell
    }
    else {
        $system32WindowsPowerShell
    }

    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        Write-Host "Windows PowerShell 5.1 was not found at '$windowsPowerShell'. Run delta sync manually from the Entra Connect server."
        return $false
    }

    Write-Host ""
    Write-Host "--------"
    Write-Host "Trying Entra Connect delta sync in Windows PowerShell 5.1..."
    Write-Host "Using PowerShell executable: $windowsPowerShell"

    $syncScript = @'
$ErrorActionPreference = "Stop"
$adSyncBin = Join-Path $env:ProgramFiles "Microsoft Azure AD Sync\Bin"
if (Test-Path -LiteralPath $adSyncBin) {
    $env:PATH = "$adSyncBin;$env:PATH"
}
$adSyncModule = Join-Path $adSyncBin "ADSync\ADSync.psd1"
if (Test-Path -LiteralPath $adSyncModule) {
    Import-Module $adSyncModule -ErrorAction Stop
}
else {
    Import-Module ADSync -ErrorAction Stop
}
Start-ADSyncSyncCycle -PolicyType Delta -ErrorAction Stop
'@
    $encodedSyncScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($syncScript))
    $syncOutput = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedSyncScript 2>&1
    $syncExitCode = $LASTEXITCODE

    if ($syncExitCode -eq 0) {
        if ($syncOutput) {
            $syncOutput | ForEach-Object { Write-Host $_ }
        }
        return $true
    }

    Write-Host "Could not run Entra Connect delta sync in Windows PowerShell 5.1."
    if ($syncOutput) {
        $syncOutput | ForEach-Object { Write-Host $_ }
    }
    Write-Host "Run this manually on the Entra Connect server in Windows PowerShell 5.1:"
    Write-Host "  Import-Module ADSync"
    Write-Host "  Start-ADSyncSyncCycle -PolicyType Delta"
    return $false
}
