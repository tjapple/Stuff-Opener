
# -------------------------
# Fill these in per ticket.
# -------------------------

# Client-specific values. Leave $DisabledUsersOU blank to search the DC at runtime.
$Client = "example"
$DisabledUsersOU = ""

# Query UI:
$UserLookup = "username"
$TicketNumber = "111111"
$GroupsToRemove = @("UserCentric", "ConnectActive")

# Delegates
$DelegatesFullAccess = @("manager@example.com")
$DelegatesSendAs = @()
$DelegatesSendOnBehalf = @()

# Options:
$ConvertToSharedMailbox = $true
$HideFromGAL = $true
$EnableSentItemCopy = $true
$RunADSync = $true
$DryRun = $true
$Force = $false
$SkipIfVerified = $false
$PollSeconds = 10
$PollAttempts = 40

# -------------------------
# 0.5. Prep work: import modules and define helper functions.
# -------------------------

$ErrorActionPreference = "Stop"

function Invoke-Main {
    # Display initial info and actions
    Initialize-UiState
    Show-TerminationPreflight

    # Get ADUser Object and display details on terminal
    Import-ActiveDirectoryModule
    $targetUser = Get-TargetUserDetails -Lookup $UserLookup
    $script:RunContext["TargetUser"] = $targetUser
    Wait-UiBeat
    Show-CurrentAdUserState

    # Pass in the supplied Disabled Users OU and test if it is valid. If not, it searches the DC using the term "Disabled Users".
    # If it finds more than one, or if technician opts not to use the single match, the tech can enter in the exact OU Distinguished Name.
    $resolvedDisabledUsersOU = Resolve-DisabledUsersOU -ConfiguredDisabledUsersOU $DisabledUsersOU -ClientName $Client
    $script:RunContext["DisabledUsersOU"] = $resolvedDisabledUsersOU
    Show-TerminationRunSummary -DisabledUsersOU $resolvedDisabledUsersOU
    Wait-UiBeat

    # Perform AD actions on account and run ADSync.
    Write-UiSection "1. On-Prem AD Cleanup"
    Invoke-OnPremObjectCleanup -TargetUser $targetUser -DisabledUsersOU $resolvedDisabledUsersOU
    Invoke-EntraConnectDeltaSyncStep
    Wait-UiBeat

    # Connect to cloud services
    Write-UiSection "2. Connect to Cloud Services"
    Connect-TerminationCloudServices

    # Restore the deleted user, null the onPremisesImmutableID, block sign-in, etc.
    Write-UiSection "3. Restore Deleted Cloud User and Secure Account"
    $cloudContext = Restore-TerminatedCloudUser -TargetUser $targetUser
    $script:RunContext["CloudUser"] = $cloudContext.CloudUser
    $script:RunContext["UserPrincipalName"] = $cloudContext.UserPrincipalName
    Wait-UiBeat
    Invoke-CloudAccountLockdown -CloudUser $cloudContext.CloudUser -UserPrincipalName $cloudContext.UserPrincipalName


    # Retrieve mailbox details, change mailbox properties and assign delegates
    Write-UiSection "4. Mailbox Changes and Delegates"
    Invoke-MailboxTerminationChanges -UserPrincipalName $cloudContext.UserPrincipalName
    Invoke-MailboxDelegateAssignments -UserPrincipalName $cloudContext.UserPrincipalName

    # Retireve tenant and user license details. Check mailbox properties for recommended changes.
    Write-UiSection "5. License Review and Assignment"
    Invoke-TerminationLicenseReviewAndAssignment -UserPrincipalName $cloudContext.UserPrincipalName
    Wait-UiBeat

    Write-UiFinalRunSummary -Title "User Termination Run Complete" -Subtitle "Review the final state before closing."
}

# -------------------------
# Shared tool helpers.
# -------------------------

# {{POWERSHELL_TOOLS: ConsoleUi, ActiveDirectoryHelpers, PowerShellModuleInstall, MgGraphHelpers, LicenseHelpers, ExchangeHelpers}}

function Show-CurrentAdUserState {
    Write-UiSection "Current ADUser State"

    $targetUser = if ($script:RunContext) { $script:RunContext["TargetUser"] } else { $null }
    $identity = if ($targetUser -and $targetUser.AdUser -and $targetUser.AdUser.ObjectGUID) {
        [string]$targetUser.AdUser.ObjectGUID
    }
    else {
        $UserLookup
    }

    if ([string]::IsNullOrWhiteSpace($identity)) {
        Write-UiStatus -Status "WARN" -Message "No AD lookup value is available yet." -Color Yellow
        return
    }

    try {
        Show-AdUserState -Identity $identity -Title "Current ADUser State"
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not query current ADUser state: $($_.Exception.Message)" -Color Yellow
    }
}

function Get-CurrentCloudUserQueryValue {
    if ($null -eq $script:RunContext) {
        return $UserLookup
    }

    $targetUser = $script:RunContext["TargetUser"]
    $userPrincipalName = $script:RunContext["UserPrincipalName"]
    if ([string]::IsNullOrWhiteSpace($userPrincipalName) -and $targetUser) {
        $userPrincipalName = $targetUser.UserPrincipalName
    }
    if ([string]::IsNullOrWhiteSpace($userPrincipalName)) {
        $userPrincipalName = $UserLookup
    }

    return $userPrincipalName
}

function Get-CurrentCloudUserLookupCandidates {
    param(
        [AllowNull()]
        $TargetUser
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $seenValues = @{}

    function Add-Candidate {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Label,

            [AllowNull()]
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        $cleanValue = $Value.Trim()
        $key = $cleanValue.ToLowerInvariant()
        if ($seenValues.ContainsKey($key)) {
            return
        }

        $seenValues[$key] = $true
        $candidates.Add([pscustomobject]@{
            Label = $Label
            Value = $cleanValue
        }) | Out-Null
    }

    if ($TargetUser) {
        Add-Candidate -Label "AD mail" -Value $TargetUser.AdUser.mail
        Add-Candidate -Label "Target UPN" -Value $TargetUser.UserPrincipalName
        Add-Candidate -Label "AD UPN" -Value $TargetUser.AdUser.UserPrincipalName
        Add-Candidate -Label "AD display name" -Value $TargetUser.AdUser.DisplayName
        Add-Candidate -Label "AD Name/CN" -Value $TargetUser.AdUser.Name
        if (-not [string]::IsNullOrWhiteSpace($TargetUser.AdUser.GivenName) -and -not [string]::IsNullOrWhiteSpace($TargetUser.AdUser.Surname)) {
            Add-Candidate -Label "AD first/last" -Value ("{0} {1}" -f $TargetUser.AdUser.GivenName, $TargetUser.AdUser.Surname)
        }
        Add-Candidate -Label "sAMAccountName/mailNickname" -Value $TargetUser.SamAccountName
    }

    Add-Candidate -Label "Current cloud query value" -Value (Get-CurrentCloudUserQueryValue)
    Add-Candidate -Label "Original lookup" -Value $UserLookup

    return @($candidates)
}

function Find-CurrentActiveCloudUsers {
    param(
        [AllowNull()]
        $TargetUser,

        [Parameter(Mandatory = $true)]
        [string]$Select
    )

    $errors = @()
    $ambiguousMatches = @()
    $ambiguousSource = ""

    if ($TargetUser -and -not [string]::IsNullOrWhiteSpace($TargetUser.OnPremisesImmutableId)) {
        try {
            $matches = @(Find-ActiveCloudUsersByImmutableId -ImmutableId $TargetUser.OnPremisesImmutableId -Select $Select)
            if ($matches.Count -gt 0) {
                return [pscustomobject]@{
                    Matches = $matches
                    Source  = "Active users (immutable ID)"
                    Errors  = $errors
                }
            }
        }
        catch {
            $errors += "Immutable ID: $($_.Exception.Message)"
        }
    }

    foreach ($candidate in @(Get-CurrentCloudUserLookupCandidates -TargetUser $TargetUser)) {
        try {
            $matches = @(Find-ActiveCloudUsersByLookup -Lookup $candidate.Value -Select $Select)
            if ($matches.Count -eq 1) {
                return [pscustomobject]@{
                    Matches = $matches
                    Source  = "Active users ($($candidate.Label): $($candidate.Value))"
                    Errors  = $errors
                }
            }
            if ($matches.Count -gt 1 -and $ambiguousMatches.Count -eq 0) {
                $ambiguousMatches = $matches
                $ambiguousSource = "Active users ($($candidate.Label): $($candidate.Value))"
            }
        }
        catch {
            $errors += "$($candidate.Label) '$($candidate.Value)': $($_.Exception.Message)"
        }
    }

    if ($ambiguousMatches.Count -gt 0) {
        return [pscustomobject]@{
            Matches = $ambiguousMatches
            Source  = $ambiguousSource
            Errors  = $errors
        }
    }

    return [pscustomobject]@{
        Matches = @()
        Source  = ""
        Errors  = $errors
    }
}

function Show-CurrentCloudUserState {
    Write-UiSection "Current CloudUser State"

    $userPrincipalName = Get-CurrentCloudUserQueryValue
    if ([string]::IsNullOrWhiteSpace($userPrincipalName)) {
        Write-UiStatus -Status "WARN" -Message "No cloud lookup value is available yet." -Color Yellow
        return
    }

    try {
        Connect-M365ServicesMgGraph -GraphScopes (Get-TerminationGraphScopes)
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not connect to Graph for CloudUser query: $($_.Exception.Message)" -Color Yellow
        return
    }

    $select = Get-CloudUserStateAttributeSelect
    $targetUser = if ($script:RunContext) { $script:RunContext["TargetUser"] } else { $null }
    $activeResult = Find-CurrentActiveCloudUsers -TargetUser $targetUser -Select $select
    $activeMatches = @($activeResult.Matches | Where-Object { $_ })

    if ($activeMatches.Count -gt 0) {
        Show-CloudUserSearchMatches -Matches $activeMatches -Source $activeResult.Source
        return
    }

    # If failed, check deleted users:
    if ($targetUser -and -not [string]::IsNullOrWhiteSpace($targetUser.OnPremisesImmutableId)) {
        try {
            $immutableIdFilter = [System.Uri]::EscapeDataString("onPremisesImmutableId eq '$($targetUser.OnPremisesImmutableId)'")
            $deletedSelect = Get-CloudUserStateAttributeSelect
            $deletedUri = "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?`$filter=$immutableIdFilter" + [char]38 + "`$select=$deletedSelect"
            $deleted = Invoke-MgGraphRequest -Method GET -Uri $deletedUri -ErrorAction Stop
            $deletedUser = @($deleted.value | Where-Object { $_ } | Sort-Object deletedDateTime -Descending | Select-Object -First 1)
            if ($deletedUser) {
                Format-CloudUserState -CloudUser $deletedUser -Source "Deleted users"
                return
            }
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not query deleted CloudUser state: $($_.Exception.Message)" -Color Yellow
        }
    }

    Write-UiStatus -Status "WARN" -Message "Could not find active or deleted CloudUser state for '$userPrincipalName'." -Color Yellow
    if (@($activeResult.Errors).Count -gt 0) {
        Write-UiBox -Title "CloudUser Lookup Attempts" -Lines @($activeResult.Errors)
    }
}

function Invoke-UiPromptQuery {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("QueryAd", "QueryCloud")]
        [string]$Query
    )

    if ($Query -eq "QueryAd") {
        Show-CurrentAdUserState
        return
    }

    Show-CurrentCloudUserState
}

function Get-UiStepActionPrompt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Run", "Retry")]
        [string]$Mode
    )

    $actionPrompt = switch -Wildcard ($Name) {
        "Disable AD account" { "Disable user?"; break }
        "Move AD account*" { "Move user?"; break }
        "Stamp AD description*" { "Stamp description?"; break }
        "Remove user from AD group*" { "Remove from AD group?"; break }
        "Remove user from distribution list*" { "Remove from distribution list?"; break }
        "Start Entra Connect delta sync" { "Run delta sync?"; break }
        "Restore deleted cloud user" { "Restore cloud user?"; break }
        "Revoke sign-in sessions" { "Revoke sign-in sessions?"; break }
        "Block cloud sign-in" { "Block cloud sign-in?"; break }
        "Clear onPremisesImmutableId" { "Clear immutable ID?"; break }
        "Convert mailbox to shared" { "Convert mailbox?"; break }
        "Hide mailbox from GAL" { "Hide mailbox from GAL?"; break }
        "Enable sent item copy*" { "Enable sent item copy?"; break }
        "Add Full Access delegate*" { "Add Full Access delegate?"; break }
        "Add Send As delegate*" { "Add Send As delegate?"; break }
        "Add Send on Behalf delegate*" { "Add Send on Behalf delegate?"; break }
        "Assign Defender license*" { "Assign Defender license?"; break }
        "Remove current licenses*" { "Replace licenses?"; break }
        "Add selected licenses" { "Add selected licenses?"; break }
        "Remove selected licenses" { "Remove selected licenses?"; break }
        default { "$($Name)?" }
    }

    if ($Mode -eq "Retry") {
        return "Retry: $actionPrompt"
    }

    return $actionPrompt
}

function Get-UiStepOptions {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Run", "Retry")]
        [string]$Mode,

        [switch]$Required
    )

    $options = @()
    if ($Mode -eq "Run") {
        $options += "y=run"
    }
    else {
        $options += "r=retry"
    }

    $options += "d=details"
    if (-not $Required) {
        $options += "s=skip"
    }
    $options += "x=abort"
    $options += "a=ADUser query"
    $options += "c=CloudUser query"

    return $options
}

function Read-UiStepChoice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$Required
    )

    while ($true) {
        $choice = Read-UiInput -Prompt (Get-UiStepActionPrompt -Name $Name -Mode "Run") -Options (Get-UiStepOptions -Mode "Run" -Required:$Required)
        if ($choice -eq "y") {
            return "Run"
        }
        if ($choice -eq "d") {
            return "Details"
        }
        if (-not $Required -and $choice -eq "s") {
            return "Skip"
        }
        if ($choice -eq "x") {
            return "Abort"
        }
        if ($choice -eq "a") {
            return "QueryAd"
        }
        if ($choice -eq "c") {
            return "QueryCloud"
        }

        Write-UiStatus -Status "WARN" -Message "Enter one exact lowercase option shown in the prompt." -Color Yellow
    }
}

function Read-UiStepErrorChoice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$Required
    )

    while ($true) {
        $choice = Read-UiInput -Prompt (Get-UiStepActionPrompt -Name $Name -Mode "Retry") -Options (Get-UiStepOptions -Mode "Retry" -Required:$Required)
        if ($choice -eq "r") {
            return "Retry"
        }
        if ($choice -eq "d") {
            return "Details"
        }
        if (-not $Required -and $choice -eq "s") {
            return "Skip"
        }
        if ($choice -eq "x") {
            return "Abort"
        }
        if ($choice -eq "a") {
            return "QueryAd"
        }
        if ($choice -eq "c") {
            return "QueryCloud"
        }

        Write-UiStatus -Status "WARN" -Message "Enter one exact lowercase option shown in the prompt." -Color Yellow
    }
}

function Show-TerminationPreflight {
    Write-UiBanner
    Write-UiHeader -Title "User Termination" -Subtitle "Client: $Client | User: $UserLookup | Ticket: #$TicketNumber"
    Write-UiBox -Title "Preflight" -Lines @(
        New-UiBoxLine -Label "Target lookup" -Value $UserLookup
        New-UiBoxLine -Label "Run mode" -Value $(if ($DryRun) { "Dry run" } elseif ($SkipIfVerified) { "Skip if verified" } else { "Live changes" })
        New-UiBoxLine -Label "Prompt mode" -Value $(if ($Force) { "Force enabled; step prompts skipped" } else { "Confirm each step" })
    )
}

function Show-TerminationRunSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisabledUsersOU
    )

    Write-UiSection "Run Summary"
    Write-UiBox -Title "Run Configuration" -Lines @(
        New-UiBoxLine -Label "Client" -Value $Client
        New-UiBoxLine -Label "Ticket" -Value "#$TicketNumber"
        New-UiBoxLine -Label "Disabled Users OU" -Value $DisabledUsersOU
        New-UiBoxLine -Label "Convert mailbox" -Value $ConvertToSharedMailbox
        New-UiBoxLine -Label "Hide from GAL" -Value $HideFromGAL
        New-UiBoxLine -Label "Enable sent item copy" -Value $EnableSentItemCopy
        New-UiBoxLine -Label "Run AD sync" -Value $RunADSync
        New-UiBoxLine -Label "Skip if verified" -Value $SkipIfVerified
        New-UiBoxLine -Label "Groups to remove" -Value $GroupsToRemove
        New-UiBoxLine -Label "Full Access delegates" -Value $DelegatesFullAccess
        New-UiBoxLine -Label "Send As delegates" -Value $DelegatesSendAs
        New-UiBoxLine -Label "Send on Behalf" -Value $DelegatesSendOnBehalf
    )
}

function Get-UiVerifiedMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StepName
    )

    $phrases = @(
        "trust me, bro",
        "i swear",
        "bruh i gotchu",
        "dunzo",
        "i swear bro",
        "swear to god",
        "i pwomise :)",
        "bro trust me",
        "trust",
        "i checked - i swear"
    )

    return ("{0}" -f (Get-Random -InputObject $phrases))
}

function ConvertTo-NumberSelection {
    param(
        [string]$InputText,
        [int]$Max
    )

    $numbers = @()
    foreach ($part in @($InputText -split "[,\s;]+" | Where-Object { $_ })) {
        if ($part -match "^\d+$") {
            $number = [int]$part
            if ($number -ge 1 -and $number -le $Max -and $numbers -notcontains $number) {
                $numbers += $number
            }
        }
    }

    return $numbers
}

function Do-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,

        [string]$CommandPreview = "",

        [string]$SuccessMessage = "",

        [scriptblock]$Verify,

        [switch]$PassThru,

        [switch]$Required
    )

    $script:UiStepNumber = $script:UiStepNumber + 1
    $stepNumber = $script:UiStepNumber
    Write-Host ""
    Write-Host ("STEP {0}: {1}:" -f $stepNumber, $Name) -ForegroundColor Cyan

    # First, run the verify scriptblock. If truthy, print UI message and return. If not, continue in do-step
    if ($SkipIfVerified -and $null -ne $Verify) {
        try {
            if (& $Verify) {
                $verifiedMessage = Get-UiVerifiedMessage -StepName $Name
                Write-UiStatus -Status "VERIFIED" -Message $verifiedMessage -Color Green
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Verified" -Note $verifiedMessage -CommandPreview $CommandPreview
                return
            }
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not verify '$Name': $($_.Exception.Message)" -Color Yellow
        }
    }

    # If Force not enabled, require operator input
    if (-not $Force) {
        while ($true) {
            $choice = Read-UiStepChoice -Name $Name -Required:$Required
            if ($choice -eq "Run") {
                break
            }
            if ($choice -eq "Details") {
                Write-UiStepDetails -CommandPreview $CommandPreview
                continue
            }
            if ($choice -eq "QueryAd" -or $choice -eq "QueryCloud") {
                Invoke-UiPromptQuery -Query $choice
                continue
            }
            if ($choice -eq "Skip") {
                Write-UiStatus -Status "SKIP" -Message "Skipped step '$Name' by operator choice." -Color Yellow
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Skipped" -Note "Skipped by operator." -CommandPreview $CommandPreview
                return
            }
            Write-UiStatus -Status "ABORT" -Message "Aborted at step ${stepNumber}: $Name." -Color Red
            if ($script:RunContext) {
                $script:RunContext["StoppedByAbort"] = $true
                $script:RunContext["StopReason"] = "Aborted at step ${stepNumber}: $Name"
            }
            Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Aborted" -Note "Aborted by operator." -CommandPreview $CommandPreview
            throw "Workflow aborted by operator at step ${stepNumber}: $Name"
        }
    }
    else {
        Write-UiStatus -Status "RUN" -Message "Force enabled; running step without prompt." -Color Cyan
    }

    if ([string]::IsNullOrWhiteSpace($SuccessMessage)) {
        $SuccessMessage = ("Step {0} completed: {1}." -f $stepNumber, $Name)
    }

    while ($true) {
        try {
            $stepResult = Invoke-UiCommand -Name $Name -Command $Command -CommandPreview $CommandPreview -PassThru:$PassThru
            if (Test-UiDryRun) {
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Dry run" -Note "No changes made." -CommandPreview $CommandPreview
            }
            else {
                Write-UiStatus -Status "OK" -Message $SuccessMessage -Color Green
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Completed" -Note $SuccessMessage -CommandPreview $CommandPreview
            }
            if ($PassThru) {
                return $stepResult
            }
            return
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-UiStatus -Status "FAIL" -Message $errorMessage -Color Red

            while ($true) {
                $choice = Read-UiStepErrorChoice -Name $Name -Required:$Required
                if ($choice -eq "Retry") {
                    break
                }
                if ($choice -eq "Details") {
                    Write-UiStepDetails -CommandPreview $CommandPreview
                    continue
                }
                if ($choice -eq "QueryAd" -or $choice -eq "QueryCloud") {
                    Invoke-UiPromptQuery -Query $choice
                    continue
                }
                if ($choice -eq "Skip") {
                    Write-UiStatus -Status "SKIP" -Message "Skipped step '$Name' after error." -Color Yellow
                    Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Skipped" -Note $errorMessage -CommandPreview $CommandPreview
                    return
                }

                Write-UiStatus -Status "ABORT" -Message "Aborted at step ${stepNumber}: $Name." -Color Red
                if ($script:RunContext) {
                    $script:RunContext["StoppedByAbort"] = $true
                    $script:RunContext["StopReason"] = "Aborted at step ${stepNumber}: $Name"
                }
                Add-UiStepResult -StepNumber $stepNumber -Name $Name -Result "Aborted" -Note $errorMessage -CommandPreview $CommandPreview
                throw "Workflow aborted by operator at step ${stepNumber}: $Name. Last error: $errorMessage"
            }
        }
    }
}

function Write-UiFinalUserState {
    param(
        [switch]$IncludeGroupMemberships
    )

    Write-UiSection "Final User State"

    if ($null -eq $script:RunContext) {
        Write-UiStatus -Status "INFO" -Message "Run context was not initialized before the script stopped." -Color Yellow
        return
    }

    $targetUser = $script:RunContext["TargetUser"]
    $targetUserObjectGuid = if ($targetUser -and $targetUser.AdUser -and $targetUser.AdUser.ObjectGUID) { [string]$targetUser.AdUser.ObjectGUID } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($targetUserObjectGuid)) {
        try {
            $finalAdUser = Get-ADUser -Identity $targetUserObjectGuid -Properties Enabled,Description,DistinguishedName,UserPrincipalName,mail,ObjectGUID
            Write-UiBox -Title "On-Prem AD User" -Lines @(
                New-UiBoxLine -Label "Name" -Value $finalAdUser.Name
                New-UiBoxLine -Label "SamAccountName" -Value $finalAdUser.SamAccountName
                New-UiBoxLine -Label "Enabled" -Value $finalAdUser.Enabled
                New-UiBoxLine -Label "UserPrincipalName" -Value $finalAdUser.UserPrincipalName
                New-UiBoxLine -Label "Mail" -Value $finalAdUser.mail
                New-UiBoxLine -Label "Description" -Value $finalAdUser.Description
                New-UiBoxLine -Label "DistinguishedName" -Value $finalAdUser.DistinguishedName
            )
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh on-prem AD user state: $($_.Exception.Message)" -Color Yellow
        }
    }
    else {
        Write-UiStatus -Status "INFO" -Message "On-prem AD user was not resolved before the script stopped." -Color Yellow
    }

    $userPrincipalName = $script:RunContext["UserPrincipalName"]
    if ([string]::IsNullOrWhiteSpace($userPrincipalName) -and $targetUser) {
        $userPrincipalName = $targetUser.UserPrincipalName
    }

    $finalCloudUser = $null
    if (-not [string]::IsNullOrWhiteSpace($userPrincipalName) -and (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        try {
            $select = Get-CloudUserStateAttributeSelect
            $cloudIdentity = $userPrincipalName
            $runCloudUser = $script:RunContext["CloudUser"]
            if ($runCloudUser -and -not [string]::IsNullOrWhiteSpace([string]$runCloudUser.id)) {
                $cloudIdentity = [string]$runCloudUser.id
            }

            $finalCloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $cloudIdentity -Select $select)
            if (-not [string]::IsNullOrWhiteSpace([string]$finalCloudUser.userPrincipalName)) {
                $userPrincipalName = [string]$finalCloudUser.userPrincipalName
                $script:RunContext["UserPrincipalName"] = $userPrincipalName
            }
            $script:RunContext["CloudUser"] = $finalCloudUser
            Format-CloudUserState -CloudUser $finalCloudUser -Source "final cloud user state"
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh cloud user state: $($_.Exception.Message)" -Color Yellow
        }
    }
    else {
        Write-UiStatus -Status "INFO" -Message "Cloud user state is not available yet." -Color Yellow
    }

    $mailboxDetails = $null
    $mailboxIdentity = $userPrincipalName
    if ($finalCloudUser) {
        if (-not [string]::IsNullOrWhiteSpace([string]$finalCloudUser.userPrincipalName)) {
            $mailboxIdentity = [string]$finalCloudUser.userPrincipalName
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$finalCloudUser.mail)) {
            $mailboxIdentity = [string]$finalCloudUser.mail
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($mailboxIdentity) -and (Get-Command Get-Mailbox -ErrorAction SilentlyContinue)) {
        try {
            $mailboxDetails = Get-MailboxDetailsAndStats -UserPrincipalName $mailboxIdentity -Silent -PollSeconds $PollSeconds -PollAttempts $PollAttempts
            $script:RunContext["MailboxDetails"] = $mailboxDetails
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh mailbox state: $($_.Exception.Message)" -Color Yellow
        }
    }

    if (-not $mailboxDetails) {
        $mailboxDetails = $script:RunContext["MailboxDetails"]
        if ($mailboxDetails) {
            Write-UiStatus -Status "WARN" -Message "Showing last cached mailbox snapshot because the current mailbox state could not be refreshed." -Color Yellow
        }
    }

    if ($mailboxDetails) {
        Write-UiBox -Title "Mailbox" -Lines @(
            New-UiBoxLine -Label "Identity" -Value $mailboxIdentity
            New-UiBoxLine -Label "DisplayName" -Value $mailboxDetails.Mailbox.DisplayName
            New-UiBoxLine -Label "PrimarySmtpAddress" -Value $mailboxDetails.Mailbox.PrimarySmtpAddress
            New-UiBoxLine -Label "RecipientType" -Value $mailboxDetails.Mailbox.RecipientTypeDetails
            New-UiBoxLine -Label "HiddenFromGAL" -Value $mailboxDetails.Mailbox.HiddenFromAddressListsEnabled
            New-UiBoxLine -Label "SentAs copy" -Value $mailboxDetails.Mailbox.MessageCopyForSentAsEnabled
            New-UiBoxLine -Label "SendOnBehalf copy" -Value $mailboxDetails.Mailbox.MessageCopyForSendOnBehalfEnabled
            New-UiBoxLine -Label "ArchiveStatus" -Value $mailboxDetails.Mailbox.ArchiveStatus
            New-UiBoxLine -Label "ArchiveState" -Value $mailboxDetails.Mailbox.ArchiveState
            New-UiBoxLine -Label "TotalItemSize" -Value $mailboxDetails.Statistics.TotalItemSize
            New-UiBoxLine -Label "ItemCount" -Value $mailboxDetails.Statistics.ItemCount
        )
    }
    else {
        Write-UiStatus -Status "INFO" -Message "Mailbox state is not available yet." -Color Yellow
    }

    if ($IncludeGroupMemberships -and -not [string]::IsNullOrWhiteSpace($targetUserObjectGuid)) {
        try {
            if (-not (Get-Command Get-ADPrincipalGroupMembership -ErrorAction SilentlyContinue)) {
                Import-ActiveDirectoryModule
            }

            $groupMemberships = @(Get-ADPrincipalGroupMembership -Identity $targetUserObjectGuid | Sort-Object Name)
            if ($groupMemberships.Count -eq 0) {
                Write-UiBox -Title "AD Group Memberships" -Lines @("None")
            }
            else {
                $groupRows = @($groupMemberships | Select-Object Name,GroupCategory,GroupScope)
                Write-UiBox -Title "AD Group Memberships" -Lines (ConvertTo-UiTableLines -Rows $groupRows -Columns @("Name", "GroupCategory", "GroupScope"))
            }
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh AD group memberships: $($_.Exception.Message)" -Color Yellow
        }
    }
}

function Write-UiFinalRunSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Subtitle = "",

        [string]$ErrorMessage = "",

        [switch]$IncludeGroupMemberships
    )

    Write-UiHeader -Title $Title -Subtitle $Subtitle
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Write-UiStatus -Status "FAIL" -Message $ErrorMessage -Color Red
    }

    Write-UiStepSummary
    Write-UiActionLog
    Write-UiFinalUserState -IncludeGroupMemberships:$IncludeGroupMemberships
    Write-TerminationFinalWarnings
}

function Add-TerminationFinalWarning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($null -eq $script:RunContext) {
        return
    }
    if (-not $script:RunContext.Contains("FinalWarnings")) {
        $script:RunContext["FinalWarnings"] = New-Object System.Collections.ArrayList
    }

    [void]$script:RunContext["FinalWarnings"].Add($Message)
}

function Write-TerminationFinalWarnings {
    if ($null -eq $script:RunContext -or -not $script:RunContext.Contains("FinalWarnings")) {
        return
    }

    $warnings = @($script:RunContext["FinalWarnings"] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($warnings.Count -eq 0) {
        return
    }

    Write-Host ""
    foreach ($warning in $warnings) {
        Write-UiStatus -Status "WARN" -Message $warning -Color Yellow
    }
}

# -------------------------
# Active Directory lookup and OU helpers.
# -------------------------





function Test-DisabledUsersOuDistinguishedName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    try {
        $ou = Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction Stop
        return $ou.DistinguishedName
    }
    catch {
        Write-Host ""
        Write-Host "No OU found for distinguished name '$DistinguishedName'." -ForegroundColor Red
        return $null
    }
}

function Read-DisabledUsersOuDistinguishedName {
    param(
        [string]$PromptReason = "Enter the exact Disabled Users OU distinguished name."
    )

    Write-Host ""
    Write-Host $PromptReason
    while ($true) {
        $enteredOu = (Read-UiInput -Prompt "Disabled Users OU?" -Options @("exact DN or search")).Trim()
        if ([string]::IsNullOrWhiteSpace($enteredOu)) {
            Write-UiStatus -Status "WARN" -Message "OU distinguished name is required." -Color Yellow
            continue
        }

        if ($enteredOu -match "(?i)OU=.*DC=") {
            $validatedOu = Test-DisabledUsersOuDistinguishedName -DistinguishedName $enteredOu
            if (-not [string]::IsNullOrWhiteSpace($validatedOu)) {
                return [string]$validatedOu
            }
            continue
        }

        $escaped = Escape-DirectoryFilterValue -Value $enteredOu
        $ouMatches = @(
            Get-ADOrganizationalUnit -Filter "Name -like '*$escaped*'" -Properties CanonicalName,DistinguishedName |
                Sort-Object CanonicalName
        )
        if ($ouMatches.Count -eq 0) {
            Write-UiStatus -Status "WARN" -Message "No OUs matched '$enteredOu'. Enter the exact OU DN or try a different search term." -Color Yellow
            continue
        }

        $selectedOu = Select-DisabledUsersOuFromMatches -OuMatches $ouMatches
        if (-not [string]::IsNullOrWhiteSpace($selectedOu)) {
            return [string]$selectedOu
        }
    }
}

function Select-DisabledUsersOuFromMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$OuMatches
    )

    $ouChoices = @($OuMatches | Where-Object { $_ })
    if ($ouChoices.Count -eq 0) {
        return $null
    }

    $rows = @()
    for ($i = 0; $i -lt $ouChoices.Count; $i++) {
        $rows += [pscustomobject]@{
            Number        = $i + 1
            Name          = $ouChoices[$i].Name
            CanonicalName = $ouChoices[$i].CanonicalName
            DN            = $ouChoices[$i].DistinguishedName
        }
    }

    Write-UiBox -Title "Disabled Users OU Search Results" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "Name", "CanonicalName", "DN"))

    if ($ouChoices.Count -eq 1) {
        if (Read-UiYesNo -Prompt "Use this Disabled Users OU?" -DefaultYes $true) {
            return [string]$ouChoices[0].DistinguishedName
        }
        return $null
    }

    while ($true) {
        $selection = (Read-UiInput -Prompt "Choose Disabled Users OU number, or type exact OU DN" -Options @("number", "exact DN")).Trim()
        if ($selection -match "^\d+$") {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $ouChoices.Count) {
                $selectedOu = [string]$ouChoices[$index].DistinguishedName
                $validatedOu = Test-DisabledUsersOuDistinguishedName -DistinguishedName $selectedOu
                if (-not [string]::IsNullOrWhiteSpace($validatedOu)) {
                    Write-UiStatus -Status "OK" -Message "Selected Disabled Users OU '$validatedOu'." -Color Green
                    return [string]$validatedOu
                }

                Write-UiStatus -Status "WARN" -Message "Selected OU number did not resolve to a valid distinguished name. Try again." -Color Yellow
                continue
            }
        }
        elseif ($selection -match "(?i)OU=.*DC=") {
            $validatedOu = Test-DisabledUsersOuDistinguishedName -DistinguishedName $selection
            if (-not [string]::IsNullOrWhiteSpace($validatedOu)) {
                return [string]$validatedOu
            }
            continue
        }

        Write-UiStatus -Status "WARN" -Message "Enter a listed number or an exact OU distinguished name." -Color Yellow
    }
}

function Resolve-DisabledUsersOU {
    param(
        [AllowNull()]
        [string]$ConfiguredDisabledUsersOU,

        [string]$SearchName = "Disabled Users",

        [string]$ClientName = $Client
    )

    Write-UiStatus -Status "LOADING..." -Message "Validating DisabledUsersOU" -Color Cyan


    if (-not [string]::IsNullOrWhiteSpace($ConfiguredDisabledUsersOU)) {
        $validatedConfiguredOu = Test-DisabledUsersOuDistinguishedName -DistinguishedName $ConfiguredDisabledUsersOU.Trim()
        if (-not [string]::IsNullOrWhiteSpace($validatedConfiguredOu)) {
            Write-UiStatus -Status "OK" -Message "Disabled Users OU: $validatedConfiguredOu validated" -Color Green
            return $validatedConfiguredOu
        }

        Write-UiStatus -Status "I Failed :(" -Message "Configured Disabled Users OU could not be found. Falling back to DC search." -Color Yellow
    }

    $escapedSearchName = Escape-DirectoryFilterValue -Value $SearchName
    $ouMatches = @(
        Get-ADOrganizationalUnit -Filter "Name -eq '$escapedSearchName'" -Properties CanonicalName,DistinguishedName |
            Sort-Object CanonicalName
    )

    if ($ouMatches.Count -eq 1) {
        $foundOu = $ouMatches[0].DistinguishedName
        Write-UiStatus -Status "FOUND" -Message "Found one candidate Disabled Users OU: $foundOu" -Color Yellow
        $useFoundOu = Read-UiInput -Prompt "Use this OU?" -Options @("y=yes", "any-other-key=enter manually")
        if ($useFoundOu -eq "y") {
            return $foundOu
        }

        return Read-DisabledUsersOuDistinguishedName -PromptReason "Enter the exact DN or enter search term."
    }

    if ($ouMatches.Count -gt 1) {
        Write-UiStatus -Status "TOO MANY" -Message "Found more than one OU named '$SearchName'." -Color Yellow
        $selectedOu = Select-DisabledUsersOuFromMatches -OuMatches $ouMatches
        if (-not [string]::IsNullOrWhiteSpace($selectedOu)) {
            return [string]$selectedOu
        }

        return Read-DisabledUsersOuDistinguishedName -PromptReason "Enter the exact OU distinguished name or search text to use."
    }

    Write-UiStatus -Status "NOT FOUND" -Message "No OU named '$SearchName' was found." -Color Yellow
    return Read-DisabledUsersOuDistinguishedName -PromptReason "Enter the exact OU distinguished name or search text to use."
}

# -------------------------
# On-prem AD cleanup and sync.
# -------------------------

function Invoke-OnPremObjectCleanup {
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser,

        [Parameter(Mandatory = $true)]
        [string]$DisabledUsersOU
    )

    $samAccountName = $TargetUser.SamAccountName
    $adUser = $TargetUser.AdUser
    $userObjectGuid = [string]$adUser.ObjectGUID

    Do-Step -Name "Disable AD account" `
        -CommandPreview "Disable-ADAccount -Identity '$userObjectGuid'" `
        -SuccessMessage "Step completed: disabled AD account '$samAccountName'." `
        -Verify {
        -not (Get-ADUser -Identity $userObjectGuid -Properties Enabled).Enabled
    } `
        -Command {
        Disable-ADAccount -Identity $userObjectGuid
    }

    Do-Step -Name "Move AD account to Disabled Users OU" `
        -CommandPreview "Move-ADObject -Identity '$userObjectGuid' -TargetPath '$DisabledUsersOU'" `
        -SuccessMessage "Step completed: moved AD account '$samAccountName' to '$DisabledUsersOU'." `
        -Verify {
        $currentUser = Get-ADUser -Identity $userObjectGuid -Properties DistinguishedName
        $currentUser.DistinguishedName.EndsWith("," + $DisabledUsersOU, [System.StringComparison]::OrdinalIgnoreCase)
    } `
        -Command {
        $currentUser = Get-ADUser -Identity $userObjectGuid -Properties DistinguishedName
        $adUser = $currentUser
        Move-ADObject -Identity $userObjectGuid -TargetPath $DisabledUsersOU
        $script:RunContext["TargetUser"].AdUser = $adUser
    }

    # After moving the user, re-query with GUID and store in adUser.
    $adUser = Get-ADUser -Identity $userObjectGuid -Properties DistinguishedName,SamAccountName,ObjectGUID
    $TargetUser.AdUser = $adUser

    Do-Step -Name "Stamp AD description with ticket number" `
        -CommandPreview "Set-ADUser -Identity '$userObjectGuid' -Description '#$TicketNumber user term'" `
        -SuccessMessage "Step completed: updated AD description for '$samAccountName' with ticket '#$TicketNumber'." `
        -Verify {
        $currentDescription = (Get-ADUser -Identity $userObjectGuid -Properties Description).Description
        -not [string]::IsNullOrWhiteSpace($currentDescription) -and
            $currentDescription -like "*$TicketNumber*" -and
            $currentDescription -like "*user term*"
    } `
        -Command {
        Set-ADUser -Identity $userObjectGuid -Description "#$TicketNumber user term"
    }

    Write-Host ""
    Write-UiStatus -Status "LOADING..." -Message "Checking AD group memberships for '$samAccountName' - gimmie a sec." -Color Cyan
    $groupMemberships = @(Get-ADPrincipalGroupMembership -Identity $userObjectGuid)
    Write-UiStatus -Status "OK" -Message "Loaded $($groupMemberships.Count) AD group membership(s)." -Color Green
    Wait-UiBeat

    foreach ($group in $GroupsToRemove) {
        if ([string]::IsNullOrWhiteSpace($group)) {
            continue
        }

        $group = $group.Trim()
        $isMember = $groupMemberships |
            Where-Object { $_.Name -eq $group -or $_.SamAccountName -eq $group }

        if ($isMember) {
            $matchedGroup = @($isMember | Select-Object -First 1)[0]
            Do-Step -Name "Remove user from AD group '$group'" `
                -CommandPreview "Remove-ADGroupMember -Identity '$($matchedGroup.DistinguishedName)' -Members '$userObjectGuid' -Confirm:`$false" `
                -SuccessMessage "Step completed: removed '$samAccountName' from AD group '$group'." `
                -Verify {
                $currentGroups = @(Get-ADPrincipalGroupMembership -Identity $userObjectGuid)
                -not ($currentGroups | Where-Object { $_.Name -eq $group -or $_.SamAccountName -eq $group })
            } `
                -Command {
                Remove-ADGroupMember -Identity $matchedGroup.DistinguishedName -Members $userObjectGuid -Confirm:$false
            }

        }
        elseif ($SkipIfVerified) {
            Do-Step -Name "Remove user from AD group '$group'" `
                -CommandPreview "Get-ADGroup -Identity '$group'`nRemove-ADGroupMember -Identity '<resolved group DN>' -Members '$userObjectGuid' -Confirm:`$false" `
                -SuccessMessage "Step completed: removed '$samAccountName' from AD group '$group'." `
                -Verify {
                $currentGroups = @(Get-ADPrincipalGroupMembership -Identity $userObjectGuid)
                -not ($currentGroups | Where-Object { $_.Name -eq $group -or $_.SamAccountName -eq $group })
            } `
                -Command {
                $targetGroup = Get-ADGroup -Identity $group -Properties DistinguishedName
                Remove-ADGroupMember -Identity $targetGroup.DistinguishedName -Members $userObjectGuid -Confirm:$false
            }
        }
        else {
            Write-Host "User is already NOT a member of '$group'."
        }
    }

    Wait-UiBeat
    Write-Host ""
    Write-UiStatus -Status "LOADING..." -Message "Checking distribution list memberships" -Color Cyan
    $distributionGroups = $groupMemberships |
        Where-Object { $_.GroupCategory -eq "Distribution" }
    Write-UiStatus -Status "OK" -Message "Found $($distributionGroups.Count) distribution list membership(s)." -Color Green
    Wait-UiBeat

    foreach ($distributionGroup in $distributionGroups) {
        Do-Step -Name "Remove user from distribution list '$($distributionGroup.Name)'" `
            -CommandPreview "Remove-ADGroupMember -Identity '$($distributionGroup.DistinguishedName)' -Members '$userObjectGuid' -Confirm:`$false" `
            -SuccessMessage "Step completed: removed '$samAccountName' from distribution list '$($distributionGroup.Name)'." `
            -Verify {
            $currentGroups = @(Get-ADPrincipalGroupMembership -Identity $userObjectGuid)
            -not ($currentGroups | Where-Object { $_.DistinguishedName -eq $distributionGroup.DistinguishedName })
        } `
            -Command {
            Remove-ADGroupMember -Identity $distributionGroup.DistinguishedName -Members $userObjectGuid -Confirm:$false
        }
    }
}

function Invoke-EntraConnectDeltaSyncStep {
    if (-not $RunADSync) {
        return
    }

    Do-Step -Name "Start Entra Connect delta sync" `
        -Required `
        -CommandPreview "Import-Module ADSync`nStart-ADSyncSyncCycle -PolicyType Delta" `
        -SuccessMessage "Step completed: Entra Connect delta sync was run or manually confirmed." `
        -Command {
        while ($true) {
            if (Start-EntraConnectDeltaSync) {
                return
            }

            Write-UiStatus -Status "SYNC" -Message "Automatic delta sync did not complete. Cloud steps should not continue until sync has run." -Color Yellow
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

# -------------------------
# Cloud connection and Graph helpers.
# -------------------------

function Get-TerminationGraphScopes {
    return @(
        "User.ReadWrite.All",
        "Directory.ReadWrite.All",
        "LicenseAssignment.ReadWrite.All",
        "User.DeleteRestore.All",
        "User.RevokeSessions.All",
        "Organization.Read.All"
    )
}

function Connect-TerminationCloudServices {
    Connect-M365ServicesMgGraph -GraphScopes (Get-TerminationGraphScopes)
    Connect-M365ServicesExchangeOnline
}



function Resolve-CloudDelegateList {
    param(
        [AllowNull()]
        [string[]]$Lookups,

        [Parameter(Mandatory = $true)]
        [string]$PermissionName
    )

    $resolvedDelegates = @()
    foreach ($lookup in @($Lookups)) {
        if ([string]::IsNullOrWhiteSpace($lookup)) {
            continue
        }

        $candidateLookup = $lookup.Trim()
        while ($true) {
            try {
                $resolvedDelegate = Resolve-CloudUserLookup -Lookup $candidateLookup -Purpose "$PermissionName delegate"
                Write-UiStatus -Status "OK" -Message "Resolved $PermissionName delegate '$candidateLookup' to '$($resolvedDelegate.Label)'." -Color Green
                $resolvedDelegates += $resolvedDelegate
                break
            }
            catch {
                if ($_.Exception.Message -like "*Lookup aborted*") {
                    throw
                }

                Write-UiStatus -Status "FAIL" -Message "Could not resolve $PermissionName delegate '$candidateLookup'." -Color Red
                Write-Host $_.Exception.Message

                $replacementLookup = (Read-UiInput -Prompt "Correct $PermissionName delegate?" -Options @("enter lookup", "Enter=skip delegate")).Trim()
                if ([string]::IsNullOrWhiteSpace($replacementLookup)) {
                    Write-UiStatus -Status "SKIP" -Message "Skipped unresolved $PermissionName delegate '$candidateLookup'." -Color Yellow
                    Add-UiStepResult -StepNumber 0 -Name "Resolve $PermissionName delegate '$candidateLookup'" -Result "Skipped" -Note $_.Exception.Message
                    break
                }

                $candidateLookup = $replacementLookup
            }
        }
    }

    return $resolvedDelegates
}

# -------------------------
# Cloud account restore and lock down.
# -------------------------

function Stop-TerminationWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($script:RunContext) {
        $script:RunContext["StoppedByAbort"] = $true
        $script:RunContext["StopReason"] = $Message
    }

    throw $Message
}

function Request-TerminationWorkflowRestart {
    $script:RestartRequested = $true
    throw "Workflow restart requested by operator."
}

function Show-ActiveCloudUserDuringDeletedUserPoll {
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser
    )

    $select = Get-CloudUserStateAttributeSelect
    $activeResult = Find-CurrentActiveCloudUsers -TargetUser $TargetUser -Select $select
    $activeMatches = @($activeResult.Matches | Where-Object { $_ })

    if ($activeMatches.Count -gt 0) {
        Show-CloudUserSearchMatches -Matches $activeMatches -Source $activeResult.Source
        if ($activeMatches.Count -eq 1) {
            $decision = Read-ActiveCloudUserPollDecision -TargetUser $TargetUser -ActiveCloudUser $activeMatches[0]
            if ($decision -eq "SkipToCloudCleanup") {
                return [pscustomobject]@{
                    SkipToCloudCleanup = $true
                    CloudUser          = $activeMatches[0]
                    UserPrincipalName  = $activeMatches[0].userPrincipalName
                }
            }
        }

        return $null
    }

    Write-UiStatus -Status "INFO" -Message "No active cloud user was found for '$($TargetUser.UserPrincipalName)'." -Color Yellow
    if (@($activeResult.Errors).Count -gt 0) {
        Write-UiBox -Title "Active CloudUser Lookup Attempts" -Lines @($activeResult.Errors)
    }
    return $false
}

function Invoke-DeletedUserPollAction {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("CheckActive", "QueryCloud", "QueryAd", "Abort")]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        $TargetUser
    )

    if ($Action -eq "QueryCloud") {
        Show-CurrentCloudUserState
        return
    }
    if ($Action -eq "QueryAd") {
        Show-CurrentAdUserState
        return
    }
    if ($Action -eq "Abort") {
        Stop-TerminationWorkflow -Message "Workflow aborted by operator while polling deleted users."
    }

    $foundActiveUser = Show-ActiveCloudUserDuringDeletedUserPoll -TargetUser $TargetUser
    return $foundActiveUser
}

function Wait-DeletedUserPollInterval {
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser,

        [int]$Seconds = $PollSeconds
    )

    Write-UiStatus -Status "WAIT" -Message "Waiting $Seconds second(s). Options: p=poll active CloudUsers / c=CloudUser query / a=ADUser query / x=abort." -Color Cyan
    $deadline = (Get-Date).AddSeconds($Seconds)

    while ((Get-Date) -lt $deadline) {
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true).KeyChar.ToString().ToLowerInvariant()
                switch ($key) {
                    "p" {
                        return Invoke-DeletedUserPollAction -Action "CheckActive" -TargetUser $TargetUser
                    }
                    "c" {
                        Invoke-DeletedUserPollAction -Action "QueryCloud" -TargetUser $TargetUser
                        return
                    }
                    "a" {
                        Invoke-DeletedUserPollAction -Action "QueryAd" -TargetUser $TargetUser
                        return
                    }
                    "x" {
                        Invoke-DeletedUserPollAction -Action "Abort" -TargetUser $TargetUser
                    }
                    default {
                        Write-UiStatus -Status "INFO" -Message "Ignored key '$key'. Waiting for next deleted-user poll." -Color Yellow
                    }
                }
            }
        }
        catch [System.InvalidOperationException] {
            Start-Sleep -Seconds $Seconds
            return
        }

        Start-Sleep -Milliseconds 250
    }
}

function Read-ActiveCloudUserPollDecision {
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser,

        [Parameter(Mandatory = $true)]
        $ActiveCloudUser
    )

    while ($true) {
        $choice = (Read-UiInput -Prompt "Active cloud user found. Next action?" -Options @("s=skip to cloud cleanup", "d=run delta sync", "p=continue polling deleted users", "c=CloudUser query", "a=ADUser query", "x=abort")).Trim()
        if ($choice -eq "s") {
            Write-UiStatus -Status "SKIP" -Message "Skipping deleted-user restore and continuing with active CloudUser '$($ActiveCloudUser.userPrincipalName)'." -Color Yellow
            return "SkipToCloudCleanup"
        }
        if ($choice -eq "d") {
            Write-UiStatus -Status "SYNC" -Message "Running another Entra Connect delta sync before continuing deleted-user polling." -Color Yellow
            Invoke-EntraConnectDeltaSyncStep
            return "ContinuePolling"
        }
        if ($choice -eq "p") {
            return "ContinuePolling"
        }
        if ($choice -eq "x") {
            Stop-TerminationWorkflow -Message "Workflow aborted by operator after active cloud user check."
        }
        if ($choice -eq "c") {
            Show-CurrentCloudUserState
            continue
        }
        if ($choice -eq "a") {
            Show-CurrentAdUserState
            continue
        }

        Write-UiStatus -Status "WARN" -Message "Enter exact lowercase s, d, p, c, a, or x." -Color Yellow
    }
}

function Read-DeletedUserPollingLimitDecision {
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser
    )

    while ($true) {
        $choice = (Read-UiInput -Prompt "Deleted user not found. Next action?" -Options @("p=keep polling", "r=restart script", "c=CloudUser query", "a=ADUser query", "x=abort")).Trim()
        if ($choice -eq "p") {
            return
        }
        if ($choice -eq "r") {
            Request-TerminationWorkflowRestart
        }
        if ($choice -eq "x") {
            Stop-TerminationWorkflow -Message "Workflow aborted by operator after deleted-user polling reached the limit."
        }
        if ($choice -eq "c") {
            Show-CurrentCloudUserState
            continue
        }
        if ($choice -eq "a") {
            Show-CurrentAdUserState
            continue
        }

        Write-UiStatus -Status "WARN" -Message "Enter exact lowercase p, r, c, a, or x." -Color Yellow
    }
}

function Restore-TerminatedCloudUser {
    # searches deleted users by onPremisesImmutableID, then restores.
    param(
        [Parameter(Mandatory = $true)]
        $TargetUser
    )

    $effectiveUserPrincipalName = $TargetUser.UserPrincipalName
    $cloudUser = $null
    $immutableIdFilter = [System.Uri]::EscapeDataString("onPremisesImmutableId eq '$($TargetUser.OnPremisesImmutableId)'")
    $deletedUri = "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?`$filter=$immutableIdFilter" + [char]38 + "`$select=id,userPrincipalName,onPremisesImmutableId,deletedDateTime"
    $deletedUser = $null
    $deletedPollAttempt = 0

    while (-not $deletedUser) {
        $deletedPollAttempt++
        $attemptInSet = (($deletedPollAttempt - 1) % $PollAttempts) + 1
        Write-UiStatus -Status "POLL" -Message "Checking deleted users for '$($TargetUser.UserPrincipalName)', attempt $attemptInSet of $PollAttempts." -Color Cyan

        try {
            $deleted = Invoke-MgGraphRequest -Method GET -Uri $deletedUri
            $deletedUsers = @($deleted.value | Where-Object { $_ })

            if ($deletedUsers.Count -gt 0) {
                $deletedUser = $deletedUsers | Sort-Object deletedDateTime -Descending | Select-Object -First 1
                Write-UiStatus -Status "OK" -Message "Found deleted cloud user '$($deletedUser.userPrincipalName)'." -Color Green
                break
            }
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Deleted user query failed on attempt ${attemptInSet}: $($_.Exception.Message)" -Color Yellow
        }

        if ($deletedUser) {
            break
        }

        if ($attemptInSet -ge $PollAttempts) {
            Write-UiStatus -Status "WAIT" -Message "Deleted user was not found after $PollAttempts poll attempt(s)." -Color Yellow
            Read-DeletedUserPollingLimitDecision -TargetUser $TargetUser
            continue
        }

        $pollActionResult = Wait-DeletedUserPollInterval -TargetUser $TargetUser -Seconds $PollSeconds
        if ($pollActionResult -and $pollActionResult.SkipToCloudCleanup) {
            return [pscustomobject]@{
                CloudUser         = $pollActionResult.CloudUser
                UserPrincipalName = $pollActionResult.UserPrincipalName
            }
        }
    }

    if ($deletedUser) {
        $restoredUser = Do-Step -Name "Restore deleted cloud user" `
            -Required `
            -PassThru `
            -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/directory/deletedItems/$($deletedUser.id)/restore'" `
            -SuccessMessage "Step completed: restored deleted cloud user for '$($TargetUser.UserPrincipalName)'." `
            -Command {
            $restoredUser = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/directory/deletedItems/$($deletedUser.id)/restore"
            return $restoredUser
        }

        if (-not $DryRun) {
            if (-not $restoredUser -or [string]::IsNullOrWhiteSpace($restoredUser.id)) {
                throw "Restore step did not return a cloud user ID. The restore may have been skipped or failed."
            }

            # Poll for the restored user so we don't proceed with nulling until user is fully restored.
            for ($i = 1; $i -le $PollAttempts; $i++) {
                Write-UiStatus -Status "POLL" -Message "Polling for restored cloud user, attempt $i of $PollAttempts..." -Color Cyan
                try {
                    $cloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $restoredUser.id -Select "id,userPrincipalName,onPremisesImmutableId,accountEnabled,assignedLicenses")
                    $effectiveUserPrincipalName = $cloudUser.userPrincipalName
                    Write-UiStatus -Status "FOUND" -Message "Restored cloud user is now active with UPN '$effectiveUserPrincipalName' and OnPremisesImmutableId '$($cloudUser.onPremisesImmutableId)'." -Color Cyan
                    break
                }
                catch {
                    Start-Sleep -Seconds $PollSeconds
                }
            }
        }
    }
    return [pscustomobject]@{
        CloudUser         = $cloudUser
        UserPrincipalName = $effectiveUserPrincipalName
    }
}

function Invoke-CloudAccountLockdown {
    param(
        [AllowNull()]
        $CloudUser,

        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    if (-not $CloudUser -and -not $DryRun) {
        throw "Cloud user was not found after restore polling."
    }

    Write-UiBox -Title "Cloud Account Lockdown Plan" -Lines @(
        New-UiBoxLine -Label "UserPrincipalName" -Value $UserPrincipalName
        New-UiBoxLine -Label "AccountEnabled" -Value $CloudUser.accountEnabled
        New-UiBoxLine -Label "ImmutableId" -Value $CloudUser.onPremisesImmutableId
        New-UiBoxLine -Label "Revoke sessions" -Value $true
        New-UiBoxLine -Label "Block sign-in" -Value $true
        New-UiBoxLine -Label "Clear immutable ID" -Value $true
    )

    Do-Step -Name "Revoke sign-in sessions" `
        -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users/$UserPrincipalName/revokeSignInSessions'" `
        -SuccessMessage "Step completed: revoked sign-in sessions for '$UserPrincipalName'." `
        -Command {
        $revokeUri = (Get-GraphUserUri -UserIdOrUpn $UserPrincipalName) + "/revokeSignInSessions"
        Invoke-MgGraphRequest -Method POST -Uri $revokeUri
    }

    Do-Step -Name "Block cloud sign-in" `
        -CommandPreview "Invoke-MgGraphRequest -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/users/$UserPrincipalName' -Body '{ accountEnabled = false }'" `
        -SuccessMessage "Step completed: blocked cloud sign-in for '$UserPrincipalName'." `
        -Verify {
        $currentCloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $UserPrincipalName -Select "accountEnabled")
        $currentCloudUser.accountEnabled -eq $false
    } `
        -Command {
        $body = @{ accountEnabled = $false } | ConvertTo-Json
        Invoke-MgGraphRequest -Method PATCH -Uri (Get-GraphUserUri -UserIdOrUpn $UserPrincipalName) -Body $body -ContentType "application/json"
    }

    Do-Step -Name "Clear onPremisesImmutableId" `
        -CommandPreview "Invoke-MgGraphRequest -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/users/$UserPrincipalName' -Body '{ onPremisesImmutableId = null }'" `
        -SuccessMessage "Step completed: cleared onPremisesImmutableId for '$UserPrincipalName'." `
        -Verify {
        $currentCloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $CloudUser.id -Select "onPremisesImmutableId")
        [string]::IsNullOrWhiteSpace([string]$currentCloudUser.onPremisesImmutableId)
    } `
        -Command {
        $immutableIdBefore = $CloudUser.onPremisesImmutableId
        $body = @{ onPremisesImmutableId = $null } | ConvertTo-Json
        Invoke-MgGraphRequest -Method PATCH -Uri (Get-GraphUserUri -UserIdOrUpn $UserPrincipalName) -Body $body -ContentType "application/json"

        $updatedCloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $CloudUser.id -Select "id,userPrincipalName,onPremisesImmutableId,accountEnabled,assignedLicenses")
        Write-UiBox -Title "Immutable ID Change" -Lines @(
            New-UiBoxLine -Label "Before" -Value $immutableIdBefore
            New-UiBoxLine -Label "After" -Value $updatedCloudUser.onPremisesImmutableId
        )
    }
}

# -------------------------
# Mailbox and delegate changes.
# -------------------------


function Invoke-MailboxTerminationChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    # Get mailbox details and store in script variable. Will also print out mailbox state.
    $mailboxDetails = Get-MailboxDetailsAndStats -UserPrincipalName $UserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
    $script:RunContext["MailboxDetails"] = $mailboxDetails
    $mailbox = $mailboxDetails.Mailbox

    Write-UiBox -Title "Mailbox Change Plan" -Lines @(
        New-UiBoxLine -Label "Mailbox" -Value $UserPrincipalName
        New-UiBoxLine -Label "Convert to shared" -Value $ConvertToSharedMailbox
        New-UiBoxLine -Label "Hide from GAL" -Value $HideFromGAL
        New-UiBoxLine -Label "Enable sent item copy" -Value $EnableSentItemCopy
    )

    if ($ConvertToSharedMailbox) {
        Do-Step -Name "Convert mailbox to shared" `
            -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -Type Shared" `
            -SuccessMessage "Step completed: converted mailbox '$UserPrincipalName' to shared." `
            -Verify {
            (Get-Mailbox -Identity $UserPrincipalName).RecipientTypeDetails -eq "SharedMailbox"
        } `
            -Command {
            Set-Mailbox -Identity $UserPrincipalName -Type Shared
        }
    }
    else {
        Write-UiStatus -Status "SKIP" -Message "Convert mailbox option is disabled." -Color Yellow
    }

    if ($HideFromGAL) {
        Do-Step -Name "Hide mailbox from GAL" `
            -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -HiddenFromAddressListsEnabled `$true" `
            -SuccessMessage "Step completed: hid mailbox '$UserPrincipalName' from the GAL." `
            -Verify {
            (Get-Mailbox -Identity $UserPrincipalName).HiddenFromAddressListsEnabled -eq $true
        } `
            -Command {
            Set-Mailbox -Identity $UserPrincipalName -HiddenFromAddressListsEnabled $true
        }
    }
    else {
        Write-UiStatus -Status "SKIP" -Message "Hide from GAL option is disabled." -Color Yellow
    }

    if ($EnableSentItemCopy) {
        Do-Step -Name "Enable sent item copy for Send As and Send on Behalf" `
            -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -MessageCopyForSentAsEnabled `$true -MessageCopyForSendOnBehalfEnabled `$true" `
            -SuccessMessage "Step completed: enabled sent item copy for '$UserPrincipalName'." `
            -Verify {
            $currentMailbox = Get-Mailbox -Identity $UserPrincipalName
            ($currentMailbox.MessageCopyForSentAsEnabled -eq $true) -and
                ($currentMailbox.MessageCopyForSendOnBehalfEnabled -eq $true)
        } `
            -Command {
            Set-Mailbox -Identity $UserPrincipalName -MessageCopyForSentAsEnabled $true -MessageCopyForSendOnBehalfEnabled $true
        }
    }
    else {
        Write-UiStatus -Status "SKIP" -Message "Enable sent item copy option is disabled." -Color Yellow
    }
}

function Invoke-MailboxDelegateAssignments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    Write-UiBox -Title "Mailbox Delegate Requests" -Lines @(
        New-UiBoxLine -Label "Mailbox" -Value $UserPrincipalName
        New-UiBoxLine -Label "Full Access" -Value $DelegatesFullAccess
        New-UiBoxLine -Label "Send As" -Value $DelegatesSendAs
        New-UiBoxLine -Label "Send on Behalf" -Value $DelegatesSendOnBehalf
    )

    $resolvedDelegatesFullAccess = Resolve-CloudDelegateList -Lookups $DelegatesFullAccess -PermissionName "Full Access"
    $resolvedDelegatesSendAs = Resolve-CloudDelegateList -Lookups $DelegatesSendAs -PermissionName "Send As"
    $resolvedDelegatesSendOnBehalf = Resolve-CloudDelegateList -Lookups $DelegatesSendOnBehalf -PermissionName "Send on Behalf"

    Write-UiBox -Title "Resolved Mailbox Delegates" -Lines @(
        New-UiBoxLine -Label "Full Access" -Value @($resolvedDelegatesFullAccess | ForEach-Object { $_.Label })
        New-UiBoxLine -Label "Send As" -Value @($resolvedDelegatesSendAs | ForEach-Object { $_.Label })
        New-UiBoxLine -Label "Send on Behalf" -Value @($resolvedDelegatesSendOnBehalf | ForEach-Object { $_.Label })
    )

    if ($resolvedDelegatesFullAccess.Count -eq 0 -and $resolvedDelegatesSendAs.Count -eq 0 -and $resolvedDelegatesSendOnBehalf.Count -eq 0) {
        Write-UiStatus -Status "INFO" -Message "No mailbox delegates were resolved for assignment." -Color Yellow
    }

    foreach ($delegate in $resolvedDelegatesFullAccess) {
        Do-Step -Name "Add Full Access delegate '$($delegate.Label)'" `
            -CommandPreview "Add-MailboxPermission -Identity '$UserPrincipalName' -User '$($delegate.UserPrincipalName)' -AccessRights FullAccess -InheritanceType All" `
            -SuccessMessage "Step completed: added Full Access delegate '$($delegate.Label)' to '$UserPrincipalName'." `
            -Command {
            Add-MailboxPermission -Identity $UserPrincipalName -User $delegate.UserPrincipalName -AccessRights FullAccess -InheritanceType All
        }
    }

    foreach ($delegate in $resolvedDelegatesSendAs) {
        Do-Step -Name "Add Send As delegate '$($delegate.Label)'" `
            -CommandPreview "Add-RecipientPermission -Identity '$UserPrincipalName' -Trustee '$($delegate.UserPrincipalName)' -AccessRights SendAs -Confirm:`$false" `
            -SuccessMessage "Step completed: added Send As delegate '$($delegate.Label)' to '$UserPrincipalName'." `
            -Command {
            Add-RecipientPermission -Identity $UserPrincipalName -Trustee $delegate.UserPrincipalName -AccessRights SendAs -Confirm:$false
        }
    }

    foreach ($delegate in $resolvedDelegatesSendOnBehalf) {
        Do-Step -Name "Add Send on Behalf delegate '$($delegate.Label)'" `
            -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -GrantSendOnBehalfTo @{ Add = '$($delegate.UserPrincipalName)' }" `
            -SuccessMessage "Step completed: added Send on Behalf delegate '$($delegate.Label)' to '$UserPrincipalName'." `
            -Command {
            Set-Mailbox -Identity $UserPrincipalName -GrantSendOnBehalfTo @{ Add = $delegate.UserPrincipalName }
        }
    }
}

# -------------------------
# License review and assignment.
# -------------------------

function Invoke-TerminationLicenseReviewAndAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    # Load licenses
    Write-UiStatus -Status "LOADING..." -Message "Loading tenant license availability." -Color Cyan
    $skus = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber,prepaidUnits,consumedUnits"
    Write-UiStatus -Status "LOADING..." -Message "Loading assigned licenses for '$UserPrincipalName'." -Color Cyan
    $cloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $UserPrincipalName -Select "assignedLicenses")

    $skuCommonNames = Get-SkuCommonNames
    $skuById = New-SkuLookup -Skus $skus.value -SkuCommonNames $skuCommonNames
    $assignedLicenses = @($cloudUser.assignedLicenses | Where-Object { $_ })
    $assignedLicenseRows = Get-AssignedLicenseRows -AssignedLicenses $assignedLicenses -SkuById $skuById
    Write-UiStatus -Status "OK" -Message "Loaded $($assignedLicenseRows.Count) assigned license row(s)." -Color Green

    if ($assignedLicenseRows.Count -eq 0) {
        Write-UiBox -Title "Current Assigned Licenses" -Lines @(
            "None"
        )
    }
    else {
        Write-UiBox -Title "Current Assigned Licenses" -Lines (ConvertTo-UiTableLines -Rows $assignedLicenseRows -Columns @("License"))
    }

    $tenantLicenseRows = @(Get-TenantLicenseRows -Skus $skus.value -SkuCommonNames $skuCommonNames)
    $availableTenantLicenseRows = @($tenantLicenseRows | Where-Object { $_.Available -gt 0 })
    Write-UiBox -Title "Tenant License Availability" -Lines (ConvertTo-UiTableLines -Rows $tenantLicenseRows -Columns @("License", "Consumed", "Enabled", "Available"))

    # Reload mailbox details
    $MailboxDetails = Get-MailboxDetailsAndStats -UserPrincipalName $UserPrincipalName -Silent -PollSeconds $PollSeconds -PollAttempts $PollAttempts
    $mailbox = $MailboxDetails.Mailbox
    $stats = $MailboxDetails.Statistics
    $mailboxDecision = Get-MailboxSizeDecisionInfo -Mailbox $mailbox -Statistics $stats

    $defenderSkuPartNumber = "ATP_ENTERPRISE"
    $defenderLicenseName = "Microsoft Defender for Office 365 (Plan 1)"
    $defenderSku = @($skus.value | Where-Object { $_.skuPartNumber -eq $defenderSkuPartNumber } | Select-Object -First 1)
    $defenderAvailable = 0
    if ($defenderSku) {
        $defenderAvailable = [int]$defenderSku.prepaidUnits.enabled - [int]$defenderSku.consumedUnits
    }

    $assignedSkuIds = @($assignedLicenses | ForEach-Object { [string]$_.skuId } | Sort-Object -Unique)
    $defenderSkuId = if ($defenderSku) { [string]$defenderSku.skuId } else { $null }
    $userAlreadyHasDefender = -not [string]::IsNullOrWhiteSpace($defenderSkuId) -and $assignedSkuIds -contains $defenderSkuId
    $mailboxCanUseDefender = (-not $mailboxDecision.ArchiveEnabled) -and $mailboxDecision.Under50GB
    $defenderAvailableOrAssigned = $defenderSku -and ($defenderAvailable -gt 0 -or $userAlreadyHasDefender)

    $mailboxSizeGbText = "Could not parse"
    if ($null -ne $mailboxDecision.SizeGB) {
        $mailboxSizeGbText = $mailboxDecision.SizeGB
    }

    Write-UiBox -Title "License Decision Mailbox Data" -Lines @(
        New-UiBoxLine -Label "Mailbox" -Value $UserPrincipalName
        New-UiBoxLine -Label "Mailbox size" -Value $stats.TotalItemSize
        New-UiBoxLine -Label "Mailbox size GB" -Value $mailboxSizeGbText
        New-UiBoxLine -Label "Archive enabled" -Value $mailboxDecision.ArchiveEnabled
        New-UiBoxLine -Label "Archive status" -Value $mailbox.ArchiveStatus
        New-UiBoxLine -Label "Archive state" -Value $mailbox.ArchiveState
        New-UiBoxLine -Label "Defender license" -Value $defenderLicenseName
        New-UiBoxLine -Label "Defender available" -Value $defenderAvailable
        New-UiBoxLine -Label "Can use Defender" -Value $mailboxCanUseDefender
    )

    if ($mailboxCanUseDefender) {
        if ($defenderAvailableOrAssigned) {
            $removeSkuIds = @($assignedSkuIds | Where-Object { $_ -ne $defenderSkuId })
            $licensesToRemoveText = @($assignedLicenseRows | Where-Object { $removeSkuIds -contains [string]$_.SkuId } | ForEach-Object { $_.License }) -join ", "
            if ([string]::IsNullOrWhiteSpace($licensesToRemoveText)) {
                $licensesToRemoveText = "None"
            }
            $addLicenses = @()
            if (-not $userAlreadyHasDefender) {
                $addLicenses += @{
                    skuId = $defenderSku.skuId
                    disabledPlans = @()
                }
            }
            $licensesToAddText = if ($addLicenses.Count -gt 0) { $defenderLicenseName } else { "None" }

            Write-UiBox -Title "License Assignment Plan" -Lines @(
                New-UiBoxLine -Label "Mailbox" -Value $UserPrincipalName
                New-UiBoxLine -Label "Target license" -Value $defenderLicenseName
                New-UiBoxLine -Label "Already has Defender" -Value $userAlreadyHasDefender
                New-UiBoxLine -Label "Licenses to remove" -Value $licensesToRemoveText
                New-UiBoxLine -Label "Licenses to add" -Value $licensesToAddText
            )

            if ($removeSkuIds.Count -eq 0 -and $addLicenses.Count -eq 0) {
                Write-UiStatus -Status "VERIFIED" -Message "User already has '$defenderLicenseName' and no non-Defender licenses need to be removed." -Color Green
            }
            elseif ($Force) {
                Do-Step -Name "Remove current licenses and assign $defenderLicenseName" `
                    -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users/$UserPrincipalName/assignLicense' -Body <add $defenderLicenseName; remove current non-Defender licenses>" `
                    -SuccessMessage "Step completed: removed current non-Defender licenses and assigned '$defenderLicenseName' to '$UserPrincipalName'." `
                    -Verify {
                    $currentCloudUser = Invoke-MgGraphRequest -Method GET -Uri (Get-GraphUserUri -UserIdOrUpn $UserPrincipalName -Select "assignedLicenses")
                    $currentSkuIds = @($currentCloudUser.assignedLicenses | Where-Object { $_ } | ForEach-Object { [string]$_.skuId } | Sort-Object -Unique)
                    $hasDefender = -not [string]::IsNullOrWhiteSpace($defenderSkuId) -and $currentSkuIds -contains $defenderSkuId
                    $hasNonDefender = @($currentSkuIds | Where-Object { $_ -ne $defenderSkuId }).Count -gt 0
                    $hasDefender -and (-not $hasNonDefender)
                } `
                    -Command {
                    $body = @{
                        addLicenses = @($addLicenses)
                        removeLicenses = @($removeSkuIds)
                    } | ConvertTo-Json -Depth 6

                    $assignLicenseUri = (Get-GraphUserUri -UserIdOrUpn $UserPrincipalName) + "/assignLicense"
                    Invoke-MgGraphRequest -Method POST -Uri $assignLicenseUri -Body $body -ContentType "application/json"
                }
            }
            else {
                Write-UiStatus -Status "INFO" -Message "Defender is available. Use license management to add Defender and remove other assigned licenses." -Color Yellow
                Invoke-TerminationLicenseManagementPrompt `
                    -UserPrincipalName $UserPrincipalName `
                    -DesiredOnlySkuId $defenderSkuId `
                    -FinalWarningIfSkipped "Termination not complete: review license assignment and remove non-Defender licenses after assigning Defender."
            }
        }
        else {
            $finalWarning = "Termination not complete: Request Defender license, assign it, then remove all other licenses on the user."
            Add-TerminationFinalWarning -Message $finalWarning
            Write-UiBox -Title "License Request Needed" -Lines @(
                $finalWarning
            )
        }
    }
    else {
        $mailboxRequirementWarning = "Mailbox does not qualify for Defender license swap. Review existing licenses before completing termination."
        Write-UiStatus -Status "WARN" -Message $mailboxRequirementWarning -Color Yellow
        Write-UiBox -Title "Leaving Current Licenses Assigned" -Lines @(
            "Mailbox archive is enabled, mailbox is 50 GB or larger,"
            "or mailbox size could not be parsed."
            New-UiBoxLine -Label "Mailbox type" -Value $mailbox.RecipientTypeDetails
            New-UiBoxLine -Label "Mailbox size" -Value $stats.TotalItemSize
            New-UiBoxLine -Label "Mailbox size GB" -Value $mailboxSizeGbText
            New-UiBoxLine -Label "Archive status" -Value $mailbox.ArchiveStatus
            New-UiBoxLine -Label "Archive state" -Value $mailbox.ArchiveState
        )

        if ($assignedLicenseRows.Count -eq 0) {
            Write-UiBox -Title "Licenses Still Assigned" -Lines @(
                "None"
            )
        }
        else {
            Write-UiBox -Title "Licenses Still Assigned" -Lines (ConvertTo-UiTableLines -Rows $assignedLicenseRows -Columns @("License"))
        }

        Invoke-TerminationLicenseManagementPrompt `
            -UserPrincipalName $UserPrincipalName `
            -FinalWarningIfSkipped "Termination not complete: mailbox does not qualify for Defender swap and license assignment still needs review."
    }
}

function Invoke-TerminationLicenseManagementPrompt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [string]$DesiredOnlySkuId = "",

        [string]$FinalWarningIfSkipped = ""
    )

    $managerResult = Invoke-InteractiveLicenseManager -UserIdOrUpn $UserPrincipalName -DisplayName $UserPrincipalName -PassThru
    $currentRows = @($managerResult.AssignedRows)

    if (-not [string]::IsNullOrWhiteSpace($DesiredOnlySkuId)) {
        $currentSkuIds = @($currentRows | ForEach-Object { [string]$_.SkuId })
        $desiredStateMet = ($currentSkuIds.Count -eq 1 -and $currentSkuIds -contains $DesiredOnlySkuId)
        if (-not $desiredStateMet -and -not [string]::IsNullOrWhiteSpace($FinalWarningIfSkipped)) {
            Add-TerminationFinalWarning -Message $FinalWarningIfSkipped
        }
    }
    elseif ($currentRows.Count -eq 0) {
        Add-TerminationFinalWarning -Message "Termination warning: user is currently unlicensed."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($FinalWarningIfSkipped)) {
        Add-TerminationFinalWarning -Message $FinalWarningIfSkipped
    }
}

while ($true) {
    $script:RestartRequested = $false

    try {
        Invoke-Main
        break
    }
    catch {
        if ($script:RestartRequested) {
            Write-UiStatus -Status "RESTART" -Message "Restarting workflow from the beginning." -Color Yellow
            continue
        }

        $includeGroupMemberships = $false
        if ($script:RunContext -and $script:RunContext["StoppedByAbort"]) {
            $includeGroupMemberships = $true
        }

        Write-UiFinalRunSummary `
            -Title "User Termination Run Stopped" `
            -Subtitle "Review the summary before rerunning or resuming manually." `
            -ErrorMessage $_.Exception.Message `
            -IncludeGroupMemberships:$includeGroupMemberships
        break
    }
}
