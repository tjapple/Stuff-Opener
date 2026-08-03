$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\harness\Load-TestScript.ps1")
. (Join-Path $here "..\fixtures\TestObjects.ps1")
. (Get-TestSharedPath -Name "powershell_ui.ps1")
. (Get-TestSharedPath -Name "exchange_helpers.ps1")

function Get-Mailbox { param($Identity, $ErrorAction) }
function Set-Mailbox { param($Identity, $Type, $HiddenFromAddressListsEnabled, $MessageCopyForSentAsEnabled, $MessageCopyForSendOnBehalfEnabled, $ErrorAction) }
function Enable-Mailbox { param($Identity, [switch]$Archive, $ErrorAction) }
function Disable-Mailbox { param($Identity, [switch]$Archive, $Confirm, $ErrorAction) }
function Start-Sleep { param($Seconds) }

Describe "Exchange helper behavior" -Tags "Exchange", "Shared" {
    BeforeEach {
        Initialize-TestUiState
        Mock Write-UiStatus { }
        Mock Write-UiBox { }
        Mock Read-UiYesNo { return $true }
        Mock Start-Sleep { }
    }

    It "parses comma, space, and semicolon separated mailbox number selections" {
        $numbers = @(ConvertTo-ExchangeNumberSelection -InputText "1, 2;3" -Max 4)

        $numbers.Count | Should Be 3
        $numbers[0] | Should Be 1
        $numbers[1] | Should Be 2
        $numbers[2] | Should Be 3
    }

    It "detects active archive states" {
        $activeMailbox = New-TestMailbox -ArchiveStatus "Active" -ArchiveState "Local"
        $disabledMailbox = New-TestMailbox -ArchiveStatus "None" -ArchiveState "None"

        (Test-ExchangeMailboxArchiveEnabled -Mailbox $activeMailbox) | Should Be $true
        (Test-ExchangeMailboxArchiveEnabled -Mailbox $disabledMailbox) | Should Be $false
    }

    It "polls mailbox type until Exchange reports the expected type" {
        $script:GetMailboxCalls = 0
        Mock Get-Mailbox {
            $script:GetMailboxCalls++
            if ($script:GetMailboxCalls -lt 2) {
                return New-TestMailbox -RecipientTypeDetails "UserMailbox"
            }

            return New-TestMailbox -RecipientTypeDetails "SharedMailbox"
        }

        $result = Wait-MailboxTypeVerification -UserPrincipalName "jtest@example.com" -ExpectedRecipientTypeDetails "SharedMailbox" -PollSeconds 1 -PollAttempts 3

        $result.Verified | Should Be $true
        $result.CurrentValue | Should Be "SharedMailbox"
        $script:GetMailboxCalls | Should Be 2
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
    }

    It "returns pending verification when mailbox type does not update in time" {
        Mock Get-Mailbox { return New-TestMailbox -RecipientTypeDetails "UserMailbox" }

        $result = Wait-MailboxTypeVerification -UserPrincipalName "jtest@example.com" -ExpectedRecipientTypeDetails "SharedMailbox" -PollSeconds 1 -PollAttempts 2

        $result.Verified | Should Be $false
        $result.CurrentValue | Should Be "UserMailbox"
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
    }

    It "polls archive state until Exchange reports the expected state" {
        $script:GetMailboxCalls = 0
        Mock Get-Mailbox {
            $script:GetMailboxCalls++
            if ($script:GetMailboxCalls -lt 2) {
                return New-TestMailbox -ArchiveStatus "None" -ArchiveState "None"
            }

            return New-TestMailbox -ArchiveStatus "Active" -ArchiveState "Local"
        }

        $result = Wait-MailboxArchiveVerification -UserPrincipalName "jtest@example.com" -ExpectedEnabled $true -PollSeconds 1 -PollAttempts 3

        $result.Verified | Should Be $true
        $result.CurrentValue | Should Match "Enabled=True"
    }

    It "submits mailbox type changes and then verifies the requested type" {
        $snapshot = [pscustomobject]@{
            UserPrincipalName = "jtest@example.com"
            Mailbox           = New-TestMailbox -RecipientTypeDetails "UserMailbox"
        }
        Mock Set-Mailbox { }
        Mock Wait-MailboxTypeVerification {
            return [pscustomobject]@{
                Verified     = $true
                Mailbox      = New-TestMailbox -RecipientTypeDetails "SharedMailbox"
                CurrentValue = "SharedMailbox"
            }
        }

        Invoke-MailboxPropertyChange -UserPrincipalName "jtest@example.com" -Snapshot $snapshot -Action "type" -PollSeconds 1 -PollAttempts 3

        Assert-MockCalled Set-Mailbox -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq "jtest@example.com" -and $Type -eq "Shared" }
        Assert-MockCalled Wait-MailboxTypeVerification -Times 1 -Exactly -Scope It -ParameterFilter { $ExpectedRecipientTypeDetails -eq "SharedMailbox" }
    }
}
