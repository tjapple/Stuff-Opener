$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\harness\Load-TestScript.ps1")
. (Join-Path $here "..\fixtures\TestObjects.ps1")
. (Get-TestSharedPath -Name "powershell_ui.ps1")
. (Get-TestSharedPath -Name "mg_graph_helpers.ps1")

function Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $ErrorAction) }

Describe "Microsoft Graph helper lookups" -Tags "Graph", "Shared" {
    BeforeEach {
        Initialize-TestUiState
        Mock Write-UiStatus { }
        Mock Write-UiBox { }
    }

    It "builds exact-match cloud lookup filters" {
        $filter = New-GraphUserLookupFilter -Lookup "Ann O'Brien"

        $filter | Should Match "userPrincipalName eq 'Ann O''Brien'"
        $filter | Should Match "mailNickname eq 'Ann O''Brien'"
        $filter | Should Match "givenName eq 'Ann'"
        $filter | Should Match "surname eq 'O''Brien'"
    }

    It "builds encoded Graph user URIs with a select clause" {
        $uri = Get-GraphUserUri -UserIdOrUpn "j.test+lab@example.com" -Select "id,userPrincipalName"

        $uri | Should Be "https://graph.microsoft.com/v1.0/users/j.test%2Blab%40example.com?`$select=id,userPrincipalName"
    }

    It "returns stable cloud identity details for one match" {
        $cloudUser = New-TestCloudUser -Id "cloud-id-1" -UserPrincipalName "jtest@tenant.example"
        Mock Invoke-MgGraphRequest { return [pscustomobject]@{ value = @($cloudUser) } }

        $result = Resolve-CloudUserLookup -Lookup "jtest@tenant.example" -Purpose "delegate"

        $result.Id | Should Be "cloud-id-1"
        $result.UserPrincipalName | Should Be "jtest@tenant.example"
        Assert-MockCalled Invoke-MgGraphRequest -Times 1 -Exactly -Scope It
    }

    It "deduplicates users by id before falling back to UPN" {
        $users = @(
            (New-TestCloudUser -Id "same" -UserPrincipalName "one@example.com"),
            (New-TestCloudUser -Id "same" -UserPrincipalName "two@example.com"),
            ([pscustomobject]@{ id = ""; userPrincipalName = "fallback@example.com" }),
            ([pscustomobject]@{ id = ""; userPrincipalName = "fallback@example.com" })
        )

        $result = @(Get-UniqueCloudUsers -Users $users)

        $result.Count | Should Be 2
        $result[0].id | Should Be "same"
        $result[1].userPrincipalName | Should Be "fallback@example.com"
    }
}
