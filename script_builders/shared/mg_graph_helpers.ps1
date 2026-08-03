function Connect-M365ServicesMgGraph {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GraphScopes
    )

    Import-OrInstallPowerShellModule -ModuleName "Microsoft.Graph.Authentication"

    try {
        Write-UiStatus -Status "LOADING..." -Message "Disconnecting from any existing Microsoft Graph sessions." -Color Cyan
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    catch {}

    Write-UiStatus -Status "LOADING..." -Message "Creating a fresh connection to Microsoft Graph." -Color Cyan
    try {
        Connect-MgGraph -NoWelcome -ContextScope Process -Scopes $GraphScopes
    }
    catch {
        if ([string]$_.Exception.Message -notmatch "ContextScope") {
            throw
        }

        Write-UiStatus -Status "WARN" -Message "This Microsoft.Graph.Authentication version does not support -ContextScope. Connecting without process-scoped context." -Color Yellow
        Connect-MgGraph -NoWelcome -Scopes $GraphScopes
    }

    $context = Get-MgContext
    if ($context -and -not [string]::IsNullOrWhiteSpace([string]$context.TenantId)) {
        Write-UiStatus -Status "OK" -Message "Connected to Microsoft Graph tenant '$($context.TenantId)'." -Color Green
    }
    else {
        Write-UiStatus -Status "OK" -Message "Connected to Microsoft Graph." -Color Green
    }
}

function Get-MgGraphExceptionText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $messages = @()
    if ($ErrorRecord.Exception -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.Message)) {
        $messages += $ErrorRecord.Exception.Message
    }

    if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        $detailsText = [string]$ErrorRecord.ErrorDetails.Message
        try {
            $details = $detailsText | ConvertFrom-Json -ErrorAction Stop
            if ($details.error) {
                if (-not [string]::IsNullOrWhiteSpace([string]$details.error.code)) {
                    $messages += ("Graph code: {0}" -f $details.error.code)
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$details.error.message)) {
                    $messages += ("Graph message: {0}" -f $details.error.message)
                }
            }
            else {
                $messages += $detailsText
            }
        }
        catch {
            $messages += $detailsText
        }
    }

    $cleanMessages = @($messages | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($cleanMessages.Count -eq 0) {
        return "Graph request failed, but no detailed error text was returned."
    }

    return ($cleanMessages -join " | ")
}


function Escape-GraphFilterValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Get-GraphUserUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn,

        [string]$Select
    )

    $encodedUser = [System.Uri]::EscapeDataString($UserIdOrUpn)
    $uri = "https://graph.microsoft.com/v1.0/users/$encodedUser"
    if (-not [string]::IsNullOrWhiteSpace($Select)) {
        $uri = "$uri`?`$select=$Select"
    }

    return $uri
}

function New-GraphUserLookupFilter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup
    )

    $escapedLookup = Escape-GraphFilterValue -Value $Lookup
    $nameParts = @($Lookup -split "\s+" | Where-Object { $_ })
    $filter = "userPrincipalName eq '$escapedLookup' or mail eq '$escapedLookup' or mailNickname eq '$escapedLookup' or displayName eq '$escapedLookup'"

    if ($nameParts.Count -ge 2) {
        $escapedFirstName = Escape-GraphFilterValue -Value $nameParts[0]
        $escapedLastName = Escape-GraphFilterValue -Value $nameParts[$nameParts.Count - 1]
        $filter = "$filter or (givenName eq '$escapedFirstName' and surname eq '$escapedLastName')"
    }

    return $filter
}

function Resolve-CloudUserLookup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup,

        [string]$Purpose = "delegate"
    )

    $candidateLookup = $Lookup
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($candidateLookup)) {
            Write-UiStatus -Status "WARN" -Message "Blank lookup value was provided for $Purpose." -Color Yellow
            $candidateLookup = Read-UiInput -Prompt "Enter lookup for $Purpose" -Options @("exact UPN/email/name", "x=abort")
            if ($candidateLookup -eq "x") {
                throw "Lookup aborted for $Purpose."
            }
            continue
        }

        $trimmedLookup = $candidateLookup.Trim()
        $filter = New-GraphUserLookupFilter -Lookup $trimmedLookup
        $encodedFilter = [System.Uri]::EscapeDataString($filter)
        $select = "id,displayName,userPrincipalName,mail,mailNickname,givenName,surname,accountEnabled,onPremisesSamAccountName,proxyAddresses"
        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$encodedFilter" + [char]38 + "`$select=$select"
        $result = Invoke-MgGraphRequest -Method GET -Uri $uri
        $matches = @($result.value | Where-Object { $_ })
        $matches = @($matches | Where-Object { Test-CloudUserExactLookupMatch -CloudUser $_ -Lookup $trimmedLookup })

        if ($matches.Count -eq 1) {
            $match = $matches[0]
            if ([string]::IsNullOrWhiteSpace($match.userPrincipalName)) {
                Write-UiStatus -Status "WARN" -Message "Cloud user found for $Purpose lookup value '$trimmedLookup', but it does not have a UserPrincipalName." -Color Yellow
            }
            else {
                $displayName = $match.displayName
                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    $displayName = $match.userPrincipalName
                }

                return [pscustomobject]@{
                    Lookup            = $trimmedLookup
                    DisplayName       = $displayName
                    UserPrincipalName = $match.userPrincipalName
                    Mail              = $match.mail
                    Id                = $match.id
                    Label             = "$displayName <$($match.userPrincipalName)>"
                }
            }
        }
        elseif ($matches.Count -eq 0) {
            Write-UiStatus -Status "WARN" -Message "No exact cloud user matched $Purpose lookup value '$trimmedLookup'." -Color Yellow
        }
        else {
            Write-UiStatus -Status "TOO MANY" -Message "Multiple exact cloud users matched $Purpose lookup value '$trimmedLookup'." -Color Yellow
            $rows = @($matches | Select-Object displayName,userPrincipalName,mail,id)
            Write-UiBox -Title "Cloud User Matches - $Purpose" -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("displayName", "userPrincipalName", "mail", "id"))
        }

        $candidateLookup = Read-UiInput -Prompt "Enter a different lookup for $Purpose" -Options @("exact UPN/email/name", "x=abort")
        if ($candidateLookup -eq "x") {
            throw "Lookup aborted for $Purpose."
        }
    }
}

function Get-CloudUserStateAttributeSelect {
    return "id,displayName,userPrincipalName,mail,mailNickname,accountEnabled,usageLocation,onPremisesImmutableId,onPremisesSyncEnabled,onPremisesSamAccountName,assignedLicenses,createdDateTime,deletedDateTime"
}

function Get-CloudUserAssignedLicenseText {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser
    )

    $assignedLicenses = @($CloudUser.assignedLicenses | Where-Object { $_ })
    if ($assignedLicenses.Count -eq 0) {
        return "None"
    }

    if ((Get-Command Get-SkuCommonNames -ErrorAction SilentlyContinue) -and (Get-Command New-SkuLookup -ErrorAction SilentlyContinue) -and (Get-Command Get-AssignedLicenseRows -ErrorAction SilentlyContinue)) {
        try {
            $skuCommonNames = Get-SkuCommonNames
            $skus = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber"
            $skuById = New-SkuLookup -Skus $skus.value -SkuCommonNames $skuCommonNames
            $licenseRows = @(Get-AssignedLicenseRows -AssignedLicenses $assignedLicenses -SkuById $skuById)
            $licenseNames = @($licenseRows | ForEach-Object { $_.License } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($licenseNames.Count -gt 0) {
                return ($licenseNames -join ", ")
            }
        }
        catch {
            Write-UiStatus -Status "WARN" -Message "Could not map assigned license names: $($_.Exception.Message)" -Color Yellow
        }
    }

    return (@($assignedLicenses | ForEach-Object { [string]$_.skuId }) -join ", ")
}

function Invoke-GraphUserFilterSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filter,

        [Parameter(Mandatory = $true)]
        [string]$Select
    )

    $encodedFilter = [System.Uri]::EscapeDataString($Filter)
    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$encodedFilter" + [char]38 + "`$select=$Select"
    $result = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    return @($result.value | Where-Object { $_ })
}

function Find-ActiveCloudUsersByImmutableId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImmutableId,

        [Parameter(Mandatory = $true)]
        [string]$Select
    )

    $escapedImmutableId = Escape-GraphFilterValue -Value $ImmutableId
    return Invoke-GraphUserFilterSearch -Filter "onPremisesImmutableId eq '$escapedImmutableId'" -Select $Select
}

function Get-UniqueCloudUsers {
    param(
        [AllowNull()]
        [object[]]$Users
    )

    $uniqueUsers = @()
    $seenIds = @{}
    foreach ($user in @($Users | Where-Object { $_ })) {
        $key = [string]$user.id
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = [string]$user.userPrincipalName
        }
        if ([string]::IsNullOrWhiteSpace($key) -or $seenIds.ContainsKey($key)) {
            continue
        }

        $seenIds[$key] = $true
        $uniqueUsers += $user
    }

    return $uniqueUsers
}

function Test-CloudUserExactLookupMatch {
    param(
        [AllowNull()]
        $CloudUser,

        [Parameter(Mandatory = $true)]
        [string]$Lookup
    )

    if ($null -eq $CloudUser -or [string]::IsNullOrWhiteSpace($Lookup)) {
        return $false
    }

    $lookupText = $Lookup.Trim()
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    foreach ($propertyName in @("displayName", "userPrincipalName", "mail", "mailNickname", "onPremisesSamAccountName", "id")) {
        $value = $CloudUser.$propertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value) -and [string]::Equals(([string]$value).Trim(), $lookupText, $comparison)) {
            return $true
        }
    }

    $nameParts = @(
        [string]$CloudUser.givenName
        [string]$CloudUser.surname
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
    $fullName = ($nameParts -join " ").Trim()
    if (-not [string]::IsNullOrWhiteSpace($fullName) -and [string]::Equals($fullName, $lookupText, $comparison)) {
        return $true
    }

    foreach ($proxyAddress in @($CloudUser.proxyAddresses | Where-Object { $_ })) {
        $addressText = [string]$proxyAddress
        if (-not [string]::IsNullOrWhiteSpace($addressText) -and [string]::Equals($addressText.Trim(), $lookupText, $comparison)) {
            return $true
        }

        if ($addressText -match "^[^:]+:(.+)$") {
            $addressText = $Matches[1]
        }

        if (-not [string]::IsNullOrWhiteSpace($addressText) -and [string]::Equals($addressText.Trim(), $lookupText, $comparison)) {
            return $true
        }
    }

    return $false
}

function Find-ActiveCloudUsersByLookup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Lookup,

        [Parameter(Mandatory = $true)]
        [string]$Select
    )

    $matches = @()
    $filter = New-GraphUserLookupFilter -Lookup $Lookup
    $matches += Invoke-GraphUserFilterSearch -Filter $filter -Select $Select

    $escapedLookup = Escape-GraphFilterValue -Value $Lookup
    try {
        $matches += Invoke-GraphUserFilterSearch -Filter "onPremisesSamAccountName eq '$escapedLookup'" -Select $Select
    }
    catch {
        # Not all tenants/Graph query paths support this filter; mailNickname/displayName fallbacks still run.
    }

    if ($Lookup -like "*@*") {
        $escapedUpperProxy = Escape-GraphFilterValue -Value "SMTP:$Lookup"
        $escapedLowerProxy = Escape-GraphFilterValue -Value "smtp:$Lookup"
        $proxyFilter = "proxyAddresses/any(p:p eq '$escapedUpperProxy') or proxyAddresses/any(p:p eq '$escapedLowerProxy')"
        try {
            $matches += Invoke-GraphUserFilterSearch -Filter $proxyFilter -Select $Select
        }
        catch {
            Write-UiStatus -Status "INFO" -Message "Proxy address lookup was not available for '$Lookup': $($_.Exception.Message)" -Color Yellow
        }
    }

    return Get-UniqueCloudUsers -Users $matches
}

function Format-CloudUserState {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $directorySource = "Cloud-only"
    if ($CloudUser.onPremisesSyncEnabled -eq $true) {
        $directorySource = "On-prem synced"
    }

    Write-UiBox -Title "CloudUser State - $Source" -Lines @(
        New-UiBoxLine -Label "Source" -Value $Source
        New-UiBoxLine -Label "DirectorySource" -Value $directorySource
        New-UiBoxLine -Label "Id" -Value $CloudUser.id
        New-UiBoxLine -Label "DisplayName" -Value $CloudUser.displayName
        New-UiBoxLine -Label "UserPrincipalName" -Value $CloudUser.userPrincipalName
        New-UiBoxLine -Label "Mail" -Value $CloudUser.mail
        New-UiBoxLine -Label "MailNickname" -Value $CloudUser.mailNickname
        New-UiBoxLine -Label "AccountEnabled" -Value $CloudUser.accountEnabled
        New-UiBoxLine -Label "UsageLocation" -Value $CloudUser.usageLocation
        New-UiBoxLine -Label "OnPremSync" -Value $CloudUser.onPremisesSyncEnabled
        New-UiBoxLine -Label "OnPremSamAccount" -Value $CloudUser.onPremisesSamAccountName
        New-UiBoxLine -Label "onPremisesImmutableId" -Value $CloudUser.onPremisesImmutableId
        New-UiBoxLine -Label "AssignedLicenses" -Value (Get-CloudUserAssignedLicenseText -CloudUser $CloudUser)
        New-UiBoxLine -Label "CreatedDateTime" -Value $CloudUser.createdDateTime
        New-UiBoxLine -Label "DeletedDateTime" -Value $CloudUser.deletedDateTime
    )
}

function Show-CloudUserSearchMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Matches,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    if ($Matches.Count -eq 1) {
        Format-CloudUserState -CloudUser $Matches[0] -Source $Source
        return
    }

    Write-UiStatus -Status "TOO MANY" -Message "Multiple active cloud users matched $Source. Use a more specific lookup before making changes." -Color Yellow
    $lines = ConvertTo-UiTableLines -Rows $Matches -Columns @("displayName", "userPrincipalName", "mail", "mailNickname", "onPremisesSyncEnabled", "onPremisesImmutableId", "id")
    Write-UiBox -Title "CloudUser Matches - $Source" -Lines $lines
}

function Get-UserAuthenticationMethodSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn
    )

    $encodedUser = [System.Uri]::EscapeDataString($UserIdOrUpn)
    $uri = "https://graph.microsoft.com/v1.0/users/$encodedUser/authentication/methods"
    try {
        $result = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        return @($result.value | Where-Object { $_ })
    }
    catch {
        $errorText = $_.Exception.Message
        if (Get-Command Get-MgGraphExceptionText -ErrorAction SilentlyContinue) {
            $errorText = Get-MgGraphExceptionText -ErrorRecord $_
        }
        throw "Could not query authentication methods for '$UserIdOrUpn': $errorText"
    }
}

function Get-AuthenticationMethodKind {
    param(
        [AllowNull()]
        $Method
    )

    $odataType = [string]$Method.'@odata.type'
    if ([string]::IsNullOrWhiteSpace($odataType)) {
        return "unknown"
    }

    return ($odataType -replace "^#microsoft\.graph\.", "")
}

function Get-AuthenticationMethodDeletePath {
    param(
        [Parameter(Mandatory = $true)]
        $Method
    )

    $kind = Get-AuthenticationMethodKind -Method $Method
    switch ($kind) {
        "emailAuthenticationMethod" { return "emailMethods" }
        "fido2AuthenticationMethod" { return "fido2Methods" }
        "microsoftAuthenticatorAuthenticationMethod" { return "microsoftAuthenticatorMethods" }
        "phoneAuthenticationMethod" { return "phoneMethods" }
        "softwareOathAuthenticationMethod" { return "softwareOathMethods" }
        "temporaryAccessPassAuthenticationMethod" { return "temporaryAccessPassMethods" }
        "windowsHelloForBusinessAuthenticationMethod" { return "windowsHelloForBusinessMethods" }
        default { return "" }
    }
}

function New-AuthenticationMethodRows {
    param(
        [AllowNull()]
        [object[]]$Methods
    )

    $rows = @()
    $cleanMethods = @($Methods | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanMethods.Count; $i++) {
        $method = $cleanMethods[$i]
        $kind = Get-AuthenticationMethodKind -Method $method
        $display = [string]$method.displayName
        if ([string]::IsNullOrWhiteSpace($display)) {
            $display = [string]$method.phoneNumber
        }
        if ([string]::IsNullOrWhiteSpace($display)) {
            $display = [string]$method.emailAddress
        }
        if ([string]::IsNullOrWhiteSpace($display)) {
            $display = [string]$method.deviceTag
        }
        if ([string]::IsNullOrWhiteSpace($display)) {
            $display = "(blank)"
        }

        $details = @()
        foreach ($propertyName in @("phoneType", "phoneNumber", "emailAddress", "createdDateTime", "keyStrength", "isUsable", "isDefault", "isUsableOnce", "startDateTime", "lifetimeInMinutes")) {
            if ($method.PSObject.Properties.Name -contains $propertyName) {
                $value = $method.$propertyName
                if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                    $details += ("{0}={1}" -f $propertyName, $value)
                }
            }
        }

        $rows += [pscustomobject]@{
            Number      = $i + 1
            Type        = $kind
            Display     = $display
            Id          = $method.id
            Resettable  = -not [string]::IsNullOrWhiteSpace((Get-AuthenticationMethodDeletePath -Method $method))
            Details     = ($details -join "; ")
            RawMethod   = $method
        }
    }

    return $rows
}

function Write-AuthenticationMethodSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Methods,

        [string]$Title = "MFA / Authentication Methods"
    )

    $rows = @(New-AuthenticationMethodRows -Methods $Methods)
    if ($rows.Count -eq 0) {
        Write-UiBox -Title $Title -Lines @("No authentication methods were returned by Graph.")
        return
    }

    Write-UiBox -Title $Title -Lines (ConvertTo-UiTableLines -Rows $rows -Columns @("Number", "Type", "Display", "Resettable", "Details"))
}

function Invoke-GraphRevokeSignInSessions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn
    )

    $encodedUser = [System.Uri]::EscapeDataString($UserIdOrUpn)
    return Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$encodedUser/revokeSignInSessions" -ContentType "application/json"
}

function Remove-UserAuthenticationMethodsForReregistration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn,

        [AllowNull()]
        [object[]]$Methods
    )

    $encodedUser = [System.Uri]::EscapeDataString($UserIdOrUpn)
    $rows = @(New-AuthenticationMethodRows -Methods $Methods)
    foreach ($row in $rows) {
        $method = $row.RawMethod
        $deletePath = Get-AuthenticationMethodDeletePath -Method $method
        if ([string]::IsNullOrWhiteSpace($deletePath)) {
            Write-UiStatus -Status "SKIP" -Message "Skipping authentication method '$($row.Type)' because Graph does not expose a delete path for it here." -Color Yellow
            continue
        }

        $encodedMethod = [System.Uri]::EscapeDataString([string]$method.id)
        $uri = "https://graph.microsoft.com/v1.0/users/$encodedUser/authentication/$deletePath/$encodedMethod"
        try {
            Invoke-UiCommand `
                -Name "Remove authentication method" `
                -CommandPreview "Invoke-MgGraphRequest -Method DELETE -Uri '$uri'" `
                -Command {
                Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null
            }
            if (Test-UiDryRun) {
                Write-UiStatus -Status "DRY RUN" -Message "Would remove authentication method '$($row.Type)' for re-registration." -Color DarkGray
            }
            else {
                Write-UiStatus -Status "OK" -Message "Removed authentication method '$($row.Type)' for re-registration." -Color Green
            }
        }
        catch {
            $errorText = $_.Exception.Message
            if (Get-Command Get-MgGraphExceptionText -ErrorAction SilentlyContinue) {
                $errorText = Get-MgGraphExceptionText -ErrorRecord $_
            }
            Write-UiStatus -Status "WARN" -Message "Could not remove authentication method '$($row.Type)': $errorText" -Color Yellow
        }
    }
}
