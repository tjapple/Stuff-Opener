
function Get-SkuCommonNames {
    return @{
        "AAD_PREMIUM" = "Microsoft Entra ID P1"
        "AAD_PREMIUM_P2" = "Microsoft Entra ID P2"
        "ATP_ENTERPRISE" = "Microsoft Defender for Office 365 (Plan 1)"
        "ATP_ENTERPRISE_FACULTY" = "Microsoft Defender for Office 365 (Plan 1) Faculty"
        "ATP_ENTERPRISE_GOV" = "Microsoft Defender for Office 365 (Plan 1) GCC"
        "ATP_ENTERPRISE_STUDENT" = "Microsoft Defender for Office 365 (Plan 1) Student"
        "DESKLESSPACK" = "Office 365 F3"
        "EMS" = "Enterprise Mobility + Security E3"
        "EMSPREMIUM" = "Enterprise Mobility + Security E5"
        "ENTERPRISEPACK" = "Office 365 E3"
        "ENTERPRISEPREMIUM" = "Office 365 E5"
        "EXCHANGESTANDARD" = "Exchange Online (Plan 1)"
        "EXCHANGEENTERPRISE" = "Exchange Online (Plan 2)"
        "FLOW_FREE" = "Microsoft Power Automate Free"
        "M365EDU_A3_FACULTY" = "Microsoft 365 A3 for Faculty"
        "M365EDU_A5_FACULTY" = "Microsoft 365 A5 for Faculty"
        "O365_BUSINESS_ESSENTIALS" = "Microsoft 365 Business Basic"
        "O365_BUSINESS_PREMIUM" = "Microsoft 365 Business Standard"
        "PBI_PREMIUM_PER_USER" = "Power BI Premium Per User"
        "PBI_PREMIUM_PER_USER_ADDON" = "Power BI Premium Per User Add-On"
        "POWER_BI_ADDON" = "Power BI for Office 365 Add-On"
        "POWER_BI_INDIVIDUAL_USER" = "Power BI"
        "POWER_BI_PRO" = "Power BI Pro"
        "POWER_BI_STANDARD" = "Microsoft Fabric Free"
        "POWER_BI_STANDARD_FACULTY" = "Microsoft Fabric Free Faculty"
        "POWER_BI_STANDARD_STUDENT" = "Microsoft Fabric Free Student"
        "POWER_BI_STANDARD_GOV" = "Microsoft Fabric Free GCC"
        "POWER_BI_STANDARD_DEPT" = "Microsoft Fabric Free Department"
        "POWER_BI_STANDARD_INF" = "Microsoft Fabric Free"
        "SMB_BUSINESS_ESSENTIALS" = "Microsoft 365 Business Basic"
        "SMB_BUSINESS_PREMIUM" = "Microsoft 365 Business Standard - Prepaid Legacy"
        "SPE_E3" = "Microsoft 365 E3"
        "SPE_E5" = "Microsoft 365 E5"
        "SPE_F1" = "Microsoft 365 F3"
        "SPB" = "Microsoft 365 Business Premium"
        "SPZA_IW" = "App Connect IW"
        "STANDARDPACK" = "Office 365 E1"
        "VISIOCLIENT" = "Visio Plan 2"
        "WINDOWS_STORE" = "Windows Store for Business"
    }
}

function New-SkuLookup {
    param(
        [AllowNull()]
        [object[]]$Skus,

        [Parameter(Mandatory = $true)]
        [hashtable]$SkuCommonNames
    )

    $skuById = @{}
    foreach ($sku in @($Skus)) {
        $commonName = $SkuCommonNames[$sku.skuPartNumber]
        if ([string]::IsNullOrWhiteSpace($commonName)) {
            $commonName = $sku.skuPartNumber
        }

        $skuById[[string]$sku.skuId] = [pscustomobject]@{
            CommonName    = $commonName
            SkuPartNumber = $sku.skuPartNumber
        }
    }

    return $skuById
}

function Get-AssignedLicenseRows {
    param(
        [AllowNull()]
        [object[]]$AssignedLicenses,

        [Parameter(Mandatory = $true)]
        [hashtable]$SkuById
    )

    return @(
        @($AssignedLicenses | Where-Object { $_ }) |
            ForEach-Object {
                $license = $SkuById[[string]$_.skuId]
                if ($license) {
                    [pscustomobject]@{
                        License       = $license.CommonName
                        SkuPartNumber = $license.SkuPartNumber
                        SkuId         = $_.skuId
                    }
                }
                else {
                    [pscustomobject]@{
                        License       = "Unknown SKU"
                        SkuPartNumber = ""
                        SkuId         = $_.skuId
                    }
                }
            } |
            Sort-Object License
    )
}

function Get-TenantLicenseRows {
    param(
        [AllowNull()]
        [object[]]$Skus,

        [Parameter(Mandatory = $true)]
        [hashtable]$SkuCommonNames
    )

    return @(
        @($Skus) |
            ForEach-Object {
                $commonName = $SkuCommonNames[$_.skuPartNumber]
                if ([string]::IsNullOrWhiteSpace($commonName)) {
                    $commonName = $_.skuPartNumber
                }

                $graphEnabled = [int]$_.prepaidUnits.enabled
                $warning = [int]$_.prepaidUnits.warning
                $suspended = [int]$_.prepaidUnits.suspended
                $lockedOut = [int]$_.prepaidUnits.lockedOut
                $consumed = [int]$_.consumedUnits
                $effectiveEnabled = $graphEnabled + $warning
                $effectiveAvailable = $effectiveEnabled - $consumed

                [pscustomobject]@{
                    License              = $commonName
                    SkuPartNumber        = $_.skuPartNumber
                    SkuId                = $_.skuId
                    AppliesTo            = $_.appliesTo
                    CapabilityStatus     = $_.capabilityStatus
                    Enabled              = $effectiveEnabled
                    GraphEnabled         = $graphEnabled
                    Warning              = $warning
                    Suspended            = $suspended
                    LockedOut            = $lockedOut
                    Consumed             = $consumed
                    AvailableEnabled     = $effectiveAvailable
                    AvailableWithWarning = $effectiveAvailable
                    Available            = $effectiveAvailable
                }
            } |
            Sort-Object License
    )
}

function Invoke-LicenseGraphCollectionRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $items = @()
    $nextUri = $Uri
    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $result = Invoke-MgGraphRequest -Method GET -Uri $nextUri -ErrorAction Stop
        $items += @($result.value | Where-Object { $_ })
        $nextUri = [string]$result.'@odata.nextLink'
    }

    return $items
}

function ConvertTo-LicenseNumberSelection {
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

function Get-CloudUserLicenseSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn
    )

    $skuCommonNames = Get-SkuCommonNames
    $skuUri = "https://graph.microsoft.com/v1.0/subscribedSkus?`$select=skuId,skuPartNumber,appliesTo,capabilityStatus,prepaidUnits,consumedUnits"
    try {
        $skuRows = @(Invoke-LicenseGraphCollectionRequest -Uri $skuUri)
    }
    catch {
        throw "Could not load tenant subscribed SKUs from Graph. URI: $skuUri. Error: $($_.Exception.Message)"
    }
    $skuById = New-SkuLookup -Skus $skuRows -SkuCommonNames $skuCommonNames

    $encodedUser = [System.Uri]::EscapeDataString($UserIdOrUpn)
    $userSelect = "id,displayName,userPrincipalName,usageLocation,assignedLicenses"
    if (Get-Command Get-GraphUserUri -ErrorAction SilentlyContinue) {
        $userUri = Get-GraphUserUri -UserIdOrUpn $UserIdOrUpn -Select $userSelect
    }
    else {
        $userUri = "https://graph.microsoft.com/v1.0/users/${encodedUser}?`$select=$userSelect"
    }
    try {
        $cloudUser = Invoke-MgGraphRequest -Method GET -Uri $userUri
    }
    catch {
        $errorText = $_.Exception.Message
        if (Get-Command Get-MgGraphExceptionText -ErrorAction SilentlyContinue) {
            $errorText = Get-MgGraphExceptionText -ErrorRecord $_
        }
        throw "Could not load assigned licenses for cloud user '$UserIdOrUpn'. URI: $userUri. Error: $errorText"
    }
    $assignedRows = @(Get-AssignedLicenseRows -AssignedLicenses $cloudUser.assignedLicenses -SkuById $skuById)
    $tenantRows = @(Get-TenantLicenseRows -Skus $skuRows -SkuCommonNames $skuCommonNames)

    return [pscustomobject]@{
        CloudUser     = $cloudUser
        SkuById       = $skuById
        AssignedRows  = $assignedRows
        TenantRows    = $tenantRows
        AvailableRows = @($tenantRows | Where-Object { $_ -and $_.Available -gt 0 })
    }
}

function New-LicenseManagerNumberedRows {
    param(
        [AllowNull()]
        [object[]]$Rows
    )

    $numberedRows = @()
    $cleanRows = @($Rows | Where-Object { $_ })
    for ($i = 0; $i -lt $cleanRows.Count; $i++) {
        $row = $cleanRows[$i]
        $numberedRows += [pscustomobject]@{
            Number               = $i + 1
            License               = $row.License
            SkuPartNumber         = $row.SkuPartNumber
            AppliesTo             = $row.AppliesTo
            Status                = $row.CapabilityStatus
            Enabled               = $row.Enabled
            GraphEnabled          = $row.GraphEnabled
            Warning               = $row.Warning
            Warn                  = $row.Warning
            Suspended             = $row.Suspended
            LockedOut             = $row.LockedOut
            Consumed              = $row.Consumed
            Used                  = $row.Consumed
            Available             = $row.Available
            Avail                 = $row.Available
            AvailableWithWarning  = $row.AvailableWithWarning
            AvailWarn             = $row.AvailableWithWarning
            SkuId                 = $row.SkuId
        }
    }

    return $numberedRows
}

function ConvertTo-LicenseDetailValue {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "(blank)"
    }

    return [string]$Value
}

function Write-LicenseInventoryDetails {
    param(
        [Parameter(Mandatory = $true)]
        $LicenseRow
    )

    Write-UiBox -Title "License Details #$($LicenseRow.Number)" -Lines @(
        New-UiBoxLine -Label "License" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.License)
        New-UiBoxLine -Label "SkuPartNumber" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.SkuPartNumber)
        New-UiBoxLine -Label "SkuId" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.SkuId)
        New-UiBoxLine -Label "AppliesTo" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.AppliesTo)
        New-UiBoxLine -Label "Status" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.Status)
        New-UiBoxLine -Label "Enabled" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.Enabled)
        New-UiBoxLine -Label "GraphEnabled" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.GraphEnabled)
        New-UiBoxLine -Label "Warning" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.Warning)
        New-UiBoxLine -Label "Suspended" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.Suspended)
        New-UiBoxLine -Label "LockedOut" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.LockedOut)
        New-UiBoxLine -Label "Consumed" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.Consumed)
        New-UiBoxLine -Label "Available" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.Available)
        New-UiBoxLine -Label "AvailableWithWarning" -Value (ConvertTo-LicenseDetailValue -Value $LicenseRow.AvailableWithWarning)
    )
}

function Write-LicenseManagerSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $usageLocation = [string]$Snapshot.CloudUser.usageLocation
    if ([string]::IsNullOrWhiteSpace($usageLocation)) {
        $usageLocation = "(blank)"
    }

    Write-UiBox -Title "License Target" -Lines @(
    New-UiBoxLine -Label "UserPrincipalName" -Value $Snapshot.CloudUser.userPrincipalName
    New-UiBoxLine -Label "UsageLocation" -Value $usageLocation
    New-UiBoxLine -Label "Tenant SKU count" -Value @($Snapshot.TenantRows).Count
    New-UiBoxLine -Label "Assignable SKU count" -Value @($Snapshot.AvailableRows).Count
)

    $tenantRows = @(New-LicenseManagerNumberedRows -Rows $Snapshot.TenantRows)
    if ($tenantRows.Count -eq 0) {
        Write-UiBox -Title "Tenant License Inventory" -Lines @("None")
    }
    else {
        Write-UiBox -Title "Tenant License Inventory" -Lines (ConvertTo-UiTableLines -Rows $tenantRows -Columns @("Number", "License", "Enabled", "Consumed", "Available"))
    }

    $availableRows = @(New-LicenseManagerNumberedRows -Rows $Snapshot.AvailableRows)
    if ($availableRows.Count -eq 0) {
        Write-UiBox -Title "Available Licenses To Add" -Lines @("None")
    }
    else {
        Write-UiBox -Title "Available Licenses To Add" -Lines (ConvertTo-UiTableLines -Rows $availableRows -Columns @("Number", "License", "Enabled", "Available"))
    }



    $assignedRows = @(New-LicenseManagerNumberedRows -Rows $Snapshot.AssignedRows)
    if ($assignedRows.Count -eq 0) {
        Write-UiBox -Title "Assigned Licenses" -Lines @("None")
    }
    else {
        Write-UiBox -Title "Assigned Licenses" -Lines (ConvertTo-UiTableLines -Rows $assignedRows -Columns @("Number", "License"))
    }
}

function Test-LicenseUsageLocation {
    param(
        [AllowNull()]
        [string]$UsageLocation
    )

    return (-not [string]::IsNullOrWhiteSpace($UsageLocation) -and $UsageLocation.Trim() -match "^[A-Za-z]{2}$")
}

function Set-CloudUserUsageLocationForLicensing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn,

        [Parameter(Mandatory = $true)]
        [string]$UsageLocation
    )

    $body = @{
        usageLocation = $UsageLocation.Trim().ToUpperInvariant()
    } | ConvertTo-Json -Depth 4

    return Invoke-MgGraphRequest -Method PATCH -Uri (Get-GraphUserUri -UserIdOrUpn $UserIdOrUpn) -Body $body -ContentType "application/json"
}

function Set-CloudUserObjectUsageLocationValue {
    param(
        [Parameter(Mandatory = $true)]
        $CloudUser,

        [Parameter(Mandatory = $true)]
        [string]$UsageLocation
    )

    try {
        $CloudUser.usageLocation = $UsageLocation
    }
    catch {
        try {
            $CloudUser | Add-Member -MemberType NoteProperty -Name usageLocation -Value $UsageLocation -Force
        }
        catch {
        }
    }
}

function Ensure-CloudUserUsageLocationForLicenseAssignment {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    if (Test-LicenseUsageLocation -UsageLocation $Snapshot.CloudUser.usageLocation) {
        return $true
    }

    $location = "US"
    try {
        Invoke-UiCommand `
            -Name "Set cloud user usage location" `
            -CommandPreview "Invoke-MgGraphRequest -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/users/$($Snapshot.CloudUser.id)' -Body '{ usageLocation = $location }'" `
            -Command {
            Set-CloudUserUsageLocationForLicensing -UserIdOrUpn $Snapshot.CloudUser.id -UsageLocation $location | Out-Null
        }
        Set-CloudUserObjectUsageLocationValue -CloudUser $Snapshot.CloudUser -UsageLocation $location
        if (Test-UiDryRun) {
            Add-UiStepResult -Name "Set cloud user usage location" -Result "Dry run" -Note "Would set UsageLocation to '$location'."
        }
        else {
            Write-UiStatus -Status "OK" -Message "Set UsageLocation to '$location' for '$($Snapshot.CloudUser.userPrincipalName)'." -Color Green
            Add-UiStepResult -Name "Set cloud user usage location" -Result "Completed" -Note "Set UsageLocation to '$location'."
        }
        return $true
    }
    catch {
        $errorText = $_.Exception.Message
        if (Get-Command Get-MgGraphExceptionText -ErrorAction SilentlyContinue) {
            $errorText = Get-MgGraphExceptionText -ErrorRecord $_
        }
        Write-UiStatus -Status "WARN" -Message "Could not set UsageLocation: $errorText" -Color Yellow
        return $false
    }
}

function Invoke-CloudUserLicenseAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn,

        [AllowNull()]
        [object[]]$AddLicenseRows = @(),

        [AllowNull()]
        [object[]]$RemoveLicenseRows = @()
    )

    $addLicenses = @(
        @($AddLicenseRows | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.SkuId) }) |
            ForEach-Object {
                @{
                    skuId         = $_.SkuId
                    disabledPlans = @()
                }
            }
    )

    $removeLicenses = @(
        @($RemoveLicenseRows | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.SkuId) }) |
            ForEach-Object { [string]$_.SkuId }
    )

    $body = @{
        addLicenses    = @($addLicenses)
        removeLicenses = @($removeLicenses)
    } | ConvertTo-Json -Depth 8

    $encodedUser = [System.Uri]::EscapeDataString($UserIdOrUpn)
    try {
        return Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$encodedUser/assignLicense" -Body $body -ContentType "application/json"
    }
    catch {
        $errorText = $_.Exception.Message
        if (Get-Command Get-MgGraphExceptionText -ErrorAction SilentlyContinue) {
            $errorText = Get-MgGraphExceptionText -ErrorRecord $_
        }
        throw $errorText
    }
}

function Read-LicenseManagerSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    while ($true) {
        $selection = Read-UiInput -Prompt $Prompt -Options @("blank=cancel")
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return @()
        }

        $numbers = ConvertTo-LicenseNumberSelection -InputText $selection -Max $Rows.Count
        if ($numbers.Count -eq 0) {
            Write-UiStatus -Status "INFO" -Message "Enter valid license numbers from the list." -Color Yellow
            continue
        }

        return @($numbers | ForEach-Object { $Rows[$_ - 1] })
    }
}

function Invoke-InteractiveLicenseManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserIdOrUpn,

        [string]$DisplayName = "",

        [switch]$ContinueOption,

        [switch]$PassThru
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName = $UserIdOrUpn
    }

    while ($true) {
        Write-UiStatus -Status "LOADING..." -Message "Refreshing license state for '$DisplayName'." -Color Cyan
        $snapshot = Get-CloudUserLicenseSnapshot -UserIdOrUpn $UserIdOrUpn
        Write-LicenseManagerSnapshot -Snapshot $snapshot

        $exitChoice = if ($ContinueOption) { "c" } else { "x" }
        $exitOption = if ($ContinueOption) { "c=continue" } else { "x=abort" }
        $exitResult = if ($ContinueOption) { "Continue" } else { "Abort" }

        $choice = Read-UiInput -Prompt "Adjust licenses?" -Options @("a=add licenses", "r=remove licenses", "d=license details", $exitOption)
        if ($choice -eq $exitChoice) {
            Write-UiStatus -Status "DONE" -Message "Exited license manager for '$DisplayName'." -Color Yellow
            if ($PassThru) {
                return [pscustomobject]@{
                    Result       = $exitResult
                    AssignedRows = @($snapshot.AssignedRows)
                    TenantRows   = @($snapshot.TenantRows)
                }
            }

            return
        }

        if ($choice -eq "d") {
            $tenantRows = @(New-LicenseManagerNumberedRows -Rows $snapshot.TenantRows)
            if ($tenantRows.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No tenant license rows are available for details." -Color Yellow
                continue
            }

            $selectedRows = @(Read-LicenseManagerSelection -Rows $tenantRows -Prompt "Select license inventory rows for details")
            foreach ($selectedRow in $selectedRows) {
                Write-LicenseInventoryDetails -LicenseRow $selectedRow
            }
            continue
        }

        if ($choice -eq "a") {
            $availableRows = @(New-LicenseManagerNumberedRows -Rows $snapshot.AvailableRows)
            if ($availableRows.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No available tenant licenses can be added." -Color Yellow
                continue
            }

            $selectedRows = @(Read-LicenseManagerSelection -Rows $availableRows -Prompt "Select the available licenses to add. Enter their corresponding number, separated by commas")
            if ($selectedRows.Count -eq 0) {
                continue
            }

            Write-UiBox -Title "Selected Licenses To Add" -Lines (ConvertTo-UiTableLines -Rows $selectedRows -Columns @("License", "Available"))
            if (-not (Read-UiYesNo -Prompt "Assign selected licenses?" -DefaultYes $false)) {
                Write-UiStatus -Status "SKIP" -Message "Skipped selected license assignment." -Color Yellow
                continue
            }

            if (-not (Ensure-CloudUserUsageLocationForLicenseAssignment -Snapshot $snapshot)) {
                continue
            }

            try {
                $selectedLicenseText = (@($selectedRows | ForEach-Object { $_.License }) -join ", ")
                Invoke-UiCommand `
                    -Name "Assign selected cloud licenses" `
                    -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users/$($snapshot.CloudUser.id)/assignLicense' -Body <add $selectedLicenseText>" `
                    -Command {
                    Invoke-CloudUserLicenseAssignment -UserIdOrUpn $snapshot.CloudUser.id -AddLicenseRows $selectedRows -RemoveLicenseRows @() | Out-Null
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage cloud licenses" -Result "Dry run" -Note "Would assign $($selectedRows.Count) license(s)."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Assigned $($selectedRows.Count) license(s) to '$($snapshot.CloudUser.userPrincipalName)'." -Color Green
                    Add-UiStepResult -Name "Manage cloud licenses" -Result "Completed" -Note "Assigned $($selectedRows.Count) license(s)."
                }
            }
            catch {
                Write-UiStatus -Status "WARN" -Message "Could not assign selected license(s) to '$($snapshot.CloudUser.userPrincipalName)': $($_.Exception.Message)" -Color Yellow
                Write-UiStatus -Status "INFO" -Message "Check whether this SKU can be assigned by Graph, whether required service plans/dependencies apply, whether usage location is set, and whether group-based licensing is involved." -Color Yellow
                Add-UiStepResult -Name "Manage cloud licenses" -Result "Failed" -Note $_.Exception.Message
            }
            continue
        }

        if ($choice -eq "r") {
            $assignedRows = @(New-LicenseManagerNumberedRows -Rows $snapshot.AssignedRows)
            if ($assignedRows.Count -eq 0) {
                Write-UiStatus -Status "INFO" -Message "No assigned licenses can be removed." -Color Yellow
                continue
            }

            $selectedRows = @(Read-LicenseManagerSelection -Rows $assignedRows -Prompt "Select the licenses to remove from the user. Enter the corresponding numbers separated by commas")
            if ($selectedRows.Count -eq 0) {
                continue
            }

            Write-UiBox -Title "Licenses To Remove" -Lines (ConvertTo-UiTableLines -Rows $selectedRows -Columns @("License"))
            $removalConfirmed = $false
            if ($selectedRows.Count -eq $assignedRows.Count) {
                Write-UiStatus -Status "WARN" -Message "This will leave '$($snapshot.CloudUser.userPrincipalName)' unlicensed." -Color Yellow
                if (-not (Read-UiYesNo -Prompt "Are you sure you want to remove all assigned licenses?" -DefaultYes $false)) {
                    Write-UiStatus -Status "SKIP" -Message "Skipped removing all assigned licenses." -Color Yellow
                    continue
                }
                $removalConfirmed = $true
            }

            if (-not $removalConfirmed -and -not (Read-UiYesNo -Prompt "Remove selected licenses?" -DefaultYes $false)) {
                Write-UiStatus -Status "SKIP" -Message "Skipped selected license removal." -Color Yellow
                continue
            }

            try {
                $selectedLicenseText = (@($selectedRows | ForEach-Object { $_.License }) -join ", ")
                Invoke-UiCommand `
                    -Name "Remove selected cloud licenses" `
                    -CommandPreview "Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users/$($snapshot.CloudUser.id)/assignLicense' -Body <remove $selectedLicenseText>" `
                    -Command {
                    Invoke-CloudUserLicenseAssignment -UserIdOrUpn $snapshot.CloudUser.id -AddLicenseRows @() -RemoveLicenseRows $selectedRows | Out-Null
                }
                if (Test-UiDryRun) {
                    Add-UiStepResult -Name "Manage cloud licenses" -Result "Dry run" -Note "Would remove $($selectedRows.Count) license(s)."
                }
                else {
                    Write-UiStatus -Status "OK" -Message "Removed $($selectedRows.Count) license(s) from '$($snapshot.CloudUser.userPrincipalName)'." -Color Green
                    Add-UiStepResult -Name "Manage cloud licenses" -Result "Completed" -Note "Removed $($selectedRows.Count) license(s)."
                }
            }
            catch {
                Write-UiStatus -Status "WARN" -Message "Could not remove selected license(s) from '$($snapshot.CloudUser.userPrincipalName)': $($_.Exception.Message)" -Color Yellow
                Add-UiStepResult -Name "Manage cloud licenses" -Result "Failed" -Note $_.Exception.Message
            }
            continue
        }

        Write-UiStatus -Status "INFO" -Message "Enter exact lowercase a, r, d, or $exitChoice." -Color Yellow
    }
}

function Get-MailboxSizeDecisionInfo {
    param(
        [Parameter(Mandatory = $true)]
        $Mailbox,

        [Parameter(Mandatory = $true)]
        $Statistics
    )

    $mailboxSizeText = [string]$Statistics.TotalItemSize
    $mailboxSizeBytes = $null
    try {
        $mailboxSizeBytes = [int64]$Statistics.TotalItemSize.ToBytes()
    }
    catch {
        if ($mailboxSizeText -match "\(([0-9,]+)\s+bytes\)") {
            $mailboxSizeBytes = [int64]($matches[1] -replace ",", "")
        }
    }

    $mailboxSizeGB = $null
    if ($null -ne $mailboxSizeBytes) {
        $mailboxSizeGB = [math]::Round($mailboxSizeBytes / 1GB, 2)
    }

    return [pscustomobject]@{
        SizeBytes      = $mailboxSizeBytes
        SizeGB         = $mailboxSizeGB
        Under50GB      = ($null -ne $mailboxSizeBytes) -and ($mailboxSizeBytes -lt 50GB)
        ArchiveEnabled = ([string]$Mailbox.ArchiveStatus -in @("Active", "Enabled")) -or ([string]$Mailbox.ArchiveState -notin @("", "None", "Disabled"))
    }
}
