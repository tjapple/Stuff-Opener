function Import-ActiveDirectoryModule {
    Import-OrInstallPowerShellModule -ModuleName "ActiveDirectory"
}

function Escape-DirectoryFilterValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function New-AdUserLookupFilter {
    # Creates a filter from the Lookup value
    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup
    )

    $escapedLookup = Escape-DirectoryFilterValue -Value $Lookup
    $nameParts = @($Lookup -split "\s+" | Where-Object { $_ })
    $filter = "SamAccountName -eq '$escapedLookup' -or UserPrincipalName -eq '$escapedLookup' -or mail -eq '$escapedLookup' -or Name -eq '$escapedLookup' -or DisplayName -eq '$escapedLookup'"

    if ($nameParts.Count -ge 2) {
        $escapedFirstName = Escape-DirectoryFilterValue -Value $nameParts[0]
        $escapedLastName = Escape-DirectoryFilterValue -Value $nameParts[$nameParts.Count - 1]
        $filter = "$filter -or (GivenName -eq '$escapedFirstName' -and Surname -eq '$escapedLastName')"
    }

    return $filter
}

function Resolve-AdUserLookup {
    # Runs Get-AdUser with a filter created with the lookup value
    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup,
        [string]$Purpose = "AD user"
    )

    $candidateLookup = $Lookup
    $lookupWasEnteredInteractively = $false
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($candidateLookup)) {
            Write-UiStatus -Status "WARN" -Message "Blank lookup value was provided for $Purpose." -Color Yellow
            $candidateLookup = Read-UiInput -Prompt "Enter lookup for $Purpose" -Options @("sAMAccountName/UPN/mail/name", "x=abort")
            if ($candidateLookup -eq "x") {
                throw "Lookup aborted for $Purpose."
            }
            $lookupWasEnteredInteractively = $true
            continue
        }

        $trimmedLookup = $candidateLookup.Trim()
        $adFilter = New-AdUserLookupFilter -Lookup $trimmedLookup
        $adMatches = @(Get-ADUser -Filter $adFilter -Properties Enabled,LockedOut,PasswordExpired,PasswordLastSet,badPwdCount,LastBadPasswordAttempt,AccountLockoutTime,Description,DistinguishedName,UserPrincipalName,mail,ObjectGUID,mS-DS-ConsistencyGuid,GivenName,Surname,DisplayName -ErrorAction Stop)
        if ($adMatches.Count -eq 1) {
            if (-not $lookupWasEnteredInteractively) {
                return $adMatches[0]
            }

            $selectedUser = Select-AdUserLookupMatch -Matches $adMatches -Purpose $Purpose -AllowCancel
            if ($selectedUser) {
                return $selectedUser
            }
        }
        elseif ($adMatches.Count -eq 0) {
            Write-UiStatus -Status "WARN" -Message "No AD user found for $Purpose lookup value '$trimmedLookup'." -Color Yellow
        }
        else {
            Write-UiStatus -Status "TOO MANY" -Message "Multiple AD users matched $Purpose lookup value '$trimmedLookup'." -Color Yellow
            $selectedUser = Select-AdUserLookupMatch -Matches $adMatches -Purpose $Purpose -AllowCancel
            if ($selectedUser) {
                return $selectedUser
            }
        }

        $candidateLookup = Read-UiInput -Prompt "Enter a different lookup for $Purpose" -Options @("sAMAccountName/UPN/mail/name", "x=abort")
        if ($candidateLookup -eq "x") {
            throw "Lookup aborted for $Purpose."
        }
        $lookupWasEnteredInteractively = $true
    }
}

function Select-AdUserLookupMatch {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Matches,

        [Parameter(Mandatory = $true)]
        [string]$Purpose,

        [switch]$AllowCancel
    )

    $cleanMatches = @($Matches | Where-Object { $_ })
    if ($cleanMatches.Count -eq 0) {
        return $null
    }

    $rows = @()
    for ($i = 0; $i -lt $cleanMatches.Count; $i++) {
        $match = $cleanMatches[$i]
        $rows += [pscustomobject]@{
            Number            = $i + 1
            Name              = $match.Name
            SamAccountName    = $match.SamAccountName
            UserPrincipalName = $match.UserPrincipalName
            Mail              = $match.mail
            Enabled           = $match.Enabled
            LockedOut         = $match.LockedOut
            DistinguishedName = $match.DistinguishedName
        }
    }

    Write-UiBox -Title "AD User Matches - $Purpose" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "Name", "SamAccountName", "UserPrincipalName", "Mail", "Enabled", "LockedOut", "DistinguishedName"))

    if ($cleanMatches.Count -eq 1) {
        $match = $cleanMatches[0]
        if (Read-UiYesNo -Prompt "Use AD user '$($match.SamAccountName)' for $Purpose?" -DefaultYes $true) {
            return $match
        }

        return $null
    }

    while ($true) {
        $options = @("number")
        if ($AllowCancel) {
            $options += "blank=new lookup"
        }
        $options += "x=abort"

        $selection = Read-UiInput -Prompt "Choose AD user for $Purpose" -Options $options
        if ($selection -eq "x") {
            throw "Lookup aborted for $Purpose."
        }

        if ([string]::IsNullOrWhiteSpace($selection) -and $AllowCancel) {
            return $null
        }

        if ($selection -match "^\d+$") {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $cleanMatches.Count) {
                $selected = $cleanMatches[$index]
                if (Read-UiYesNo -Prompt "Use AD user '$($selected.SamAccountName)' for $Purpose?" -DefaultYes $true) {
                    return $selected
                }
                continue
            }
        }

        Write-UiStatus -Status "WARN" -Message "Enter a valid match number, blank for a new lookup, or x to abort." -Color Yellow
    }
}

function Get-AdUserSourceAnchorInfo {
    param(
        [Parameter(Mandatory = $true)]
        $User
    )

    $sourceAnchorBytes = $User.'mS-DS-ConsistencyGuid'
    if ($sourceAnchorBytes) {
        return [pscustomobject]@{
            Attribute   = "mS-DS-ConsistencyGuid"
            ImmutableId = [Convert]::ToBase64String($sourceAnchorBytes)
        }
    }

    return [pscustomobject]@{
        Attribute   = "ObjectGUID"
        ImmutableId = [Convert]::ToBase64String($User.ObjectGUID.ToByteArray())
    }
}

function Get-AdUserStateSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity
    )

    if (-not (Get-Command Get-ADUser -ErrorAction SilentlyContinue)) {
        Import-ActiveDirectoryModule
    }

    return Get-ADUser -Identity $Identity -Properties Enabled,LockedOut,PasswordExpired,PasswordLastSet,badPwdCount,LastBadPasswordAttempt,AccountLockoutTime,Description,Manager,DistinguishedName,UserPrincipalName,mail,DisplayName,GivenName,Surname,whenCreated,whenChanged,LastLogonDate,MemberOf,ObjectGUID,'mS-DS-ConsistencyGuid'
}

function Show-AdUserState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [string]$Title = "Current ADUser State",

        [switch]$PassThru
    )

    $adUser = Get-AdUserStateSnapshot -Identity $Identity
    $sourceAnchor = Get-AdUserSourceAnchorInfo -User $adUser

    Write-UiBox -Title $Title -Lines @(
        New-UiBoxLine -Label "Name" -Value $adUser.Name
        New-UiBoxLine -Label "DisplayName" -Value $adUser.DisplayName
        New-UiBoxLine -Label "SamAccountName" -Value $adUser.SamAccountName
        New-UiBoxLine -Label "Enabled" -Value $adUser.Enabled
        New-UiBoxLine -Label "LockedOut" -Value $adUser.LockedOut
        New-UiBoxLine -Label "UserPrincipalName" -Value $adUser.UserPrincipalName
        New-UiBoxLine -Label "Mail" -Value $adUser.mail
        New-UiBoxLine -Label "Description" -Value $adUser.Description
        New-UiBoxLine -Label "Manager" -Value $adUser.Manager
        New-UiBoxLine -Label "DistinguishedName" -Value $adUser.DistinguishedName
        New-UiBoxLine -Label "MemberOfCount" -Value (@($adUser.MemberOf).Count)
        New-UiBoxLine -Label "LastLogonDate" -Value $adUser.LastLogonDate
        New-UiBoxLine -Label "PasswordLastSet" -Value $adUser.PasswordLastSet
        New-UiBoxLine -Label "PasswordExpired" -Value $adUser.PasswordExpired
        New-UiBoxLine -Label "BadPasswordCount" -Value $adUser.badPwdCount
        New-UiBoxLine -Label "LastBadPasswordAttempt" -Value $adUser.LastBadPasswordAttempt
        New-UiBoxLine -Label "AccountLockoutTime" -Value $adUser.AccountLockoutTime
        New-UiBoxLine -Label "WhenCreated" -Value $adUser.whenCreated
        New-UiBoxLine -Label "WhenChanged" -Value $adUser.whenChanged
        New-UiBoxLine -Label "ObjectGUID" -Value $adUser.ObjectGUID
        New-UiBoxLine -Label "SourceAnchorAttribute" -Value $sourceAnchor.Attribute
        New-UiBoxLine -Label "OnPremisesImmutableId" -Value $sourceAnchor.ImmutableId
    )

    if ($PassThru) {
        return $adUser
    }
}

function Get-TargetUserDetails {
    # Retrieve user Object and store attributes in custom object.

    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup
    )

    $adUser = Resolve-AdUserLookup -Lookup $Lookup -Purpose "terminated user"
    $samAccountName = $adUser.SamAccountName
    $userPrincipalName = $adUser.UserPrincipalName

    if ([string]::IsNullOrWhiteSpace($userPrincipalName)) {
        $userPrincipalName = $adUser.mail
    }
    if ([string]::IsNullOrWhiteSpace($userPrincipalName)) {
        throw "AD user '$samAccountName' does not have UserPrincipalName or mail populated. Set `$UserPrincipalName manually before cloud steps."
    }

    # Find the source anchor of onPremisesImmutableID.
    $sourceAnchor = Get-AdUserSourceAnchorInfo -User $adUser

    return [pscustomobject]@{
        AdUser                = $adUser
        ObjectGUID            = $adUser.ObjectGUID
        SamAccountName        = $samAccountName
        UserPrincipalName     = $userPrincipalName
        OnPremisesImmutableId = $sourceAnchor.ImmutableId
        SourceAnchorAttribute = $sourceAnchor.Attribute
    }
}
