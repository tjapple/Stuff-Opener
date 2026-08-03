# -------------------------
# Fill these in per ticket.
# -------------------------

$Client = "Client"
$FirstName = "First"
$LastName = "Last"
$CopyAfterLookup = ""

# Optional identity/location overrides. Leave blank to resolve interactively.
$SamAccountName = ""
$UserPrincipalName = ""
$TargetOU = ""
$AdObjectName = ""

# Optional attributes for the new AD user.
$Title = ""
$Department = ""
$Description = ""
$ManagerLookup = ""
$MappedDriveLetters = ""

# Run options.
$RunADSync = $true
$MustChangePasswordAtNextLogon = $true
$DryRun = $true
$Force = $false
$ResumeExistingUser = $false
$ResumeUserLookup = ""
$PollSeconds = 5
$PollAttempts = 100

# -------------------------
# 0.5. Prep work: import modules and define helper functions.
# -------------------------

$ErrorActionPreference = "Stop"

function Invoke-Main {
    Initialize-UiState
    Initialize-NewUserIssueState
    Write-UiBanner
    Write-UiHeader -Title "MSP New User" -Subtitle "Client: $Client"
    Write-UiBox -Title "Preflight" -Lines @(
        New-UiBoxLine -Label "Client" -Value $Client
        New-UiBoxLine -Label "Run mode" -Value $(if ($DryRun) { "Dry run" } else { "Live changes" })
        New-UiBoxLine -Label "Force mode" -Value $Force
        New-UiBoxLine -Label "Resume existing user" -Value $ResumeExistingUser
        New-UiBoxLine -Label "Run AD sync" -Value $RunADSync
        New-UiBoxLine -Label "Mapped drives" -Value $MappedDriveLetters
    )
    Import-ActiveDirectoryModule
    Test-NewUserConfig

    $copyAfterUser = Resolve-CopyAfterUser
    $creation = Resolve-NewUserAdCreation -CopyAfterUser $copyAfterUser
    if ($creation.Stopped) {
        Write-UiFinalNewUserSummary -Title "New User Run Stopped" -Subtitle "No AD user was created."
        return
    }

    $plan = $creation.Plan
    $newUser = $creation.User

    $script:RunContext["NewUserObjectGuid"] = if ($newUser.ObjectGUID) { [string]$newUser.ObjectGUID } else { "" }
    $script:RunContext["NewUserDistinguishedName"] = $newUser.DistinguishedName
    if (Test-UiDryRun) {
        Write-UiBox -Title "Planned AD User" -Lines @(
            New-UiBoxLine -Label "Name" -Value $newUser.Name
            New-UiBoxLine -Label "SamAccountName" -Value $newUser.SamAccountName
            New-UiBoxLine -Label "UserPrincipalName" -Value $newUser.UserPrincipalName
            New-UiBoxLine -Label "Enabled" -Value $newUser.Enabled
            New-UiBoxLine -Label "DistinguishedName" -Value $newUser.DistinguishedName
        )
    }
    else {
        Show-AdUserState -Identity ([string]$newUser.ObjectGUID) -Title "Created AD User"
    }

    Invoke-AdGroupCopyAndReview -NewUser $newUser -CopyAfterUser $copyAfterUser
    Invoke-MappedDriveAccessReview -NewUser $newUser -TargetOU $plan.TargetOU -DriveLettersText $MappedDriveLetters

    if ($RunADSync) {
        Invoke-NewUserDeltaSync
    }
    else {
        Write-UiStatus -Status "SKIP" -Message "RunADSync is false. Run delta sync manually before expecting the cloud user." -Color Yellow
        Add-UiStepResult -Name "Entra Connect delta sync" -Result "Skipped" -Note "RunADSync was false."
    }

    if (Test-UiDryRun) {
        Write-UiStatus -Status "DRY RUN" -Message "Stopping before cloud polling because the AD user was not actually created." -Color DarkGray
        Write-UiFinalNewUserSummary -Title "New User Dry Run Complete" -Subtitle "Review the action log before running live."
        return
    }

    if (-not (Connect-NewUserCloudServices)) {
        Write-UiFinalNewUserSummary -Title "New User Run Cloud Steps Skipped" -Subtitle "AD-side work completed. Rerun with resume mode to finish cloud steps."
        return
    }

    $cloudUser = Wait-NewCloudUser -Plan $plan
    if ($cloudUser) {
        $script:RunContext["CloudUserId"] = $cloudUser.id
        Format-CloudUserState -CloudUser $cloudUser -Source "New user lookup"
        Invoke-CloudLicensePicker -CloudUser $cloudUser -CopyAfterUser $copyAfterUser
        Invoke-CloudGroupCopyReview -NewCloudUser $cloudUser -CopyAfterUser $copyAfterUser
    }

    Write-UiFinalNewUserSummary -Title "New User Run Complete" -Subtitle "Review the AD and cloud state before closing."
}

# -------------------------
# Shared tool helpers.
# -------------------------

# {{POWERSHELL_TOOLS: ConsoleUi, ActiveDirectoryHelpers, PowerShellModuleInstall, MgGraphHelpers, LicenseHelpers}}

# -------------------------
# New user workflow.
# -------------------------

function Test-NewUserConfig {
    if ([string]::IsNullOrWhiteSpace($Client)) {
        throw "Client is required."
    }
    if ([string]::IsNullOrWhiteSpace($FirstName)) {
        throw "FirstName is required."
    }
    if ([string]::IsNullOrWhiteSpace($LastName)) {
        throw "LastName is required."
    }
}

function Test-NewUserForceMode {
    return [bool]$Force
}

function Test-NewUserResumeMode {
    return [bool]$ResumeExistingUser
}

function Initialize-NewUserIssueState {
    $script:NewUserRunIssues = New-Object System.Collections.ArrayList
}

function Add-NewUserRunIssue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [string]$Target = "",

        [Parameter(Mandatory = $true)]
        [string]$Detail,

        [string]$Result = "Failed"
    )

    try {
        if ($null -eq $script:NewUserRunIssues -or -not ($script:NewUserRunIssues -is [System.Collections.ArrayList])) {
            $existingIssues = @($script:NewUserRunIssues | Where-Object { $_ })
            $script:NewUserRunIssues = New-Object System.Collections.ArrayList
            foreach ($existingIssue in $existingIssues) {
                [void]$script:NewUserRunIssues.Add($existingIssue)
            }
        }

        [void]$script:NewUserRunIssues.Add([pscustomobject]@{
            Time   = (Get-Date).ToString("HH:mm:ss")
            Result = $Result
            Source = $Source
            Target = $Target
            Detail = $Detail
        })
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not record final issue entry: $($_.Exception.Message)" -Color Yellow
    }
}

function Test-NewUserCreationAlreadyExistsError {
    param(
        [AllowNull()]
        [string]$ErrorMessage
    )

    return ([string]$ErrorMessage -match "(?i)(already exists|already in use|name that is already in use|object.*already|duplicate)")
}

function Test-NewUserPasswordRejectedError {
    param(
        [AllowNull()]
        [string]$ErrorMessage
    )

    return ([string]$ErrorMessage -match "(?i)(password.*(complexity|length|history|requirement|policy|does not meet)|does not meet.*password|0000052D|constraint.*password)")
}

function Get-NewUserResumeSignal {
    return "__NEW_USER_RESUME_REQUESTED__"
}

function Get-NewUserAdStateProperties {
    return @("Enabled", "DistinguishedName", "UserPrincipalName", "mail", "DisplayName", "MemberOf", "ObjectGUID", "mS-DS-ConsistencyGuid")
}

function Get-CopyAfterAdUserProperties {
    return @((Get-NewUserAdStateProperties) + @("Title", "Department", "Description", "GivenName", "Surname"))
}

function Get-ResumeAdUserProperties {
    return @((Get-CopyAfterAdUserProperties) + @("Manager"))
}

function Get-PartialCreatedAdUserProperties {
    return @((Get-NewUserAdStateProperties) + @("PasswordLastSet"))
}

function Get-NewUserCloudAnchorAdProperties {
    return @("ObjectGUID", "mS-DS-ConsistencyGuid", "UserPrincipalName")
}

function Get-NewUserSamConflictMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamAccountName
    )

    $escaped = Escape-DirectoryFilterValue -Value $SamAccountName
    return @(Get-ADUser -Filter "SamAccountName -eq '$escaped'" -Properties (Get-ResumeAdUserProperties) -ErrorAction Stop)
}

function Get-NewUserPrincipalNameConflictMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    $alias = Get-UpnAlias -UserPrincipalName $UserPrincipalName
    $escapedAlias = Escape-DirectoryFilterValue -Value $alias
    return @(Get-ADUser -Filter "UserPrincipalName -like '$escapedAlias@*'" -Properties (Get-ResumeAdUserProperties) -ErrorAction Stop)
}

function Get-NewUserObjectNameConflictMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$TargetOu
    )

    $escapedName = Escape-LdapFilterValue -Value $Name
    return @(Get-ADUser -LDAPFilter "(cn=$escapedName)" -SearchBase $TargetOu -SearchScope OneLevel -Properties (Get-ResumeAdUserProperties) -ErrorAction Stop)
}

function Read-NewUserExistingUserConflictAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConflictName,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    while ($true) {
        $choice = Read-UiInput -Prompt "$ConflictName '$Value' already exists. Next action?" -Options @("r=resume this user", "n=enter different value", "x=exit")
        switch ($choice) {
            "r" { return "Resume" }
            "n" { return "NewValue" }
            "x" { return "Exit" }
            default {
                Write-UiStatus -Status "INFO" -Message "Enter exact lowercase r, n, or x." -Color Yellow
            }
        }
    }
}

function Request-NewUserResumeFromMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Matches,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $cleanMatches = @($Matches | Where-Object { $_ })
    if ($cleanMatches.Count -eq 0) {
        Write-UiStatus -Status "WARN" -Message "No existing AD user was available to resume for $Purpose." -Color Yellow
        return
    }

    $selectedUser = Select-AdUserLookupMatch -Matches $cleanMatches -Purpose $Purpose -AllowCancel
    if (-not $selectedUser) {
        return
    }

    $script:NewUserPendingResumeAdUser = Get-ADUser -Identity ([string]$selectedUser.ObjectGUID) -Properties (Get-ResumeAdUserProperties)
    throw (Get-NewUserResumeSignal)
}

function Read-NewUserIdentityAfterCreationCollision {
    param(
        [Parameter(Mandatory = $true)]
        $Plan
    )

    $suggestedSam = $Plan.SamAccountName
    while ($true) {
        $candidateText = (Read-UiInput -Prompt "Enter different pre-Windows 2000 User Logon Name" -Options @("sAMAccountName", "x=abort")).Trim()
        if ($candidateText -eq "x") {
            throw "New-user workflow aborted while choosing a different logon name."
        }
        if ([string]::IsNullOrWhiteSpace($candidateText)) {
            $candidateText = $suggestedSam
        }
        if ([string]::IsNullOrWhiteSpace($candidateText)) {
            Write-UiStatus -Status "WARN" -Message "A new sAMAccountName is required before retrying user creation." -Color Yellow
            continue
        }
        if ($candidateText.Length -gt 20) {
            Write-UiStatus -Status "WARN" -Message "sAMAccountName '$candidateText' is $($candidateText.Length) characters. The pre-Windows 2000 logon name limit is 20 characters." -Color Yellow
            continue
        }

        $candidateSam = ConvertTo-SafeSamAccountName -Value $candidateText
        if ([string]::IsNullOrWhiteSpace($candidateSam)) {
            Write-UiStatus -Status "WARN" -Message "Enter a sAMAccountName containing letters, numbers, dot, dash, or underscore." -Color Yellow
            continue
        }

        $escaped = Escape-DirectoryFilterValue -Value $candidateSam
        if (-not (Test-AdUserValueAvailable -Filter "SamAccountName -eq '$escaped'" -ValueName "sAMAccountName" -Value $candidateSam)) {
            continue
        }

        $script:SamAccountName = $candidateSam
        $upnInput = (Read-UiInput -Prompt "Enter different UPN alias or full UserPrincipalName" -Options @("blank=use same logon name", "user@domain.com", "x=abort")).Trim()
        if ($upnInput -eq "x") {
            throw "New-user workflow aborted while choosing a different UPN."
        }
        if ([string]::IsNullOrWhiteSpace($upnInput)) {
            $script:UserPrincipalName = $candidateSam
        }
        else {
            $script:UserPrincipalName = $upnInput
        }

        return
    }
}

function Test-AdGroupMemberAlreadyExistsError {
    param(
        [AllowNull()]
        [string]$ErrorMessage
    )

    return ([string]$ErrorMessage -match "(?i)already\s+(a\s+)?member")
}

function ConvertTo-SafeSamAccountName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $cleaned = ($Value -replace "[^A-Za-z0-9._-]", "").Trim(".-_")
    if ($cleaned.Length -gt 20) {
        $cleaned = $cleaned.Substring(0, 20)
    }
    return $cleaned
}

function Get-ParentDistinguishedName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    $parts = @(Split-AdDistinguishedName -DistinguishedName $DistinguishedName)
    if ($parts.Count -lt 2) {
        return ""
    }

    return @($parts[1..($parts.Count - 1)]) -join ","
}

function Test-AdUserValueAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filter,

        [Parameter(Mandatory = $true)]
        [string]$ValueName,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $match = @(Get-ADUser -Filter $Filter -ErrorAction Stop)
    if ($match.Count -eq 0) {
        return $true
    }

    Write-UiStatus -Status "WARN" -Message "$ValueName '$Value' is already in use." -Color Yellow
    return $false
}

function Resolve-NewSamAccountName {
    param(
        [string]$DefaultSamAccountName = ""
    )

    $candidate = $SamAccountName.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = ConvertTo-SafeSamAccountName -Value $DefaultSamAccountName
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = ConvertTo-SafeSamAccountName -Value ("{0}{1}" -f $FirstName.Substring(0, 1), $LastName)
    }

    while ($true) {
        $candidateText = ([string]$candidate).Trim()
        if ($candidateText.Length -gt 20) {
            Write-UiStatus -Status "WARN" -Message "sAMAccountName '$candidateText' is $($candidateText.Length) characters. The pre-Windows 2000 logon name limit is 20 characters." -Color Yellow
            $candidate = Read-UiInput -Prompt "Enter different pre-Windows 2000 User Logon Name" -Options @("sAMAccountName", "max 20 chars")
            continue
        }

        $candidate = ConvertTo-SafeSamAccountName -Value $candidateText
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = Read-UiInput -Prompt "Enter pre-Windows 2000 User Logon Name" -Options @("sAMAccountName", "required")
            continue
        }

        $escaped = Escape-DirectoryFilterValue -Value $candidate
        if (Test-AdUserValueAvailable -Filter "SamAccountName -eq '$escaped'" -ValueName "sAMAccountName" -Value $candidate) {
            return $candidate
        }

        $action = Read-NewUserExistingUserConflictAction -ConflictName "sAMAccountName" -Value $candidate
        if ($action -eq "Resume") {
            Request-NewUserResumeFromMatches -Matches (Get-NewUserSamConflictMatches -SamAccountName $candidate) -Purpose "new-user resume target"
            continue
        }
        if ($action -eq "Exit") {
            throw "New-user workflow stopped after sAMAccountName conflict."
        }

        $candidate = Read-UiInput -Prompt "Enter different pre-Windows 2000 User Logon Name" -Options @("sAMAccountName", "max 20 chars")
    }
}

function Resolve-NewUserPrincipalName {
    param(
        [string]$SuggestedUpnAlias,
        [AllowNull()]$CopyAfterUser
    )

    $preferredSuffix = ""
    if ($CopyAfterUser -and $CopyAfterUser.UserPrincipalName -like "*@*") {
        $preferredSuffix = ($CopyAfterUser.UserPrincipalName -split "@", 2)[1]
    }

    $candidate = $UserPrincipalName.Trim()
    $selectedDomain = ""
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            if ([string]::IsNullOrWhiteSpace($selectedDomain)) {
                $selectedDomain = Select-UpnSuffix -PreferredSuffix $preferredSuffix
            }
            $candidate = Resolve-UpnFromInput -InputText $SuggestedUpnAlias -DefaultAlias $SuggestedUpnAlias -SelectedDomain $selectedDomain
            continue
        }

        if ([string]::IsNullOrWhiteSpace($selectedDomain) -and $candidate -notlike "*@*") {
            $selectedDomain = Select-UpnSuffix -PreferredSuffix $preferredSuffix
        }

        $candidate = Resolve-UpnFromInput -InputText $candidate -DefaultAlias $SuggestedUpnAlias -SelectedDomain $selectedDomain
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = Read-UiInput -Prompt "Enter UPN alias or full UserPrincipalName" -Options @("alias", "user@domain.com")
            continue
        }

        if ([string]::IsNullOrWhiteSpace($selectedDomain)) {
            $selectedDomain = ($candidate -split "@", 2)[1]
        }

        $conflictMatches = @(Get-NewUserPrincipalNameConflictMatches -UserPrincipalName $candidate)
        if ($conflictMatches.Count -eq 0) {
            return $candidate
        }

        $candidateAlias = Get-UpnAlias -UserPrincipalName $candidate
        Write-UiStatus -Status "WARN" -Message "UPN logon name '$candidateAlias' is already in use by existing UserPrincipalName value(s)." -Color Yellow
        Write-UiBox -Title "Matching Existing UPNs" -Lines (ConvertTo-UiTableLines -Rows $conflictMatches -Columns @("SamAccountName", "UserPrincipalName", "DisplayName", "Enabled"))
        Write-UiStatus -Status "WARN" -Message "UserPrincipalName '$candidate' is already in use." -Color Yellow

        $action = Read-NewUserExistingUserConflictAction -ConflictName "UserPrincipalName" -Value $candidate
        if ($action -eq "Resume") {
            Request-NewUserResumeFromMatches -Matches $conflictMatches -Purpose "new-user resume target"
            continue
        }
        if ($action -eq "Exit") {
            throw "New-user workflow stopped after UserPrincipalName conflict."
        }

        $candidate = Read-UiInput -Prompt "Enter different UPN alias or full UserPrincipalName" -Options @("alias", "user@domain.com")
    }
}

function Get-UpnAlias {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    return (($UserPrincipalName -split "@", 2)[0]).Trim()
}

function Get-AvailableUpnSuffixes {
    $suffixes = @()

    try {
        $forest = Get-ADForest -ErrorAction Stop
        $suffixes += @($forest.UPNSuffixes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $suffixes += @($forest.Domains | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    catch {
        Write-UiStatus -Status "INFO" -Message "Could not query AD forest UPN suffixes: $($_.Exception.Message)" -Color Yellow
    }

    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $suffixes += @($domain.DNSRoot | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    catch {
        Write-UiStatus -Status "INFO" -Message "Could not query AD domain suffixes: $($_.Exception.Message)" -Color Yellow
    }

    return @($suffixes |
        ForEach-Object { ([string]$_).Trim().TrimStart("@") } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match "^[^@\s]+\.[^@\s]+$" } |
        Sort-Object -Unique)
}

function Select-UpnSuffix {
    param(
        [string]$PreferredSuffix = ""
    )

    $suffixes = @(Get-AvailableUpnSuffixes)
    if ($suffixes.Count -eq 0) {
        return (Read-UiInput -Prompt "Enter UPN domain suffix" -Options @("domain.com")).Trim().TrimStart("@")
    }

    $rows = @()
    for ($i = 0; $i -lt $suffixes.Count; $i++) {
        $rows += [pscustomobject]@{
            Number = $i + 1
            Domain = $suffixes[$i]
        }
    }

    Write-UiBox -Title "Available UPN Domains" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "Domain"))
    if (-not [string]::IsNullOrWhiteSpace($PreferredSuffix) -and $suffixes -contains $PreferredSuffix) {
        if (Test-NewUserForceMode) {
            return $PreferredSuffix
        }
        if (Read-UiYesNo -Prompt "Use UPN domain '$PreferredSuffix'?" -DefaultYes $true) {
            return $PreferredSuffix
        }
    }

    if (Test-NewUserForceMode) {
        if (-not [string]::IsNullOrWhiteSpace($PreferredSuffix)) {
            throw "Force mode could not auto-select copy-after UPN domain '$PreferredSuffix' because it is not listed as an available AD UPN suffix."
        }
        if ($suffixes.Count -eq 1) {
            return $suffixes[0]
        }
        throw "Force mode could not auto-select a UPN domain. Configure UserPrincipalName or use a copy-after user with a valid UPN suffix."
    }

    while ($true) {
        $selection = (Read-UiInput -Prompt "Choose UPN domain number, or type domain" -Options @("number", "domain.com")).Trim()
        if ($selection -match "^\d+$") {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $suffixes.Count) {
                return $suffixes[$index]
            }
        }

        $typedSuffix = $selection.TrimStart("@")
        if ($typedSuffix -match "^[^@\s]+\.[^@\s]+$") {
            if ($suffixes -contains $typedSuffix) {
                return $typedSuffix
            }

            Write-UiStatus -Status "WARN" -Message "UPN domain '$typedSuffix' was not found in AD forest/domain suffixes." -Color Yellow
        }
    }
}

function Resolve-UpnFromInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText,

        [Parameter(Mandatory = $true)]
        [string]$DefaultAlias,

        [string]$SelectedDomain = ""
    )

    $cleaned = $InputText.Trim()
    if ([string]::IsNullOrWhiteSpace($cleaned)) {
        return ""
    }

    if ($cleaned -match "^[^@\s]+@([^@\s]+\.[^@\s]+)$") {
        $lockedDomain = $SelectedDomain.Trim().TrimStart("@")
        if (-not [string]::IsNullOrWhiteSpace($lockedDomain)) {
            $alias = ($cleaned -split "@", 2)[0]
            if ($matches[1] -ne $lockedDomain) {
                Write-UiStatus -Status "WARN" -Message "Keeping selected UPN domain '$lockedDomain'. Use abort if that domain was wrong." -Color Yellow
            }

            return "$alias@$lockedDomain"
        }

        $suffix = $matches[1]
        $availableSuffixes = @(Get-AvailableUpnSuffixes)
        if ($availableSuffixes.Count -eq 0 -or $availableSuffixes -contains $suffix) {
            return $cleaned
        }

        Write-UiStatus -Status "WARN" -Message "UPN domain '$suffix' is not listed as an available AD UPN suffix." -Color Yellow
        $selectedSuffix = Select-UpnSuffix -PreferredSuffix $suffix
        return (($cleaned -split "@", 2)[0] + "@$selectedSuffix")
    }

    if ($cleaned -like "*@*") {
        Write-UiStatus -Status "WARN" -Message "UserPrincipalName '$cleaned' does not look like user@domain.com." -Color Yellow
        return ""
    }

    $alias = ConvertTo-SafeSamAccountName -Value $cleaned
    if ([string]::IsNullOrWhiteSpace($alias)) {
        $alias = $DefaultAlias
    }

    $selectedDomain = $SelectedDomain.Trim().TrimStart("@")
    if ([string]::IsNullOrWhiteSpace($selectedDomain)) {
        $selectedDomain = Select-UpnSuffix
    }
    if ([string]::IsNullOrWhiteSpace($selectedDomain)) {
        return ""
    }

    return "$alias@$selectedDomain"
}

function Get-CopyAfterUserDetails {
    param(
        [Parameter(Mandatory = $true)]
        $User
    )

    $copyAfterUser = Get-ADUser -Identity ([string]$User.ObjectGUID) -Properties (Get-CopyAfterAdUserProperties)
    Show-AdUserState -Identity ([string]$copyAfterUser.ObjectGUID) -Title "Copy-After AD User"
    if ($copyAfterUser.Enabled -eq $false) {
        $message = if (Test-NewUserForceMode) {
            "Copy-after user is disabled. Force mode will still use its OU and memberships."
        }
        else {
            "Copy-after user is disabled. Group copy can still continue, but the target OU must be confirmed manually."
        }
        Write-UiStatus -Status "NOTE" -Message $message -Color Yellow
    }

    return $copyAfterUser
}

function Show-CopyAfterLookupMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Matches,

        [Parameter(Mandatory = $true)]
        [string]$Lookup
    )

    $rows = @()
    $cleanMatches = @($Matches | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanMatches.Count; $i++) {
        $match = $cleanMatches[$i]
        $rows += [pscustomobject]@{
            Number            = $i + 1
            Name              = $match.Name
            SamAccountName    = $match.SamAccountName
            UserPrincipalName = $match.UserPrincipalName
            Mail              = $match.mail
            Enabled           = $match.Enabled
            DistinguishedName = $match.DistinguishedName
        }
    }

    Write-UiStatus -Status "TOO MANY" -Message "Force mode requires one exact copy-after match for '$Lookup'." -Color Yellow
    Write-UiBox -Title "Copy-After Lookup Matches" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "Name", "SamAccountName", "UserPrincipalName", "Mail", "Enabled", "DistinguishedName"))
}

function Resolve-ForceCopyAfterUser {
    $candidateLookup = $CopyAfterLookup
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($candidateLookup)) {
            Write-UiStatus -Status "WARN" -Message "Force mode requires a copy-after user." -Color Yellow
            $candidateLookup = Read-UiInput -Prompt "Enter copy-after user lookup" -Options @("sAMAccountName/UPN/mail/name", "x=abort")
            if ($candidateLookup -eq "x") {
                throw "Force mode requires a copy-after user."
            }
            continue
        }

        $trimmedLookup = $candidateLookup.Trim()
        $adFilter = New-AdUserLookupFilter -Lookup $trimmedLookup
        $matches = @(Get-ADUser -Filter $adFilter -Properties (Get-CopyAfterAdUserProperties) -ErrorAction Stop)
        if ($matches.Count -eq 1) {
            return Get-CopyAfterUserDetails -User $matches[0]
        }

        if ($matches.Count -eq 0) {
            Write-UiStatus -Status "WARN" -Message "No AD user found for Force copy-after lookup '$trimmedLookup'." -Color Yellow
        }
        else {
            Show-CopyAfterLookupMatches -Matches $matches -Lookup $trimmedLookup
        }

        $candidateLookup = Read-UiInput -Prompt "Enter a different copy-after lookup" -Options @("sAMAccountName/UPN/mail/name", "x=abort")
        if ($candidateLookup -eq "x") {
            throw "Force mode requires a single resolved copy-after user."
        }
    }
}

function Resolve-CopyAfterUser {
    if (Test-NewUserForceMode) {
        return Resolve-ForceCopyAfterUser
    }

    if ([string]::IsNullOrWhiteSpace($CopyAfterLookup)) {
        Write-UiStatus -Status "INFO" -Message "No copy-after user was provided. The script will create a user from explicit inputs." -Color Yellow
        return $null
    }

    try {
        $copyAfterUser = Resolve-AdUserLookup -Lookup $CopyAfterLookup -Purpose "copy-after user"
        return Get-CopyAfterUserDetails -User $copyAfterUser
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not use copy-after lookup '$CopyAfterLookup': $($_.Exception.Message)" -Color Yellow
        Add-UiStepResult -Name "Resolve copy-after user" -Result "Skipped" -Note $_.Exception.Message
        return $null
    }
}

function Test-TargetOrganizationalUnit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    try {
        [void](Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction Stop)
        return $true
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not find OU '$DistinguishedName': $($_.Exception.Message)" -Color Yellow
        return $false
    }
}

function Read-TargetOrganizationalUnit {
    while ($true) {
        $answer = Read-UiInput -Prompt "Enter target OU DN or OU search text" -Options @("exact DN or search")
        if ([string]::IsNullOrWhiteSpace($answer)) {
            continue
        }

        if ($answer -match "(?i)OU=.*DC=") {
            if (Test-TargetOrganizationalUnit -DistinguishedName $answer) {
                return $answer
            }
            continue
        }

        $escaped = Escape-DirectoryFilterValue -Value $answer
        $ouMatches = @(Get-ADOrganizationalUnit -Filter "Name -like '*$escaped*'" -Properties CanonicalName | Sort-Object CanonicalName)
        if ($ouMatches.Count -eq 0) {
            Write-UiStatus -Status "WARN" -Message "No OUs matched '$answer'. Enter the exact OU DN or try a different search term." -Color Yellow
            continue
        }

        $rows = @()
        for ($i = 0; $i -lt $ouMatches.Count; $i++) {
            $rows += [pscustomobject]@{
                Number        = $i + 1
                Name          = $ouMatches[$i].Name
                CanonicalName = $ouMatches[$i].CanonicalName
                DN            = $ouMatches[$i].DistinguishedName
            }
        }

        Write-UiBox -Title "OU Search Results" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "Name", "CanonicalName", "DN"))
        if ($ouMatches.Count -eq 1 -and (Read-UiYesNo -Prompt "Use this OU?" -DefaultYes $true)) {
            return $ouMatches[0].DistinguishedName
        }

        $selection = (Read-UiInput -Prompt "Choose OU number, or type exact OU DN" -Options @("number", "exact DN")).Trim()
        if ($selection -match "^\d+$") {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $ouMatches.Count) {
                $selectedOu = [string]$ouMatches[$index].DistinguishedName
                if (-not [string]::IsNullOrWhiteSpace($selectedOu) -and (Test-TargetOrganizationalUnit -DistinguishedName $selectedOu)) {
                    Write-UiStatus -Status "OK" -Message "Selected target OU '$selectedOu'." -Color Green
                    return $selectedOu
                }

                Write-UiStatus -Status "WARN" -Message "Selected OU number did not resolve to a valid distinguished name. Try again." -Color Yellow
            }
        }
        elseif ($selection -match "(?i)OU=.*DC=" -and (Test-TargetOrganizationalUnit -DistinguishedName $selection)) {
            return $selection
        }
    }
}

function Resolve-NewUserTargetOU {
    param(
        [AllowNull()]$CopyAfterUser
    )

    if (Test-NewUserForceMode) {
        if (-not $CopyAfterUser) {
            throw "Force mode requires a copy-after user to resolve the target OU."
        }

        $copyAfterOu = Get-ParentDistinguishedName -DistinguishedName $CopyAfterUser.DistinguishedName
        if ([string]::IsNullOrWhiteSpace($copyAfterOu)) {
            throw "Force mode could not resolve the copy-after user's parent OU."
        }
        if (-not (Test-TargetOrganizationalUnit -DistinguishedName $copyAfterOu)) {
            throw "Force mode copy-after OU '$copyAfterOu' could not be validated."
        }

        Write-UiStatus -Status "FORCE" -Message "Using copy-after user's OU '$copyAfterOu'." -Color Yellow
        return $copyAfterOu
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetOU)) {
        if ((Test-TargetOrganizationalUnit -DistinguishedName $TargetOU) -and (Read-UiYesNo -Prompt "Use configured target OU '$TargetOU'?" -DefaultYes $true)) {
            return $TargetOU
        }
    }

    if ($CopyAfterUser -and $CopyAfterUser.Enabled -eq $true) {
        $copyAfterOu = Get-ParentDistinguishedName -DistinguishedName $CopyAfterUser.DistinguishedName
        if (-not [string]::IsNullOrWhiteSpace($copyAfterOu) -and (Read-UiYesNo -Prompt "Use copy-after user's OU '$copyAfterOu'?" -DefaultYes $true)) {
            return $copyAfterOu
        }
    }

    $resolvedOu = Read-TargetOrganizationalUnit
    if ([string]::IsNullOrWhiteSpace($resolvedOu)) {
        throw "Target OU was not resolved. Enter a valid OU distinguished name before creating the user."
    }

    return $resolvedOu
}

function Escape-LdapFilterValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace("\", "\5c").Replace("*", "\2a").Replace("(", "\28").Replace(")", "\29").Replace([string][char]0, "\00")
}

function Test-AdObjectNameAvailableInOu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$TargetOu
    )

    $escapedName = Escape-LdapFilterValue -Value $Name
    $existingObjects = @(Get-ADObject -LDAPFilter "(cn=$escapedName)" -SearchBase $TargetOu -SearchScope OneLevel -Properties Name,objectClass,DistinguishedName -ErrorAction Stop)
    if ($existingObjects.Count -eq 0) {
        return $true
    }

    Write-UiStatus -Status "WARN" -Message "AD object name/CN '$Name' is already in use in target OU '$TargetOu'." -Color Yellow
    Write-UiBox -Title "Matching AD Object Name" -Lines (ConvertTo-UiTableLines -Rows $existingObjects -Columns @("Name", "objectClass", "DistinguishedName"))
    return $false
}

function Read-NewUserObjectName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DefaultName
    )

    while ($true) {
        $answer = (Read-UiInput -Prompt "Enter different AD Object Name/CN" -Options @("name", "x=abort")).Trim()
        if ($answer -eq "x") {
            throw "New-user workflow aborted while choosing a different AD Object Name/CN."
        }
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = $DefaultName
        }
        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-UiStatus -Status "WARN" -Message "AD Object Name/CN cannot be blank." -Color Yellow
            continue
        }

        return $answer
    }
}

function Resolve-NewUserObjectName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DefaultName,

        [Parameter(Mandatory = $true)]
        [string]$TargetOU
    )

    $candidate = ([string]$AdObjectName).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $DefaultName
    }

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = Read-NewUserObjectName -DefaultName $DefaultName
            continue
        }

        if (Test-AdObjectNameAvailableInOu -Name $candidate -TargetOu $TargetOU) {
            $script:AdObjectName = $candidate
            return $candidate
        }

        $action = Read-NewUserExistingUserConflictAction -ConflictName "AD Object Name/CN" -Value $candidate
        if ($action -eq "Resume") {
            Request-NewUserResumeFromMatches -Matches (Get-NewUserObjectNameConflictMatches -Name $candidate -TargetOu $TargetOU) -Purpose "new-user resume target"
            continue
        }
        if ($action -eq "Exit") {
            throw "New-user workflow stopped after AD Object Name/CN conflict."
        }

        Write-UiStatus -Status "WARN" -Message "Choose a different AD Object Name/CN. DisplayName can remain '$DefaultName'." -Color Yellow
        $candidate = Read-NewUserObjectName -DefaultName $DefaultName
    }
}

function New-NewUserPlan {
    param(
        [AllowNull()]$CopyAfterUser
    )

    $suggestedUpnAlias = ConvertTo-SafeSamAccountName -Value ("{0}{1}" -f $FirstName.Substring(0, 1), $LastName)
    $resolvedUpn = Resolve-NewUserPrincipalName -SuggestedUpnAlias $suggestedUpnAlias -CopyAfterUser $CopyAfterUser
    $resolvedSam = Resolve-NewSamAccountName -DefaultSamAccountName (Get-UpnAlias -UserPrincipalName $resolvedUpn)
    $displayName = ("{0} {1}" -f $FirstName.Trim(), $LastName.Trim()).Trim()
    $resolvedOu = Resolve-NewUserTargetOU -CopyAfterUser $CopyAfterUser
    $resolvedName = Resolve-NewUserObjectName -DefaultName $displayName -TargetOU $resolvedOu

    return [pscustomobject]@{
        Client            = $Client.Trim()
        FirstName         = $FirstName.Trim()
        LastName          = $LastName.Trim()
        DisplayName       = $displayName
        Name              = $resolvedName
        SamAccountName    = $resolvedSam
        UserPrincipalName = $resolvedUpn
        TargetOU          = $resolvedOu
        Title             = $Title.Trim()
        Department        = $Department.Trim()
        Description       = $Description.Trim()
        ManagerLookup     = $ManagerLookup.Trim()
        ManagerDN         = ""
        ManagerLabel      = ""
        MustChangePasswordAtNextLogon = [bool]$MustChangePasswordAtNextLogon
    }
}

function Complete-NewUserPlan {
    param(
        [Parameter(Mandatory = $true)]
        $Plan,

        [AllowNull()]$CopyAfterUser
    )

    if ([string]::IsNullOrWhiteSpace($Plan.UserPrincipalName) -or $Plan.UserPrincipalName -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") {
        Write-UiStatus -Status "WARN" -Message "The new user still needs a valid UPN before creation." -Color Yellow
        $script:UserPrincipalName = ""
        $suggestedUpnAlias = ConvertTo-SafeSamAccountName -Value ("{0}{1}" -f $FirstName.Substring(0, 1), $LastName)
        if (-not [string]::IsNullOrWhiteSpace($Plan.SamAccountName)) {
            $suggestedUpnAlias = $Plan.SamAccountName
        }
        $Plan.UserPrincipalName = Resolve-NewUserPrincipalName -SuggestedUpnAlias $suggestedUpnAlias -CopyAfterUser $CopyAfterUser
    }

    if ([string]::IsNullOrWhiteSpace($Plan.SamAccountName)) {
        $Plan.SamAccountName = Resolve-NewSamAccountName -DefaultSamAccountName (Get-UpnAlias -UserPrincipalName $Plan.UserPrincipalName)
    }

    while ([string]::IsNullOrWhiteSpace($Plan.TargetOU)) {
        Write-UiStatus -Status "WARN" -Message "The new user still needs a target OU before creation." -Color Yellow
        $Plan.TargetOU = Resolve-NewUserTargetOU -CopyAfterUser $CopyAfterUser
    }

    if (-not (Test-TargetOrganizationalUnit -DistinguishedName $Plan.TargetOU)) {
        Write-UiStatus -Status "WARN" -Message "The planned target OU could not be validated." -Color Yellow
        $script:TargetOU = ""
        $Plan.TargetOU = Resolve-NewUserTargetOU -CopyAfterUser $CopyAfterUser
    }

    if ([string]::IsNullOrWhiteSpace($Plan.TargetOU)) {
        throw "Target OU is required before creating a new AD user."
    }

    if ([string]::IsNullOrWhiteSpace($Plan.Name)) {
        $Plan.Name = $Plan.DisplayName
    }

    $Plan.Name = Resolve-NewUserObjectName -DefaultName $Plan.DisplayName -TargetOU $Plan.TargetOU

    Resolve-NewUserManagerForPlan -Plan $Plan

    return $Plan
}

function Show-NewUserPlan {
    param(
        [Parameter(Mandatory = $true)]
        $Plan,

        [AllowNull()]$CopyAfterUser
    )

    $copyAfterLabel = "None"
    if ($CopyAfterUser) {
        $copyAfterLabel = "{0} ({1})" -f $CopyAfterUser.DisplayName, $CopyAfterUser.SamAccountName
    }

    Write-UiBox -Title "New User Plan" -Lines @(
        New-UiBoxLine -Label "Client" -Value $Plan.Client
        New-UiBoxLine -Label "DisplayName" -Value $Plan.DisplayName
        New-UiBoxLine -Label "AD Object Name" -Value $Plan.Name
        New-UiBoxLine -Label "SamAccountName" -Value $Plan.SamAccountName
        New-UiBoxLine -Label "UserPrincipalName" -Value $Plan.UserPrincipalName
        New-UiBoxLine -Label "TargetOU" -Value $Plan.TargetOU
        New-UiBoxLine -Label "CopyAfter" -Value $copyAfterLabel
        New-UiBoxLine -Label "Title" -Value $Plan.Title
        New-UiBoxLine -Label "Department" -Value $Plan.Department
        New-UiBoxLine -Label "Description" -Value $Plan.Description
        New-UiBoxLine -Label "Manager" -Value $Plan.ManagerLabel
        New-UiBoxLine -Label "Must change password" -Value $Plan.MustChangePasswordAtNextLogon
    )
}

function Resolve-NewUserAdCreation {
    param(
        [AllowNull()]
        $CopyAfterUser
    )

    if (Test-NewUserResumeMode) {
        $resumeUser = Resolve-NewUserResumeAdUser -Lookup $ResumeUserLookup -Plan $null
        $plan = New-NewUserPlanFromExistingAdUser -ExistingUser $resumeUser
        Show-NewUserPlan -Plan $plan -CopyAfterUser $CopyAfterUser
        Add-UiStepResult -Name "Resume AD user" -Result "Completed" -Note "Resuming workflow for existing AD user '$($resumeUser.SamAccountName)'."
        return [pscustomobject]@{
            Stopped = $false
            Plan    = $plan
            User    = $resumeUser
        }
    }

    while ($true) {
        $script:NewUserPendingResumeAdUser = $null
        try {
            $plan = New-NewUserPlan -CopyAfterUser $CopyAfterUser
            $plan = Complete-NewUserPlan -Plan $plan -CopyAfterUser $CopyAfterUser
        }
        catch {
            if ($_.Exception.Message -eq (Get-NewUserResumeSignal) -and $script:NewUserPendingResumeAdUser) {
                $resumeUser = $script:NewUserPendingResumeAdUser
                $plan = New-NewUserPlanFromExistingAdUser -ExistingUser $resumeUser
                Show-NewUserPlan -Plan $plan -CopyAfterUser $CopyAfterUser
                Add-UiStepResult -Name "Resume AD user" -Result "Completed" -Note "Resuming workflow for existing AD user '$($resumeUser.SamAccountName)' after planning conflict."
                return [pscustomobject]@{
                    Stopped = $false
                    Plan    = $plan
                    User    = $resumeUser
                }
            }

            throw
        }

        Show-NewUserPlan -Plan $plan -CopyAfterUser $CopyAfterUser

        if (-not (Test-NewUserForceMode) -and -not (Read-UiYesNo -Prompt "Create this AD user?" -DefaultYes $false)) {
            Add-UiStepResult -Name "Create AD user" -Result "Stopped" -Note "Operator chose not to create the user."
            return [pscustomobject]@{
                Stopped = $true
                Plan    = $plan
                User    = $null
            }
        }

        $result = Invoke-NewUserCreationPasswordLoop -Plan $plan
        if ($result.User) {
            return [pscustomobject]@{
                Stopped = $false
                Plan    = $plan
                User    = $result.User
            }
        }

        if (-not $result.RetryIdentity) {
            throw "AD user creation ended without creating a user or requesting a new identity."
        }
    }
}

function New-NewUserPlanFromExistingAdUser {
    param(
        [Parameter(Mandatory = $true)]
        $ExistingUser
    )

    $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$ExistingUser.DisplayName)) { [string]$ExistingUser.DisplayName } else { ("{0} {1}" -f $FirstName.Trim(), $LastName.Trim()).Trim() }
    $targetOu = Get-ParentDistinguishedName -DistinguishedName $ExistingUser.DistinguishedName
    $plan = [pscustomobject]@{
        Client            = $Client.Trim()
        FirstName         = if (-not [string]::IsNullOrWhiteSpace([string]$ExistingUser.GivenName)) { [string]$ExistingUser.GivenName } else { $FirstName.Trim() }
        LastName          = if (-not [string]::IsNullOrWhiteSpace([string]$ExistingUser.Surname)) { [string]$ExistingUser.Surname } else { $LastName.Trim() }
        DisplayName       = $displayName
        Name              = $ExistingUser.Name
        SamAccountName    = $ExistingUser.SamAccountName
        UserPrincipalName = $ExistingUser.UserPrincipalName
        TargetOU          = $targetOu
        Title             = if ($ExistingUser.PSObject.Properties.Match("Title").Count -gt 0) { [string]$ExistingUser.Title } else { $Title.Trim() }
        Department        = if ($ExistingUser.PSObject.Properties.Match("Department").Count -gt 0) { [string]$ExistingUser.Department } else { $Department.Trim() }
        Description       = if ($ExistingUser.PSObject.Properties.Match("Description").Count -gt 0) { [string]$ExistingUser.Description } else { $Description.Trim() }
        ManagerLookup     = $ManagerLookup.Trim()
        ManagerDN         = if ($ExistingUser.PSObject.Properties.Match("Manager").Count -gt 0) { [string]$ExistingUser.Manager } else { "" }
        ManagerLabel      = if ($ExistingUser.PSObject.Properties.Match("Manager").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$ExistingUser.Manager)) { [string]$ExistingUser.Manager } else { "" }
        MustChangePasswordAtNextLogon = [bool]$MustChangePasswordAtNextLogon
    }

    return $plan
}

function Update-NewUserPlanFromExistingAdUser {
    param(
        [Parameter(Mandatory = $true)]
        $Plan,

        [Parameter(Mandatory = $true)]
        $ExistingUser
    )

    $resumePlan = New-NewUserPlanFromExistingAdUser -ExistingUser $ExistingUser
    foreach ($property in @("FirstName", "LastName", "DisplayName", "Name", "SamAccountName", "UserPrincipalName", "TargetOU", "Title", "Department", "Description", "ManagerDN", "ManagerLabel")) {
        $Plan.$property = $resumePlan.$property
    }
}

function Get-NewUserResumeLookupFromPlan {
    param(
        [AllowNull()]
        $Plan
    )

    if (-not [string]::IsNullOrWhiteSpace($ResumeUserLookup)) {
        return $ResumeUserLookup.Trim()
    }
    if ($Plan) {
        foreach ($value in @($Plan.UserPrincipalName, $Plan.SamAccountName, $Plan.Name)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [string]$value
            }
        }
    }

    return ""
}

function Resolve-NewUserResumeAdUser {
    param(
        [AllowNull()]
        [string]$Lookup,

        [AllowNull()]
        $Plan
    )

    $candidateLookup = $Lookup
    if ([string]::IsNullOrWhiteSpace($candidateLookup)) {
        $candidateLookup = Get-NewUserResumeLookupFromPlan -Plan $Plan
    }

    $resolvedUser = Resolve-AdUserLookup -Lookup $candidateLookup -Purpose "existing new-user resume target"
    $existingUser = Get-ADUser -Identity ([string]$resolvedUser.ObjectGUID) -Properties (Get-ResumeAdUserProperties)

    Write-UiBox -Title "Resume Existing AD User" -Lines @(
        New-UiBoxLine -Label "Name" -Value $existingUser.Name
        New-UiBoxLine -Label "DisplayName" -Value $existingUser.DisplayName
        New-UiBoxLine -Label "SamAccountName" -Value $existingUser.SamAccountName
        New-UiBoxLine -Label "UserPrincipalName" -Value $existingUser.UserPrincipalName
        New-UiBoxLine -Label "Enabled" -Value $existingUser.Enabled
        New-UiBoxLine -Label "DistinguishedName" -Value $existingUser.DistinguishedName
    )

    $expectedDisplayName = ("{0} {1}" -f $FirstName.Trim(), $LastName.Trim()).Trim()
    if (-not [string]::IsNullOrWhiteSpace($expectedDisplayName) -and -not [string]::Equals([string]$existingUser.DisplayName, $expectedDisplayName, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-UiStatus -Status "WARN" -Message "Resume target display name '$($existingUser.DisplayName)' does not match generated name '$expectedDisplayName'." -Color Yellow
    }

    if (-not (Test-NewUserForceMode) -and -not (Read-UiYesNo -Prompt "Resume workflow using existing AD user '$($existingUser.SamAccountName)'?" -DefaultYes $false)) {
        throw "Resume was cancelled for existing AD user '$($existingUser.SamAccountName)'."
    }

    return $existingUser
}

function Read-NewUserCreationCollisionAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    Write-UiStatus -Status "WARN" -Message "AD user creation failed because a matching AD account or object already exists: $ErrorMessage" -Color Yellow
    Write-UiStatus -Status "INFO" -Message "Existing users are not modified unless you explicitly resume the matching new-user run." -Color Yellow

    while ($true) {
        $choice = Read-UiInput -Prompt "AD user already exists. Next action?" -Options @("r=resume this user", "n=enter new identity", "x=exit")
        switch ($choice) {
            "r" { return "Resume" }
            "n" { return "NewIdentity" }
            "x" { return "Exit" }
            default {
                Write-UiStatus -Status "INFO" -Message "Enter exact lowercase r, n, or x." -Color Yellow
            }
        }
    }
}

function Write-NewUserPasswordRejectedRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage,

        [Parameter(Mandatory = $true)]
        [string]$Instruction,

        [Parameter(Mandatory = $true)]
        [string]$Note
    )

    Write-UiStatus -Status "WARN" -Message "The password was rejected by Active Directory policy: $ErrorMessage" -Color Yellow
    Write-UiStatus -Status "INFO" -Message $Instruction -Color Yellow
    Add-UiStepResult -Name "Create AD user" -Result "Retry" -Note $Note
}

function Invoke-NewUserCreationPasswordLoop {
    param(
        [Parameter(Mandatory = $true)]
        $Plan
    )

    $newUser = $null
    $retryIdentity = $false
    $passwordRejectedDuringThisPlan = $false
    $partialCreatedUser = $null

    while (-not $newUser -and -not $retryIdentity) {
        $securePassword = Read-NewUserInitialPassword -SamAccountName $Plan.SamAccountName
        try {
            try {
                if ($partialCreatedUser) {
                    $newUser = Complete-PartiallyCreatedAdUser -Plan $Plan -ExistingUser $partialCreatedUser -SecurePassword $securePassword
                }
                else {
                    $newUser = New-AdUserFromPlan -Plan $Plan -SecurePassword $securePassword
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                if (Test-NewUserCreationAlreadyExistsError -ErrorMessage $errorMessage) {
                    if ($passwordRejectedDuringThisPlan) {
                        $partialCreatedUser = Resolve-PartiallyCreatedAdUserFromPlan -Plan $Plan
                        if ($partialCreatedUser) {
                            Write-UiStatus -Status "INFO" -Message "Found the AD object that was created before the password policy failure. Retrying password setup against that object." -Color Yellow
                            try {
                                $newUser = Complete-PartiallyCreatedAdUser -Plan $Plan -ExistingUser $partialCreatedUser -SecurePassword $securePassword
                            }
                            catch {
                                if (Test-NewUserPasswordRejectedError -ErrorMessage $_.Exception.Message) {
                                    Write-NewUserPasswordRejectedRetry `
                                        -ErrorMessage $_.Exception.Message `
                                        -Instruction "Enter a different initial password to finish the partially-created user." `
                                        -Note "Initial password was rejected while finishing the partially-created AD user."
                                    $newUser = $null
                                    continue
                                }

                                throw
                            }
                            continue
                        }
                    }

                    $collisionAction = Read-NewUserCreationCollisionAction -ErrorMessage $errorMessage
                    if ($collisionAction -eq "Resume") {
                        $newUser = Resolve-NewUserResumeAdUser -Lookup (Get-NewUserResumeLookupFromPlan -Plan $Plan) -Plan $Plan
                        Update-NewUserPlanFromExistingAdUser -Plan $Plan -ExistingUser $newUser
                        Add-UiStepResult -Name "Resume AD user" -Result "Completed" -Note "Resuming workflow for existing AD user '$($newUser.SamAccountName)' after creation collision."
                        continue
                    }
                    if ($collisionAction -eq "NewIdentity") {
                        Add-UiStepResult -Name "Create AD user" -Result "Retry" -Note "Creation collided with an existing AD account or object."
                        Read-NewUserIdentityAfterCreationCollision -Plan $Plan
                        $retryIdentity = $true
                        continue
                    }

                    Add-UiStepResult -Name "Create AD user" -Result "Stopped" -Note "Operator exited after AD user creation collision."
                    throw "New-user workflow stopped after AD user creation collision."
                }

                if (Test-NewUserPasswordRejectedError -ErrorMessage $errorMessage) {
                    Write-NewUserPasswordRejectedRetry `
                        -ErrorMessage $errorMessage `
                        -Instruction "Enter a different initial password to retry this same new-user plan." `
                        -Note "Initial password was rejected by Active Directory policy."
                    $passwordRejectedDuringThisPlan = $true
                    $partialCreatedUser = Resolve-PartiallyCreatedAdUserFromPlan -Plan $Plan
                    continue
                }

                throw
            }
        }
        finally {
            Clear-SecureStringReference -SecureString ([ref]$securePassword)
        }
    }

    return [pscustomobject]@{
        User          = $newUser
        RetryIdentity = $retryIdentity
    }
}

function Resolve-NewUserManagerForPlan {
    param(
        [Parameter(Mandatory = $true)]
        $Plan
    )

    if ([string]::IsNullOrWhiteSpace($Plan.ManagerLookup)) {
        return
    }

    while ($true) {
        try {
            $manager = Resolve-AdUserLookup -Lookup $Plan.ManagerLookup -Purpose "new user's manager"
            $Plan.ManagerDN = $manager.DistinguishedName
            $Plan.ManagerLabel = "{0} ({1})" -f $manager.DisplayName, $manager.SamAccountName
            Write-UiBox -Title "Matched Manager" -Lines @(
                New-UiBoxLine -Label "DisplayName" -Value $manager.DisplayName
                New-UiBoxLine -Label "SamAccountName" -Value $manager.SamAccountName
                New-UiBoxLine -Label "UserPrincipalName" -Value $manager.UserPrincipalName
                New-UiBoxLine -Label "Enabled" -Value $manager.Enabled
                New-UiBoxLine -Label "DistinguishedName" -Value $manager.DistinguishedName
            )
            return
        }
        catch {
            Write-UiStatus -Status "WARN" -Message $_.Exception.Message -Color Yellow
            $newLookup = Read-UiInput -Prompt "Enter manager lookup" -Options @("blank=skip manager")
            if ([string]::IsNullOrWhiteSpace($newLookup)) {
                $Plan.ManagerLookup = ""
                $Plan.ManagerDN = ""
                $Plan.ManagerLabel = ""
                Write-UiStatus -Status "SKIP" -Message "Skipped manager assignment." -Color Yellow
                return
            }

            $Plan.ManagerLookup = $newLookup.Trim()
        }
    }
}

function Read-NewUserInitialPassword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamAccountName
    )

    while ($true) {
        Write-Host -NoNewline ("  Paste/type initial password for '{0}' >: " -f $SamAccountName) -ForegroundColor Magenta
        $securePassword = $Host.UI.ReadLineAsSecureString()
        if ($securePassword -and $securePassword.Length -gt 0) {
            return $securePassword
        }

        Write-UiStatus -Status "WARN" -Message "Blank passwords are not accepted for new AD user creation." -Color Yellow
    }
}

function Resolve-PartiallyCreatedAdUserFromPlan {
    param(
        [Parameter(Mandatory = $true)]
        $Plan
    )

    if ([string]::IsNullOrWhiteSpace($Plan.SamAccountName) -or [string]::IsNullOrWhiteSpace($Plan.TargetOU)) {
        return $null
    }

    try {
        $escapedSam = Escape-DirectoryFilterValue -Value $Plan.SamAccountName
        $matches = @(Get-ADUser -Filter "SamAccountName -eq '$escapedSam'" -Properties (Get-PartialCreatedAdUserProperties) -ErrorAction Stop)
        $matches = @($matches | Where-Object {
                $_ -and
                $_.SamAccountName -eq $Plan.SamAccountName -and
                ([string]::IsNullOrWhiteSpace([string]$_.UserPrincipalName) -or $_.UserPrincipalName -eq $Plan.UserPrincipalName) -and
                $_.Name -eq $Plan.Name -and
                (Get-ParentDistinguishedName -DistinguishedName $_.DistinguishedName) -eq $Plan.TargetOU
            })

        if ($matches.Count -eq 1) {
            return $matches[0]
        }

        if ($matches.Count -gt 1) {
            Write-UiStatus -Status "WARN" -Message "Found multiple matching AD objects for the failed password attempt. The script will not guess which one to finish." -Color Yellow
        }
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not check whether AD partially created the user after password rejection: $($_.Exception.Message)" -Color Yellow
    }

    return $null
}

function Complete-PartiallyCreatedAdUser {
    param(
        [Parameter(Mandatory = $true)]
        $Plan,

        [Parameter(Mandatory = $true)]
        $ExistingUser,

        [Parameter(Mandatory = $true)]
        [securestring]$SecurePassword
    )

    $script:UiStepNumber = $script:UiStepNumber + 1
    $existingUserObjectGuid = [string]$ExistingUser.ObjectGUID
    if ([string]::IsNullOrWhiteSpace($existingUserObjectGuid)) {
        throw "The partially created AD user did not have an ObjectGUID."
    }

    $commandPreviewLines = @(
        "Set-ADAccountPassword -Identity '$existingUserObjectGuid' -NewPassword <secure string> -Reset"
        "Set-ADUser -Identity '$existingUserObjectGuid' -GivenName '$($Plan.FirstName)' -Surname '$($Plan.LastName)' -DisplayName '$($Plan.DisplayName)' -UserPrincipalName '$($Plan.UserPrincipalName)'"
        "Set-ADUser -Identity '$existingUserObjectGuid' -ChangePasswordAtLogon `$$([bool]$Plan.MustChangePasswordAtNextLogon)"
    )
    if (-not [string]::IsNullOrWhiteSpace($Plan.ManagerDN)) {
        $commandPreviewLines += "Set-ADUser -Identity '$existingUserObjectGuid' -Manager '$($Plan.ManagerDN)'"
    }
    $commandPreviewLines += "Enable-ADAccount -Identity '$existingUserObjectGuid'"
    $commandPreview = $commandPreviewLines -join "`n"

    $completedUser = Invoke-UiCommand -Name "Finish partially created AD user" -CommandPreview $commandPreview -PassThru -Command {
        Set-ADAccountPassword -Identity $existingUserObjectGuid -NewPassword $SecurePassword -Reset -ErrorAction Stop
        Set-ADUser -Identity $existingUserObjectGuid -GivenName $Plan.FirstName -Surname $Plan.LastName -DisplayName $Plan.DisplayName -UserPrincipalName $Plan.UserPrincipalName -ErrorAction Stop
        Set-ADUser -Identity $existingUserObjectGuid -ChangePasswordAtLogon ([bool]$Plan.MustChangePasswordAtNextLogon) -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($Plan.Title)) {
            Set-ADUser -Identity $existingUserObjectGuid -Title $Plan.Title -ErrorAction Stop
        }
        if (-not [string]::IsNullOrWhiteSpace($Plan.Department)) {
            Set-ADUser -Identity $existingUserObjectGuid -Department $Plan.Department -ErrorAction Stop
        }
        if (-not [string]::IsNullOrWhiteSpace($Plan.Description)) {
            Set-ADUser -Identity $existingUserObjectGuid -Description $Plan.Description -ErrorAction Stop
        }
        if (-not [string]::IsNullOrWhiteSpace($Plan.ManagerDN)) {
            Set-ADUser -Identity $existingUserObjectGuid -Manager $Plan.ManagerDN -ErrorAction Stop
            Write-UiStatus -Status "OK" -Message "Set manager for '$($Plan.SamAccountName)' to '$($Plan.ManagerLabel)'." -Color Green
        }
        Enable-ADAccount -Identity $existingUserObjectGuid -ErrorAction Stop
        return Get-ADUser -Identity $existingUserObjectGuid -Properties (Get-NewUserAdStateProperties)
    }

    Write-UiStatus -Status "OK" -Message "Step completed: finished and enabled AD user '$($completedUser.SamAccountName)'." -Color Green
    Add-UiStepResult -Name "Create AD user" -Result "Completed" -Note "Finished partially created user '$($completedUser.SamAccountName)' in '$($Plan.TargetOU)'." -CommandPreview $commandPreview
    return $completedUser
}

function Clear-SecureStringReference {
    param(
        [ref]$SecureString
    )

    if ($SecureString.Value) {
        try {
            $SecureString.Value.Dispose()
        }
        catch {
        }
        $SecureString.Value = $null
    }
}

function New-AdUserFromPlan {
    param(
        [Parameter(Mandatory = $true)]
        $Plan,

        [Parameter(Mandatory = $true)]
        [securestring]$SecurePassword
    )

    $script:UiStepNumber = $script:UiStepNumber + 1
    if ([string]::IsNullOrWhiteSpace($Plan.TargetOU)) {
        throw "Target OU is blank. The script cannot create '$($Plan.SamAccountName)' until a valid OU distinguished name is selected."
    }
    if (-not (Test-TargetOrganizationalUnit -DistinguishedName $Plan.TargetOU)) {
        throw "Target OU '$($Plan.TargetOU)' could not be validated."
    }

    $newUserParams = @{
        Name                  = $Plan.Name
        GivenName             = $Plan.FirstName
        Surname               = $Plan.LastName
        DisplayName           = $Plan.DisplayName
        SamAccountName        = $Plan.SamAccountName
        UserPrincipalName     = $Plan.UserPrincipalName
        Path                  = $Plan.TargetOU
        AccountPassword       = $SecurePassword
        Enabled               = $true
        ChangePasswordAtLogon = [bool]$Plan.MustChangePasswordAtNextLogon
    }
    if (-not [string]::IsNullOrWhiteSpace($Plan.Title)) {
        $newUserParams["Title"] = $Plan.Title
    }
    if (-not [string]::IsNullOrWhiteSpace($Plan.Department)) {
        $newUserParams["Department"] = $Plan.Department
    }
    if (-not [string]::IsNullOrWhiteSpace($Plan.Description)) {
        $newUserParams["Description"] = $Plan.Description
    }

    $commandPreviewLines = @(
        "New-ADUser -Name '$($Plan.Name)' -GivenName '$($Plan.FirstName)' -Surname '$($Plan.LastName)' -DisplayName '$($Plan.DisplayName)' -SamAccountName '$($Plan.SamAccountName)' -UserPrincipalName '$($Plan.UserPrincipalName)' -Path '$($Plan.TargetOU)' -Enabled `$true -ChangePasswordAtLogon `$$([bool]$Plan.MustChangePasswordAtNextLogon)"
    )
    if (-not [string]::IsNullOrWhiteSpace($Plan.ManagerDN)) {
        $commandPreviewLines += "Set-ADUser -Identity '<created user GUID>' -Manager '$($Plan.ManagerDN)'"
    }
    $commandPreviewLines += "Enable-ADAccount -Identity '<created user GUID>'"
    $commandPreview = $commandPreviewLines -join "`n"

    $createdUser = Invoke-UiCommand -Name "Create and enable AD user" -CommandPreview $commandPreview -PassThru -Command {
        $created = New-ADUser @newUserParams -PassThru
        $createdUserObjectGuid = [string]$created.ObjectGUID
        $created = Get-ADUser -Identity $createdUserObjectGuid -Properties (Get-NewUserAdStateProperties)
        if (-not [string]::IsNullOrWhiteSpace($Plan.ManagerDN)) {
            Set-ADUser -Identity $createdUserObjectGuid -Manager $Plan.ManagerDN
            Write-UiStatus -Status "OK" -Message "Set manager for '$($created.SamAccountName)' to '$($Plan.ManagerLabel)'." -Color Green
        }
        Enable-ADAccount -Identity $createdUserObjectGuid
        return Get-ADUser -Identity $createdUserObjectGuid -Properties (Get-NewUserAdStateProperties)
    }

    if (Test-UiDryRun) {
        $createdUser = [pscustomobject]@{
            Name                  = $Plan.Name
            GivenName             = $Plan.FirstName
            Surname               = $Plan.LastName
            DisplayName           = $Plan.DisplayName
            SamAccountName        = $Plan.SamAccountName
            UserPrincipalName     = $Plan.UserPrincipalName
            DistinguishedName     = "CN=$($Plan.Name),$($Plan.TargetOU)"
            Enabled               = $true
            mail                  = ""
            MemberOf              = @()
            ObjectGUID            = ""
            SimulatedGroups       = @()
            IsDryRunPlannedObject = $true
        }
        Add-UiStepResult -Name "Create AD user" -Result "Dry run" -Note "Would create '$($Plan.SamAccountName)' in '$($Plan.TargetOU)'." -CommandPreview $commandPreview
    }
    else {
        Write-UiStatus -Status "OK" -Message "Step completed: created and enabled AD user '$($createdUser.SamAccountName)'." -Color Green
        Add-UiStepResult -Name "Create AD user" -Result "Completed" -Note "Created '$($createdUser.SamAccountName)' in '$($Plan.TargetOU)'." -CommandPreview $commandPreview
    }

    return $createdUser
}

function Get-AdPrincipalGroups {
    param(
        [Parameter(Mandatory = $true)]
        $User
    )

    if (Test-UiDryRun -and $User.PSObject.Properties.Match("SimulatedGroups").Count -gt 0) {
        return @($User.SimulatedGroups | Where-Object { $_ } | Sort-Object Name)
    }

    return @(Get-ADPrincipalGroupMembership -Identity ([string]$User.ObjectGUID) | Sort-Object Name)
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

function Select-ItemsByNumber {
    param(
        [AllowNull()]
        [object[]]$Items,

        [AllowNull()]
        [int[]]$Numbers
    )

    $cleanItems = @($Items | Where-Object { $_ })
    $selectedItems = @()
    foreach ($number in @($Numbers)) {
        $index = [int]$number - 1
        if ($index -ge 0 -and $index -lt $cleanItems.Count) {
            $selectedItems += $cleanItems[$index]
        }
    }

    return $selectedItems
}

function New-NumberedRows {
    param(
        [AllowNull()]
        [object[]]$Items,

        [string]$NameProperty = "Name"
    )

    $rows = @()
    $cleanItems = @($Items | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanItems.Count; $i++) {
        $rows += [pscustomobject]@{
            Number = $i + 1
            Name   = $cleanItems[$i].$NameProperty
            Detail = $cleanItems[$i].DistinguishedName
        }
    }

    return $rows
}

function Read-GroupsToExclude {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Groups
    )

    if ($Groups.Count -eq 0) {
        return @()
    }

    Write-UiBox -Title "Copy-After AD Groups" -Lines (ConvertTo-UiTableLines -Rows (New-NumberedRows -Items $Groups) -Columns @("Number", "Name", "Detail"))
    if (Test-NewUserForceMode) {
        Write-UiStatus -Status "FORCE" -Message "Copying all copy-after AD groups." -Color Yellow
        return @()
    }

    $choice = Read-UiInput -Prompt "Copy AD groups?" -Options @("y=copy all", "e=exclude some", "s=skip")
    if ($choice -eq "s") {
        return $Groups
    }
    if ($choice -ne "e") {
        return @()
    }

    $selection = Read-UiInput -Prompt "Enter group numbers to exclude" -Options @("comma separated", "blank=none")
    $numbers = ConvertTo-NumberSelection -InputText $selection -Max $Groups.Count
    return @(Select-ItemsByNumber -Items $Groups -Numbers $numbers)
}

function Add-AdGroupsToNewUser {
    param(
        [Parameter(Mandatory = $true)]
        $NewUser,

        [AllowNull()]
        [object[]]$Groups
    )

    $groupsToAdd = @($Groups | Where-Object { $_ })
    if ($groupsToAdd.Count -eq 0) {
        Write-UiStatus -Status "INFO" -Message "No AD groups selected to add." -Color Yellow
        return
    }

    $newUserObjectGuid = [string]$NewUser.ObjectGUID
    foreach ($group in $groupsToAdd) {
        try {
            Invoke-UiCommand `
                -Name "Add new user to AD group" `
                -CommandPreview "Add-ADGroupMember -Identity '$($group.DistinguishedName)' -Members '$newUserObjectGuid'" `
                -Command {
                Add-ADGroupMember -Identity $group.DistinguishedName -Members $newUserObjectGuid -ErrorAction Stop
            }
            if (Test-UiDryRun) {
                if ($NewUser.PSObject.Properties.Match("SimulatedGroups").Count -gt 0 -and @($NewUser.SimulatedGroups | Where-Object { $_.DistinguishedName -eq $group.DistinguishedName }).Count -eq 0) {
                    $NewUser.SimulatedGroups = @($NewUser.SimulatedGroups + $group)
                }
                Write-UiStatus -Status "DRY RUN" -Message "Would add '$($NewUser.SamAccountName)' to AD group '$($group.Name)'." -Color DarkGray
            }
            else {
                Write-UiStatus -Status "OK" -Message "Added '$($NewUser.SamAccountName)' to AD group '$($group.Name)'." -Color Green
            }
        }
        catch {
            $errorMessage = [string]$_.Exception.Message
            if (Test-AdGroupMemberAlreadyExistsError -ErrorMessage $errorMessage) {
                Write-UiStatus -Status "SKIP" -Message "'$($NewUser.SamAccountName)' is already in AD group '$($group.Name)'. No change needed." -Color Yellow
                continue
            }

            Write-UiStatus -Status "WARN" -Message "Could not add '$($NewUser.SamAccountName)' to AD group '$($group.Name)': $errorMessage" -Color Yellow
            Add-NewUserRunIssue -Source "AD group assignment" -Target $group.Name -Detail "Could not add '$($NewUser.SamAccountName)' to AD group '$($group.Name)': $errorMessage"
        }
    }
}

function Invoke-AdGroupCopyAndReview {
    param(
        [Parameter(Mandatory = $true)]
        $NewUser,

        [AllowNull()]$CopyAfterUser
    )

    if ($CopyAfterUser) {
        $sourceGroups = Get-AdPrincipalGroups -User $CopyAfterUser
        $excludedGroups = @(Read-GroupsToExclude -Groups $sourceGroups)
        $groupsToCopy = @($sourceGroups | Where-Object { $excludedGroups.DistinguishedName -notcontains $_.DistinguishedName })
        if ($groupsToCopy.Count -gt 0) {
            $script:UiStepNumber = $script:UiStepNumber + 1
            Add-AdGroupsToNewUser -NewUser $NewUser -Groups $groupsToCopy
            if (Test-UiDryRun) {
                Add-UiStepResult -Name "Copy AD groups" -Result "Dry run" -Note "Would copy $($groupsToCopy.Count) group(s)."
            }
            else {
                Add-UiStepResult -Name "Copy AD groups" -Result "Completed" -Note "Attempted to copy $($groupsToCopy.Count) group(s)."
            }
        }
    }

    if (Test-NewUserForceMode) {
        return
    }

    Invoke-AdGroupMembershipReview -NewUser $NewUser
}

function Invoke-AdGroupMembershipReview {
    param(
        [Parameter(Mandatory = $true)]
        $NewUser
    )

    $newUserObjectGuid = [string]$NewUser.ObjectGUID
    while ($true) {
        $currentGroups = Get-AdPrincipalGroups -User $NewUser
        Write-UiBox -Title "New User AD Groups" -Lines (ConvertTo-UiTableLines -Rows (New-NumberedRows -Items $currentGroups) -Columns @("Number", "Name", "Detail"))
        $choice = Read-UiInput -Prompt "Adjust AD groups?" -Options @("a=add", "r=remove", "c=continue")
        if ($choice -notin @("a", "r", "c")) {
            Write-UiStatus -Status "INFO" -Message "Enter exact lowercase a, r, or c." -Color Yellow
            continue
        }
        if ($choice -eq "c") {
            return
        }
        if ($choice -eq "r") {
            $selection = Read-UiInput -Prompt "Enter group numbers to remove" -Options @("comma separated")
            $numbers = ConvertTo-NumberSelection -InputText $selection -Max $currentGroups.Count
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No valid AD group numbers selected to remove." -Color Yellow
                continue
            }

            foreach ($number in $numbers) {
                $group = $currentGroups[$number - 1]
                try {
                    Invoke-UiCommand `
                        -Name "Remove new user from AD group" `
                        -CommandPreview "Remove-ADGroupMember -Identity '$($group.DistinguishedName)' -Members '$newUserObjectGuid' -Confirm:`$false" `
                        -Command {
                        Remove-ADGroupMember -Identity $group.DistinguishedName -Members $newUserObjectGuid -Confirm:$false -ErrorAction Stop
                    }
                    if (Test-UiDryRun) {
                        if ($NewUser.PSObject.Properties.Match("SimulatedGroups").Count -gt 0) {
                            $NewUser.SimulatedGroups = @($NewUser.SimulatedGroups | Where-Object { $_.DistinguishedName -ne $group.DistinguishedName })
                        }
                        Write-UiStatus -Status "DRY RUN" -Message "Would remove '$($NewUser.SamAccountName)' from AD group '$($group.Name)'." -Color DarkGray
                    }
                    else {
                        Write-UiStatus -Status "OK" -Message "Removed '$($NewUser.SamAccountName)' from AD group '$($group.Name)'." -Color Green
                    }
                }
                catch {
                    $errorMessage = [string]$_.Exception.Message
                    Write-UiStatus -Status "WARN" -Message "Could not remove AD group '$($group.Name)': $errorMessage" -Color Yellow
                    Add-NewUserRunIssue -Source "AD group assignment" -Target $group.Name -Detail "Could not remove '$($NewUser.SamAccountName)' from AD group '$($group.Name)': $errorMessage"
                }
            }
            continue
        }
        if ($choice -eq "a") {
            $term = Read-UiInput -Prompt "Search AD groups by name" -Options @("text")
            if ([string]::IsNullOrWhiteSpace($term)) {
                continue
            }
            $escaped = Escape-DirectoryFilterValue -Value $term
            $groupMatches = @(Get-ADGroup -Filter "Name -like '*$escaped*' -or SamAccountName -like '*$escaped*'" | Sort-Object Name)
            if ($groupMatches.Count -eq 0) {
                Write-UiStatus -Status "WARN" -Message "No AD groups matched '$term'." -Color Yellow
                continue
            }
            Write-UiBox -Title "AD Group Search Results" -Lines (ConvertTo-UiTableLines -Rows (New-NumberedRows -Items $groupMatches) -Columns @("Number", "Name", "Detail"))
            $selection = Read-UiInput -Prompt "Enter group numbers to add" -Options @("comma separated")
            $numbers = ConvertTo-NumberSelection -InputText $selection -Max $groupMatches.Count
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No valid AD group numbers selected to add." -Color Yellow
                continue
            }

            Add-AdGroupsToNewUser -NewUser $NewUser -Groups @(Select-ItemsByNumber -Items $groupMatches -Numbers $numbers)
        }
    }
}

function ConvertTo-MappedDriveLetterList {
    param(
        [AllowNull()]
        [string]$InputText
    )

    $letters = @()
    foreach ($part in @($InputText -split "[,\s;]+" | Where-Object { $_ })) {
        $candidate = ([string]$part).Trim().TrimEnd(":").ToUpperInvariant()
        if ($candidate -match "^[A-Z]$") {
            if ($letters -notcontains $candidate) {
                $letters += $candidate
            }
            continue
        }

        Write-UiStatus -Status "WARN" -Message "Ignoring invalid mapped drive letter '$part'. Use letters such as P, S, or X." -Color Yellow
    }

    return $letters
}

function Import-GroupPolicyModuleForMappedDriveReview {
    if ((Get-Command Get-GPO -ErrorAction SilentlyContinue) -and (Get-Command Get-GPInheritance -ErrorAction SilentlyContinue)) {
        return $true
    }

    try {
        Write-UiStatus -Status "LOADING..." -Message "Loading GroupPolicy module for mapped drive discovery." -Color Cyan
        Import-Module GroupPolicy -ErrorAction Stop
        Write-UiStatus -Status "OK" -Message "Loaded GroupPolicy module." -Color Green
        return $true
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not load GroupPolicy module: $($_.Exception.Message)" -Color Yellow
        return $false
    }
}

function ConvertTo-GpoGuidKey {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    try {
        return ([guid]([string]$Value).Trim("{}")).ToString("D").ToUpperInvariant()
    }
    catch {
        return ""
    }
}

function Get-GpoLinkGuidKey {
    param(
        [AllowNull()]
        $Link
    )

    if ($null -eq $Link) {
        return ""
    }

    foreach ($propertyName in @("GpoId", "Guid", "Id")) {
        if ($Link.PSObject.Properties.Match($propertyName).Count -gt 0) {
            $key = ConvertTo-GpoGuidKey -Value $Link.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                return $key
            }
        }
    }

    return ""
}

function ConvertTo-GpoNameKey {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    return ([string]$Value).Trim().ToUpperInvariant()
}

function Get-GpoLinkNameKey {
    param(
        [AllowNull()]
        $Link
    )

    if ($null -eq $Link) {
        return ""
    }

    foreach ($propertyName in @("DisplayName", "GpoName", "Name")) {
        if ($Link.PSObject.Properties.Match($propertyName).Count -gt 0) {
            $key = ConvertTo-GpoNameKey -Value $Link.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                return $key
            }
        }
    }

    return ""
}

function Split-AdDistinguishedName {
    param(
        [AllowNull()]
        [string]$DistinguishedName
    )

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return @()
    }

    $parts = @()
    $current = New-Object System.Text.StringBuilder
    $escaped = $false
    foreach ($char in $DistinguishedName.ToCharArray()) {
        if ($escaped) {
            [void]$current.Append($char)
            $escaped = $false
            continue
        }

        if ($char -eq "\") {
            [void]$current.Append($char)
            $escaped = $true
            continue
        }

        if ($char -eq ",") {
            $parts += $current.ToString()
            [void]$current.Clear()
            continue
        }

        [void]$current.Append($char)
    }

    $parts += $current.ToString()
    return @($parts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Get-AdContainerAncestorDns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    $parts = @(Split-AdDistinguishedName -DistinguishedName $DistinguishedName)
    if ($parts.Count -eq 0) {
        return @()
    }

    $containers = @()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $current = @($parts[$i..($parts.Count - 1)]) -join ","
        if ($parts[$i] -match "^(?i)OU=") {
            $containers += $current
            continue
        }

        if ($parts[$i] -match "^(?i)DC=") {
            $containers += $current
            break
        }
    }

    return $containers
}

function Get-RawGpLinkEntries {
    param(
        [AllowNull()]
        [string]$GpLink
    )

    if ([string]::IsNullOrWhiteSpace($GpLink)) {
        return @()
    }

    $entries = @()
    foreach ($match in [regex]::Matches($GpLink, "\[LDAP://(?<dn>[^;\]]+);(?<options>\d+)\]", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $options = 0
        [void][int]::TryParse($match.Groups["options"].Value, [ref]$options)
        if (($options -band 1) -ne 0) {
            continue
        }

        $guidMatch = [regex]::Match($match.Groups["dn"].Value, "\{(?<guid>[0-9a-fA-F-]{36})\}")
        if (-not $guidMatch.Success) {
            continue
        }

        $entries += [pscustomobject]@{
            GpoId   = $guidMatch.Groups["guid"].Value
            Options = $options
        }
    }

    return $entries
}

function Add-GpoLinkKeys {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$GuidLookup,

        [Parameter(Mandatory = $true)]
        [hashtable]$NameLookup,

        [AllowNull()]
        $Link
    )

    $key = Get-GpoLinkGuidKey -Link $Link
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $GuidLookup[$key] = $true
    }

    $nameKey = Get-GpoLinkNameKey -Link $Link
    if (-not [string]::IsNullOrWhiteSpace($nameKey)) {
        $NameLookup[$nameKey] = $true
    }
}

function Get-ApplicableGpoLinkInfoForOu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetOU
    )

    $guidLookup = @{}
    $nameLookup = @{}
    $checked = $false
    try {
        $inheritance = Get-GPInheritance -Target $TargetOU -ErrorAction Stop
        $checked = $true
        $links = @()
        $links += @($inheritance.GpoLinks | Where-Object { $_ })
        $links += @($inheritance.InheritedGpoLinks | Where-Object { $_ })
        foreach ($link in $links) {
            if ($link.PSObject.Properties.Match("Enabled").Count -gt 0 -and ([string]$link.Enabled) -match "^(False|No|Disabled)$") {
                continue
            }

            Add-GpoLinkKeys -GuidLookup $guidLookup -NameLookup $nameLookup -Link $link
        }
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not inspect GPO links for target OU '$TargetOU': $($_.Exception.Message)" -Color Yellow
    }

    try {
        foreach ($containerDn in @(Get-AdContainerAncestorDns -DistinguishedName $TargetOU)) {
            $container = Get-ADObject -Identity $containerDn -Properties gPLink, gPOptions -ErrorAction Stop
            foreach ($entry in @(Get-RawGpLinkEntries -GpLink ([string]$container.gPLink))) {
                $key = ConvertTo-GpoGuidKey -Value $entry.GpoId
                if (-not [string]::IsNullOrWhiteSpace($key)) {
                    $guidLookup[$key] = $true
                    $checked = $true
                }
            }

            $gpoOptions = 0
            [void][int]::TryParse([string]$container.gPOptions, [ref]$gpoOptions)
            if (($gpoOptions -band 1) -ne 0) {
                break
            }
        }
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not inspect raw gPLink inheritance for target OU '$TargetOU': $($_.Exception.Message)" -Color Yellow
    }

    return [pscustomobject]@{
        Checked    = $checked
        Lookup     = $guidLookup
        GuidLookup = $guidLookup
        NameLookup = $nameLookup
    }
}

function Get-XmlAttributeValue {
    param(
        [AllowNull()]
        $Node,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $Node -or $null -eq $Node.Attributes) {
        return ""
    }

    foreach ($name in $Names) {
        $attribute = $Node.Attributes.GetNamedItem($name)
        if ($attribute -and -not [string]::IsNullOrWhiteSpace([string]$attribute.Value)) {
            return [string]$attribute.Value
        }
    }

    return ""
}

function Resolve-MappedDriveLetterFromXml {
    param(
        [Parameter(Mandatory = $true)]
        $DriveNode
    )

    $propertiesNode = @($DriveNode.SelectNodes("./Properties") | Where-Object { $_ }) | Select-Object -First 1
    $letter = Get-XmlAttributeValue -Node $propertiesNode -Names @("letter", "driveLetter")
    if ([string]::IsNullOrWhiteSpace($letter)) {
        $letter = Get-XmlAttributeValue -Node $DriveNode -Names @("name")
    }

    $letter = $letter.Trim().TrimEnd(":").ToUpperInvariant()
    if ($letter -match "^[A-Z]$") {
        return $letter
    }

    return ""
}

function Get-MappedDriveTargetGroupRefs {
    param(
        [Parameter(Mandatory = $true)]
        $DriveNode
    )

    $refs = @()
    $seen = @{}
    foreach ($node in @($DriveNode.SelectNodes(".//*") | Where-Object { $_ })) {
        $localName = [string]$node.LocalName
        $name = Get-XmlAttributeValue -Node $node -Names @("name", "group")
        $sid = Get-XmlAttributeValue -Node $node -Names @("sid", "groupSid")
        if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($sid)) {
            continue
        }

        $looksLikeGroupCondition = ($localName -match "(?i)^FilterGroup$|Group") -or -not [string]::IsNullOrWhiteSpace($sid)
        if (-not $looksLikeGroupCondition) {
            continue
        }

        $notValue = (Get-XmlAttributeValue -Node $node -Names @("not")).Trim()
        $isNegated = $notValue -in @("1", "true", "True")
        $key = ("{0}|{1}|{2}" -f $name, $sid, $isNegated).ToUpperInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $refs += [pscustomobject]@{
            Name    = $name
            Sid     = $sid
            Negated = $isNegated
        }
    }

    return $refs
}

function Get-MappedDriveGpoDrivesXmlPath {
    param(
        [Parameter(Mandatory = $true)]
        $Gpo,

        [Parameter(Mandatory = $true)]
        [string]$DomainDnsRoot
    )

    $gpoGuid = ConvertTo-GpoGuidKey -Value $Gpo.Id
    if ([string]::IsNullOrWhiteSpace($gpoGuid)) {
        return ""
    }

    $policyGuid = "{0}" -f ([guid]$gpoGuid).ToString("B").ToUpperInvariant()
    return "\\$DomainDnsRoot\SYSVOL\$DomainDnsRoot\Policies\$policyGuid\User\Preferences\Drives\Drives.xml"
}

function Resolve-MappedDriveTargetGroup {
    param(
        [Parameter(Mandatory = $true)]
        $GroupRef
    )

    $properties = "SamAccountName", "Name", "DistinguishedName", "SID", "ObjectGUID"
    if (-not [string]::IsNullOrWhiteSpace([string]$GroupRef.Sid)) {
        try {
            return Get-ADGroup -Identity ([string]$GroupRef.Sid) -Properties $properties -ErrorAction Stop
        }
        catch {
        }
    }

    $name = ([string]$GroupRef.Name).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    $shortName = $name
    if ($shortName -match "^[^\\]+\\(.+)$") {
        $shortName = $Matches[1]
    }

    foreach ($identity in @($name, $shortName | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
        try {
            return Get-ADGroup -Identity $identity -Properties $properties -ErrorAction Stop
        }
        catch {
        }
    }

    try {
        $escaped = Escape-DirectoryFilterValue -Value $shortName
        $matches = @(Get-ADGroup -Filter "SamAccountName -eq '$escaped' -or Name -eq '$escaped'" -Properties $properties -ErrorAction Stop)
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
    }
    catch {
    }

    return $null
}

function Test-MappedDriveIdentityMatchesGroup {
    param(
        [AllowNull()]
        $IdentityReference,

        [Parameter(Mandatory = $true)]
        $Group
    )

    if ($null -eq $IdentityReference -or $null -eq $Group) {
        return $false
    }

    $identityText = [string]$IdentityReference
    $groupSid = ""
    if ($Group.SID) {
        $groupSid = [string]$Group.SID.Value
        if ([string]::IsNullOrWhiteSpace($groupSid)) {
            $groupSid = [string]$Group.SID
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($groupSid)) {
        try {
            $translatedSid = ""
            if ($IdentityReference -is [System.Security.Principal.IdentityReference]) {
                $translatedSid = $IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            else {
                $translatedSid = (New-Object System.Security.Principal.NTAccount($identityText)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            if ([string]::Equals($translatedSid, $groupSid, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch {
        }
    }

    foreach ($candidate in @($groupSid, $Group.SamAccountName, $Group.Name)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and [string]::Equals($identityText, [string]$candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Group.SamAccountName) -and $identityText.EndsWith("\$($Group.SamAccountName)", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Group.Name) -and $identityText.EndsWith("\$($Group.Name)", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $false
}

function Get-MappedDriveAccessRank {
    param(
        [string]$Access
    )

    switch ($Access) {
        "Full" { return 5 }
        "Modify" { return 4 }
        "Read" { return 3 }
        "Custom" { return 2 }
        "None" { return 1 }
        "Deny" { return 0 }
        default { return -1 }
    }
}

function ConvertTo-MappedDriveAccessLevel {
    param(
        [AllowNull()]
        [string]$RightsText
    )

    if ([string]::IsNullOrWhiteSpace($RightsText)) {
        return "None"
    }

    if ($RightsText -match "(?i)FullControl|Full") {
        return "Full"
    }
    if ($RightsText -match "(?i)Modify|Change|Write|Delete|CreateFiles|AppendData|ChangePermissions|TakeOwnership") {
        return "Modify"
    }
    if ($RightsText -match "(?i)Read|ReadAndExecute|ListDirectory") {
        return "Read"
    }

    return "Custom"
}

function Select-MappedDriveBestAccessLevel {
    param(
        [AllowNull()]
        [string[]]$AccessLevels
    )

    $best = "None"
    foreach ($level in @($AccessLevels | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        if ((Get-MappedDriveAccessRank -Access $level) -gt (Get-MappedDriveAccessRank -Access $best)) {
            $best = $level
        }
    }

    return $best
}

function Get-MappedDriveNtfsAccessForGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UncPath,

        [Parameter(Mandatory = $true)]
        $Group
    )

    if ([string]::IsNullOrWhiteSpace($UncPath) -or $UncPath -notmatch "^\\\\") {
        return "Not checked"
    }

    try {
        $acl = Get-Acl -LiteralPath $UncPath -ErrorAction Stop
    }
    catch {
        return "Not checked"
    }

    $matchingRules = @($acl.Access | Where-Object { Test-MappedDriveIdentityMatchesGroup -IdentityReference $_.IdentityReference -Group $Group })
    if ($matchingRules.Count -eq 0) {
        return "None"
    }
    if (@($matchingRules | Where-Object { [string]$_.AccessControlType -eq "Deny" }).Count -gt 0) {
        return "Deny"
    }

    return Select-MappedDriveBestAccessLevel -AccessLevels @($matchingRules | ForEach-Object { ConvertTo-MappedDriveAccessLevel -RightsText ([string]$_.FileSystemRights) })
}

function Get-MappedDriveSmbShareAccessForGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UncPath,

        [Parameter(Mandatory = $true)]
        $Group
    )

    if (-not (Get-Command Get-SmbShareAccess -ErrorAction SilentlyContinue)) {
        return "Not checked"
    }
    if ($UncPath -notmatch "^\\\\([^\\]+)\\([^\\]+)") {
        return "Not checked"
    }

    $server = $Matches[1]
    $share = $Matches[2]
    $session = $null
    try {
        if ([string]::Equals($server, $env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase)) {
            $shareAccess = @(Get-SmbShareAccess -Name $share -ErrorAction Stop)
        }
        else {
            $session = New-CimSession -ComputerName $server -ErrorAction Stop
            $shareAccess = @(Get-SmbShareAccess -Name $share -CimSession $session -ErrorAction Stop)
        }
    }
    catch {
        return "Not checked"
    }
    finally {
        if ($session) {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
    }

    $matchingRules = @($shareAccess | Where-Object { Test-MappedDriveIdentityMatchesGroup -IdentityReference $_.AccountName -Group $Group })
    if ($matchingRules.Count -eq 0) {
        return "None"
    }

    return Select-MappedDriveBestAccessLevel -AccessLevels @($matchingRules | ForEach-Object { ConvertTo-MappedDriveAccessLevel -RightsText ([string]$_.AccessRight) })
}

function Get-MappedDriveEffectiveAccessSummary {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$AlreadyMember,

        [Parameter(Mandatory = $true)]
        [string]$Applies,

        [string]$NtfsAccess = "",

        [string]$SmbAccess = ""
    )

    if ($Applies -eq "No") {
        return "GPO not linked"
    }
    if ($Applies -ne "Yes") {
        return "GPO link unknown"
    }
    if (-not $AlreadyMember) {
        return "Not a member"
    }
    if ($NtfsAccess -eq "Deny" -or $SmbAccess -eq "Deny") {
        return "Denied by ACL"
    }

    $confirmedLevels = @(@($NtfsAccess, $SmbAccess) | Where-Object { $_ -in @("Read", "Modify", "Full", "Custom") })
    if ($confirmedLevels.Count -gt 0) {
        return "Likely " + (Select-MappedDriveBestAccessLevel -AccessLevels $confirmedLevels)
    }

    return "Member; ACL not confirmed"
}

function Find-MappedDriveAccessCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DriveLetters,

        [Parameter(Mandatory = $true)]
        [string]$TargetOU,

        [Parameter(Mandatory = $true)]
        $NewUser
    )

    if (-not (Import-GroupPolicyModuleForMappedDriveReview)) {
        Add-NewUserRunIssue -Source "Mapped drive access" -Target ($DriveLetters -join ",") -Detail "GroupPolicy module was not available." -Result "Skipped"
        return @()
    }

    $domain = Get-ADDomain -ErrorAction Stop
    $domainDnsRoot = [string]$domain.DNSRoot
    $linkInfo = Get-ApplicableGpoLinkInfoForOu -TargetOU $TargetOU
    $currentGroupDns = @((Get-AdPrincipalGroups -User $NewUser) | ForEach-Object { [string]$_.DistinguishedName })
    $candidates = @()

    Write-UiStatus -Status "LOOKUP" -Message "Searching GPO drive mappings for drive letter(s): $($DriveLetters -join ', ')." -Color Cyan
    $gpos = @(Get-GPO -All -ErrorAction Stop)
    foreach ($gpo in $gpos) {
        $gpoKey = ConvertTo-GpoGuidKey -Value $gpo.Id
        $gpoNameKey = ConvertTo-GpoNameKey -Value $gpo.DisplayName
        $appliesToTargetOU = $false
        if ($linkInfo.Checked) {
            $appliesToTargetOU = (
                (-not [string]::IsNullOrWhiteSpace($gpoKey) -and $linkInfo.GuidLookup.ContainsKey($gpoKey)) -or
                (-not [string]::IsNullOrWhiteSpace($gpoNameKey) -and $linkInfo.NameLookup.ContainsKey($gpoNameKey))
            )
        }

        $drivesXmlPath = Get-MappedDriveGpoDrivesXmlPath -Gpo $gpo -DomainDnsRoot $domainDnsRoot
        if (-not [string]::IsNullOrWhiteSpace([string]$gpo.DomainName)) {
            $drivesXmlPath = Get-MappedDriveGpoDrivesXmlPath -Gpo $gpo -DomainDnsRoot ([string]$gpo.DomainName)
        }
        if ([string]::IsNullOrWhiteSpace($drivesXmlPath) -or -not (Test-Path -LiteralPath $drivesXmlPath)) {
            continue
        }

        try {
            [xml]$drivesXml = Get-Content -LiteralPath $drivesXmlPath -Raw -ErrorAction Stop
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not read drive map XML for GPO '$($gpo.DisplayName)': $($_.Exception.Message)" -Color Yellow
            continue
        }

        foreach ($driveNode in @($drivesXml.SelectNodes("//Drive") | Where-Object { $_ })) {
            $driveLetter = Resolve-MappedDriveLetterFromXml -DriveNode $driveNode
            if ([string]::IsNullOrWhiteSpace($driveLetter) -or $DriveLetters -notcontains $driveLetter) {
                continue
            }

            $propertiesNode = @($driveNode.SelectNodes("./Properties") | Where-Object { $_ }) | Select-Object -First 1
            $uncPath = Get-XmlAttributeValue -Node $propertiesNode -Names @("path", "location")
            $groupRefs = @(Get-MappedDriveTargetGroupRefs -DriveNode $driveNode | Where-Object { $_ -and $_.Negated -ne $true })
            $appliesText = if ($linkInfo.Checked) {
                if ($appliesToTargetOU) { "Yes" } else { "No" }
            }
            else {
                "Unknown"
            }
            if ($groupRefs.Count -eq 0) {
                $candidates += [pscustomobject]@{
                    Drive               = "$driveLetter`:"
                    UncPath             = $uncPath
                    GPO                 = $gpo.DisplayName
                    Applies             = $appliesText
                    Group               = "(no targeting group found)"
                    GroupSamAccountName = ""
                    GroupDistinguishedName = ""
                    GroupObject         = $null
                    Member              = "No"
                    NTFS                = "Not checked"
                    SMB                 = "Not checked"
                    EffectiveAccess     = if ($appliesText -eq "Yes") { "No group target" } elseif ($appliesText -eq "Unknown") { "GPO link unknown" } else { "GPO not linked" }
                    GpoXmlPath          = $drivesXmlPath
                    CanAdd              = $false
                }
                continue
            }

            foreach ($groupRef in $groupRefs) {
                $group = Resolve-MappedDriveTargetGroup -GroupRef $groupRef
                $alreadyMember = $false
                $ntfsAccess = "Not checked"
                $smbAccess = "Not checked"
                if ($group) {
                    $alreadyMember = $currentGroupDns -contains [string]$group.DistinguishedName
                    if (-not [string]::IsNullOrWhiteSpace($uncPath)) {
                        $ntfsAccess = Get-MappedDriveNtfsAccessForGroup -UncPath $uncPath -Group $group
                        $smbAccess = Get-MappedDriveSmbShareAccessForGroup -UncPath $uncPath -Group $group
                    }
                }

                $candidates += [pscustomobject]@{
                    Drive               = "$driveLetter`:"
                    UncPath             = $uncPath
                    GPO                 = $gpo.DisplayName
                    Applies             = $appliesText
                    Group               = if ($group) { $group.Name } elseif (-not [string]::IsNullOrWhiteSpace([string]$groupRef.Name)) { [string]$groupRef.Name } else { [string]$groupRef.Sid }
                    GroupSamAccountName = if ($group) { $group.SamAccountName } else { "" }
                    GroupDistinguishedName = if ($group) { $group.DistinguishedName } else { "" }
                    GroupObject         = $group
                    Member              = if ($alreadyMember) { "Yes" } else { "No" }
                    NTFS                = $ntfsAccess
                    SMB                 = $smbAccess
                    EffectiveAccess     = Get-MappedDriveEffectiveAccessSummary -AlreadyMember $alreadyMember -Applies $appliesText -NtfsAccess $ntfsAccess -SmbAccess $smbAccess
                    GpoXmlPath          = $drivesXmlPath
                    CanAdd              = ($null -ne $group -and $appliesText -eq "Yes" -and -not $alreadyMember)
                }
            }
        }
    }

    return $candidates
}

function New-MappedDriveCandidateRows {
    param(
        [AllowNull()]
        [object[]]$Candidates
    )

    $rows = @()
    $cleanCandidates = @($Candidates | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanCandidates.Count; $i++) {
        $candidate = $cleanCandidates[$i]
        $rows += [pscustomobject]@{
            Number  = $i + 1
            Drive   = $candidate.Drive
            UNC     = $candidate.UncPath
            Group   = $candidate.Group
            Applies = $candidate.Applies
            Member  = $candidate.Member
            NTFS    = $candidate.NTFS
            SMB     = $candidate.SMB
            GPO     = $candidate.GPO
        }
    }

    return $rows
}

function Write-MappedDriveCandidateDetails {
    param(
        [Parameter(Mandatory = $true)]
        $Candidate
    )

    Write-UiBox -Title "Mapped Drive Candidate - $($Candidate.Drive)" -Lines @(
        New-UiBoxLine -Label "Drive" -Value $Candidate.Drive
        New-UiBoxLine -Label "UNC path" -Value $Candidate.UncPath
        New-UiBoxLine -Label "GPO" -Value $Candidate.GPO
        New-UiBoxLine -Label "Applies to target OU" -Value $Candidate.Applies
        New-UiBoxLine -Label "Group" -Value $Candidate.Group
        New-UiBoxLine -Label "Group SamAccountName" -Value $Candidate.GroupSamAccountName
        New-UiBoxLine -Label "Already member" -Value $Candidate.Member
        New-UiBoxLine -Label "NTFS evidence" -Value $Candidate.NTFS
        New-UiBoxLine -Label "SMB evidence" -Value $Candidate.SMB
        New-UiBoxLine -Label "Effective access" -Value $Candidate.EffectiveAccess
        New-UiBoxLine -Label "Drives.xml" -Value $Candidate.GpoXmlPath
    )
}

function Get-MappedDriveCandidateLetter {
    param(
        [AllowNull()]
        $Candidate
    )

    if ($null -eq $Candidate -or [string]::IsNullOrWhiteSpace([string]$Candidate.Drive)) {
        return ""
    }

    return ([string]$Candidate.Drive).Trim().TrimEnd(":").ToUpperInvariant()
}

function Add-MappedDriveCandidateGroups {
    param(
        [Parameter(Mandatory = $true)]
        $NewUser,

        [Parameter(Mandatory = $true)]
        [string]$TargetOU,

        [AllowNull()]
        [object[]]$Candidates,

        [switch]$Confirm
    )

    $selectedCandidates = @($Candidates | Where-Object { $_ })
    $groupsToAdd = @()
    $seenGroupDns = @{}
    foreach ($candidate in $selectedCandidates) {
        if ($candidate.Member -eq "Yes") {
            Write-UiStatus -Status "SKIP" -Message "'$($NewUser.SamAccountName)' is already in mapped drive group '$($candidate.Group)'." -Color Yellow
            continue
        }
        if ($candidate.Applies -ne "Yes") {
            Write-UiStatus -Status "SKIP" -Message "Skipping '$($candidate.Group)' because GPO '$($candidate.GPO)' does not apply to target OU '$TargetOU'." -Color Yellow
            continue
        }
        if (-not $candidate.GroupObject) {
            Write-UiStatus -Status "SKIP" -Message "Skipping unresolved mapped drive group '$($candidate.Group)'." -Color Yellow
            continue
        }

        $groupDn = [string]$candidate.GroupObject.DistinguishedName
        if (-not $seenGroupDns.ContainsKey($groupDn)) {
            $seenGroupDns[$groupDn] = $true
            $groupsToAdd += $candidate.GroupObject
        }
    }

    if ($groupsToAdd.Count -eq 0) {
        Write-UiStatus -Status "INFO" -Message "No addable mapped drive groups were selected." -Color Yellow
        return 0
    }

    Write-UiBox -Title "Mapped Drive Groups To Add" -Lines (ConvertTo-UiTableLines -Rows (New-NumberedRows -Items $groupsToAdd) -Columns @("Number", "Name", "Detail")) -Color Yellow
    if ($Confirm -and -not (Read-UiYesNo -Prompt "Add selected mapped drive groups?" -DefaultYes $false)) {
        Write-UiStatus -Status "SKIP" -Message "Skipped mapped drive group assignment." -Color Yellow
        return 0
    }

    Add-AdGroupsToNewUser -NewUser $NewUser -Groups $groupsToAdd
    Add-UiStepResult -Name "Mapped drive access" -Result $(if (Test-UiDryRun) { "Dry run" } else { "Completed" }) -Note "Attempted to add $($groupsToAdd.Count) mapped drive group(s)."
    return $groupsToAdd.Count
}

function Select-ForceMappedDriveCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DriveLetters,

        [AllowNull()]
        [object[]]$Candidates
    )

    $selectedCandidates = @()
    foreach ($driveLetter in $DriveLetters) {
        $driveCandidates = @($Candidates | Where-Object { (Get-MappedDriveCandidateLetter -Candidate $_) -eq $driveLetter })
        if ($driveCandidates.Count -eq 0) {
            Write-UiStatus -Status "INFO" -Message "Force mode found no mapped drive candidates for drive '$($driveLetter):'." -Color Yellow
            continue
        }

        if ($driveCandidates.Count -eq 1) {
            if ($driveCandidates[0].CanAdd -eq $true) {
                Write-UiStatus -Status "FORCE" -Message "Auto-selected mapped drive group '$($driveCandidates[0].Group)' for drive '$($driveLetter):'." -Color Yellow
            }
            $selectedCandidates += $driveCandidates[0]
            continue
        }

        $addableCandidates = @($driveCandidates | Where-Object { $_.CanAdd -eq $true })
        if ($addableCandidates.Count -eq 0) {
            $memberCandidates = @($driveCandidates | Where-Object { $_.Member -eq "Yes" })
            if ($memberCandidates.Count -gt 0) {
                Write-UiStatus -Status "SKIP" -Message "User is already in a mapped drive group for drive '$($driveLetter):'." -Color Yellow
            }
            else {
                Write-UiStatus -Status "INFO" -Message "Force mode found no addable mapped drive groups for drive '$($driveLetter):'." -Color Yellow
            }
            continue
        }

        Write-UiBox -Title "Multiple Mapped Drive Candidates - $driveLetter`:" -Lines (ConvertTo-UiTableLines -Rows (New-MappedDriveCandidateRows -Candidates $driveCandidates) -Columns @("Number", "Drive", "UNC", "Group", "Applies", "Member", "NTFS", "SMB", "GPO")) -Color Yellow
        while ($true) {
            $selection = Read-UiInput -Prompt "Force mode found multiple mappings for drive '$($driveLetter):'. Select group numbers to add" -Options @("comma separated", "s=skip this drive")
            if ($selection -eq "s") {
                Write-UiStatus -Status "SKIP" -Message "Skipped mapped drive assignment for drive '$($driveLetter):'." -Color Yellow
                break
            }

            $numbers = @(ConvertTo-NumberSelection -InputText $selection -Max $driveCandidates.Count)
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "Enter mapped drive candidate numbers or s to skip this drive." -Color Yellow
                continue
            }

            $selectedCandidates += @(Select-ItemsByNumber -Items $driveCandidates -Numbers $numbers)
            break
        }
    }

    return $selectedCandidates
}

function Invoke-MappedDriveAccessReview {
    param(
        [Parameter(Mandatory = $true)]
        $NewUser,

        [Parameter(Mandatory = $true)]
        [string]$TargetOU,

        [AllowNull()]
        [string]$DriveLettersText
    )

    $driveLetters = @(ConvertTo-MappedDriveLetterList -InputText $DriveLettersText)
    if ($driveLetters.Count -eq 0) {
        return
    }

    $script:UiStepNumber = $script:UiStepNumber + 1
    Write-UiSection "Mapped Drive Access Review"

    try {
        $candidates = @(Find-MappedDriveAccessCandidates -DriveLetters $driveLetters -TargetOU $TargetOU -NewUser $NewUser)
    }
    catch {
        $message = "Could not inspect mapped drive GPOs: $($_.Exception.Message)"
        Write-UiStatus -Status "WARN" -Message $message -Color Yellow
        Add-UiStepResult -Name "Mapped drive access" -Result "Failed" -Note $message
        Add-NewUserRunIssue -Source "Mapped drive access" -Target ($driveLetters -join ",") -Detail $message
        return
    }

    if ($candidates.Count -eq 0) {
        Write-UiStatus -Status "INFO" -Message "No GPO drive mappings matched requested drive letter(s): $($driveLetters -join ', ')." -Color Yellow
        Add-UiStepResult -Name "Mapped drive access" -Result "Skipped" -Note "No matching drive mappings were found."
        return
    }

    Write-UiBox -Title "Mapped Drive Access Candidates" -Lines (ConvertTo-UiTableLines -Rows (New-MappedDriveCandidateRows -Candidates $candidates) -Columns @("Number", "Drive", "UNC", "Group", "Applies", "Member", "NTFS", "SMB", "GPO"))

    if (Test-NewUserForceMode) {
        $forceCandidates = @(Select-ForceMappedDriveCandidates -DriveLetters $driveLetters -Candidates $candidates)
        $addedCount = Add-MappedDriveCandidateGroups -NewUser $NewUser -TargetOU $TargetOU -Candidates $forceCandidates
        if ($addedCount -eq 0) {
            Add-UiStepResult -Name "Mapped drive access" -Result "Skipped" -Note "Force mode did not select any addable mapped drive groups."
        }
        return
    }

    while ($true) {
        $selection = Read-UiInput -Prompt "Mapped drive groups:" -Options @("numbers=add", "a=add all addable", "d=details", "s=skip")
        if ($selection -eq "s") {
            Add-UiStepResult -Name "Mapped drive access" -Result "Skipped" -Note "Operator skipped mapped drive group assignment."
            return
        }

        if ($selection -eq "d") {
            $detailSelection = Read-UiInput -Prompt "Enter mapped drive result numbers for details:" -Options @("comma separated", "blank=cancel")
            $numbers = ConvertTo-NumberSelection -InputText $detailSelection -Max $candidates.Count
            foreach ($number in $numbers) {
                Write-MappedDriveCandidateDetails -Candidate $candidates[$number - 1]
            }
            continue
        }

        $numbersToAdd = @()
        if ($selection -eq "a") {
            for ($i = 1; $i -le $candidates.Count; $i++) {
                $numbersToAdd += $i
            }
        }
        else {
            $numbersToAdd = @(ConvertTo-NumberSelection -InputText $selection -Max $candidates.Count)
        }

        if ($numbersToAdd.Count -eq 0) {
            Write-UiStatus -Status "INFO" -Message "Enter mapped drive candidate numbers, a, d, or s." -Color Yellow
            continue
        }

        $selectedCandidates = @(Select-ItemsByNumber -Items $candidates -Numbers $numbersToAdd)
        $addedCount = Add-MappedDriveCandidateGroups -NewUser $NewUser -TargetOU $TargetOU -Candidates $selectedCandidates -Confirm
        if ($addedCount -eq 0) {
            continue
        }
        return
    }
}

function Invoke-NewUserDeltaSync {
    $script:UiStepNumber = $script:UiStepNumber + 1

    while ($true) {
        $syncStarted = $false
        try {
            Invoke-UiCommand -Name "Start Entra Connect delta sync" -CommandPreview "Import-Module ADSync`nStart-ADSyncSyncCycle -PolicyType Delta" -Command {
                if (-not (Start-EntraConnectDeltaSync)) {
                    throw "Automatic delta sync did not start."
                }
            }
            $syncStarted = $true
        }
        catch {
            Write-UiStatus -Status "WARN" -Message $_.Exception.Message -Color Yellow
        }
        if (Test-UiDryRun) {
            Add-UiStepResult -Name "Entra Connect delta sync" -Result "Dry run" -Note "Would start delta sync."
            return
        }

        if ($syncStarted) {
            Write-UiStatus -Status "OK" -Message "Step completed: started Entra Connect delta sync." -Color Green
            Add-UiStepResult -Name "Entra Connect delta sync" -Result "Completed"
            return
        }

        Write-UiStatus -Status "WARN" -Message "Delta sync did not start automatically. Run sync manually before continuing cloud steps." -Color Yellow
        $choice = Read-UiInput -Prompt "Next sync action?" -Options @("t=try again", "m=manual sync completed", "a=abort")
        if ($choice -eq "t") {
            continue
        }
        if ($choice -eq "m") {
            Add-UiStepResult -Name "Entra Connect delta sync" -Result "Manual action completed" -Note "Operator confirmed sync was run manually."
            return
        }
        if ($choice -eq "a") {
            Add-UiStepResult -Name "Entra Connect delta sync" -Result "Aborted" -Note "Operator aborted after sync failure."
            throw "Delta sync did not start automatically, and the run was aborted."
        }

        Write-UiStatus -Status "INFO" -Message "Enter exact lowercase t, m, or a." -Color Yellow
    }
}

function Connect-NewUserCloudServices {
    $script:UiStepNumber = $script:UiStepNumber + 1
    $graphScopes = @(
        "User.ReadWrite.All",
        "Directory.ReadWrite.All",
        "Organization.Read.All",
        "LicenseAssignment.ReadWrite.All",
        "Group.ReadWrite.All",
        "GroupMember.ReadWrite.All"
    )

    while ($true) {
        try {
            Connect-M365ServicesMgGraph -GraphScopes $graphScopes
            Write-UiStatus -Status "OK" -Message "Connected to Microsoft Graph for new-user cloud steps." -Color Green
            Add-UiStepResult -Name "Connect Microsoft Graph" -Result "Completed"
            return $true
        }
        catch {
            $message = $_.Exception.Message
            Write-UiStatus -Status "WARN" -Message "Microsoft Graph connection failed: $message" -Color Yellow
            Add-UiStepResult -Name "Connect Microsoft Graph" -Result "Failed" -Note $message

            $choice = Read-UiInput -Prompt "Cloud connection failed. Next action?" -Options @("r=retry cloud connection", "s=skip cloud steps", "x=exit")
            if ($choice -eq "r") {
                continue
            }
            if ($choice -eq "s") {
                Add-UiStepResult -Name "Cloud steps" -Result "Skipped" -Note "Operator skipped cloud steps after Microsoft Graph connection failure."
                return $false
            }
            if ($choice -eq "x") {
                throw "Microsoft Graph connection failed, and the run was stopped."
            }

            Write-UiStatus -Status "INFO" -Message "Enter exact lowercase r, s, or x." -Color Yellow
        }
    }
}

function Wait-NewCloudUser {
    param(
        [Parameter(Mandatory = $true)]
        $Plan
    )

    $select = Get-CloudUserStateAttributeSelect
    $newUserObjectGuid = if ($script:RunContext) { [string]$script:RunContext["NewUserObjectGuid"] } else { "" }
    if ([string]::IsNullOrWhiteSpace($newUserObjectGuid)) {
        throw "New user ObjectGUID is not available for cloud polling. Resolve or create the AD user before polling Graph."
    }
    $adUser = Get-ADUser -Identity $newUserObjectGuid -Properties (Get-NewUserCloudAnchorAdProperties)
    $sourceAnchor = Get-AdUserSourceAnchorInfo -User $adUser

    $attempt = 0
    while ($true) {
        $attempt++
        Write-UiStatus -Status "POLL" -Message "Polling Graph for new cloud user '$($Plan.UserPrincipalName)' (attempt $attempt of $PollAttempts)." -Color Cyan
        $immutableMatches = @()
        if (-not [string]::IsNullOrWhiteSpace($sourceAnchor.ImmutableId)) {
            try {
                $immutableMatches = @(Find-ActiveCloudUsersByImmutableId -ImmutableId $sourceAnchor.ImmutableId -Select $select)
            }
            catch {
                Write-UiStatus -Status "INFO" -Message "ImmutableId lookup was not available yet: $($_.Exception.Message)" -Color Yellow
            }
        }

        $immutableMatches = @(Get-UniqueCloudUsers -Users $immutableMatches)
        if ($immutableMatches.Count -eq 1) {
            $cloudUser = $immutableMatches[0]
            if ($cloudUser.userPrincipalName -ne $Plan.UserPrincipalName) {
                Write-UiStatus -Status "INFO" -Message "Cloud user matched by source anchor. Cloud UPN is '$($cloudUser.userPrincipalName)', planned AD UPN was '$($Plan.UserPrincipalName)'." -Color Yellow
            }

            return $cloudUser
        }
        if ($immutableMatches.Count -gt 1) {
            Show-CloudUserSearchMatches -Matches $immutableMatches -Source "new user immutableId polling"
            $choice = Read-UiInput -Prompt "Multiple source-anchor matches found. Next action?" -Options @("c=continue polling", "a=abort")
            if ($choice -eq "a") {
                throw "Multiple cloud users matched new user source anchor."
            }
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $lookupMatches = @()
        try {
            $lookupMatches += Find-ActiveCloudUsersByLookup -Lookup $Plan.UserPrincipalName -Select $select
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "UPN lookup did not find the user yet: $($_.Exception.Message)" -Color Yellow
        }

        $lookupMatches = @(Get-UniqueCloudUsers -Users $lookupMatches)
        if ($lookupMatches.Count -eq 1) {
            return $lookupMatches[0]
        }
        if ($lookupMatches.Count -gt 1) {
            Show-CloudUserSearchMatches -Matches $lookupMatches -Source "new user UPN polling"
            $choice = Read-UiInput -Prompt "Multiple cloud users found. Next action?" -Options @("c=continue polling", "a=abort")
            if ($choice -eq "a") {
                throw "Multiple cloud users matched new user polling."
            }
        }

        if ($attempt -ge $PollAttempts) {
            $choice = Read-UiInput -Prompt "Polling limit reached. Next action?" -Options @("k=keep polling", "a=abort", "m=manual lookup")
            if ($choice -eq "k") {
                $attempt = 0
            }
            elseif ($choice -eq "m") {
                $manualLookup = Read-UiInput -Prompt "Enter cloud user UPN or mail" -Options @("manual lookup")
                $manualMatches = @(Find-ActiveCloudUsersByLookup -Lookup $manualLookup -Select $select)
                if ($manualMatches.Count -eq 1) {
                    return $manualMatches[0]
                }
                Show-CloudUserSearchMatches -Matches $manualMatches -Source "manual lookup"
            }
            else {
                throw "Cloud user was not found after polling."
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-CloudLicensePicker {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser,

        [AllowNull()]
        $CopyAfterUser
    )

    $script:UiStepNumber = $script:UiStepNumber + 1

    $cloudUserId = if (-not [string]::IsNullOrWhiteSpace([string]$CloudUser.id)) { [string]$CloudUser.id } else { [string]$CloudUser.userPrincipalName }
    $cloudUserLabel = if (-not [string]::IsNullOrWhiteSpace([string]$CloudUser.userPrincipalName)) { [string]$CloudUser.userPrincipalName } else { $cloudUserId }

    if (Test-NewUserForceMode) {
        Copy-CopyAfterCloudLicensesToNewUser -CloudUser $CloudUser -CopyAfterUser $CopyAfterUser
        return
    }

    if ($CopyAfterUser) {
        try {
            $snapshot = Get-CloudUserLicenseSnapshot -UserIdOrUpn $cloudUserId
            $choice = Read-UiInput -Prompt "Check copy-after user's assigned licenses before license manager?" -Options @("y=yes", "n=no")
            if ($choice -eq "y") {
                Show-CopyAfterCloudUserLicenses -CopyAfterUser $CopyAfterUser -SkuById $snapshot.SkuById
            }
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not load copy-after license context: $($_.Exception.Message)" -Color Yellow
        }
    }

    try {
        $managerResult = Invoke-InteractiveLicenseManager -UserIdOrUpn $cloudUserId -DisplayName $cloudUserLabel -ContinueOption -PassThru
        if ($managerResult.Result -eq "Continue") {
            Add-UiStepResult -Name "Manage cloud licenses" -Result "Completed" -Note "Continued from license manager."
        }
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "License manager could not continue for '$cloudUserLabel': $($_.Exception.Message)" -Color Yellow
        Write-UiStatus -Status "INFO" -Message "Continuing the new-user workflow. Use the Microsoft 365 admin center or rerun a license-only workflow if needed." -Color Yellow
        Add-UiStepResult -Name "Manage cloud licenses" -Result "Failed" -Note $_.Exception.Message
    }
}

function Copy-CopyAfterCloudLicensesToNewUser {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser,

        [Parameter(Mandatory = $true)]
        $CopyAfterUser
    )

    $cloudUserId = if (-not [string]::IsNullOrWhiteSpace([string]$CloudUser.id)) { [string]$CloudUser.id } else { [string]$CloudUser.userPrincipalName }
    try {
        $snapshot = Get-CloudUserLicenseSnapshot -UserIdOrUpn $cloudUserId
        $copyAfterCloudUser = Find-CopyAfterCloudUser -CopyAfterUser $CopyAfterUser
        if (-not $copyAfterCloudUser) {
            Write-UiStatus -Status "WARN" -Message "Force mode could not find the copy-after cloud user for license copy." -Color Yellow
            Add-UiStepResult -Name "Copy cloud licenses" -Result "Failed" -Note "Copy-after cloud user was not found."
            return
        }

        $copyAfterRows = @(Get-AssignedLicenseRows -AssignedLicenses $copyAfterCloudUser.assignedLicenses -SkuById $snapshot.SkuById)
        if ($copyAfterRows.Count -eq 0) {
            Write-UiStatus -Status "INFO" -Message "Copy-after cloud user has no assigned licenses to copy." -Color Yellow
            Add-UiStepResult -Name "Copy cloud licenses" -Result "Skipped" -Note "Copy-after user had no assigned licenses."
            return
        }

        $targetSkuIds = @{}
        foreach ($assignedRow in @($snapshot.AssignedRows | Where-Object { $_ })) {
            if (-not [string]::IsNullOrWhiteSpace([string]$assignedRow.SkuId)) {
                $targetSkuIds[[string]$assignedRow.SkuId] = $true
            }
        }

        $rowsToAdd = @($copyAfterRows | Where-Object { $_ -and -not $targetSkuIds.ContainsKey([string]$_.SkuId) })
        if ($rowsToAdd.Count -eq 0) {
            Write-UiStatus -Status "INFO" -Message "New cloud user already has all copy-after licenses." -Color Yellow
            Add-UiStepResult -Name "Copy cloud licenses" -Result "Skipped" -Note "No missing licenses."
            return
        }

        if (-not (Ensure-CloudUserUsageLocationForLicenseAssignment -Snapshot $snapshot)) {
            Add-UiStepResult -Name "Copy cloud licenses" -Result "Failed" -Note "UsageLocation could not be set."
            return
        }

        $selectedLicenseText = (@($rowsToAdd | ForEach-Object { $_.License }) -join ", ")
        Invoke-UiCommand `
            -Name "Copy cloud licenses from copy-after user" `
            -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users/$($snapshot.CloudUser.id)/assignLicense' -Body <add $selectedLicenseText>" `
            -Command {
            Invoke-CloudUserLicenseAssignment -UserIdOrUpn $snapshot.CloudUser.id -AddLicenseRows $rowsToAdd -RemoveLicenseRows @() | Out-Null
        }

        if (Test-UiDryRun) {
            Add-UiStepResult -Name "Copy cloud licenses" -Result "Dry run" -Note "Would assign $($rowsToAdd.Count) license(s)."
        }
        else {
            Write-UiStatus -Status "OK" -Message "Copied $($rowsToAdd.Count) cloud license(s) from copy-after user." -Color Green
            Add-UiStepResult -Name "Copy cloud licenses" -Result "Completed" -Note "Assigned $($rowsToAdd.Count) license(s)."
        }
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not copy cloud licenses from copy-after user: $($_.Exception.Message)" -Color Yellow
        Add-UiStepResult -Name "Copy cloud licenses" -Result "Failed" -Note $_.Exception.Message
    }
}

function Show-CopyAfterCloudUserLicenses {
    param(
        [Parameter(Mandatory = $true)]
        $CopyAfterUser,

        [Parameter(Mandatory = $true)]
        [hashtable]$SkuById
    )

    $copyAfterCloudUser = Find-CopyAfterCloudUser -CopyAfterUser $CopyAfterUser
    if (-not $copyAfterCloudUser) {
        Write-UiStatus -Status "WARN" -Message "Could not find copy-after cloud user for license review." -Color Yellow
        return
    }

    Format-CloudUserState -CloudUser $copyAfterCloudUser -Source "copy-after license lookup"
    $licenseRows = @(Get-AssignedLicenseRows -AssignedLicenses $copyAfterCloudUser.assignedLicenses -SkuById $SkuById)
    if ($licenseRows.Count -eq 0) {
        Write-UiStatus -Status "INFO" -Message "Copy-after cloud user has no assigned licenses." -Color Yellow
        return
    }

    Write-UiBox -Title "Copy-After Assigned Licenses" -Lines (ConvertTo-UiTableLines -Rows $licenseRows -Columns @("License"))
}

function Find-CopyAfterCloudUser {
    param(
        [Parameter(Mandatory = $true)]
        $CopyAfterUser
    )

    $select = Get-CloudUserStateAttributeSelect
    $sourceAnchor = Get-AdUserSourceAnchorInfo -User $CopyAfterUser
    $immutableMatches = @()
    if (-not [string]::IsNullOrWhiteSpace($sourceAnchor.ImmutableId)) {
        $immutableMatches = @(Find-ActiveCloudUsersByImmutableId -ImmutableId $sourceAnchor.ImmutableId -Select $select)
    }

    $immutableMatches = @(Get-UniqueCloudUsers -Users $immutableMatches)
    if ($immutableMatches.Count -eq 1) {
        return $immutableMatches[0]
    }
    if ($immutableMatches.Count -gt 1) {
        Show-CloudUserSearchMatches -Matches $immutableMatches -Source "copy-after cloud immutableId lookup"
        return $null
    }

    $lookupCandidates = [System.Collections.Generic.List[string]]::new()
    $seenLookupCandidates = @{}
    function Add-CopyAfterCloudLookupCandidate {
        param([AllowNull()][string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        $cleanValue = $Value.Trim()
        $key = $cleanValue.ToLowerInvariant()
        if ($seenLookupCandidates.ContainsKey($key)) {
            return
        }

        $seenLookupCandidates[$key] = $true
        $lookupCandidates.Add($cleanValue) | Out-Null
    }

    Add-CopyAfterCloudLookupCandidate -Value $CopyAfterLookup
    Add-CopyAfterCloudLookupCandidate -Value $CopyAfterUser.mail
    Add-CopyAfterCloudLookupCandidate -Value $CopyAfterUser.UserPrincipalName
    Add-CopyAfterCloudLookupCandidate -Value $CopyAfterUser.DisplayName
    Add-CopyAfterCloudLookupCandidate -Value $CopyAfterUser.Name
    Add-CopyAfterCloudLookupCandidate -Value $CopyAfterUser.SamAccountName

    $lookupMatches = @()
    foreach ($lookupCandidate in @($lookupCandidates)) {
        try {
            $lookupMatches += Find-ActiveCloudUsersByLookup -Lookup $lookupCandidate -Select $select
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "Copy-after cloud lookup '$lookupCandidate' did not return a usable match: $($_.Exception.Message)" -Color Yellow
        }
    }

    $lookupMatches = @(Get-UniqueCloudUsers -Users $lookupMatches)
    if ($lookupMatches.Count -eq 1) {
        return $lookupMatches[0]
    }

    if ($lookupMatches.Count -gt 1) {
        Show-CloudUserSearchMatches -Matches $lookupMatches -Source "copy-after cloud lookup"
    }
    return $null
}

function Get-CloudGroupSessionUserKey {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser
    )

    foreach ($propertyName in @("id", "userPrincipalName", "mail")) {
        $value = [string]$CloudUser.$propertyName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim().ToLowerInvariant()
        }
    }

    return ""
}

function Get-CloudGroupSessionGroupKey {
    param(
        [Parameter(Mandatory = $true)]
        $Group
    )

    foreach ($propertyName in @("id", "mail", "mailNickname", "displayName")) {
        $value = [string]$Group.$propertyName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim().ToLowerInvariant()
        }
    }

    return ""
}

function Get-CloudGroupSessionState {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser
    )

    $userKey = Get-CloudGroupSessionUserKey -CloudUser $CloudUser
    if ([string]::IsNullOrWhiteSpace($userKey)) {
        return $null
    }

    if (-not $script:CloudGroupSessionState) {
        $script:CloudGroupSessionState = @{}
    }

    if (-not $script:CloudGroupSessionState.ContainsKey($userKey)) {
        $script:CloudGroupSessionState[$userKey] = @{
            Added   = @{}
            Removed = @{}
        }
    }

    return $script:CloudGroupSessionState[$userKey]
}

function Update-CloudGroupSessionState {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser,

        [Parameter(Mandatory = $true)]
        $Group,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Add", "Remove")]
        [string]$Action
    )

    $state = Get-CloudGroupSessionState -CloudUser $CloudUser
    $groupKey = Get-CloudGroupSessionGroupKey -Group $Group
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace($groupKey)) {
        return
    }

    if ($Action -eq "Add") {
        $state.Removed.Remove($groupKey)
        $state.Added[$groupKey] = $Group
        return
    }

    $state.Added.Remove($groupKey)
    $state.Removed[$groupKey] = $true
}

function Merge-CloudGroupSessionState {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser,

        [AllowNull()]
        [object[]]$Groups
    )

    $state = Get-CloudGroupSessionState -CloudUser $CloudUser
    if ($null -eq $state) {
        return @($Groups | Where-Object { $_ } | Sort-Object displayName)
    }

    $merged = @()
    $seen = @{}
    foreach ($group in @($Groups | Where-Object { $_ })) {
        $groupKey = Get-CloudGroupSessionGroupKey -Group $group
        if ([string]::IsNullOrWhiteSpace($groupKey) -or $state.Removed.ContainsKey($groupKey)) {
            continue
        }

        if (-not $seen.ContainsKey($groupKey)) {
            $merged += $group
            $seen[$groupKey] = $true
        }
    }

    foreach ($groupKey in @($state.Added.Keys)) {
        if (-not $seen.ContainsKey($groupKey) -and -not $state.Removed.ContainsKey($groupKey)) {
            $merged += $state.Added[$groupKey]
            $seen[$groupKey] = $true
        }
    }

    return @($merged | Sort-Object displayName)
}

function Get-CloudUserGroups {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser
    )

    $encodedUser = [System.Uri]::EscapeDataString($CloudUser.id)
    $select = "id,displayName,mailEnabled,securityEnabled,groupTypes,mail,mailNickname,onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesSecurityIdentifier"
    $uri = "https://graph.microsoft.com/v1.0/users/$encodedUser/memberOf/microsoft.graph.group?`$select=$select"
    $result = Invoke-MgGraphRequest -Method GET -Uri $uri
    return @(Merge-CloudGroupSessionState -CloudUser $CloudUser -Groups @($result.value | Where-Object { $_ }))
}

function Get-CloudGroupTypeLabel {
    param(
        [AllowNull()]
        $Group
    )

    if ($null -eq $Group) {
        return "Unknown"
    }

    $recipientTypeDetails = ""
    if ($Group.PSObject.Properties.Match("RecipientTypeDetails").Count -gt 0) {
        $recipientTypeDetails = [string]$Group.RecipientTypeDetails
    }
    elseif ($Group.PSObject.Properties.Match("recipientTypeDetails").Count -gt 0) {
        $recipientTypeDetails = [string]$Group.recipientTypeDetails
    }

    switch -Regex ($recipientTypeDetails) {
        "^DynamicDistributionGroup$"      { return "Dynamic distribution list" }
        "^MailUniversalSecurityGroup$"   { return "Mail-enabled security group" }
        "^Mail.*Distribution"            { return "Distribution list" }
        "^RoomList$"                     { return "Room list" }
        "^(GroupMailbox|Microsoft365)"   { return "M365 group" }
    }

    $groupTypes = @($Group.groupTypes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $isUnified = $groupTypes -contains "Unified"
    $isDynamic = $groupTypes -contains "DynamicMembership"
    $isMailEnabled = $Group.mailEnabled -eq $true
    $isSecurityEnabled = $Group.securityEnabled -eq $true

    if ($isUnified -and $isDynamic) {
        return "Dynamic M365 group"
    }
    if ($isUnified) {
        return "M365 group"
    }
    if ($isDynamic -and $isSecurityEnabled) {
        return "Dynamic security group"
    }
    if ($isDynamic) {
        return "Dynamic group"
    }
    if ($isMailEnabled -and $isSecurityEnabled) {
        return "Mail-enabled security group"
    }
    if ($isMailEnabled) {
        return "Distribution list"
    }
    if ($isSecurityEnabled) {
        return "Security group"
    }

    if ($groupTypes.Count -gt 0) {
        return ($groupTypes -join ",")
    }

    return "Group"
}

function New-CloudGroupRows {
    param(
        [AllowNull()]
        [object[]]$Groups
    )

    $rows = @()
    $cleanGroups = @($Groups | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanGroups.Count; $i++) {
        $directorySource = "Cloud-only"
        if ($cleanGroups[$i].onPremisesSyncEnabled -eq $true) {
            $directorySource = "On-prem synced"
        }

        $rows += [pscustomobject]@{
            Number          = $i + 1
            DisplayName     = $cleanGroups[$i].displayName
            Management      = Get-CloudGroupManagementLabel -Group $cleanGroups[$i]
            DirectorySource = $directorySource
            MailEnabled     = $cleanGroups[$i].mailEnabled
            SecurityEnabled = $cleanGroups[$i].securityEnabled
            GroupTypes      = Get-CloudGroupTypeLabel -Group $cleanGroups[$i]
        }
    }

    return $rows
}

function Get-CloudGroupManagementType {
    param(
        [AllowNull()]
        $Group
    )

    if ($null -eq $Group) {
        return "Unknown"
    }

    if (@($Group.groupTypes) -contains "DynamicMembership") {
        return "SkipDynamic"
    }

    if ($Group.onPremisesSyncEnabled -eq $true) {
        return "AD"
    }

    if (@($Group.groupTypes) -contains "Unified") {
        return "Graph"
    }

    if ($Group.mailEnabled -eq $true) {
        return "Exchange"
    }

    return "Graph"
}

function Get-CloudGroupManagementLabel {
    param(
        [AllowNull()]
        $Group
    )

    switch (Get-CloudGroupManagementType -Group $Group) {
        "Graph"       { return "Graph" }
        "Exchange"    { return "Exchange Online" }
        "AD"          { return "Active Directory" }
        "SkipDynamic" { return "Skip - dynamic" }
        default       { return "Unknown" }
    }
}

function Get-NewUserCloudMemberIdentity {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser
    )

    foreach ($propertyName in @("userPrincipalName", "mail", "id")) {
        $value = [string]$NewCloudUser.$propertyName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ""
}

function Get-ExchangeCloudGroupIdentity {
    param(
        [Parameter(Mandatory = $true)]
        $Group
    )

    foreach ($propertyName in @("mail", "mailNickname", "displayName", "id")) {
        $value = [string]$Group.$propertyName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ""
}

function Get-NewUserAdMemberIdentity {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser
    )

    $newUserObjectGuid = if ($script:RunContext) { [string]$script:RunContext["NewUserObjectGuid"] } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($newUserObjectGuid)) {
        return $newUserObjectGuid
    }

    foreach ($propertyName in @("userPrincipalName", "mail")) {
        $value = [string]$NewCloudUser.$propertyName
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        try {
            $escaped = Escape-DirectoryFilterValue -Value $value
            $match = Get-ADUser -Filter "UserPrincipalName -eq '$escaped' -or mail -eq '$escaped'" -Properties ObjectGUID -ErrorAction Stop | Select-Object -First 1
            if ($match -and $match.ObjectGUID) {
                return [string]$match.ObjectGUID
            }
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "Could not resolve AD user from cloud value '$value': $($_.Exception.Message)" -Color Yellow
        }
    }

    return ""
}

function Resolve-OnPremSyncedCloudGroupAdGroup {
    param(
        [Parameter(Mandatory = $true)]
        $Group
    )

    foreach ($propertyName in @("onPremisesSecurityIdentifier", "onPremisesSamAccountName")) {
        $value = [string]$Group.$propertyName
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        try {
            return Get-ADGroup -Identity $value -Properties DistinguishedName,Name,SamAccountName,mail,ObjectGUID -ErrorAction Stop
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "Could not resolve AD group '$($Group.displayName)' by $propertyName '$value': $($_.Exception.Message)" -Color Yellow
        }
    }

    $exactCandidates = @()
    foreach ($propertyName in @("mail", "mailNickname", "displayName")) {
        $value = [string]$Group.$propertyName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $exactCandidates += $value.Trim()
        }
    }

    foreach ($candidate in @($exactCandidates | Select-Object -Unique)) {
        try {
            $escaped = Escape-DirectoryFilterValue -Value $candidate
            $matches = @(Get-ADGroup -Filter "Name -eq '$escaped' -or SamAccountName -eq '$escaped' -or mail -eq '$escaped'" -Properties DistinguishedName,Name,SamAccountName,mail,ObjectGUID -ErrorAction Stop)
            if ($matches.Count -eq 1) {
                return $matches[0]
            }
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "Could not resolve AD group '$($Group.displayName)' by exact value '$candidate': $($_.Exception.Message)" -Color Yellow
        }
    }

    return $null
}

function Ensure-NewUserExchangeOnlineConnected {
    if ($script:NewUserExchangeOnlineConnected) {
        return
    }

    Connect-M365ServicesExchangeOnline
    $script:NewUserExchangeOnlineConnected = $true
    Write-UiStatus -Status "OK" -Message "Connected to Exchange Online for mail-enabled group and mailbox permission changes." -Color Green
}

function Resolve-MailboxPermissionLevel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText
    )

    $normalizedInput = $InputText.Trim() -replace "\s+", ""
    switch ($normalizedInput) {
        "f" { return "FullAccess" }
        "full" { return "FullAccess" }
        "fullaccess" { return "FullAccess" }
        "s" { return "SendAs" }
        "sendas" { return "SendAs" }
        "b" { return "SendOnBehalf" }
        "sendonbehalf" { return "SendOnBehalf" }
        default { return "" }
    }
}

function Resolve-MailboxPermissionLevels {
    param(
        [AllowNull()]
        [string]$InputText
    )

    $permissionLevels = @()
    $invalidTokens = @()
    $seen = @{}

    foreach ($token in @($InputText -split "," | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($token -eq "x") {
            return [pscustomobject]@{
                IsBack           = $true
                PermissionLevels = @()
                InvalidTokens    = @()
            }
        }

        $permissionLevel = Resolve-MailboxPermissionLevel -InputText $token
        if ([string]::IsNullOrWhiteSpace($permissionLevel)) {
            $invalidTokens += $token
            continue
        }

        if (-not $seen.ContainsKey($permissionLevel)) {
            $seen[$permissionLevel] = $true
            $permissionLevels += $permissionLevel
        }
    }

    return [pscustomobject]@{
        IsBack           = $false
        PermissionLevels = $permissionLevels
        InvalidTokens    = $invalidTokens
    }
}

function Get-MailboxPermissionLevelLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PermissionLevel
    )

    switch ($PermissionLevel) {
        "FullAccess" { return "Full Access" }
        "SendAs" { return "Send As" }
        "SendOnBehalf" { return "Send on Behalf" }
        default { return $PermissionLevel }
    }
}

function Get-MailboxDelegatePrincipal {
    param(
        [AllowNull()]
        $Delegate
    )

    if ($null -eq $Delegate) {
        return ""
    }

    foreach ($propertyName in @("PrimarySmtpAddress", "UserPrincipalName", "mail", "WindowsEmailAddress", "ExternalDirectoryObjectId", "Guid", "Identity", "Name")) {
        $value = $Delegate.$propertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    return [string]$Delegate
}

function Invoke-MailboxDelegateAdd {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        [string]$PermissionLevel,

        [Parameter(Mandatory = $true)]
        $DelegateUser
    )

    $delegateIdentity = Get-MailboxDelegatePrincipal -Delegate $DelegateUser
    if ([string]::IsNullOrWhiteSpace($delegateIdentity)) {
        throw "Could not resolve delegate identity for mailbox permission assignment."
    }

    $label = Get-MailboxPermissionLevelLabel -PermissionLevel $PermissionLevel
    $commandPreview = switch ($PermissionLevel) {
        "FullAccess" { "Add-MailboxPermission -Identity '$UserPrincipalName' -User '$delegateIdentity' -AccessRights FullAccess -InheritanceType All" }
        "SendAs" { "Add-RecipientPermission -Identity '$UserPrincipalName' -Trustee '$delegateIdentity' -AccessRights SendAs -Confirm:`$false" }
        "SendOnBehalf" { "Set-Mailbox -Identity '$UserPrincipalName' -GrantSendOnBehalfTo @{ Add = '$delegateIdentity' }" }
        default { throw "Unsupported mailbox permission level '$PermissionLevel'." }
    }

    Invoke-UiCommand -Name "Add $label mailbox delegate" -CommandPreview $commandPreview -Command {
        switch ($PermissionLevel) {
            "FullAccess" {
                Add-MailboxPermission -Identity $UserPrincipalName -User $delegateIdentity -AccessRights FullAccess -InheritanceType All -ErrorAction Stop | Out-Null
            }
            "SendAs" {
                Add-RecipientPermission -Identity $UserPrincipalName -Trustee $delegateIdentity -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
            }
            "SendOnBehalf" {
                Set-Mailbox -Identity $UserPrincipalName -GrantSendOnBehalfTo @{ Add = $delegateIdentity } -ErrorAction Stop
            }
        }
    }

    if (Test-UiDryRun) {
        Add-UiStepResult -Name "Manage mailbox delegates" -Result "Dry run" -Note "Would add $label delegate '$delegateIdentity'."
    }
    else {
        Write-UiStatus -Status "OK" -Message "Added $label delegate '$delegateIdentity' to '$UserPrincipalName'." -Color Green
        Add-UiStepResult -Name "Manage mailbox delegates" -Result "Completed" -Note "Added $label delegate '$delegateIdentity'."
    }
}

function Get-NewUserMailboxIdentity {
    param(
        [Parameter(Mandatory = $true)]
        $Mailbox
    )

    foreach ($propertyName in @("PrimarySmtpAddress", "UserPrincipalName", "WindowsEmailAddress", "ExternalDirectoryObjectId", "Guid", "Identity", "Name")) {
        $value = $Mailbox.$propertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    return [string]$Mailbox
}

function Get-NewUserMailboxSearchKey {
    param(
        [Parameter(Mandatory = $true)]
        $Mailbox
    )

    foreach ($propertyName in @("ExternalDirectoryObjectId", "Guid", "PrimarySmtpAddress", "UserPrincipalName", "Identity", "Name")) {
        $value = $Mailbox.$propertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return ([string]$value).Trim().ToLowerInvariant()
        }
    }

    return ([string]$Mailbox).Trim().ToLowerInvariant()
}

function Find-MailboxesBySearchTerm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchTerm
    )

    Ensure-NewUserExchangeOnlineConnected

    $matches = @()
    $lookupText = $SearchTerm.Trim()
    try {
        $exactMatch = Get-Mailbox -Identity $lookupText -ErrorAction Stop
        if ($exactMatch) {
            $matches += $exactMatch
        }
    }
    catch {
    }

    try {
        $matches += @(Get-Mailbox -Anr $lookupText -ResultSize 50 -ErrorAction Stop)
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not search Exchange mailboxes for '$SearchTerm': $($_.Exception.Message)" -Color Yellow
    }

    $uniqueMatches = @()
    $seen = @{}
    foreach ($match in @($matches | Where-Object { $_ })) {
        $key = Get-NewUserMailboxSearchKey -Mailbox $match
        if ([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $uniqueMatches += $match
    }

    return @($uniqueMatches | Sort-Object DisplayName)
}

function New-MailboxSearchRows {
    param(
        [AllowNull()]
        [object[]]$Mailboxes
    )

    $rows = @()
    $cleanMailboxes = @($Mailboxes | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanMailboxes.Count; $i++) {
        $mailbox = $cleanMailboxes[$i]
        $rows += [pscustomobject]@{
            Number               = $i + 1
            DisplayName          = $mailbox.DisplayName
            PrimarySmtpAddress   = $mailbox.PrimarySmtpAddress
            RecipientTypeDetails = $mailbox.RecipientTypeDetails
        }
    }

    return $rows
}

function Add-NewUserMailboxPermissionSessionChange {
    param(
        [Parameter(Mandatory = $true)]
        $Mailbox,

        [Parameter(Mandatory = $true)]
        [string]$PermissionLevel,

        [Parameter(Mandatory = $true)]
        $DelegateUser,

        [Parameter(Mandatory = $true)]
        [string]$Result
    )

    if (-not $script:NewUserMailboxPermissionChanges) {
        $script:NewUserMailboxPermissionChanges = New-Object System.Collections.ArrayList
    }

    [void]$script:NewUserMailboxPermissionChanges.Add([pscustomobject]@{
        Mailbox              = Get-NewUserMailboxIdentity -Mailbox $Mailbox
        MailboxDisplayName   = $Mailbox.DisplayName
        MailboxType          = $Mailbox.RecipientTypeDetails
        Permission           = Get-MailboxPermissionLevelLabel -PermissionLevel $PermissionLevel
        Delegate             = Get-MailboxDelegatePrincipal -Delegate $DelegateUser
        Result               = $Result
    })
}

function Invoke-NewUserMailboxPermissionAssignmentFlow {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser,

        [Parameter(Mandatory = $true)]
        [string]$SearchTerm
    )

    $mailboxMatches = @(Find-MailboxesBySearchTerm -SearchTerm $SearchTerm)
    if ($mailboxMatches.Count -eq 0) {
        Write-UiStatus -Status "WARN" -Message "No Exchange mailboxes matched '$SearchTerm'." -Color Yellow
        return
    }

    Write-UiBox -Title "Mailbox Search Results" -Lines (ConvertTo-UiTableLines -Rows (New-MailboxSearchRows -Mailboxes $mailboxMatches) -Columns @("Number", "DisplayName", "PrimarySmtpAddress", "RecipientTypeDetails"))

    while ($true) {
        $selection = Read-UiInput -Prompt "Select mailbox for permission assignment" -Options @("number", "blank=back")
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return
        }

        $numbers = ConvertTo-NumberSelection -InputText $selection -Max $mailboxMatches.Count
        if ($numbers.Count -ne 1) {
            Write-UiStatus -Status "INFO" -Message "Select exactly one mailbox number." -Color Yellow
            continue
        }

        $mailbox = $mailboxMatches[([int]$numbers[0] - 1)]
        $mailboxIdentity = Get-NewUserMailboxIdentity -Mailbox $mailbox
        if ([string]::IsNullOrWhiteSpace($mailboxIdentity)) {
            Write-UiStatus -Status "WARN" -Message "Could not resolve the selected mailbox identity." -Color Yellow
            return
        }

        $permissionInput = Read-UiInput -Prompt "Permission level to add? (enter comma-separated list, such as 'f,b')" -Options @("f=Full Access", "s=Send As", "b=Send on Behalf", "x=back")
        $permissionSelection = Resolve-MailboxPermissionLevels -InputText $permissionInput
        if ($permissionSelection.IsBack) {
            return
        }

        if ($permissionSelection.InvalidTokens.Count -gt 0) {
            Write-UiStatus -Status "INFO" -Message "Invalid permission selection(s): $($permissionSelection.InvalidTokens -join ', '). Enter comma-separated f, s, b, or x." -Color Yellow
            continue
        }

        $permissionLevels = @($permissionSelection.PermissionLevels | Where-Object { $_ })
        if ($permissionLevels.Count -eq 0) {
            Write-UiStatus -Status "INFO" -Message "Enter comma-separated f, s, b, or x." -Color Yellow
            continue
        }

        $permissionLabels = @($permissionLevels | ForEach-Object { Get-MailboxPermissionLevelLabel -PermissionLevel $_ })
        $permissionLabelText = $permissionLabels -join ", "
        $delegatePrincipal = Get-MailboxDelegatePrincipal -Delegate $NewCloudUser
        if ([string]::IsNullOrWhiteSpace($delegatePrincipal)) {
            Write-UiStatus -Status "WARN" -Message "Could not resolve the new cloud user identity for mailbox permission assignment." -Color Yellow
            return
        }

        Write-UiBox -Title "Mailbox Permission Add Plan" -Lines @(
            New-UiBoxLine -Label "Mailbox" -Value $mailboxIdentity
            New-UiBoxLine -Label "Mailbox type" -Value $mailbox.RecipientTypeDetails
            New-UiBoxLine -Label "Permissions" -Value $permissionLabelText
            New-UiBoxLine -Label "Delegate" -Value $delegatePrincipal
        )

        $confirmPrompt = if ($permissionLevels.Count -gt 1) { "Add these mailbox permissions?" } else { "Add this mailbox permission?" }
        if (-not (Read-UiYesNo -Prompt $confirmPrompt -DefaultYes $false)) {
            Write-UiStatus -Status "SKIP" -Message "Skipped mailbox permission assignment." -Color Yellow
            return
        }

        foreach ($permissionLevel in $permissionLevels) {
            $label = Get-MailboxPermissionLevelLabel -PermissionLevel $permissionLevel
            $script:UiStepNumber = $script:UiStepNumber + 1
            try {
                Invoke-MailboxDelegateAdd -UserPrincipalName $mailboxIdentity -PermissionLevel $permissionLevel -DelegateUser $NewCloudUser
                $result = if (Test-UiDryRun) { "Dry run" } else { "Completed" }
                Add-NewUserMailboxPermissionSessionChange -Mailbox $mailbox -PermissionLevel $permissionLevel -DelegateUser $NewCloudUser -Result $result
            }
            catch {
                Write-UiStatus -Status "WARN" -Message "Could not add mailbox permission '$label' on '$mailboxIdentity' for '$delegatePrincipal': $($_.Exception.Message)" -Color Yellow
                Add-UiStepResult -Name "Manage mailbox delegates" -Result "Failed" -Note $_.Exception.Message
            }
        }
        return
    }
}

function Invoke-NewUserCloudGroupMembershipChange {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser,

        [Parameter(Mandatory = $true)]
        $Group,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Add", "Remove")]
        [string]$Action
    )

    $managementType = Get-CloudGroupManagementType -Group $Group
    if ($managementType -eq "SkipDynamic") {
        Write-UiStatus -Status "SKIP" -Message "Skipped dynamic cloud group '$($Group.displayName)'." -Color Yellow
        return
    }

    if ($managementType -eq "AD") {
        $adGroup = Resolve-OnPremSyncedCloudGroupAdGroup -Group $Group
        $memberIdentity = Get-NewUserAdMemberIdentity -NewCloudUser $NewCloudUser
        if (-not $adGroup -or [string]::IsNullOrWhiteSpace($memberIdentity)) {
            Write-UiStatus -Status "WARN" -Message "Could not resolve AD group/member identity for synced cloud group '$($Group.displayName)'." -Color Yellow
            Add-NewUserRunIssue -Source "Cloud group assignment" -Target $Group.displayName -Detail "Could not resolve AD group/member identity for synced cloud group '$($Group.displayName)'."
            return
        }

        try {
            if ($Action -eq "Add") {
                Invoke-UiCommand `
                    -Name "Add new user to AD-synced cloud group" `
                    -CommandPreview "Add-ADGroupMember -Identity '$($adGroup.DistinguishedName)' -Members '$memberIdentity'" `
                    -Command {
                    Add-ADGroupMember -Identity $adGroup.DistinguishedName -Members $memberIdentity -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Write-UiStatus -Status "DRY RUN" -Message "Would add '$($NewCloudUser.userPrincipalName)' to AD-synced group '$($Group.displayName)' through AD group '$($adGroup.Name)'." -Color DarkGray
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Added '$($NewCloudUser.userPrincipalName)' to AD-synced group '$($Group.displayName)' through AD group '$($adGroup.Name)'." -Color Green
                    return [pscustomobject]@{ RequiresDirectorySync = $true }
                }
            }
            else {
                Invoke-UiCommand `
                    -Name "Remove new user from AD-synced cloud group" `
                    -CommandPreview "Remove-ADGroupMember -Identity '$($adGroup.DistinguishedName)' -Members '$memberIdentity' -Confirm:`$false" `
                    -Command {
                    Remove-ADGroupMember -Identity $adGroup.DistinguishedName -Members $memberIdentity -Confirm:$false -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Write-UiStatus -Status "DRY RUN" -Message "Would remove '$($NewCloudUser.userPrincipalName)' from AD-synced group '$($Group.displayName)' through AD group '$($adGroup.Name)'." -Color DarkGray
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Removed '$($NewCloudUser.userPrincipalName)' from AD-synced group '$($Group.displayName)' through AD group '$($adGroup.Name)'." -Color Green
                    return [pscustomobject]@{ RequiresDirectorySync = $true }
                }
            }
        }
        catch {
            $errorMessage = [string]$_.Exception.Message
            if ($Action -eq "Add" -and (Test-AdGroupMemberAlreadyExistsError -ErrorMessage $errorMessage)) {
                Write-UiStatus -Status "SKIP" -Message "'$($NewCloudUser.userPrincipalName)' is already in AD-synced group '$($Group.displayName)' through AD group '$($adGroup.Name)'. No change needed." -Color Yellow
                return
            }

            Write-UiStatus -Status "WARN" -Message "Could not $($Action.ToLowerInvariant()) '$($NewCloudUser.userPrincipalName)' in AD-synced group '$($Group.displayName)' through AD group '$($adGroup.Name)': $errorMessage" -Color Yellow
            Add-NewUserRunIssue -Source "Cloud group assignment" -Target $Group.displayName -Detail "Could not $($Action.ToLowerInvariant()) '$($NewCloudUser.userPrincipalName)' in AD-synced group '$($Group.displayName)' through AD group '$($adGroup.Name)': $errorMessage"
        }
        return
    }

    if ($managementType -eq "Exchange") {
        $groupIdentity = Get-ExchangeCloudGroupIdentity -Group $Group
        $memberIdentity = Get-NewUserCloudMemberIdentity -NewCloudUser $NewCloudUser
        if ([string]::IsNullOrWhiteSpace($groupIdentity) -or [string]::IsNullOrWhiteSpace($memberIdentity)) {
            Write-UiStatus -Status "WARN" -Message "Could not resolve Exchange Online group/member identity for '$($Group.displayName)'." -Color Yellow
            Add-NewUserRunIssue -Source "Cloud group assignment" -Target $Group.displayName -Detail "Could not resolve Exchange Online group/member identity for '$($Group.displayName)'."
            return
        }

        try {
            if ($Action -eq "Add") {
                Invoke-UiCommand `
                    -Name "Add new user to Exchange-managed group" `
                    -CommandPreview "Add-DistributionGroupMember -Identity '$groupIdentity' -Member '$memberIdentity' -BypassSecurityGroupManagerCheck" `
                    -Command {
                    Ensure-NewUserExchangeOnlineConnected
                    Add-DistributionGroupMember -Identity $groupIdentity -Member $memberIdentity -BypassSecurityGroupManagerCheck -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Write-UiStatus -Status "DRY RUN" -Message "Would add '$memberIdentity' to Exchange-managed group '$($Group.displayName)'." -Color DarkGray
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Added '$memberIdentity' to Exchange-managed group '$($Group.displayName)'." -Color Green
                    Update-CloudGroupSessionState -CloudUser $NewCloudUser -Group $Group -Action "Add"
                }
            }
            else {
                Invoke-UiCommand `
                    -Name "Remove new user from Exchange-managed group" `
                    -CommandPreview "Remove-DistributionGroupMember -Identity '$groupIdentity' -Member '$memberIdentity' -BypassSecurityGroupManagerCheck -Confirm:`$false" `
                    -Command {
                    Ensure-NewUserExchangeOnlineConnected
                    Remove-DistributionGroupMember -Identity $groupIdentity -Member $memberIdentity -BypassSecurityGroupManagerCheck -Confirm:$false -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Write-UiStatus -Status "DRY RUN" -Message "Would remove '$memberIdentity' from Exchange-managed group '$($Group.displayName)'." -Color DarkGray
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Removed '$memberIdentity' from Exchange-managed group '$($Group.displayName)'." -Color Green
                    Update-CloudGroupSessionState -CloudUser $NewCloudUser -Group $Group -Action "Remove"
                }
            }
        }
        catch {
            $errorMessage = [string]$_.Exception.Message
            Write-UiStatus -Status "WARN" -Message "Could not $($Action.ToLowerInvariant()) Exchange-managed group '$($Group.displayName)': $errorMessage" -Color Yellow
            Add-NewUserRunIssue -Source "Cloud group assignment" -Target $Group.displayName -Detail "Could not $($Action.ToLowerInvariant()) Exchange-managed group '$($Group.displayName)': $errorMessage"
        }
        return
    }

    try {
        $encodedGroup = [System.Uri]::EscapeDataString($Group.id)
        $encodedUser = [System.Uri]::EscapeDataString($NewCloudUser.id)
        if ($Action -eq "Add") {
            $body = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($NewCloudUser.id)"
            } | ConvertTo-Json -Depth 4
            Invoke-UiCommand `
                -Name "Add new user to Graph-managed group" `
                -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups/$encodedGroup/members/`$ref' -Body <directoryObjects/$($NewCloudUser.id)>" `
                -Command {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$encodedGroup/members/`$ref" -Body $body -ContentType "application/json"
            }
            if (Test-UiDryRun) {
                Write-UiStatus -Status "DRY RUN" -Message "Would add '$($NewCloudUser.userPrincipalName)' to Graph-managed group '$($Group.displayName)'." -Color DarkGray
            }
            else {
                Write-UiStatus -Status "OK" -Message "Added '$($NewCloudUser.userPrincipalName)' to Graph-managed group '$($Group.displayName)'." -Color Green
                Update-CloudGroupSessionState -CloudUser $NewCloudUser -Group $Group -Action "Add"
            }
        }
        else {
            Invoke-UiCommand `
                -Name "Remove new user from Graph-managed group" `
                -CommandPreview "Invoke-MgGraphRequest -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/groups/$encodedGroup/members/$encodedUser/`$ref'" `
                -Command {
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$encodedGroup/members/$encodedUser/`$ref"
            }
            if (Test-UiDryRun) {
                Write-UiStatus -Status "DRY RUN" -Message "Would remove '$($NewCloudUser.userPrincipalName)' from Graph-managed group '$($Group.displayName)'." -Color DarkGray
            }
            else {
                Write-UiStatus -Status "OK" -Message "Removed '$($NewCloudUser.userPrincipalName)' from Graph-managed group '$($Group.displayName)'." -Color Green
                Update-CloudGroupSessionState -CloudUser $NewCloudUser -Group $Group -Action "Remove"
            }
        }
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        Write-UiStatus -Status "WARN" -Message "Could not $($Action.ToLowerInvariant()) Graph-managed group '$($Group.displayName)': $errorMessage" -Color Yellow
        Add-NewUserRunIssue -Source "Cloud group assignment" -Target $Group.displayName -Detail "Could not $($Action.ToLowerInvariant()) Graph-managed group '$($Group.displayName)': $errorMessage"
    }
}

function Add-CloudGroupsToNewUser {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser,

        [AllowNull()]
        [object[]]$Groups
    )

    $groupsToAdd = @($Groups | Where-Object { $_ })
    if ($groupsToAdd.Count -eq 0) {
        Write-UiStatus -Status "INFO" -Message "No cloud groups selected to add." -Color Yellow
        return
    }

    $requiresDirectorySync = $false
    foreach ($group in $groupsToAdd) {
        $changeResult = Invoke-NewUserCloudGroupMembershipChange -NewCloudUser $NewCloudUser -Group $group -Action "Add"
        if ($changeResult -and $changeResult.RequiresDirectorySync) {
            $requiresDirectorySync = $true
        }
    }

    if ($requiresDirectorySync) {
        Write-UiStatus -Status "INFO" -Message "AD-synced cloud group membership will update after directory sync." -Color Yellow
    }
}

function Remove-CloudGroupsFromNewUser {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser,

        [AllowNull()]
        [object[]]$Groups
    )

    $groupsToRemove = @($Groups | Where-Object { $_ })
    if ($groupsToRemove.Count -eq 0) {
        Write-UiStatus -Status "INFO" -Message "No cloud groups selected to remove." -Color Yellow
        return
    }

    $requiresDirectorySync = $false
    foreach ($group in $groupsToRemove) {
        $changeResult = Invoke-NewUserCloudGroupMembershipChange -NewCloudUser $NewCloudUser -Group $group -Action "Remove"
        if ($changeResult -and $changeResult.RequiresDirectorySync) {
            $requiresDirectorySync = $true
        }
    }

    if ($requiresDirectorySync) {
        Write-UiStatus -Status "INFO" -Message "AD-synced cloud group membership will update after directory sync." -Color Yellow
    }
}

function Find-CloudGroupsBySearchTerm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchTerm
    )

    $select = "id,displayName,mailEnabled,securityEnabled,groupTypes,mail,mailNickname,onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesSecurityIdentifier"
    $escapedTerm = Escape-GraphFilterValue -Value $SearchTerm
    $escapedSearchTerm = $SearchTerm.Replace('"', '\"')
    $matches = @()

    $filters = @(
        "startswith(displayName,'$escapedTerm') or startswith(mailNickname,'$escapedTerm') or mail eq '$escapedTerm'",
        "contains(displayName,'$escapedTerm') or contains(mailNickname,'$escapedTerm') or mail eq '$escapedTerm'"
    )

    foreach ($filter in $filters) {
        try {
            $encodedFilter = [System.Uri]::EscapeDataString($filter)
            $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter" + [char]38 + "`$count=true" + [char]38 + "`$select=$select"
            $result = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = "eventual" } -ErrorAction Stop
            $matches += @($result.value | Where-Object { $_ })
        }
        catch {
            # Some Graph search modes are tenant/API dependent; other strategies are still tried.
        }
    }

    try {
        $search = [System.Uri]::EscapeDataString('"displayName:{0}"' -f $escapedSearchTerm)
        $uri = "https://graph.microsoft.com/v1.0/groups?`$search=$search" + [char]38 + "`$count=true" + [char]38 + "`$select=$select"
        $result = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = "eventual" } -ErrorAction Stop
        $matches += @($result.value | Where-Object { $_ })
    }
    catch {
        # Full-text search is optional because filter-based search may already have results.
    }

    return @(Get-UniqueCloudUsers -Users $matches | Sort-Object displayName)
}

function Read-CloudGroupsToExclude {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Groups
    )

    if ($Groups.Count -eq 0) {
        return @()
    }

    Write-UiBox -Title "Copy-After Cloud Groups" -Lines (ConvertTo-UiTableLines -Rows (New-CloudGroupRows -Groups $Groups) -Columns @("Number", "DisplayName", "Management", "DirectorySource", "GroupTypes"))
    if (Test-NewUserForceMode) {
        Write-UiStatus -Status "FORCE" -Message "Copying all copy-after cloud groups." -Color Yellow
        return @()
    }

    $choice = Read-UiInput -Prompt "Copy cloud groups?" -Options @("y=copy all", "e=exclude some", "s=skip")
    if ($choice -eq "s") {
        return $Groups
    }
    if ($choice -ne "e") {
        return @()
    }

    $selection = Read-UiInput -Prompt "Enter cloud group numbers to exclude" -Options @("comma separated", "blank=none")
    $numbers = ConvertTo-NumberSelection -InputText $selection -Max $Groups.Count
    return @(Select-ItemsByNumber -Items $Groups -Numbers $numbers)
}

function Invoke-CloudGroupCopyReview {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser,

        [AllowNull()]$CopyAfterUser
    )

    if ($CopyAfterUser) {
        $copyAfterCloudUser = Find-CopyAfterCloudUser -CopyAfterUser $CopyAfterUser
        if (-not $copyAfterCloudUser) {
            Write-UiStatus -Status "WARN" -Message "Could not find copy-after cloud user. Skipping copy-after cloud group copy." -Color Yellow
            Add-NewUserRunIssue -Source "Copy cloud groups" -Target "Copy-after cloud user" -Detail "Could not find copy-after cloud user. Cloud group copy was skipped."
        }
        else {
            Format-CloudUserState -CloudUser $copyAfterCloudUser -Source "copy-after cloud user"
            $groups = @(Get-CloudUserGroups -CloudUser $copyAfterCloudUser)
            if ($groups.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "Copy-after cloud user has no Graph-visible group memberships." -Color Yellow
            }
            else {
                $excludedGroups = @(Read-CloudGroupsToExclude -Groups $groups)
                $groupsToCopy = @($groups | Where-Object { $excludedGroups.id -notcontains $_.id })
                if ($groupsToCopy.Count -eq 0) {
                    Add-UiStepResult -Name "Copy cloud groups" -Result "Skipped"
                }
                else {
                    $script:UiStepNumber = $script:UiStepNumber + 1
                    Add-CloudGroupsToNewUser -NewCloudUser $NewCloudUser -Groups $groupsToCopy
                    Add-UiStepResult -Name "Copy cloud groups" -Result $(if (Test-UiDryRun) { "Dry run" } else { "Completed" }) -Note "Attempted $($groupsToCopy.Count) cloud group assignment(s)."
                }
            }
        }
    }
    else {
        Write-UiStatus -Status "INFO" -Message "No copy-after user was available for cloud group copy." -Color Yellow
    }

    if (Test-NewUserForceMode) {
        return
    }

    Invoke-CloudGroupMembershipReview -NewCloudUser $NewCloudUser
}

function Invoke-CloudGroupMembershipReview {
    param(
        [Parameter(Mandatory = $true)]
        $NewCloudUser
    )

    while ($true) {
        $currentGroups = @(Get-CloudUserGroups -CloudUser $NewCloudUser)
        Write-UiBox -Title "New User Cloud Groups" -Lines (ConvertTo-UiTableLines -Rows (New-CloudGroupRows -Groups $currentGroups) -Columns @("Number", "DisplayName", "Management", "DirectorySource", "GroupTypes"))
        $choice = Read-UiInput -Prompt "Adjust cloud groups?" -Options @("a=add", "r=remove", "c=continue")
        if ($choice -notin @("a", "r", "c")) {
            Write-UiStatus -Status "INFO" -Message "Enter exact lowercase a, r, or c." -Color Yellow
            continue
        }
        if ($choice -eq "c") {
            return
        }
        if ($choice -eq "r") {
            $selection = Read-UiInput -Prompt "Enter cloud group numbers to remove" -Options @("comma separated")
            $numbers = ConvertTo-NumberSelection -InputText $selection -Max $currentGroups.Count
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No valid cloud group numbers selected to remove." -Color Yellow
                continue
            }

            $script:UiStepNumber = $script:UiStepNumber + 1
            Remove-CloudGroupsFromNewUser -NewCloudUser $NewCloudUser -Groups @(Select-ItemsByNumber -Items $currentGroups -Numbers $numbers)
            Add-UiStepResult -Name "Remove cloud groups" -Result $(if (Test-UiDryRun) { "Dry run" } else { "Completed" }) -Note "Attempted $($numbers.Count) removal(s)."
            continue
        }
        if ($choice -eq "a") {
            $term = Read-UiInput -Prompt "Search cloud groups by name" -Options @("text")
            if ([string]::IsNullOrWhiteSpace($term)) {
                continue
            }

            $groupMatches = @(Find-CloudGroupsBySearchTerm -SearchTerm $term)
            if ($groupMatches.Count -eq 0) {
                Write-UiStatus -Status "WARN" -Message "No cloud groups matched '$term'." -Color Yellow
                $mailboxChoice = Read-UiInput -Prompt "Query mailboxes with the same search term?" -Options @("m=query mailboxes", "blank=back")
                if ($mailboxChoice -eq "m") {
                    Invoke-NewUserMailboxPermissionAssignmentFlow -NewCloudUser $NewCloudUser -SearchTerm $term
                }
                continue
            }

            Write-UiBox -Title "Cloud Group Search Results" -Lines (ConvertTo-UiTableLines -Rows (New-CloudGroupRows -Groups $groupMatches) -Columns @("Number", "DisplayName", "Management", "DirectorySource", "GroupTypes"))
            $selection = Read-UiInput -Prompt "Enter cloud group numbers to add" -Options @("m=query mailboxes", "blank=back")
            if ([string]::IsNullOrWhiteSpace($selection)) {
                continue
            }
            if ($selection -eq "m") {
                Invoke-NewUserMailboxPermissionAssignmentFlow -NewCloudUser $NewCloudUser -SearchTerm $term
                continue
            }

            $numbers = ConvertTo-NumberSelection -InputText $selection -Max $groupMatches.Count
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No valid cloud group numbers selected to add." -Color Yellow
                continue
            }

            $script:UiStepNumber = $script:UiStepNumber + 1
            Add-CloudGroupsToNewUser -NewCloudUser $NewCloudUser -Groups @(Select-ItemsByNumber -Items $groupMatches -Numbers $numbers)
            Add-UiStepResult -Name "Add cloud groups" -Result $(if (Test-UiDryRun) { "Dry run" } else { "Completed" }) -Note "Attempted $($numbers.Count) addition(s)."
        }
    }
}

function Write-FinalAssignedLicenses {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $assignedRows = @(New-LicenseManagerNumberedRows -Rows $Snapshot.AssignedRows)
    if ($assignedRows.Count -eq 0) {
        Write-UiBox -Title "Final Assigned Licenses" -Lines @("None")
        return
    }

    Write-UiBox -Title "Final Assigned Licenses" -Lines (ConvertTo-UiTableLines -Rows $assignedRows -Columns @("Number", "License", "SkuPartNumber"))
}

function Write-FinalCloudGroupMemberships {
    param(
        [AllowNull()]
        [object[]]$Groups
    )

    $groupRows = @(New-CloudGroupRows -Groups $Groups)
    if ($groupRows.Count -eq 0) {
        Write-UiBox -Title "Final Cloud Group Memberships" -Lines @("None")
        return
    }

    Write-UiBox -Title "Final Cloud Group Memberships" -Lines (ConvertTo-UiTableLines -Rows $groupRows -Columns @("Number", "DisplayName", "Management", "DirectorySource", "GroupTypes"))
}

function Write-FinalMailboxPermissionChanges {
    $rows = @($script:NewUserMailboxPermissionChanges | Where-Object { $_ })
    if ($rows.Count -eq 0) {
        return
    }

    Write-UiBox -Title "Mailbox Permission Changes" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("MailboxDisplayName", "Mailbox", "MailboxType", "Permission", "Delegate", "Result"))
}

function Get-FinalNewUserIssueRows {
    $rows = @()

    foreach ($result in @($script:UiStepResults | Where-Object { $_ })) {
        if ([string]$result.Result -notin @("Failed", "Aborted", "Stopped")) {
            continue
        }

        $rows += [pscustomobject]@{
            Time   = $result.Time
            Result = $result.Result
            Source = $result.Name
            Target = if ($result.Step) { "Step $($result.Step)" } else { "" }
            Detail = $result.Note
        }
    }

    foreach ($issue in @($script:NewUserRunIssues | Where-Object { $_ })) {
        $rows += [pscustomobject]@{
            Time   = $issue.Time
            Result = $issue.Result
            Source = $issue.Source
            Target = $issue.Target
            Detail = $issue.Detail
        }
    }

    $uniqueRows = @()
    $seen = @{}
    foreach ($row in @($rows | Where-Object { $_ })) {
        $key = "{0}|{1}|{2}|{3}" -f $row.Result, $row.Source, $row.Target, $row.Detail
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $uniqueRows += $row
    }

    return @($uniqueRows)
}

function Write-FinalNewUserIssues {
    $rows = @(Get-FinalNewUserIssueRows)
    if ($rows.Count -eq 0) {
        return
    }

    Write-UiBox -Title "Issues Needing Review" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Time", "Result", "Source", "Target", "Detail"))
}

function Write-UiFinalNewUserSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Subtitle = "",

        [string]$ErrorMessage = ""
    )

    Write-UiHeader -Title $Title -Subtitle $Subtitle
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Write-UiStatus -Status "FAIL" -Message $ErrorMessage -Color Red
    }

    if ($script:RunContext -and $script:RunContext["NewUserObjectGuid"]) {
        try {
            Show-AdUserState -Identity $script:RunContext["NewUserObjectGuid"] -Title "Final AD User State"
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh final AD user state: $($_.Exception.Message)" -Color Yellow
        }
    }

    if ($script:RunContext -and $script:RunContext["CloudUserId"]) {
        $cloudUserId = [string]$script:RunContext["CloudUserId"]
        $cloudUser = $null
        try {
            $select = Get-CloudUserStateAttributeSelect
            $uri = Get-GraphUserUri -UserIdOrUpn $cloudUserId -Select $select
            $cloudUser = Invoke-MgGraphRequest -Method GET -Uri $uri
            Format-CloudUserState -CloudUser $cloudUser -Source "final cloud user state"
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh final cloud user state: $($_.Exception.Message)" -Color Yellow
        }

        try {
            $licenseSnapshot = Get-CloudUserLicenseSnapshot -UserIdOrUpn $cloudUserId
            Write-FinalAssignedLicenses -Snapshot $licenseSnapshot
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh final assigned licenses: $($_.Exception.Message)" -Color Yellow
        }

        try {
            $groupCloudUser = $cloudUser
            if (-not $groupCloudUser) {
                $groupCloudUser = [pscustomobject]@{ id = $cloudUserId }
            }

            $cloudGroups = @(Get-CloudUserGroups -CloudUser $groupCloudUser)
            Write-FinalCloudGroupMemberships -Groups $cloudGroups
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not refresh final cloud group memberships: $($_.Exception.Message)" -Color Yellow
        }
    }

    Write-FinalMailboxPermissionChanges
    Write-FinalNewUserIssues

    Write-UiStepSummary
    Write-UiActionLog
}

try {
    Invoke-Main
}
catch {
    Write-UiFinalNewUserSummary `
        -Title "New User Run Stopped" `
        -Subtitle "Review the summary before rerunning or resuming manually." `
        -ErrorMessage $_.Exception.Message
}
