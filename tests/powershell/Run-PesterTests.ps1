[CmdletBinding()]
param(
    [string[]]$Tag = @(),

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $testRoot "..\..")

$pesterModule = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule) {
    throw "Pester is not installed. Install Pester separately, then rerun $($MyInvocation.MyCommand.Path)."
}

Import-Module Pester -ErrorAction Stop
Write-Host "Pester: $($pesterModule.Version)" -ForegroundColor Cyan
Write-Host "Repo:   $repoRoot" -ForegroundColor DarkCyan
Write-Host "Tests:  $testRoot" -ForegroundColor DarkCyan

$invokeParams = @{
    Path = $testRoot
}
if ($Tag.Count -gt 0) {
    $invokeParams.Tag = $Tag
}
if ($PassThru) {
    $invokeParams.PassThru = $true
}

Invoke-Pester @invokeParams
