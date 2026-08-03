$script:PowerShellTestRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")
$script:PowerShellRepoRoot = Resolve-Path (Join-Path $script:PowerShellTestRoot "..\..")

function Get-TestRepoRoot {
    return [string]$script:PowerShellRepoRoot
}

function Get-TestSharedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (Join-Path $script:PowerShellRepoRoot "script_builders\shared\$Name")
}

function Import-SharedPowerShell {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $path = Get-TestSharedPath -Name $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Shared PowerShell file not found: $path"
        }

        . $path
    }
}

function Reset-TestInputQueue {
    param(
        [AllowNull()]
        [object[]]$Inputs = @()
    )

    $script:TestInputQueue = New-Object System.Collections.Queue
    foreach ($inputValue in @($Inputs)) {
        $script:TestInputQueue.Enqueue([string]$inputValue)
    }
}

function Read-TestInputQueue {
    if ($null -eq $script:TestInputQueue -or $script:TestInputQueue.Count -eq 0) {
        throw "Test input queue is empty. Add input with Reset-TestInputQueue before the prompt is reached."
    }

    return [string]$script:TestInputQueue.Dequeue()
}

function Get-TestInputQueueCount {
    if ($null -eq $script:TestInputQueue) {
        return 0
    }

    return $script:TestInputQueue.Count
}

function Initialize-TestUiState {
    $script:UiStepNumber = 0
    $script:UiStepResults = New-Object System.Collections.ArrayList
    $script:UiActionLog = New-Object System.Collections.ArrayList
    $script:UiWidth = 120
    $script:RunContext = [ordered]@{}
    $script:MailboxSnapshotFreshnessNoteShown = $false
}
