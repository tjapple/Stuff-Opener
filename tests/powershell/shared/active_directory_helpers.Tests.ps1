$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\harness\Load-TestScript.ps1")
. (Join-Path $here "..\fixtures\TestObjects.ps1")
. (Get-TestSharedPath -Name "powershell_ui.ps1")
. (Get-TestSharedPath -Name "active_directory_helpers.ps1")

function Get-ADUser { param($Identity, $Filter, $Properties, $ErrorAction) }

Describe "Active Directory helper lookups" -Tags "AD", "Shared" {
    BeforeEach {
        Initialize-TestUiState
        $script:FakeAdUser = New-TestAdUser
        Mock Write-UiStatus { }
        Mock Write-UiBox { }
        Mock Read-UiYesNo { return $true }
    }

    It "builds exact-match filters and escapes apostrophes" {
        $filter = New-AdUserLookupFilter -Lookup "Ann O'Brien"

        $filter | Should Match "SamAccountName -eq 'Ann O''Brien'"
        $filter | Should Match "GivenName -eq 'Ann'"
        $filter | Should Match "Surname -eq 'O''Brien'"
    }

    It "returns a single non-interactive match without prompting for confirmation" {
        Mock Get-ADUser { return @($script:FakeAdUser) }
        Mock Read-UiYesNo { throw "Should not confirm a single initial exact match." }

        $result = Resolve-AdUserLookup -Lookup "jtest" -Purpose "unit test user"

        $result.SamAccountName | Should Be "jtest"
        $result.ObjectGUID | Should Be $script:FakeAdUser.ObjectGUID
        Assert-MockCalled Get-ADUser -Times 1 -Exactly -Scope It
    }

    It "re-prompts and confirms when the first lookup has no result" {
        $script:GetAdUserCalls = 0
        Reset-TestInputQueue -Inputs @("jtest")
        Mock Read-UiInput { return Read-TestInputQueue }
        Mock Read-UiYesNo { return $true }
        Mock Get-ADUser {
            $script:GetAdUserCalls++
            if ($script:GetAdUserCalls -eq 1) {
                return @()
            }

            return @($script:FakeAdUser)
        }

        $result = Resolve-AdUserLookup -Lookup "missing" -Purpose "unit test user"

        $result.SamAccountName | Should Be "jtest"
        $script:GetAdUserCalls | Should Be 2
        Get-TestInputQueueCount | Should Be 0
    }

    It "uses the provided identity when querying current AD state" {
        $expectedGuid = [string]$script:FakeAdUser.ObjectGUID
        Mock Get-ADUser {
            $Identity | Should Be $expectedGuid
            return $script:FakeAdUser
        }

        $result = Get-AdUserStateSnapshot -Identity $expectedGuid

        $result.ObjectGUID | Should Be $script:FakeAdUser.ObjectGUID
        Assert-MockCalled Get-ADUser -Times 1 -Exactly -Scope It
    }
}
