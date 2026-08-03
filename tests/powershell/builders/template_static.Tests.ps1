$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\harness\Load-TestScript.ps1")

Describe "Script builder template static safety checks" -Tags "Static", "Builders" {
    $repoRoot = Get-TestRepoRoot
    $templates = @(
        "script_builders\user_term\template_user_term.ps1",
        "script_builders\user_new\template_user_new.ps1",
        "script_builders\user_lockdown\template_user_lockdown.ps1"
    )

    foreach ($relativePath in $templates) {
        It "parses $relativePath" {
            $path = Join-Path $repoRoot $relativePath
            Test-Path -LiteralPath $path | Should Be $true

            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should Be 0
        }
    }

    It "keeps user_term AD writes anchored to the selected user ObjectGUID" {
        $path = Join-Path $repoRoot "script_builders\user_term\template_user_term.ps1"
        $text = Get-Content -Path $path -Raw

        $text | Should Match 'Disable-ADAccount\s+-Identity\s+\$userObjectGuid'
        $text | Should Match 'Move-ADObject\s+-Identity\s+\$userObjectGuid'
        $text | Should Match 'Set-ADUser\s+-Identity\s+\$userObjectGuid'
        $text | Should Match '(?s)Remove-ADGroupMember.*?-Members\s+\$userObjectGuid'
    }

    It "keeps user_new mapped drive review after AD groups and before sync" {
        $path = Join-Path $repoRoot "script_builders\user_new\template_user_new.ps1"
        $text = Get-Content -Path $path -Raw

        $text | Should Match '\$MappedDriveLetters\s*=\s*""'
        $text | Should Match '\$ResumeExistingUser\s*=\s*\$false'
        $text | Should Match '\$ResumeUserLookup\s*=\s*""'
        $text | Should Match 'Resolve-NewUserAdCreation\s+-CopyAfterUser\s+\$copyAfterUser'
        $text | Should Match 'function\s+Resolve-NewUserResumeAdUser'
        $text | Should Match 'function\s+Read-NewUserExistingUserConflictAction'
        $text | Should Match 'function\s+Request-NewUserResumeFromMatches'
        $text | Should Match 'function\s+Get-NewUserSamConflictMatches'
        $text | Should Match 'function\s+Get-NewUserPrincipalNameConflictMatches'
        $text | Should Match 'function\s+Get-NewUserObjectNameConflictMatches'
        $text | Should Match 'NewUserPendingResumeAdUser'
        $text | Should Match 'Read-NewUserExistingUserConflictAction\s+-ConflictName\s+"UserPrincipalName"'
        $text | Should Match 'Read-NewUserExistingUserConflictAction\s+-ConflictName\s+"sAMAccountName"'
        $text | Should Match 'Read-NewUserExistingUserConflictAction\s+-ConflictName\s+"AD Object Name/CN"'
        $text | Should Match '(?s)Resolve-NewUserPrincipalName.*?Request-NewUserResumeFromMatches'
        $text | Should Match '(?s)Resolve-NewSamAccountName.*?Request-NewUserResumeFromMatches'
        $text | Should Match '(?s)Resolve-NewUserObjectName.*?Request-NewUserResumeFromMatches'
        $text | Should Match 'AD user already exists\. Next action\?'
        $text | Should Match 'r=resume this user'
        $text | Should Match 'Cloud connection failed\. Next action\?'
        $text | Should Match 's=skip cloud steps'
        $text | Should Match 'function\s+Invoke-NewUserCreationPasswordLoop'
        $text | Should Match 'function\s+Get-NewUserAdStateProperties'
        $text | Should Match 'function\s+Get-CloudGroupTypeLabel'
        $text | Should Match 'GroupTypes\s+=\s+Get-CloudGroupTypeLabel\s+-Group'
        $text | Should Match 'Columns\s+@\("Number",\s*"DisplayName",\s*"Management",\s*"DirectorySource",\s*"GroupTypes"\)'
        $text | Should Not Match 'Columns\s+@\("Number",\s*"DisplayName",\s*"Management",\s*"DirectorySource",\s*"MailEnabled",\s*"SecurityEnabled",\s*"GroupTypes"\)'
        $text | Should Match '(?s)Invoke-AdGroupCopyAndReview.*?Invoke-MappedDriveAccessReview.*?Invoke-NewUserDeltaSync'
        $text | Should Match 'Get-GPO\s+-All'
        $text | Should Match 'Get-GPInheritance\s+-Target\s+\$TargetOU'
        $text | Should Match 'Get-ADObject\s+-Identity\s+\$containerDn\s+-Properties\s+gPLink,\s*gPOptions'
        $text | Should Match 'Get-RawGpLinkEntries\s+-GpLink'
        $text | Should Match 'NameLookup'
        $text | Should Match 'User\\Preferences\\Drives\\Drives\.xml'
        $text | Should Match 'function\s+Select-ForceMappedDriveCandidates'
        $text | Should Match 'if\s+\(Test-NewUserForceMode\)\s*\{(?s).*?Select-ForceMappedDriveCandidates'
        $text | Should Match 'Auto-selected mapped drive group'
        $text | Should Match 'Force mode found multiple mappings for drive'
        $text | Should Match 'Add-AdGroupsToNewUser\s+-NewUser\s+\$NewUser\s+-Groups\s+\$groupsToAdd'
    }
}
