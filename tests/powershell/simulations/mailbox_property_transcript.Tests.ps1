$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\harness\Load-TestScript.ps1")
. (Join-Path $here "..\fixtures\TestObjects.ps1")
. (Get-TestSharedPath -Name "powershell_ui.ps1")
. (Get-TestSharedPath -Name "exchange_helpers.ps1")

function Get-Mailbox { param($Identity, $ErrorAction) }
function Get-MailboxStatistics { param($Identity, $ErrorAction) }
function Get-MailboxPermission { param($Identity, $ErrorAction) }
function Get-RecipientPermission { param($Identity, $ErrorAction) }
function Set-Mailbox { param($Identity, $Type, $HiddenFromAddressListsEnabled, $MessageCopyForSentAsEnabled, $MessageCopyForSendOnBehalfEnabled, $ErrorAction) }
function Get-Recipient { param($Identity, $ErrorAction) }
function Start-Sleep { param($Seconds) }

Describe "Mailbox property manager transcript simulation" -Tags "Simulation", "Exchange" {
    BeforeEach {
        Initialize-TestUiState
        Reset-TestInputQueue -Inputs @("t", "y", "x")
        Mock Read-UiInput { return Read-TestInputQueue }
        Mock Write-UiStatus { }
        Mock Write-UiBox { }
        Mock Start-Sleep { }
        Mock Get-MailboxStatistics { return New-TestMailboxStatistics }
        Mock Get-MailboxPermission { return @() }
        Mock Get-RecipientPermission { return @() }
        Mock Set-Mailbox { }
    }

    It "lets a technician choose type toggle, confirms it, verifies it, and exits" {
        $script:GetMailboxCalls = 0
        Mock Get-Mailbox {
            $script:GetMailboxCalls++
            if ($script:GetMailboxCalls -lt 3) {
                return New-TestMailbox -UserPrincipalName "jtest@example.com" -RecipientTypeDetails "UserMailbox"
            }

            return New-TestMailbox -UserPrincipalName "jtest@example.com" -RecipientTypeDetails "SharedMailbox"
        }

        Invoke-InteractiveMailboxPropertyManager -UserPrincipalName "jtest@example.com" -PollSeconds 1 -PollAttempts 3

        Assert-MockCalled Set-Mailbox -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq "jtest@example.com" -and $Type -eq "Shared" }
        Get-TestInputQueueCount | Should Be 0
    }
}
