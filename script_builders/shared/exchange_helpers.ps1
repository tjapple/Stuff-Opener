function Get-MailboxDetailsAndStats {
    # Returns custom object with Mailbox and Statistics
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Alias("s")]
        [switch]$Silent,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    $attempts = [Math]::Max(1, $PollAttempts)
    $mailbox = $null
    $stats = $null
    $lastError = $null

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if ($attempts -gt 1) {
            Write-UiStatus -Status "POLL" -Message "Loading mailbox snapshot for '$UserPrincipalName' (attempt $attempt of $attempts)." -Color Cyan
        }
        else {
            Write-UiStatus -Status "LOADING..." -Message "Loading mailbox snapshot for '$UserPrincipalName'." -Color Cyan
        }

        try {
            $mailbox = Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop
            $stats = Get-MailboxStatistics -Identity $UserPrincipalName -ErrorAction Stop
            break
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -ge $attempts) {
                break
            }

            Write-UiStatus -Status "WAIT" -Message "Mailbox is not available yet: $lastError" -Color Yellow
            Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        }
    }

    if (-not $mailbox -or -not $stats) {
        throw "Mailbox '$UserPrincipalName' was not available after $attempts attempt(s). Last error: $lastError"
    }

    Write-UiStatus -Status "OK" -Message "Loaded mailbox snapshot for '$UserPrincipalName'." -Color Green

    if (-not $Silent) {
        Write-UiBox -Title "Mailbox Snapshot" -Lines @(
            New-UiBoxLine -Label "Identity" -Value $UserPrincipalName
            New-UiBoxLine -Label "Mailbox type" -Value $mailbox.RecipientTypeDetails
            New-UiBoxLine -Label "Hidden from GAL" -Value $mailbox.HiddenFromAddressListsEnabled
            New-UiBoxLine -Label "SentAs copy" -Value $mailbox.MessageCopyForSentAsEnabled
            New-UiBoxLine -Label "SendOnBehalf copy" -Value $mailbox.MessageCopyForSendOnBehalfEnabled
            New-UiBoxLine -Label "Mailbox size" -Value $stats.TotalItemSize
            New-UiBoxLine -Label "Item count" -Value $stats.ItemCount
            New-UiBoxLine -Label "Archive status" -Value $mailbox.ArchiveStatus
            New-UiBoxLine -Label "Archive state" -Value $mailbox.ArchiveState
        )
    }

    return [pscustomobject]@{
        Mailbox    = $mailbox
        Statistics = $stats
    }
}

function ConvertTo-ExchangeNumberSelection {
    param(
        [string]$InputText,
        [int]$Max
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return @()
    }

    $numbers = @()
    $parts = @($InputText -split "[,\s;]+" | Where-Object { $_ })
    if ($parts.Count -eq 0) {
        return @()
    }

    foreach ($part in $parts) {
        if ($part -notmatch "^\d+$") {
            return @()
        }

        $number = [int]$part
        if ($number -lt 1 -or $number -gt $Max) {
            return @()
        }

        if ($numbers -notcontains $number) {
            $numbers += $number
        }
    }

    return $numbers
}

function Test-ExchangeMailboxArchiveEnabled {
    param(
        [Parameter(Mandatory = $true)]
        $Mailbox
    )

    return ([string]$Mailbox.ArchiveStatus -in @("Active", "Enabled")) -or ([string]$Mailbox.ArchiveState -notin @("", "None", "Disabled"))
}

function Resolve-MailboxDelegateDisplayIdentity {
    param(
        [AllowNull()]
        $Identity
    )

    $identityText = [string]$Identity
    if ([string]::IsNullOrWhiteSpace($identityText)) {
        return [pscustomobject]@{
            DisplayName = ""
            Principal   = ""
        }
    }

    if ($Identity.PrimarySmtpAddress) {
        $identityText = [string]$Identity.PrimarySmtpAddress
    }
    elseif ($Identity.UserPrincipalName) {
        $identityText = [string]$Identity.UserPrincipalName
    }
    elseif ($Identity.ExternalDirectoryObjectId) {
        $identityText = [string]$Identity.ExternalDirectoryObjectId
    }
    elseif ($Identity.Guid) {
        $identityText = [string]$Identity.Guid
    }

    $display = ""
    $principal = ""
    try {
        $recipient = Get-Recipient -Identity $identityText -ErrorAction Stop
        if ($recipient.DisplayName) {
            $display = [string]$recipient.DisplayName
        }
        elseif ($recipient.Name) {
            $display = [string]$recipient.Name
        }

        if ($recipient.PrimarySmtpAddress) {
            $principal = [string]$recipient.PrimarySmtpAddress
        }
        elseif ($recipient.WindowsEmailAddress) {
            $principal = [string]$recipient.WindowsEmailAddress
        }
        elseif ($recipient.UserPrincipalName) {
            $principal = [string]$recipient.UserPrincipalName
        }
        elseif ($recipient.ExternalDirectoryObjectId) {
            $principal = [string]$recipient.ExternalDirectoryObjectId
        }
    }
    catch {
        if ($Identity.DisplayName) {
            $display = [string]$Identity.DisplayName
        }
        elseif ($Identity.Name) {
            $display = [string]$Identity.Name
        }

        if ($Identity.PrimarySmtpAddress) {
            $principal = [string]$Identity.PrimarySmtpAddress
        }
        elseif ($Identity.WindowsEmailAddress) {
            $principal = [string]$Identity.WindowsEmailAddress
        }
        elseif ($Identity.UserPrincipalName) {
            $principal = [string]$Identity.UserPrincipalName
        }
    }

    if ([string]::IsNullOrWhiteSpace($principal)) {
        $principal = $identityText
    }
    if ([string]::IsNullOrWhiteSpace($display)) {
        $display = $principal
    }

    return [pscustomobject]@{
        DisplayName = $display
        Principal   = $principal
    }
}

function New-MailboxDelegateRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PermissionLevel,

        [AllowNull()]
        $DisplayName,

        [AllowNull()]
        $Principal,

        [AllowNull()]
        $RawObject
    )

    $display = [string]$DisplayName
    $principalText = [string]$Principal
    if ([string]::IsNullOrWhiteSpace($display)) {
        $display = $principalText
    }
    if ([string]::IsNullOrWhiteSpace($principalText)) {
        $principalText = $display
    }

    return [pscustomobject]@{
        PermissionLevel = $PermissionLevel
        DisplayName     = $display
        Principal       = $principalText
        RawObject       = $RawObject
    }
}

function Get-MailboxDelegateSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        $Mailbox
    )

    $fullAccessRows = @()
    try {
        $fullAccessRows = @(
            Get-MailboxPermission -Identity $UserPrincipalName -ErrorAction Stop |
                Where-Object {
                    ($_.AccessRights -contains "FullAccess") -and
                    ($_.IsInherited -ne $true) -and
                    ($_.Deny -ne $true) -and
                    ([string]$_.User -notmatch "^(NT AUTHORITY\\SELF|S-1-5-)")
                } |
                ForEach-Object {
                    $identity = Resolve-MailboxDelegateDisplayIdentity -Identity $_.User
                    New-MailboxDelegateRow -PermissionLevel "Full Access" -DisplayName $identity.DisplayName -Principal $identity.Principal -RawObject $_
                }
        )
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not query Full Access delegates: $($_.Exception.Message)" -Color Yellow
    }

    $sendAsRows = @()
    try {
        $sendAsRows = @(
            Get-RecipientPermission -Identity $UserPrincipalName -ErrorAction Stop |
                Where-Object {
                    ($_.AccessRights -contains "SendAs") -and
                    ($_.IsInherited -ne $true) -and
                    ([string]$_.Trustee -notmatch "^(NT AUTHORITY\\SELF|S-1-5-)")
                } |
                ForEach-Object {
                    $identity = Resolve-MailboxDelegateDisplayIdentity -Identity $_.Trustee
                    New-MailboxDelegateRow -PermissionLevel "Send As" -DisplayName $identity.DisplayName -Principal $identity.Principal -RawObject $_
                }
        )
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not query Send As delegates: $($_.Exception.Message)" -Color Yellow
    }

    $sendOnBehalfRows = @(
        @($Mailbox.GrantSendOnBehalfTo | Where-Object { $_ }) |
            ForEach-Object {
                $identity = Resolve-MailboxDelegateDisplayIdentity -Identity $_
                New-MailboxDelegateRow -PermissionLevel "Send on Behalf" -DisplayName $identity.DisplayName -Principal $identity.Principal -RawObject $_
            }
    )

    return [pscustomobject]@{
        FullAccess     = $fullAccessRows
        SendAs         = $sendAsRows
        SendOnBehalf   = $sendOnBehalfRows
        AllDelegates   = @($fullAccessRows + $sendAsRows + $sendOnBehalfRows)
    }
}

function Get-MailboxManagementSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    $mailboxDetails = Get-MailboxDetailsAndStats -UserPrincipalName $UserPrincipalName -Silent -PollSeconds $PollSeconds -PollAttempts $PollAttempts
    $delegateSnapshot = Get-MailboxDelegateSnapshot -UserPrincipalName $UserPrincipalName -Mailbox $mailboxDetails.Mailbox

    return [pscustomobject]@{
        UserPrincipalName = $UserPrincipalName
        Mailbox           = $mailboxDetails.Mailbox
        Statistics        = $mailboxDetails.Statistics
        Delegates         = $delegateSnapshot
    }
}

function Write-MailboxManagementSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $mailbox = $Snapshot.Mailbox
    $stats = $Snapshot.Statistics
    $archiveEnabled = Test-ExchangeMailboxArchiveEnabled -Mailbox $mailbox

    Write-UiBox -Title "Mailbox Snapshot" -Lines @(
        New-UiBoxLine -Label "Identity" -Value $Snapshot.UserPrincipalName
        New-UiBoxLine -Label "DisplayName" -Value $mailbox.DisplayName
        New-UiBoxLine -Label "PrimarySmtpAddress" -Value $mailbox.PrimarySmtpAddress
        New-UiBoxLine -Label "Mailbox type" -Value $mailbox.RecipientTypeDetails
        New-UiBoxLine -Label "Hidden from GAL" -Value $mailbox.HiddenFromAddressListsEnabled
        New-UiBoxLine -Label "SentAs copy" -Value $mailbox.MessageCopyForSentAsEnabled
        New-UiBoxLine -Label "SendOnBehalf copy" -Value $mailbox.MessageCopyForSendOnBehalfEnabled
        New-UiBoxLine -Label "Archive enabled" -Value $archiveEnabled
        New-UiBoxLine -Label "Archive status" -Value $mailbox.ArchiveStatus
        New-UiBoxLine -Label "Archive state" -Value $mailbox.ArchiveState
        New-UiBoxLine -Label "Mailbox size" -Value $stats.TotalItemSize
        New-UiBoxLine -Label "Item count" -Value $stats.ItemCount
    )
}

function Write-MailboxDelegateSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $delegates = $Snapshot.Delegates
    $fullAccessRows = @(New-MailboxManagerNumberedRows -Rows $delegates.FullAccess)
    $sendAsRows = @(New-MailboxManagerNumberedRows -Rows $delegates.SendAs)
    $sendOnBehalfRows = @(New-MailboxManagerNumberedRows -Rows $delegates.SendOnBehalf)

    Write-UiBox -Title "Full Access Delegates" -Lines (ConvertTo-UiTableLines -Rows $fullAccessRows -Columns @("Number", "DisplayName", "Principal"))
    Write-UiBox -Title "Send As Delegates" -Lines (ConvertTo-UiTableLines -Rows $sendAsRows -Columns @("Number", "DisplayName", "Principal"))
    Write-UiBox -Title "Send on Behalf Delegates" -Lines (ConvertTo-UiTableLines -Rows $sendOnBehalfRows -Columns @("Number", "DisplayName", "Principal"))
}

function New-MailboxManagerNumberedRows {
    param(
        [AllowNull()]
        [object[]]$Rows
    )

    $numberedRows = @()
    $cleanRows = @($Rows | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanRows.Count; $i++) {
        $row = $cleanRows[$i]
        $numberedRows += [pscustomobject]@{
            Number          = $i + 1
            PermissionLevel = $row.PermissionLevel
            DisplayName     = $row.DisplayName
            Principal       = $row.Principal
            RawObject       = $row.RawObject
        }
    }

    return $numberedRows
}

function Resolve-MailboxPermissionLevel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText
    )

    switch ($InputText) {
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

function Get-MailboxDelegateRowsForPermission {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot,

        [Parameter(Mandatory = $true)]
        [string]$PermissionLevel
    )

    switch ($PermissionLevel) {
        "FullAccess" { return @($Snapshot.Delegates.FullAccess) }
        "SendAs" { return @($Snapshot.Delegates.SendAs) }
        "SendOnBehalf" { return @($Snapshot.Delegates.SendOnBehalf) }
        default { return @() }
    }
}

function Show-MailboxDelegateSearchMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Matches
    )

    $rows = @()
    $cleanMatches = @($Matches | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanMatches.Count; $i++) {
        $match = $cleanMatches[$i]
        $rows += [pscustomobject]@{
            Number            = $i + 1
            DisplayName       = $match.displayName
            UserPrincipalName = $match.userPrincipalName
            Mail              = $match.mail
            DirectorySource   = if ($match.onPremisesSyncEnabled -eq $true) { "On-prem synced" } else { "Cloud-only" }
        }
    }

    Write-UiBox -Title "Delegate Search Results" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "DisplayName", "UserPrincipalName", "Mail", "DirectorySource"))
}

function Resolve-MailboxDelegateUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup
    )

    $select = Get-CloudUserStateAttributeSelect
    $matches = @(Find-ActiveCloudUsersByLookup -Lookup $Lookup -Select $select)
    if ($matches.Count -eq 0) {
        Write-UiStatus -Status "WARN" -Message "No active cloud users matched '$Lookup'." -Color Yellow
        return $null
    }

    if ($matches.Count -eq 1) {
        Format-CloudUserState -CloudUser $matches[0] -Source "delegate lookup"
        return $matches[0]
    }

    Show-MailboxDelegateSearchMatches -Matches $matches
    while ($true) {
        $selection = Read-UiInput -Prompt "Choose delegate user" -Options @("number", "blank=cancel")
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return $null
        }

        $numbers = ConvertTo-ExchangeNumberSelection -InputText $selection -Max $matches.Count
        if ($numbers.Count -eq 1) {
            Format-CloudUserState -CloudUser $matches[$numbers[0] - 1] -Source "selected delegate"
            return $matches[$numbers[0] - 1]
        }

        Write-UiStatus -Status "INFO" -Message "Enter exactly one delegate number from the list." -Color Yellow
    }
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

    $delegateIdentity = [string]$DelegateUser.userPrincipalName
    if ([string]::IsNullOrWhiteSpace($delegateIdentity)) {
        $delegateIdentity = [string]$DelegateUser.mail
    }
    if ([string]::IsNullOrWhiteSpace($delegateIdentity)) {
        $delegateIdentity = [string]$DelegateUser.id
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

function Invoke-MailboxDelegateRemove {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        [string]$PermissionLevel,

        [Parameter(Mandatory = $true)]
        [object[]]$DelegateRows
    )

    $label = Get-MailboxPermissionLevelLabel -PermissionLevel $PermissionLevel
    foreach ($delegate in @($DelegateRows | Where-Object { $_ })) {
        $delegatePrincipal = [string]$delegate.Principal
        $commandPreview = switch ($PermissionLevel) {
            "FullAccess" { "Remove-MailboxPermission -Identity '$UserPrincipalName' -User '$delegatePrincipal' -AccessRights FullAccess -InheritanceType All -Confirm:`$false" }
            "SendAs" { "Remove-RecipientPermission -Identity '$UserPrincipalName' -Trustee '$delegatePrincipal' -AccessRights SendAs -Confirm:`$false" }
            "SendOnBehalf" { "Set-Mailbox -Identity '$UserPrincipalName' -GrantSendOnBehalfTo @{ Remove = '$delegatePrincipal' }" }
            default { throw "Unsupported mailbox permission level '$PermissionLevel'." }
        }

        Invoke-UiCommand -Name "Remove $label mailbox delegate" -CommandPreview $commandPreview -Command {
            switch ($PermissionLevel) {
                "FullAccess" {
                    Remove-MailboxPermission -Identity $UserPrincipalName -User $delegatePrincipal -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop | Out-Null
                }
                "SendAs" {
                    Remove-RecipientPermission -Identity $UserPrincipalName -Trustee $delegatePrincipal -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
                }
                "SendOnBehalf" {
                    Set-Mailbox -Identity $UserPrincipalName -GrantSendOnBehalfTo @{ Remove = $delegatePrincipal } -ErrorAction Stop
                }
            }
        }
    }

    if (Test-UiDryRun) {
        Add-UiStepResult -Name "Manage mailbox delegates" -Result "Dry run" -Note "Would remove $($DelegateRows.Count) $label delegate(s)."
    }
    else {
        Write-UiStatus -Status "OK" -Message "Removed $($DelegateRows.Count) $label delegate(s) from '$UserPrincipalName'." -Color Green
        Add-UiStepResult -Name "Manage mailbox delegates" -Result "Completed" -Note "Removed $($DelegateRows.Count) $label delegate(s)."
    }
}

function Invoke-InteractiveMailboxDelegateManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    Write-MailboxSnapshotFreshnessNote

    while ($true) {
        $snapshot = Get-MailboxManagementSnapshot -UserPrincipalName $UserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
        Write-MailboxDelegateSnapshot -Snapshot $snapshot

        $choice = Read-UiInput -Prompt "Manage mailbox delegates?" -Options @("a=add", "r=remove", "q=query mailbox state", "x=abort")
        if ($choice -eq "x") {
            return
        }
        if ($choice -eq "q") {
            Write-MailboxManagementSnapshot -Snapshot $snapshot
            continue
        }
        if ($choice -eq "a") {
            Invoke-MailboxDelegateAddFlow -UserPrincipalName $UserPrincipalName -Snapshot $snapshot -PollSeconds $PollSeconds -PollAttempts $PollAttempts
            continue
        }
        if ($choice -eq "r") {
            Invoke-MailboxDelegateRemoveFlow -UserPrincipalName $UserPrincipalName -Snapshot $snapshot -PollSeconds $PollSeconds -PollAttempts $PollAttempts
            continue
        }

        Write-UiStatus -Status "INFO" -Message "Enter exact lowercase a, r, q, or x." -Color Yellow
    }
}

function Invoke-MailboxDelegateAddFlow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        $Snapshot,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    while ($true) {
        $permissionInput = Read-UiInput -Prompt "Permission level to add?" -Options @("f=Full Access", "s=Send As", "b=Send on Behalf", "q=query mailbox state", "x=cancel")
        if ($permissionInput -eq "x") {
            return
        }
        if ($permissionInput -eq "q") {
            $currentSnapshot = Get-MailboxManagementSnapshot -UserPrincipalName $UserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
            Write-MailboxManagementSnapshot -Snapshot $currentSnapshot
            continue
        }

        $permissionLevel = Resolve-MailboxPermissionLevel -InputText $permissionInput
        if ([string]::IsNullOrWhiteSpace($permissionLevel)) {
            Write-UiStatus -Status "INFO" -Message "Enter exact f, s, b, q, or x." -Color Yellow
            continue
        }

        while ($true) {
            $lookup = Read-UiInput -Prompt "Delegate lookup" -Options @("UPN/name/email", "q=query mailbox state", "blank=cancel")
            if ([string]::IsNullOrWhiteSpace($lookup)) {
                return
            }
            if ($lookup -eq "q") {
                $currentSnapshot = Get-MailboxManagementSnapshot -UserPrincipalName $UserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
                Write-MailboxManagementSnapshot -Snapshot $currentSnapshot
                continue
            }

            $delegateUser = Resolve-MailboxDelegateUser -Lookup $lookup
            if (-not $delegateUser) {
                continue
            }

            $label = Get-MailboxPermissionLevelLabel -PermissionLevel $permissionLevel
            $delegateIdentity = if ($delegateUser.userPrincipalName) { $delegateUser.userPrincipalName } elseif ($delegateUser.mail) { $delegateUser.mail } else { $delegateUser.id }
            Write-UiBox -Title "Delegate Add Plan" -Lines @(
                New-UiBoxLine -Label "Mailbox" -Value $UserPrincipalName
                New-UiBoxLine -Label "Permission" -Value $label
                New-UiBoxLine -Label "Delegate" -Value $delegateIdentity
            )

            if (-not (Read-UiYesNo -Prompt "Add this mailbox delegate?" -DefaultYes $false)) {
                Write-UiStatus -Status "SKIP" -Message "Skipped delegate assignment." -Color Yellow
                return
            }

            try {
                Invoke-MailboxDelegateAdd -UserPrincipalName $UserPrincipalName -PermissionLevel $permissionLevel -DelegateUser $delegateUser
            }
            catch {
                Write-UiStatus -Status "WARN" -Message "Could not add mailbox delegate: $($_.Exception.Message)" -Color Yellow
                Add-UiStepResult -Name "Manage mailbox delegates" -Result "Failed" -Note $_.Exception.Message
            }
            return
        }
    }
}

function Invoke-MailboxDelegateRemoveFlow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        $Snapshot,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    while ($true) {
        $permissionInput = Read-UiInput -Prompt "Permission level to remove?" -Options @("f=Full Access", "s=Send As", "b=Send on Behalf", "q=query mailbox state", "x=cancel")
        if ($permissionInput -eq "x") {
            return
        }
        if ($permissionInput -eq "q") {
            $currentSnapshot = Get-MailboxManagementSnapshot -UserPrincipalName $UserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
            Write-MailboxManagementSnapshot -Snapshot $currentSnapshot
            continue
        }

        $permissionLevel = Resolve-MailboxPermissionLevel -InputText $permissionInput
        if ([string]::IsNullOrWhiteSpace($permissionLevel)) {
            Write-UiStatus -Status "INFO" -Message "Enter exact f, s, b, q, or x." -Color Yellow
            continue
        }

        $rows = @(New-MailboxManagerNumberedRows -Rows (Get-MailboxDelegateRowsForPermission -Snapshot $Snapshot -PermissionLevel $permissionLevel))
        $label = Get-MailboxPermissionLevelLabel -PermissionLevel $permissionLevel
        if ($rows.Count -eq 0) {
            Write-UiStatus -Status "INFO" -Message "No $label delegates are assigned." -Color Yellow
            return
        }

        Write-UiBox -Title "$label Delegates" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "DisplayName", "Principal"))
        while ($true) {
            $selection = Read-UiInput -Prompt "Select delegates to remove" -Options @("comma separated numbers", "q=query mailbox state", "blank=cancel")
            if ([string]::IsNullOrWhiteSpace($selection)) {
                return
            }
            if ($selection -eq "q") {
                $currentSnapshot = Get-MailboxManagementSnapshot -UserPrincipalName $UserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
                Write-MailboxManagementSnapshot -Snapshot $currentSnapshot
                continue
            }

            $numbers = ConvertTo-ExchangeNumberSelection -InputText $selection -Max $rows.Count
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "Enter valid delegate numbers from the list." -Color Yellow
                continue
            }

            $selectedRows = @($numbers | ForEach-Object { $rows[$_ - 1] })
            Write-UiBox -Title "Delegates To Remove" -Lines (ConvertTo-UiTableLines -Rows $selectedRows -Columns @("PermissionLevel", "DisplayName", "Principal"))
            if (-not (Read-UiYesNo -Prompt "Remove selected mailbox delegates?" -DefaultYes $false)) {
                Write-UiStatus -Status "SKIP" -Message "Skipped delegate removal." -Color Yellow
                return
            }

            try {
                Invoke-MailboxDelegateRemove -UserPrincipalName $UserPrincipalName -PermissionLevel $permissionLevel -DelegateRows $selectedRows
            }
            catch {
                Write-UiStatus -Status "WARN" -Message "Could not remove mailbox delegate(s): $($_.Exception.Message)" -Color Yellow
                Add-UiStepResult -Name "Manage mailbox delegates" -Result "Failed" -Note $_.Exception.Message
            }
            return
        }
    }
}

function Write-MailboxPropertyMenuSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $mailbox = $Snapshot.Mailbox
    $archiveEnabled = Test-ExchangeMailboxArchiveEnabled -Mailbox $mailbox
    Write-UiBox -Title "Mailbox Properties" -Lines @(
        New-UiBoxLine -Label "Mailbox" -Value $Snapshot.UserPrincipalName
        New-UiBoxLine -Label "Mailbox type" -Value $mailbox.RecipientTypeDetails
        New-UiBoxLine -Label "Hidden from GAL" -Value $mailbox.HiddenFromAddressListsEnabled
        New-UiBoxLine -Label "SentAs copy" -Value $mailbox.MessageCopyForSentAsEnabled
        New-UiBoxLine -Label "SendOnBehalf copy" -Value $mailbox.MessageCopyForSendOnBehalfEnabled
        New-UiBoxLine -Label "Archive enabled" -Value $archiveEnabled
        New-UiBoxLine -Label "Archive status" -Value $mailbox.ArchiveStatus
        New-UiBoxLine -Label "Archive state" -Value $mailbox.ArchiveState
    )
}

function Write-MailboxSnapshotFreshnessNote {
    if ($script:MailboxSnapshotFreshnessNoteShown) {
        return
    }

    $script:MailboxSnapshotFreshnessNoteShown = $true
    Write-UiStatus -Status "INFO" -Message "Mailbox snapshots may load before Microsoft finishes reporting recent Exchange Online changes. Requery the object to verify updated properties." -Color Yellow
}

function Resolve-MailboxVerificationTiming {
    param(
        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    $attempts = if ($PollAttempts -gt 1) { $PollAttempts } else { 6 }
    $seconds = if ($PollSeconds -gt 0) { $PollSeconds } else { 5 }

    return [pscustomobject]@{
        Attempts = $attempts
        Seconds  = $seconds
    }
}

function Wait-MailboxTypeVerification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedRecipientTypeDetails,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    $timing = Resolve-MailboxVerificationTiming -PollSeconds $PollSeconds -PollAttempts $PollAttempts
    $lastMailbox = $null
    $lastValue = ""

    for ($attempt = 1; $attempt -le $timing.Attempts; $attempt++) {
        try {
            $mailbox = Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop
            $lastMailbox = $mailbox
            $lastValue = [string]$mailbox.RecipientTypeDetails

            if ($lastValue -eq $ExpectedRecipientTypeDetails) {
                Write-UiStatus -Status "VERIFIED" -Message "Mailbox type for '$UserPrincipalName' is '$ExpectedRecipientTypeDetails'." -Color Green
                return [pscustomobject]@{
                    Verified     = $true
                    Mailbox      = $mailbox
                    CurrentValue = $lastValue
                }
            }

            if ($attempt -lt $timing.Attempts) {
                Write-UiStatus -Status "WAIT" -Message "Exchange currently reports mailbox type '$lastValue'. Waiting for '$ExpectedRecipientTypeDetails' (attempt $attempt of $($timing.Attempts))." -Color Yellow
                Start-Sleep -Seconds $timing.Seconds
            }
        }
        catch {
            $lastValue = "Query failed: $($_.Exception.Message)"
            if ($attempt -lt $timing.Attempts) {
                Write-UiStatus -Status "WAIT" -Message "Could not verify mailbox type yet: $($_.Exception.Message)" -Color Yellow
                Start-Sleep -Seconds $timing.Seconds
            }
        }
    }

    Write-UiStatus -Status "WARN" -Message "Exchange accepted the mailbox type change, but the latest query still reports '$lastValue' instead of '$ExpectedRecipientTypeDetails'. Requery later to verify." -Color Yellow
    return [pscustomobject]@{
        Verified     = $false
        Mailbox      = $lastMailbox
        CurrentValue = $lastValue
    }
}

function Wait-MailboxArchiveVerification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        [bool]$ExpectedEnabled,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    $timing = Resolve-MailboxVerificationTiming -PollSeconds $PollSeconds -PollAttempts $PollAttempts
    $expectedText = if ($ExpectedEnabled) { "enabled" } else { "disabled" }
    $lastMailbox = $null
    $lastValue = ""

    for ($attempt = 1; $attempt -le $timing.Attempts; $attempt++) {
        try {
            $mailbox = Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop
            $lastMailbox = $mailbox
            $currentEnabled = [bool](Test-ExchangeMailboxArchiveEnabled -Mailbox $mailbox)
            $lastValue = "Enabled=$currentEnabled; ArchiveStatus=$($mailbox.ArchiveStatus); ArchiveState=$($mailbox.ArchiveState)"

            if ($currentEnabled -eq $ExpectedEnabled) {
                Write-UiStatus -Status "VERIFIED" -Message "Archive is $expectedText for '$UserPrincipalName' ($lastValue)." -Color Green
                return [pscustomobject]@{
                    Verified     = $true
                    Mailbox      = $mailbox
                    CurrentValue = $lastValue
                }
            }

            if ($attempt -lt $timing.Attempts) {
                Write-UiStatus -Status "WAIT" -Message "Exchange currently reports archive state '$lastValue'. Waiting for archive to be $expectedText (attempt $attempt of $($timing.Attempts))." -Color Yellow
                Start-Sleep -Seconds $timing.Seconds
            }
        }
        catch {
            $lastValue = "Query failed: $($_.Exception.Message)"
            if ($attempt -lt $timing.Attempts) {
                Write-UiStatus -Status "WAIT" -Message "Could not verify archive state yet: $($_.Exception.Message)" -Color Yellow
                Start-Sleep -Seconds $timing.Seconds
            }
        }
    }

    Write-UiStatus -Status "WARN" -Message "Exchange accepted the archive change, but the latest query still reports '$lastValue'. Requery later to verify." -Color Yellow
    return [pscustomobject]@{
        Verified     = $false
        Mailbox      = $lastMailbox
        CurrentValue = $lastValue
    }
}
function Invoke-MailboxPropertyChange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        $Snapshot,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    $mailbox = $Snapshot.Mailbox
    switch ($Action) {
        "gal" {
            $newValue = -not [bool]$mailbox.HiddenFromAddressListsEnabled
            $stateText = if ($newValue) { "hide from GAL" } else { "show in GAL" }
            if (Read-UiYesNo -Prompt "Set mailbox to $stateText?" -DefaultYes $false) {
                Invoke-UiCommand -Name "Set mailbox GAL visibility" -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -HiddenFromAddressListsEnabled `$$($newValue.ToString().ToLowerInvariant())" -Command {
                    Set-Mailbox -Identity $UserPrincipalName -HiddenFromAddressListsEnabled $newValue -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Dry run" -Note "Would set HiddenFromAddressListsEnabled = $newValue."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Updated GAL visibility for '$UserPrincipalName'." -Color Green
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Completed" -Note "HiddenFromAddressListsEnabled = $newValue."
                }
            }
        }
        "sentascopy" {
            $newValue = -not [bool]$mailbox.MessageCopyForSentAsEnabled
            if (Read-UiYesNo -Prompt "Set Sent As copy to '$newValue'?" -DefaultYes $false) {
                Invoke-UiCommand -Name "Set mailbox Sent As copy" -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -MessageCopyForSentAsEnabled `$$($newValue.ToString().ToLowerInvariant())" -Command {
                    Set-Mailbox -Identity $UserPrincipalName -MessageCopyForSentAsEnabled $newValue -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Dry run" -Note "Would set MessageCopyForSentAsEnabled = $newValue."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Updated Sent As copy for '$UserPrincipalName'." -Color Green
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Completed" -Note "MessageCopyForSentAsEnabled = $newValue."
                }
            }
        }
        "sendonbehalfcopy" {
            $newValue = -not [bool]$mailbox.MessageCopyForSendOnBehalfEnabled
            if (Read-UiYesNo -Prompt "Set Send on Behalf copy to '$newValue'?" -DefaultYes $false) {
                Invoke-UiCommand -Name "Set mailbox Send on Behalf copy" -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -MessageCopyForSendOnBehalfEnabled `$$($newValue.ToString().ToLowerInvariant())" -Command {
                    Set-Mailbox -Identity $UserPrincipalName -MessageCopyForSendOnBehalfEnabled $newValue -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Dry run" -Note "Would set MessageCopyForSendOnBehalfEnabled = $newValue."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Updated Send on Behalf copy for '$UserPrincipalName'." -Color Green
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Completed" -Note "MessageCopyForSendOnBehalfEnabled = $newValue."
                }
            }
        }
        "type" {
            $newType = if ([string]$mailbox.RecipientTypeDetails -eq "SharedMailbox") { "Regular" } else { "Shared" }
            $expectedRecipientTypeDetails = if ($newType -eq "Shared") { "SharedMailbox" } else { "UserMailbox" }
            if (Read-UiYesNo -Prompt "Convert mailbox type to '$newType'?" -DefaultYes $false) {
                Invoke-UiCommand -Name "Set mailbox type" -CommandPreview "Set-Mailbox -Identity '$UserPrincipalName' -Type '$newType'" -Command {
                    Set-Mailbox -Identity $UserPrincipalName -Type $newType -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Dry run" -Note "Would set mailbox type = $newType."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Submitted mailbox type change for '$UserPrincipalName' to '$newType'." -Color Green
                    $verification = Wait-MailboxTypeVerification -UserPrincipalName $UserPrincipalName -ExpectedRecipientTypeDetails $expectedRecipientTypeDetails -PollSeconds $PollSeconds -PollAttempts $PollAttempts
                    if ($verification.Verified) {
                        Add-UiStepResult -Name "Manage mailbox properties" -Result "Completed" -Note "Mailbox type verified = $expectedRecipientTypeDetails."
                    }
                    else {
                        Add-UiStepResult -Name "Manage mailbox properties" -Result "Pending verification" -Note "Requested mailbox type = $expectedRecipientTypeDetails; latest report = $($verification.CurrentValue)."
                    }
                }
            }
        }
        "enablearchive" {
            if (Test-ExchangeMailboxArchiveEnabled -Mailbox $mailbox) {
                Write-UiStatus -Status "VERIFIED" -Message "Archive is already enabled for '$UserPrincipalName'." -Color Green
                return
            }
            if (Read-UiYesNo -Prompt "Enable archive mailbox?" -DefaultYes $false) {
                Invoke-UiCommand -Name "Enable mailbox archive" -CommandPreview "Enable-Mailbox -Identity '$UserPrincipalName' -Archive" -Command {
                    Enable-Mailbox -Identity $UserPrincipalName -Archive -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Dry run" -Note "Would enable archive."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Submitted archive enable for '$UserPrincipalName'." -Color Green
                    $verification = Wait-MailboxArchiveVerification -UserPrincipalName $UserPrincipalName -ExpectedEnabled $true -PollSeconds $PollSeconds -PollAttempts $PollAttempts
                    if ($verification.Verified) {
                        Add-UiStepResult -Name "Manage mailbox properties" -Result "Completed" -Note "Archive enabled and verified."
                    }
                    else {
                        Add-UiStepResult -Name "Manage mailbox properties" -Result "Pending verification" -Note "Requested archive enabled; latest report = $($verification.CurrentValue)."
                    }
                }
            }
        }
        "disablearchive" {
            if (-not (Test-ExchangeMailboxArchiveEnabled -Mailbox $mailbox)) {
                Write-UiStatus -Status "VERIFIED" -Message "Archive is already disabled for '$UserPrincipalName'." -Color Green
                return
            }
            Write-UiStatus -Status "WARN" -Message "Disabling an archive can affect access to archived mailbox data." -Color Yellow
            if (Read-UiYesNo -Prompt "Disable archive mailbox?" -DefaultYes $false) {
                Invoke-UiCommand -Name "Disable mailbox archive" -CommandPreview "Disable-Mailbox -Identity '$UserPrincipalName' -Archive -Confirm:`$false" -Command {
                    Disable-Mailbox -Identity $UserPrincipalName -Archive -Confirm:$false -ErrorAction Stop
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage mailbox properties" -Result "Dry run" -Note "Would disable archive."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Submitted archive disable for '$UserPrincipalName'." -Color Green
                    $verification = Wait-MailboxArchiveVerification -UserPrincipalName $UserPrincipalName -ExpectedEnabled $false -PollSeconds $PollSeconds -PollAttempts $PollAttempts
                    if ($verification.Verified) {
                        Add-UiStepResult -Name "Manage mailbox properties" -Result "Completed" -Note "Archive disabled and verified."
                    }
                    else {
                        Add-UiStepResult -Name "Manage mailbox properties" -Result "Pending verification" -Note "Requested archive disabled; latest report = $($verification.CurrentValue)."
                    }
                }
            }
        }
        default {
            throw "Unsupported mailbox property action '$Action'."
        }
    }
}

function Invoke-InteractiveMailboxPropertyManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    Write-MailboxSnapshotFreshnessNote

    while ($true) {
        $snapshot = Get-MailboxManagementSnapshot -UserPrincipalName $UserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
        Write-MailboxPropertyMenuSnapshot -Snapshot $snapshot

        $choice = Read-UiInput -Prompt "Manage mailbox properties?" -Options @("g=toggle GAL hidden", "sa=toggle SentAs copy", "sb=toggle SendOnBehalf copy", "t=toggle shared/user", "ea=enable archive", "da=disable archive", "q=query mailbox state", "x=abort")
        if ($choice -eq "x") {
            return
        }
        if ($choice -eq "q") {
            Write-MailboxManagementSnapshot -Snapshot $snapshot
            continue
        }

        $action = switch ($choice) {
            "g" { "gal"; break }
            "sa" { "sentascopy"; break }
            "sb" { "sendonbehalfcopy"; break }
            "t" { "type"; break }
            "ea" { "enablearchive"; break }
            "da" { "disablearchive"; break }
            default { "" }
        }

        if ([string]::IsNullOrWhiteSpace($action)) {
            Write-UiStatus -Status "INFO" -Message "Enter exact g, sa, sb, t, ea, da, q, or x." -Color Yellow
            continue
        }

        try {
            Invoke-MailboxPropertyChange -UserPrincipalName $UserPrincipalName -Snapshot $snapshot -Action $action -PollSeconds $PollSeconds -PollAttempts $PollAttempts
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not update mailbox property: $($_.Exception.Message)" -Color Yellow
            Add-UiStepResult -Name "Manage mailbox properties" -Result "Failed" -Note $_.Exception.Message
        }
    }
}

function Invoke-InteractiveMailboxManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [int]$PollSeconds = 0,

        [int]$PollAttempts = 1
    )

    Write-MailboxSnapshotFreshnessNote

    $currentUserPrincipalName = $UserPrincipalName
    $snapshot = $null
    while ($true) {
        try {
            $snapshot = Get-MailboxManagementSnapshot -UserPrincipalName $currentUserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not load mailbox '$currentUserPrincipalName': $($_.Exception.Message)" -Color Yellow
            $replacement = Read-UiInput -Prompt "Enter a different mailbox/user lookup" -Options @("UPN/email/identity", "x=abort")
            if ($replacement -eq "x") {
                return [pscustomobject]@{
                    Result   = "Aborted"
                    Snapshot = $snapshot
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($replacement)) {
                $currentUserPrincipalName = $replacement.Trim()
            }
            continue
        }

        Write-MailboxManagementSnapshot -Snapshot $snapshot

        $choice = Read-UiInput -Prompt "Manage mailbox?" -Options @("d=delegate management", "m=mailbox properties", "q=query mailbox state", "x=abort")
        if ($choice -eq "x") {
            return [pscustomobject]@{
                Result   = "Aborted"
                Snapshot = $snapshot
            }
        }
        if ($choice -eq "q") {
            continue
        }
        if ($choice -eq "d") {
            Invoke-InteractiveMailboxDelegateManager -UserPrincipalName $currentUserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
            continue
        }
        if ($choice -eq "m") {
            Invoke-InteractiveMailboxPropertyManager -UserPrincipalName $currentUserPrincipalName -PollSeconds $PollSeconds -PollAttempts $PollAttempts
            continue
        }

        Write-UiStatus -Status "INFO" -Message "Enter exact lowercase d, m, q, or x." -Color Yellow
    }
}

function Get-MailboxInboxRuleSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    Write-UiStatus -Status "LOADING..." -Message "Loading inbox rules for '$UserPrincipalName'." -Color Cyan
    try {
        $rules = @(Get-InboxRule -Mailbox $UserPrincipalName -IncludeHidden -ErrorAction Stop)
        Write-UiStatus -Status "OK" -Message "Loaded $($rules.Count) inbox rule(s), including hidden rules when available." -Color Green
        return $rules
    }
    catch {
        Write-UiStatus -Status "INFO" -Message "Could not query hidden inbox rules; retrying visible rules only: $($_.Exception.Message)" -Color Yellow
    }

    $visibleRules = @(Get-InboxRule -Mailbox $UserPrincipalName -ErrorAction Stop)
    Write-UiStatus -Status "OK" -Message "Loaded $($visibleRules.Count) visible inbox rule(s)." -Color Green
    return $visibleRules
}

function Get-MailboxInboxRuleModifiedValue {
    param(
        [AllowNull()]
        $Rule
    )

    if ($null -eq $Rule) {
        return $null
    }

    foreach ($propertyName in @("LastModifiedTime", "LastModifiedDateTime", "WhenChangedUTC", "WhenChanged", "ModifiedTime", "DateTimeModified")) {
        if ($Rule.PSObject.Properties.Name -notcontains $propertyName) {
            continue
        }

        $value = $Rule.$propertyName
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            continue
        }

        if ($value -is [datetime]) {
            return $value
        }

        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$value, [ref]$parsed)) {
            return $parsed
        }
    }

    return $null
}

function Format-MailboxInboxRuleModifiedValue {
    param(
        [AllowNull()]
        $Rule
    )

    $modified = Get-MailboxInboxRuleModifiedValue -Rule $Rule
    if ($null -eq $modified) {
        return "(unknown)"
    }

    return $modified.ToString("yyyy-MM-dd HH:mm")
}

function Test-MailboxInboxRuleModifiedSortAvailable {
    param(
        [AllowNull()]
        [object[]]$Rules
    )

    foreach ($rule in @($Rules | Where-Object { $_ })) {
        if ($null -ne (Get-MailboxInboxRuleModifiedValue -Rule $rule)) {
            return $true
        }
    }

    return $false
}

function Resolve-MailboxInboxRuleSortMode {
    param(
        [AllowNull()]
        [object[]]$Rules,

        [ValidateSet("Auto", "Modified", "Priority", "Name")]
        [string]$PreferredSort = "Auto"
    )

    $hasModified = Test-MailboxInboxRuleModifiedSortAvailable -Rules $Rules
    if ($PreferredSort -eq "Modified" -and -not $hasModified) {
        Write-UiStatus -Status "INFO" -Message "Rule modified time is not available in Get-InboxRule output; using priority order." -Color Yellow
        return "Priority"
    }

    if ($PreferredSort -eq "Auto") {
        if ($hasModified) {
            return "Modified"
        }
        return "Priority"
    }

    return $PreferredSort
}

function Sort-MailboxInboxRules {
    param(
        [AllowNull()]
        [object[]]$Rules,

        [ValidateSet("Modified", "Priority", "Name")]
        [string]$SortMode = "Priority"
    )

    $cleanRules = @($Rules | Where-Object { $_ })
    switch ($SortMode) {
        "Modified" {
            return @(
                $cleanRules |
                    Sort-Object `
                        @{ Expression = { $value = Get-MailboxInboxRuleModifiedValue -Rule $_; if ($null -eq $value) { [datetime]::MinValue } else { $value } }; Descending = $true },
                        @{ Expression = { $_.Priority }; Ascending = $true },
                        @{ Expression = { $_.Name }; Ascending = $true }
            )
        }
        "Name" {
            return @($cleanRules | Sort-Object Name,Priority)
        }
        default {
            return @($cleanRules | Sort-Object Priority,Name)
        }
    }
}

function Get-MailboxInboxRuleHiddenValue {
    param(
        [AllowNull()]
        $Rule
    )

    if ($null -eq $Rule) {
        return "(unknown)"
    }

    foreach ($propertyName in @("IsHidden", "Hidden")) {
        if ($Rule.PSObject.Properties.Name -contains $propertyName) {
            return $Rule.$propertyName
        }
    }

    return "(unknown)"
}

function Get-MailboxInboxRuleActionSummary {
    param(
        [AllowNull()]
        $Rule
    )

    if ($null -eq $Rule) {
        return "None"
    }

    $actions = @()
    foreach ($propertyName in @("ForwardTo", "ForwardAsAttachmentTo", "RedirectTo", "DeleteMessage", "MoveToFolder", "CopyToFolder", "MarkAsRead", "MarkImportance", "StopProcessingRules")) {
        if ($Rule.PSObject.Properties.Name -notcontains $propertyName) {
            continue
        }

        $value = $Rule.$propertyName
        if ($null -eq $value) {
            continue
        }

        $valueText = Format-UiBoxValue -Value $value
        if ([string]::IsNullOrWhiteSpace($valueText) -or $valueText -in @("(blank)", "None", "False")) {
            continue
        }

        $actions += ("{0}={1}" -f $propertyName, $valueText)
    }

    if ($actions.Count -eq 0) {
        return "None"
    }

    return ($actions -join "; ")
}

function New-MailboxInboxRuleRows {
    param(
        [AllowNull()]
        [object[]]$Rules
    )

    $rows = @()
    $cleanRules = @($Rules | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanRules.Count; $i++) {
        $rule = $cleanRules[$i]
        $rows += [pscustomobject]@{
            Number   = $i + 1
            Name     = $rule.Name
            Enabled  = $rule.Enabled
            Hidden   = Get-MailboxInboxRuleHiddenValue -Rule $rule
            Priority = $rule.Priority
            Modified = Format-MailboxInboxRuleModifiedValue -Rule $rule
            Actions  = Get-MailboxInboxRuleActionSummary -Rule $rule
            Identity = $rule.Identity
            RawRule  = $rule
        }
    }

    return $rows
}

function Write-MailboxInboxRuleSnapshot {
    param(
        [AllowNull()]
        [object[]]$Rules,

        [ValidateSet("Modified", "Priority", "Name")]
        [string]$SortMode = "Priority"
    )

    $rows = @(New-MailboxInboxRuleRows -Rules $Rules)
    $lines = @(
        New-UiBoxLine -Label "Sort" -Value $SortMode
        New-UiBoxLine -Label "Rule count" -Value $rows.Count
        ""
    )

    if ($rows.Count -eq 0) {
        $lines += "No inbox rules were returned."
    }
    else {
        $lines += ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "Name", "Enabled", "Hidden", "Priority", "Modified", "Actions")
    }

    Write-UiBox -Title "Mailbox Inbox Rules" -Lines $lines
}

function Write-MailboxInboxRuleDetails {
    param(
        [Parameter(Mandatory = $true)]
        $Rule
    )

    $lines = @(
        New-UiBoxLine -Label "Name" -Value $Rule.Name
        New-UiBoxLine -Label "Enabled" -Value $Rule.Enabled
        New-UiBoxLine -Label "Hidden" -Value (Get-MailboxInboxRuleHiddenValue -Rule $Rule)
        New-UiBoxLine -Label "Priority" -Value $Rule.Priority
        New-UiBoxLine -Label "Modified" -Value (Format-MailboxInboxRuleModifiedValue -Rule $Rule)
        New-UiBoxLine -Label "Identity" -Value $Rule.Identity
        New-UiBoxWrappedLine -Label "Action summary" -Value (Get-MailboxInboxRuleActionSummary -Rule $Rule)
        ""
    )

    foreach ($property in @($Rule.PSObject.Properties | Sort-Object Name)) {
        if ($property.Name -in @("Actions", "Description")) {
            $lines += New-UiBoxWrappedLine -Label $property.Name -Value $property.Value
        }
        else {
            $lines += New-UiBoxLine -Label $property.Name -Value $property.Value
        }
    }

    Write-UiBox -Title "Inbox Rule Details - $($Rule.Name)" -Lines $lines
}

function Invoke-InteractiveInboxRuleAudit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    $preferredSort = "Auto"

    while ($true) {
        try {
            $rules = @(Get-MailboxInboxRuleSnapshot -UserPrincipalName $UserPrincipalName)
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not load inbox rules for '$UserPrincipalName': $($_.Exception.Message)" -Color Yellow
            $retryChoice = Read-UiInput -Prompt "Mailbox rules" -Options @("q=try again", "c=continue")
            if ($retryChoice -eq "q") {
                continue
            }
            return [pscustomobject]@{
                Result = "Continue"
                Rules  = @()
            }
        }

        $sortMode = Resolve-MailboxInboxRuleSortMode -Rules $rules -PreferredSort $preferredSort
        $sortedRules = @(Sort-MailboxInboxRules -Rules $rules -SortMode $sortMode)
        Write-MailboxInboxRuleSnapshot -Rules $sortedRules -SortMode $sortMode

        $choice = Read-UiInput -Prompt "Inspect mailbox rules?" -Options @("d=details", "r=disable rules", "s=sort", "q=query again", "c=continue")
        if ($choice -eq "c") {
            return [pscustomobject]@{
                Result = "Continue"
                Rules  = $sortedRules
            }
        }
        if ($choice -eq "q") {
            continue
        }
        if ($choice -eq "s") {
            $sortInput = Read-UiInput -Prompt "Sort rules by" -Options @("m=modified", "p=priority", "n=name", "c=continue")
            switch ($sortInput) {
                "m" { $preferredSort = "Modified" }
                "p" { $preferredSort = "Priority" }
                "n" { $preferredSort = "Name" }
                "c" { }
                default {
                    Write-UiStatus -Status "INFO" -Message "Enter exact m, p, n, or c." -Color Yellow
                }
            }
            continue
        }
        if ($choice -eq "d") {
            $selection = Read-UiInput -Prompt "Enter rule number for details" -Options @("number", "blank=cancel")
            if ([string]::IsNullOrWhiteSpace($selection)) {
                continue
            }

            $numbers = ConvertTo-ExchangeNumberSelection -InputText $selection -Max $sortedRules.Count
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "Enter valid rule number(s)." -Color Yellow
                continue
            }

            foreach ($number in $numbers) {
                Write-MailboxInboxRuleDetails -Rule $sortedRules[$number - 1]
            }
            continue
        }
        if ($choice -eq "r") {
            $rows = @(New-MailboxInboxRuleRows -Rules $sortedRules)
            $enabledRows = @($rows | Where-Object { $_.Enabled -eq $true })
            if ($enabledRows.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No enabled inbox rules are available to disable." -Color Yellow
                continue
            }

            Write-UiBox -Title "Enabled Inbox Rules" -Lines (ConvertTo-UiTableLines -Rows $enabledRows -Columns @("Number", "Name", "Priority", "Modified", "Actions"))
            $selection = Read-UiInput -Prompt "Enter rule numbers to disable" -Options @("comma separated", "blank=cancel")
            if ([string]::IsNullOrWhiteSpace($selection)) {
                continue
            }

            $numbers = ConvertTo-ExchangeNumberSelection -InputText $selection -Max $sortedRules.Count
            if ($numbers.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "Enter valid rule numbers from the current rule list." -Color Yellow
                continue
            }

            $rulesToDisable = @($numbers | ForEach-Object { $sortedRules[$_ - 1] } | Where-Object { $_ -and $_.Enabled -eq $true })
            if ($rulesToDisable.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No enabled rules were selected." -Color Yellow
                continue
            }

            Write-UiBox -Title "Inbox Rules To Disable" -Lines (ConvertTo-UiTableLines -Rows (New-MailboxInboxRuleRows -Rules $rulesToDisable) -Columns @("Number", "Name", "Priority", "Modified", "Actions")) -Color Yellow
            if (-not (Read-UiYesNo -Prompt "Disable selected inbox rules?" -DefaultYes $false)) {
                Write-UiStatus -Status "SKIP" -Message "Skipped inbox rule disable action." -Color Yellow
                continue
            }

            foreach ($rule in $rulesToDisable) {
                try {
                    Invoke-UiCommand `
                        -Name "Disable inbox rule" `
                        -CommandPreview "Disable-InboxRule -Identity '$($rule.Identity)' -Confirm:`$false" `
                        -Command {
                            Disable-InboxRule -Identity $rule.Identity -Confirm:$false -ErrorAction Stop
                        }

                    if (Test-UiDryRun) {
                        Add-UiStepResult -Name "Disable inbox rule" -Result "Dry run" -Note "Would disable inbox rule '$($rule.Name)'."
                    }
                    else {
                        Write-UiStatus -Status "OK" -Message "Disabled inbox rule '$($rule.Name)'." -Color Green
                        Add-UiStepResult -Name "Disable inbox rule" -Result "Completed" -Note "Disabled '$($rule.Name)'."
                    }
                }
                catch {
                    Write-UiStatus -Status "WARN" -Message "Could not disable inbox rule '$($rule.Name)': $($_.Exception.Message)" -Color Yellow
                    Add-UiStepResult -Name "Disable inbox rule" -Result "Failed" -Note $_.Exception.Message
                }
            }
            continue
        }

        Write-UiStatus -Status "INFO" -Message "Enter exact lowercase d, r, s, q, or c." -Color Yellow
    }
}
