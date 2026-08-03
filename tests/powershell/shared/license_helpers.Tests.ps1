$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\harness\Load-TestScript.ps1")
. (Join-Path $here "..\fixtures\TestObjects.ps1")
. (Get-TestSharedPath -Name "powershell_ui.ps1")
. (Get-TestSharedPath -Name "mg_graph_helpers.ps1")
. (Get-TestSharedPath -Name "license_helpers.ps1")

function Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $ErrorAction) }

Describe "License helper behavior" -Tags "License", "Shared" {
    BeforeEach {
        Initialize-TestUiState
        Mock Write-UiStatus { }
        Mock Write-UiBox { }
        Mock Read-UiYesNo { return $true }
    }

    It "maps common SKU part numbers to portal-friendly names" {
        $names = Get-SkuCommonNames

        $names["SPB"] | Should Be "Microsoft 365 Business Premium"
        $names["POWER_BI_PRO"] | Should Be "Power BI Pro"
        $names["POWER_BI_STANDARD"] | Should Be "Microsoft Fabric Free"
    }

    It "parses comma, space, and semicolon separated license number selections" {
        $numbers = @(ConvertTo-LicenseNumberSelection -InputText "1, 2;3" -Max 4)

        $numbers.Count | Should Be 3
        $numbers[0] | Should Be 1
        $numbers[1] | Should Be 2
        $numbers[2] | Should Be 3
    }

    It "rejects invalid license selections" {
        @(ConvertTo-LicenseNumberSelection -InputText "1, nope" -Max 4).Count | Should Be 0
        @(ConvertTo-LicenseNumberSelection -InputText "5" -Max 4).Count | Should Be 0
    }

    It "loads cloud user and tenant license snapshots from Graph" {
        $sku = New-TestSku -SkuId "sku-spb" -SkuPartNumber "SPB" -Enabled 5 -Consumed 3
        $assigned = New-TestAssignedLicense -SkuId "sku-spb"
        $cloudUser = New-TestCloudUser -Id "cloud-id-1" -AssignedLicenses @($assigned)
        Mock Invoke-MgGraphRequest {
            if ($Uri -like "*subscribedSkus*") {
                return [pscustomobject]@{ value = @($sku) }
            }

            return $cloudUser
        }

        $snapshot = Get-CloudUserLicenseSnapshot -UserIdOrUpn "cloud-id-1"

        $snapshot.AssignedRows.Count | Should Be 1
        $snapshot.AssignedRows[0].License | Should Be "Microsoft 365 Business Premium"
        $snapshot.AvailableRows[0].Available | Should Be 2
    }

    It "loads every subscribed SKU page returned by Graph" {
        $firstSku = New-TestSku -SkuId "sku-flow" -SkuPartNumber "FLOW_FREE" -Enabled 100 -Consumed 1
        $secondSku = New-TestSku -SkuId "sku-spb" -SkuPartNumber "SPB" -Enabled 5 -Consumed 3
        $cloudUser = New-TestCloudUser -Id "cloud-id-1"
        Mock Invoke-MgGraphRequest {
            if ($Uri -like "*page2") {
                return [pscustomobject]@{ value = @($secondSku) }
            }
            if ($Uri -like "*subscribedSkus*") {
                return [pscustomobject]@{
                    value             = @($firstSku)
                    '@odata.nextLink' = "https://graph.microsoft.com/v1.0/subscribedSkus/page2"
                }
            }

            return $cloudUser
        }

        $snapshot = Get-CloudUserLicenseSnapshot -UserIdOrUpn "cloud-id-1"

        $snapshot.TenantRows.Count | Should Be 2
        @($snapshot.TenantRows | Where-Object { $_.SkuPartNumber -eq "SPB" }).Count | Should Be 1
        @($snapshot.AvailableRows | Where-Object { $_.SkuPartNumber -eq "SPB" }).Count | Should Be 1
    }

    It "counts warning units as enabled availability" {
        $sku = New-TestSku -SkuId "sku-defender" -SkuPartNumber "ATP_ENTERPRISE" -Enabled 24 -Warning 5 -Consumed 25
        $cloudUser = New-TestCloudUser -Id "cloud-id-1"
        Mock Invoke-MgGraphRequest {
            if ($Uri -like "*subscribedSkus*") {
                return [pscustomobject]@{ value = @($sku) }
            }

            return $cloudUser
        }

        $snapshot = Get-CloudUserLicenseSnapshot -UserIdOrUpn "cloud-id-1"
        $row = @($snapshot.TenantRows)[0]

        $row.Enabled | Should Be 29
        $row.GraphEnabled | Should Be 24
        $row.Available | Should Be 4
        $row.AvailableWithWarning | Should Be 4
        $row.Warning | Should Be 5
        $row.CapabilityStatus | Should Be "Enabled"
        @($snapshot.AvailableRows).Count | Should Be 1
    }

    It "sets a blank UsageLocation before license assignment" {
        $cloudUser = New-TestCloudUser -Id "cloud-id-1" -UsageLocation ""
        $snapshot = [pscustomobject]@{ CloudUser = $cloudUser }
        Mock Invoke-MgGraphRequest { return [pscustomobject]@{} }

        $result = Ensure-CloudUserUsageLocationForLicenseAssignment -Snapshot $snapshot

        $result | Should Be $true
        $snapshot.CloudUser.usageLocation | Should Be "US"
        Assert-MockCalled Invoke-MgGraphRequest -Times 1 -Exactly -Scope It
    }

    It "posts assignLicense requests to the selected cloud user" {
        $addRow = New-TestLicenseRow -SkuId "sku-add" -License "Power BI Pro"
        $removeRow = New-TestLicenseRow -SkuId "sku-remove" -License "Old License"
        $script:LastGraphCall = $null
        Mock Invoke-MgGraphRequest {
            $script:LastGraphCall = [pscustomobject]@{
                Method      = $Method
                Uri         = $Uri
                Body        = $Body
                ContentType = $ContentType
            }
            return [pscustomobject]@{}
        }

        Invoke-CloudUserLicenseAssignment -UserIdOrUpn "cloud-id-1" -AddLicenseRows @($addRow) -RemoveLicenseRows @($removeRow) | Out-Null
        $body = $script:LastGraphCall.Body | ConvertFrom-Json

        $script:LastGraphCall.Method | Should Be "POST"
        $script:LastGraphCall.Uri | Should Match "/users/cloud-id-1/assignLicense$"
        $body.addLicenses[0].skuId | Should Be "sku-add"
        $body.removeLicenses[0] | Should Be "sku-remove"
    }
}
