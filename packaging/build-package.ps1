<#
.SYNOPSIS
Builds the portable application bundle and, by default, a Windows installer.

.DESCRIPTION
This is a maintainer command. End users should install a published
StuffOpener-Setup-<version>.exe instead of running this script.

Use build-package.cmd from PowerShell or Command Prompt to avoid changing the
machine's PowerShell execution policy.
#>
param(
    [string]$Version = "0.1.0",

    [string]$ConfigPath = "",

    [switch]$AllowPrivateConfig,

    [switch]$SkipInstaller,

    [switch]$SkipHotkeyHelper,

    [switch]$PreflightOnly,

    [string]$AutoHotkeyRoot = "",

    [string]$AhkBasePath = "",

    [string]$Ahk2ExePath = "",

    [string]$InnoSetupPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-ToolPath {
    param(
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }

    return $null
}

function Resolve-UvCommand {
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if ($uv) {
        return $uv.Source
    }

    if ($env:USERPROFILE) {
        $candidate = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw @"
uv was not found.

Install uv on the build machine, then rerun packaging.

This script is only for maintainers creating release artifacts.
End users should NOT run this script; they should only double-click:
  StuffOpener-Setup-<version>.exe
"@
}

function ConvertTo-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -match '[\s"]') {
        return '"' + $Value.Replace('"', '\"') + '"'
    }

    return $Value
}

function Wait-ForFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Path) {
            $item = Get-Item $Path -ErrorAction SilentlyContinue
            if ($item -and $item.Length -gt 0) {
                return $true
            }
        }

        Start-Sleep -Milliseconds 250
    }

    return $false
}

function Resolve-RequiredFileOverride {
    param(
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found at the supplied path: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-AutoHotkeyInstallRoots {
    param(
        [string]$AdditionalRoot = ""
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (![string]::IsNullOrWhiteSpace($AdditionalRoot)) {
        [void]$candidates.Add($AdditionalRoot)
    }

    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\AutoHotkey"))
    }
    [void]$candidates.Add("C:\Program Files\AutoHotkey")
    [void]$candidates.Add("C:\Program Files (x86)\AutoHotkey")

    $registryPaths = @(
        "HKCU:\Software\AutoHotkey",
        "HKLM:\Software\AutoHotkey",
        "HKLM:\Software\WOW6432Node\AutoHotkey"
    )
    foreach ($registryPath in $registryPaths) {
        try {
            $installDir = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop).InstallDir
            if (![string]::IsNullOrWhiteSpace($installDir)) {
                [void]$candidates.Add($installDir)
            }
        }
        catch {
            # AutoHotkey does not register every install type or scope.
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or !(Test-Path -LiteralPath $candidate -PathType Container)) {
            continue
        }

        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        $key = $resolved.ToLowerInvariant()
        if (!$seen.ContainsKey($key)) {
            $seen[$key] = $true
            $resolved
        }
    }
}

function Get-AutoHotkeyV2Directories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $directories = @()
    $currentV2 = Join-Path $InstallRoot "v2"
    if (Test-Path -LiteralPath $currentV2 -PathType Container) {
        $directories += Get-Item -LiteralPath $currentV2
    }

    $directories += @(
        Get-ChildItem -LiteralPath $InstallRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^v2\.\d+(?:\.\d+){0,2}$' } |
            Sort-Object LastWriteTime -Descending
    )

    $directories
}

function Resolve-AhkBaseExe {
    param(
        [string[]]$InstallRoots,
        [string]$OverridePath = ""
    )

    $override = Resolve-RequiredFileOverride -Path $OverridePath -Description "AutoHotkey v2 base executable"
    if ($override) {
        return $override
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($installRoot in $InstallRoots) {
        foreach ($versionDir in (Get-AutoHotkeyV2Directories -InstallRoot $installRoot)) {
            [void]$candidates.Add((Join-Path $versionDir.FullName "AutoHotkey64.exe"))
            [void]$candidates.Add((Join-Path $versionDir.FullName "AutoHotkey32.exe"))
            [void]$candidates.Add((Join-Path $versionDir.FullName "Compiler\AutoHotkey64.exe"))
            [void]$candidates.Add((Join-Path $versionDir.FullName "Compiler\AutoHotkey32.exe"))
        }

        # Portable layouts sometimes place the runtime directly in the root.
        [void]$candidates.Add((Join-Path $installRoot "AutoHotkey64.exe"))
        [void]$candidates.Add((Join-Path $installRoot "AutoHotkey32.exe"))
    }

    $resolved = Resolve-ToolPath -Candidates $candidates
    if ($resolved) {
        return $resolved
    }

    $pathCommand = Get-Command AutoHotkey64.exe, AutoHotkey32.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($pathCommand -and $pathCommand.Source) {
        return $pathCommand.Source
    }

    $rootSummary = if ($InstallRoots.Count -gt 0) { $InstallRoots -join "`n  " } else { "(none detected)" }
    throw @"
AutoHotkey v2 runtime executable was not found.

Detected install roots:
  $rootSummary

Install the official AutoHotkey v2 desktop release, provide a custom path with
-AhkBasePath, or build without the optional global hotkey using
-SkipHotkeyHelper.
"@
}

function Resolve-Ahk2Exe {
    param(
        [string[]]$InstallRoots,
        [string]$OverridePath = ""
    )

    $override = Resolve-RequiredFileOverride -Path $OverridePath -Description "Ahk2Exe compiler"
    if ($override) {
        return $override
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($installRoot in $InstallRoots) {
        [void]$candidates.Add((Join-Path $installRoot "Compiler\Ahk2Exe.exe"))
        foreach ($versionDir in (Get-AutoHotkeyV2Directories -InstallRoot $installRoot)) {
            [void]$candidates.Add((Join-Path $versionDir.FullName "Compiler\Ahk2Exe.exe"))
        }
    }

    $resolved = Resolve-ToolPath -Candidates $candidates
    if ($resolved) {
        return $resolved
    }

    $pathCommand = Get-Command Ahk2Exe.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pathCommand -and $pathCommand.Source) {
        return $pathCommand.Source
    }

    throw @"
Ahk2Exe was not found. The AutoHotkey runtime and compiler are separate components.

Open "AutoHotkey Dash" from the Start menu, choose "Compile", and approve the
compiler download. Then rerun this command. You can also provide -Ahk2ExePath
or build without the optional global hotkey using -SkipHotkeyHelper.
"@
}

function Resolve-InnoSetupCompiler {
    param(
        [string]$OverridePath = ""
    )

    $override = Resolve-RequiredFileOverride -Path $OverridePath -Description "Inno Setup compiler"
    if ($override) {
        return $override
    }

    $resolved = Resolve-ToolPath -Candidates @(
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )
    if ($resolved) {
        return $resolved
    }

    throw @"
Inno Setup 6 compiler (ISCC.exe) was not found.

Install Inno Setup 6, provide a custom path with -InnoSetupPath, or use
-SkipInstaller when you only need the unpackaged application bundle.
"@
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appEntry = Join-Path $projectRoot "app.py"
$exampleConfigPath = Join-Path $projectRoot "config.example.json"

if ([string]::IsNullOrWhiteSpace($Version) -or $Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') {
    throw "Version must contain only letters, numbers, dots, plus signs, and hyphens."
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $configCandidate = $exampleConfigPath
    $configMode = "public example"
}
else {
    $configCandidate = $ConfigPath
    if (![System.IO.Path]::IsPathRooted($configCandidate)) {
        $configCandidate = Join-Path $projectRoot $configCandidate
    }
    $configMode = "explicit override"
}

if (!(Test-Path -LiteralPath $configCandidate -PathType Leaf)) {
    throw "Missing configuration seed: $configCandidate"
}

$configSource = (Resolve-Path -LiteralPath $configCandidate).Path
$exampleConfigSource = (Resolve-Path -LiteralPath $exampleConfigPath).Path
$usesExampleConfig = [System.StringComparer]::OrdinalIgnoreCase.Equals($configSource, $exampleConfigSource)

if (!$usesExampleConfig -and !$AllowPrivateConfig) {
    throw @"
Packaging a non-example configuration is blocked by default because the seed is embedded in the installer.

For a private/internal build only, rerun with:
  -ConfigPath <path> -AllowPrivateConfig

Never upload that resulting installer to a public release.
"@
}

if (!$usesExampleConfig) {
    Write-Warning "PRIVATE CONFIG BUILD: the selected configuration will be embedded in the installer."
}
$iconPath = Join-Path $projectRoot "logo_new.ico"
$logoPath = Join-Path $projectRoot "logo.png"
$hotkeyScript = Join-Path $projectRoot "stuff-opener-hotkey.ahk"
$scriptBuildersSource = Join-Path $projectRoot "script_builders"
$innoScript = Join-Path $projectRoot "packaging\StuffOpener.iss"
$instructionsTemplate = Join-Path $projectRoot "packaging\INSTRUCTIONS.txt"

if (!(Test-Path $appEntry)) {
    throw "Missing app entrypoint: $appEntry"
}
if (!(Test-Path $iconPath)) {
    throw "Missing icon file: $iconPath"
}
if (!(Test-Path $logoPath)) {
    throw "Missing logo file: $logoPath"
}
if (!(Test-Path $hotkeyScript)) {
    throw "Missing hotkey script: $hotkeyScript"
}
if (!(Test-Path (Join-Path $projectRoot "pyproject.toml"))) {
    throw "Missing pyproject.toml at repo root. Packaging now builds from the uv-managed project environment."
}
if (!(Test-Path (Join-Path $projectRoot "uv.lock"))) {
    throw "Missing uv.lock at repo root. Run 'uv lock' before packaging."
}

$releaseRoot = Join-Path $projectRoot "dist\release"
$bundleRoot = Join-Path $releaseRoot "app"
$bundleDir = Join-Path $bundleRoot "StuffOpener"
$pyInstallerBuild = Join-Path $releaseRoot "pyinstaller-build"
$pyInstallerSpec = Join-Path $releaseRoot "pyinstaller-spec"
$installerOut = Join-Path $releaseRoot "installer"

$uvExe = Resolve-UvCommand
$autoHotkeyRoots = @(Get-AutoHotkeyInstallRoots -AdditionalRoot $AutoHotkeyRoot)
$ahkBaseExe = $null
$ahk2exe = $null
if (!$SkipHotkeyHelper) {
    $ahkBaseExe = Resolve-AhkBaseExe -InstallRoots $autoHotkeyRoots -OverridePath $AhkBasePath
    $ahk2exe = Resolve-Ahk2Exe -InstallRoots $autoHotkeyRoots -OverridePath $Ahk2ExePath
}

$iscc = $null
if (!$SkipInstaller) {
    $iscc = Resolve-InnoSetupCompiler -OverridePath $InnoSetupPath
}

Write-Host "Build mode: maintainer packaging pipeline."
Write-Host "Config seed: $configMode ($configSource)"
Write-Host "uv:          $uvExe"
if ($SkipHotkeyHelper) {
    Write-Host "Hotkey:      skipped"
}
else {
    Write-Host "Ahk2Exe:     $ahk2exe"
    Write-Host "AHK base:    $ahkBaseExe"
}
if ($SkipInstaller) {
    Write-Host "Installer:   skipped"
}
else {
    Write-Host "Inno Setup:  $iscc"
}
Write-Host "End users should only run StuffOpener-Setup-<version>.exe."
Write-Host ""

if ($PreflightOnly) {
    Write-Host "Preflight complete. No build output was changed."
    exit 0
}

if (Test-Path $releaseRoot) {
    Remove-Item -Recurse -Force $releaseRoot
}
New-Item -ItemType Directory -Force -Path $bundleRoot | Out-Null
New-Item -ItemType Directory -Force -Path $installerOut | Out-Null

Write-Host "Syncing locked Python build environment..."
Push-Location $projectRoot
try {
    & $uvExe sync --locked --group build
    if ($LASTEXITCODE -ne 0) {
        throw "uv sync failed. The lockfile may be stale, or the build environment could not be created."
    }

    Write-Host "Building StuffOpener.exe from uv locked environment..."
    & $uvExe run --locked --no-sync python -m PyInstaller `
        --noconfirm `
        --clean `
        --windowed `
        --name "StuffOpener" `
        --icon $iconPath `
        --add-data "$projectRoot\ui_web\web;ui_web\web" `
        --distpath $bundleRoot `
        --workpath $pyInstallerBuild `
        --specpath $pyInstallerSpec `
        $appEntry

    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller failed."
    }
}
finally {
    Pop-Location
}

if (!(Test-Path (Join-Path $bundleDir "StuffOpener.exe"))) {
    throw "PyInstaller build did not produce StuffOpener.exe in $bundleDir"
}

Copy-Item -LiteralPath $configSource -Destination (Join-Path $bundleDir "default_config.json") -Force
Copy-Item $iconPath (Join-Path $bundleDir "logo_new.ico") -Force
Copy-Item $logoPath (Join-Path $bundleDir "logo.png") -Force
Copy-Item $hotkeyScript (Join-Path $bundleDir "stuff-opener-hotkey.ahk") -Force

if (Test-Path $scriptBuildersSource) {
    Copy-Item $scriptBuildersSource (Join-Path $bundleDir "script_builders") -Recurse -Force
}
if (Test-Path (Join-Path $projectRoot "ui_web")) {
    Copy-Item (Join-Path $projectRoot "ui_web") (Join-Path $bundleDir "ui_web") -Recurse -Force
}
if (Test-Path (Join-Path $projectRoot "core")) {
    Copy-Item (Join-Path $projectRoot "core") (Join-Path $bundleDir "core") -Recurse -Force
}

# Source imports and test runs can leave bytecode caches in the project tree.
# They are not required in the release bundle copied beside the frozen app.
Get-ChildItem -Path $bundleDir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force
Get-ChildItem -Path $bundleDir -Recurse -File -Include "*.pyc", "*.pyo" -ErrorAction SilentlyContinue |
    Remove-Item -Force

$hotkeyExeOut = Join-Path $bundleDir "stuff-opener-hotkey.exe"
if (!$SkipHotkeyHelper) {
    if (Test-Path $hotkeyExeOut) {
        Remove-Item -Force $hotkeyExeOut
    }

    Write-Host "Compiling hotkey helper executable..."
    Write-Host "Ahk2Exe:  $ahk2exe"
    Write-Host "AHK base: $ahkBaseExe"
    Write-Host "Input:    $hotkeyScript"
    Write-Host "Output:   $hotkeyExeOut"

    $ahkArgs = @(
        "/in", $hotkeyScript,
        "/out", $hotkeyExeOut,
        "/base", $ahkBaseExe,
        "/icon", $iconPath
    )

    $ahkStartArgs = $ahkArgs | ForEach-Object { ConvertTo-ProcessArgument $_ }
    $ahkProcess = Start-Process -FilePath $ahk2exe -ArgumentList $ahkStartArgs -Wait -PassThru

    $ahkExitCode = $ahkProcess.ExitCode

    if ($null -ne $ahkExitCode -and $ahkExitCode -ne 0) {
        throw "Ahk2Exe failed with exit code $ahkExitCode."
    }

    if (!(Wait-ForFile -Path $hotkeyExeOut -TimeoutSeconds 20)) {
        Write-Host ""
        Write-Host "Expected hotkey helper was not created at:"
        Write-Host "  $hotkeyExeOut"
        Write-Host ""
        Write-Host "Searching release folder for any generated hotkey exe..."
        Get-ChildItem $releaseRoot -Recurse -Filter "*hotkey*.exe" -ErrorAction SilentlyContinue |
            Select-Object FullName, Length, LastWriteTime |
            Format-Table -AutoSize

        throw "Hotkey helper compile failed. Ahk2Exe returned success, but the output exe was not found."
    }
}
else {
    Write-Host "Skipping compiled hotkey helper. The .ahk source remains in the bundle for users who already have AutoHotkey v2."
}

if ($SkipInstaller) {
    Write-Host ""
    Write-Host "Build complete (installer skipped)."
    Write-Host "Bundle path: $bundleDir"
    exit 0
}

if (!(Test-Path $innoScript)) {
    throw "Missing Inno Setup script: $innoScript"
}

Write-Host "Compiling installer..."
$includeHotkeyHelper = if ($SkipHotkeyHelper) { "0" } else { "1" }
& $iscc `
    "/DAppVersion=$Version" `
    "/DSourceDir=$bundleDir" `
    "/DOutputDir=$installerOut" `
    "/DIncludeHotkeyHelper=$includeHotkeyHelper" `
    $innoScript

if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compiler failed."
}

if (Test-Path $instructionsTemplate) {
    Copy-Item $instructionsTemplate (Join-Path $installerOut "INSTRUCTIONS.txt") -Force
}

Write-Host ""
Write-Host "Build complete."
Write-Host "App bundle: $bundleDir"
Write-Host "Installer output: $installerOut"
