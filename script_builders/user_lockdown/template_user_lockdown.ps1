# -------------------------
# Fill these in per ticket.
# -------------------------

$Client = "Client"
$UserLookup = "user@example.com"
$TicketNumber = ""

# Run options.
$RunADSync = $true
$CheckEmailRules = $true
$DryRun = $true
$Force = $false

# -------------------------
# 0.5. Prep work: import modules and define helper functions.
# -------------------------

$ErrorActionPreference = "Stop"

function Invoke-Main {
    Initialize-UiState
    Write-UiBanner
    Write-UiHeader -Title "User Lockdown" -Subtitle "Client: $Client"
    Write-UiBox -Title "Preflight" -Lines @(
        New-UiBoxLine -Label "Client" -Value $Client
        New-UiBoxLine -Label "User lookup" -Value $UserLookup
        New-UiBoxLine -Label "Ticket" -Value $TicketNumber
        New-UiBoxLine -Label "Run mode" -Value $(if ($DryRun) { "Dry run" } else { "Live changes" })
        New-UiBoxLine -Label "Run AD sync" -Value $RunADSync
        New-UiBoxLine -Label "Check email rules" -Value $CheckEmailRules
        New-UiBoxLine -Label "Force" -Value $Force
    )

    Import-ActiveDirectoryModule
    $targetUser = Get-LockdownTargetUserDetails -Lookup $UserLookup
    $script:RunContext["TargetUser"] = $targetUser
    Show-AdUserState -Identity ([string]$targetUser.AdUser.ObjectGUID) -Title "Matched AD User"

    Write-UiSection "1. Cloud Session Revocation"
    Connect-LockdownCloudServices
    $cloudUser = Find-LockdownCloudUser -TargetUser $targetUser
    $script:RunContext["CloudUserId"] = $cloudUser.id
    $script:RunContext["CloudUserPrincipalName"] = $cloudUser.userPrincipalName
    Format-CloudUserState -CloudUser $cloudUser -Source "lockdown cloud match"
    Invoke-CloudUserLockdown -CloudUser $cloudUser

    Write-UiSection "2. MFA Audit and Reset"
    Invoke-MfaAuditAndReset -CloudUser $cloudUser

    Write-UiSection "3. On-Prem AD Lockdown"
    Invoke-OnPremUserLockdown -TargetUser $targetUser

    Write-UiSection "4. Entra Connect Delta Sync"
    Invoke-LockdownDeltaSync

    Write-UiSection "5. Cloud Account Disable"
    $disabledCloudUser = Invoke-LockdownCloudAccountDisable -CloudUser $cloudUser
    if ($disabledCloudUser) {
        $cloudUser = $disabledCloudUser
    }

    if ($CheckEmailRules) {
        Write-UiSection "6. Mailbox Rule Inspection"
        Connect-M365ServicesExchangeOnline
        Invoke-InteractiveInboxRuleAudit -UserPrincipalName $cloudUser.userPrincipalName | Out-Null
    }
    else {
        Write-UiSection "6. Mailbox Rule Inspection"
        Write-UiStatus -Status "SKIP" -Message "CheckEmailRules is false. Skipping mailbox rule inspection." -Color Yellow
        Add-UiStepResult -Name "Mailbox rule inspection" -Result "Skipped" -Note "CheckEmailRules was false."
    }

    Write-UiFinalLockdownSummary -Title "User Lockdown Run Complete" -Subtitle "Review final state and next steps before closing."
}

function Get-LockdownTargetUserDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup
    )

    if ([string]::IsNullOrWhiteSpace($Lookup)) {
        throw "UserLookup is required."
    }

    $adUser = Resolve-AdUserLookup -Lookup $Lookup -Purpose "lockdown target user"
    $userPrincipalName = $adUser.UserPrincipalName
    if ([string]::IsNullOrWhiteSpace($userPrincipalName)) {
        $userPrincipalName = $adUser.mail
    }
    if ([string]::IsNullOrWhiteSpace($userPrincipalName)) {
        throw "AD user '$($adUser.SamAccountName)' does not have UserPrincipalName or mail populated. Use a more specific lookup or update AD before cloud steps."
    }

    $sourceAnchor = Get-AdUserSourceAnchorInfo -User $adUser
    return [pscustomobject]@{
        AdUser                = $adUser
        ObjectGUID            = $adUser.ObjectGUID
        SamAccountName        = $adUser.SamAccountName
        UserPrincipalName     = $userPrincipalName
        OnPremisesImmutableId = $sourceAnchor.ImmutableId
        SourceAnchorAttribute = $sourceAnchor.Attribute
    }
}

function New-LockdownRandomPassword {
    param(
        [int]$Length = 32
    )

    $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower = "abcdefghijkmnopqrstuvwxyz"
    $digits = "23456789"
    $special = "!#$%&*+-=?@^_"
    $all = $upper + $lower + $digits + $special
    $required = @($upper, $lower, $digits, $special)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    function Get-RandomCharFromSet {
        param([Parameter(Mandatory = $true)][string]$Characters)
        $buffer = New-Object byte[] 4
        $rng.GetBytes($buffer)
        $index = [BitConverter]::ToUInt32($buffer, 0) % $Characters.Length
        return $Characters[[int]$index]
    }

    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in $required) {
        $chars.Add((Get-RandomCharFromSet -Characters $set))
    }
    while ($chars.Count -lt $Length) {
        $chars.Add((Get-RandomCharFromSet -Characters $all))
    }

    for ($i = 0; $i -lt $chars.Count; $i++) {
        $buffer = New-Object byte[] 4
        $rng.GetBytes($buffer)
        $swapIndex = [int]([BitConverter]::ToUInt32($buffer, 0) % $chars.Count)
        $temp = $chars[$i]
        $chars[$i] = $chars[$swapIndex]
        $chars[$swapIndex] = $temp
    }

    $rng.Dispose()
    return -join $chars
}

function Do-LockdownStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,

        [string]$CommandPreview = "",

        [string]$SuccessMessage = "",

        [scriptblock]$Verify,

        [switch]$Required,

        [switch]$PassThru
    )

    $script:UiStepNumber = $script:UiStepNumber + 1
    $stepNumber = $script:UiStepNumber
    Write-Host ""
    Write-Host ("STEP {0}: {1}:" -f $stepNumber, $Name) -ForegroundColor Cyan

    if ($null -ne $Verify) {
        try {
            if (& $Verify) {
                $message = "Already verified: $Name."
                Write-UiStatus -Status "VERIFIED" -Message $message -Color Green
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Verified" -Note $message -CommandPreview $CommandPreview
                return
            }
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "Verification before '$Name' could not complete: $($_.Exception.Message)" -Color Yellow
        }
    }

    if (-not $Force) {
        while ($true) {
            $options = @("y=run", "d=details", "s=skip", "a=abort")
            if ($Required) {
                $options = @("y=run", "d=details", "a=abort")
            }
            $choice = Read-UiInput -Prompt $Name -Options $options
            if ($choice -eq "y") {
                break
            }
            if ($choice -eq "d") {
                Write-UiStepDetails -CommandPreview $CommandPreview
                continue
            }
            if ($choice -eq "s" -and -not $Required) {
                Write-UiStatus -Status "SKIP" -Message "Skipped '$Name' by operator choice." -Color Yellow
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Skipped" -Note "Skipped by operator." -CommandPreview $CommandPreview
                return
            }
            if ($choice -eq "a") {
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Aborted" -Note "Aborted by operator." -CommandPreview $CommandPreview
                throw "Workflow aborted by operator at step ${stepNumber}: $Name"
            }
            Write-UiStatus -Status "INFO" -Message "Enter exact lowercase y, d, s, or a." -Color Yellow
        }
    }

    if ([string]::IsNullOrWhiteSpace($SuccessMessage)) {
        $SuccessMessage = "Step completed: $Name."
    }

    while ($true) {
        try {
            $result = Invoke-UiCommand -Name $Name -CommandPreview $CommandPreview -Command $Command -PassThru:$PassThru
            if (Test-UiDryRun) {
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Dry run" -Note "No changes made." -CommandPreview $CommandPreview
            }
            else {
                Write-UiStatus -Status "OK" -Message $SuccessMessage -Color Green
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Completed" -Note $SuccessMessage -CommandPreview $CommandPreview
            }
            if ($PassThru) {
                return $result
            }
            return
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-UiStatus -Status "FAIL" -Message $errorMessage -Color Red
            while ($true) {
                $choice = Read-UiInput -Prompt "Step failed. Next action?" -Options @("r=retry", "d=details", "s=skip", "a=abort")
                if ($choice -eq "r") {
                    break
                }
                if ($choice -eq "d") {
                    Write-UiStepDetails -CommandPreview $CommandPreview
                    continue
                }
                if ($choice -eq "s" -and -not $Required) {
                    Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Skipped" -Note $errorMessage -CommandPreview $CommandPreview
                    return
                }
                if ($choice -eq "a") {
                    Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Aborted" -Note $errorMessage -CommandPreview $CommandPreview
                    throw "Workflow aborted by operator at step ${stepNumber}: $Name. Last error: $errorMessage"
                }
                Write-UiStatus -Status "INFO" -Message "Enter exact lowercase r, d, s, or a." -Color Yellow
            }
        }
    }
}

function Invoke-OnPremUserLockdown {
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser
    )

    $samAccountName = $TargetUser.SamAccountName
    $userObjectGuid = [string]$TargetUser.AdUser.ObjectGUID

    Do-LockdownStep -Name "Disable on-prem AD account" `
        -CommandPreview "Disable-ADAccount -Identity '$userObjectGuid'" `
        -SuccessMessage "Disabled AD account '$samAccountName'." `
        -Verify {
        -not (Get-ADUser -Identity $userObjectGuid -Properties Enabled).Enabled
    } `
        -Command {
        Disable-ADAccount -Identity $userObjectGuid -ErrorAction Stop
    }

    for ($rotation = 1; $rotation -le 2; $rotation++) {
        Do-LockdownStep -Name "Change AD password to random value ($rotation of 2)" `
            -CommandPreview "Set-ADAccountPassword -Identity '$userObjectGuid' -Reset -NewPassword <random secure password>" `
            -SuccessMessage "Changed AD password for '$samAccountName' to a random value ($rotation of 2)." `
            -Command {
            $randomPassword = New-LockdownRandomPassword
            $securePassword = ConvertTo-SecureString -String $randomPassword -AsPlainText -Force
            try {
                Set-ADAccountPassword -Identity $userObjectGuid -Reset -NewPassword $securePassword -ErrorAction Stop
            }
            finally {
                if ($securePassword) {
                    $securePassword.Dispose()
                }
                $randomPassword = $null
            }
        }
    }
}

function Invoke-LockdownDeltaSync {
    if (-not $RunADSync) {
        Write-UiStatus -Status "SKIP" -Message "RunADSync is false. Run delta sync manually before expecting cloud disablement." -Color Yellow
        Add-UiStepResult -Name "Entra Connect delta sync" -Result "Skipped" -Note "RunADSync was false."
        return
    }

    Do-LockdownStep -Name "Start Entra Connect delta sync" `
        -Required `
        -CommandPreview "Import-Module ADSync`nStart-ADSyncSyncCycle -PolicyType Delta" `
        -SuccessMessage "Entra Connect delta sync was run or manually confirmed." `
        -Command {
        while ($true) {
            if (Start-EntraConnectDeltaSync) {
                return
            }

            Write-UiStatus -Status "SYNC" -Message "Automatic delta sync did not complete. Cloud disablement should not be trusted until sync has run." -Color Yellow
            Write-UiBox -Title "Manual ADSync Fallback" -Lines @(
                "1. Open Windows PowerShell 5.1 on the Entra Connect server."
                "2. Run: Import-Module ADSync"
                "3. Run: Start-ADSyncSyncCycle -PolicyType Delta"
            )

            $choice = Read-UiInput -Prompt "ADSync ready?" -Options @("r=retry automatic sync", "y=manual sync has been started")
            if ($choice -eq "y") {
                return
            }
            if ($choice -ne "r") {
                Write-UiStatus -Status "WARN" -Message "Enter exact lowercase r or y." -Color Yellow
            }
        }
    }
}

function Connect-LockdownCloudServices {
    Connect-M365ServicesMgGraph -GraphScopes @(
        "User.ReadWrite.All",
        "Directory.ReadWrite.All",
        "Directory.Read.All",
        "User.RevokeSessions.All",
        "UserAuthenticationMethod.ReadWrite.All"
    )
    Add-UiStepResult -Name "Connect Microsoft Graph" -Result "Completed"
}

function Select-LockdownCloudUserMatch {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Matches
    )

    $rows = @()
    for ($i = 0; $i -lt $Matches.Count; $i++) {
        $rows += [pscustomobject]@{
            Number            = $i + 1
            DisplayName       = $Matches[$i].displayName
            UserPrincipalName = $Matches[$i].userPrincipalName
            Mail              = $Matches[$i].mail
            AccountEnabled    = $Matches[$i].accountEnabled
            OnPremSync        = $Matches[$i].onPremisesSyncEnabled
            Id                = $Matches[$i].id
        }
    }

    Write-UiBox -Title "Cloud User Matches" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "DisplayName", "UserPrincipalName", "Mail", "AccountEnabled", "OnPremSync", "Id"))
    while ($true) {
        $selection = Read-UiInput -Prompt "Choose cloud user" -Options @("number", "x=abort")
        if ($selection -eq "x") {
            throw "Cloud user selection aborted."
        }
        if ($selection -match "^\d+$") {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $Matches.Count) {
                return $Matches[$index]
            }
        }
        Write-UiStatus -Status "WARN" -Message "Enter a valid cloud user number or x to abort." -Color Yellow
    }
}

function Find-LockdownCloudUser {
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser
    )

    $select = Get-CloudUserStateAttributeSelect
    $matches = @()
    if (-not [string]::IsNullOrWhiteSpace($TargetUser.OnPremisesImmutableId)) {
        try {
            $matches += Find-ActiveCloudUsersByImmutableId -ImmutableId $TargetUser.OnPremisesImmutableId -Select $select
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "ImmutableId lookup did not return a usable match yet: $($_.Exception.Message)" -Color Yellow
        }
    }

    if ($matches.Count -eq 0) {
        $matches += Find-ActiveCloudUsersByLookup -Lookup $TargetUser.UserPrincipalName -Select $select
    }

    $matches = @(Get-UniqueCloudUsers -Users $matches)
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    if ($matches.Count -gt 1) {
        return Select-LockdownCloudUserMatch -Matches $matches
    }

    throw "Could not find active cloud user for '$($TargetUser.UserPrincipalName)'."
}

function Invoke-CloudUserLockdown {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser
    )

    $userId = [string]$CloudUser.id
    Do-LockdownStep -Name "Revoke cloud sign-in sessions" `
        -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users/$userId/revokeSignInSessions'" `
        -SuccessMessage "Revoked sign-in sessions for '$($CloudUser.userPrincipalName)'." `
        -Command {
        Invoke-GraphRevokeSignInSessions -UserIdOrUpn $userId | Out-Null
    }
}

function Invoke-LockdownCloudAccountDisable {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser
    )

    $userId = [string]$CloudUser.id
    $select = Get-CloudUserStateAttributeSelect
    $result = Do-LockdownStep -Name "Disable cloud account" `
        -CommandPreview "Invoke-MgGraphRequest -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/users/$userId' -Body '{ accountEnabled = false }'" `
        -SuccessMessage "Disabled cloud account '$($CloudUser.userPrincipalName)'." `
        -PassThru `
        -Command {
        $body = @{
            accountEnabled = $false
        } | ConvertTo-Json -Depth 4

        Invoke-MgGraphRequest -Method PATCH -Uri (Get-GraphUserUri -UserIdOrUpn $userId) -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        $refreshed = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $userId -Select $select) -ErrorAction Stop
        if ($refreshed.accountEnabled -ne $false) {
            Write-UiStatus -Status "WARN" -Message "Graph accepted the disable request, but the refreshed cloud state still reports AccountEnabled=$($refreshed.accountEnabled)." -Color Yellow
        }

        Format-CloudUserState -CloudUser $refreshed -Source "cloud disable result"
        return $refreshed
    }

    return $result
}

function Invoke-MfaAuditAndReset {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser
    )

    Write-UiStatus -Status "LOADING..." -Message "Taking MFA/authentication method snapshot for '$($CloudUser.userPrincipalName)'." -Color Cyan
    $methods = @(Get-UserAuthenticationMethodSnapshot -UserIdOrUpn $CloudUser.id)
    Write-AuthenticationMethodSnapshot -Methods $methods -Title "MFA / Authentication Methods - Before Reset"
    Add-UiStepResult -Name "Audit MFA methods" -Result "Completed" -Note "Captured $($methods.Count) authentication method row(s)."

    Do-LockdownStep -Name "Require re-register multifactor authentication" `
        -CommandPreview "Remove resettable authentication methods from Graph for '$($CloudUser.userPrincipalName)'" `
        -SuccessMessage "Attempted MFA re-registration reset for '$($CloudUser.userPrincipalName)'." `
        -Command {
        Remove-UserAuthenticationMethodsForReregistration -UserIdOrUpn $CloudUser.id -Methods $methods
    }

    $afterMethods = @(Get-UserAuthenticationMethodSnapshot -UserIdOrUpn $CloudUser.id)
    Write-AuthenticationMethodSnapshot -Methods $afterMethods -Title "MFA / Authentication Methods - After Reset"
}

function Write-UiFinalLockdownSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Subtitle = ""
    )

    Write-UiHeader -Title $Title -Subtitle $Subtitle
    Write-UiSection "Final User State"

    $targetUser = $script:RunContext["TargetUser"]
    if ($targetUser -and $targetUser.AdUser) {
        try {
            Show-AdUserState -Identity ([string]$targetUser.AdUser.ObjectGUID) -Title "Final On-Prem AD User"
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh final AD user state: $($_.Exception.Message)" -Color Yellow
        }
    }

    $cloudUserId = [string]$script:RunContext["CloudUserId"]
    if (-not [string]::IsNullOrWhiteSpace($cloudUserId) -and (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        try {
            $cloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $cloudUserId -Select (Get-CloudUserStateAttributeSelect))
            Format-CloudUserState -CloudUser $cloudUser -Source "final lockdown state"
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh final cloud user state: $($_.Exception.Message)" -Color Yellow
        }
    }

    Write-UiBox -Title "Next Steps" -Lines @(
        "Next-step instructions will be added to this builder later."
        "For now, review AD/cloud state, MFA method changes, mailbox rules, and the action log."
    )
    Write-UiStepSummary
    Write-UiActionLog
}

# -------------------------
# Shared tool helpers.
# -------------------------

# {{POWERSHELL_TOOLS: ConsoleUi, ActiveDirectoryHelpers, PowerShellModuleInstall, MgGraphHelpers, ExchangeHelpers}}

try {
    Invoke-Main
}
catch {
    Write-Host ""
    Write-UiHeader -Title "User Lockdown Run Stopped" -Subtitle "Review final state, summary, and action log before rerunning or resuming manually."
    Write-UiStatus -Status "FAIL" -Message $_.Exception.Message -Color Red
    try {
        Write-UiFinalLockdownSummary -Title "User Lockdown Run Stopped" -Subtitle "Partial run summary."
    }
    catch {
        Write-UiStepSummary
        Write-UiActionLog
    }
}
