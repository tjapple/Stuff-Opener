function New-TestAdUser {
    param(
        [string]$SamAccountName = "jtest",
        [string]$UserPrincipalName = "jtest@lab.local",
        [string]$Mail = "jtest@lab.local",
        [string]$Name = "Jimmy Test",
        [string]$GivenName = "Jimmy",
        [string]$Surname = "Test",
        [bool]$Enabled = $true,
        [bool]$LockedOut = $false,
        [guid]$ObjectGuid = [guid]"11111111-1111-1111-1111-111111111111",
        [byte[]]$ConsistencyGuid = $null,
        [string]$DistinguishedName = "CN=Jimmy Test,OU=Users,DC=lab,DC=local"
    )

    $user = [pscustomobject][ordered]@{
        Name                    = $Name
        DisplayName             = $Name
        SamAccountName          = $SamAccountName
        UserPrincipalName       = $UserPrincipalName
        mail                    = $Mail
        GivenName               = $GivenName
        Surname                 = $Surname
        Enabled                 = $Enabled
        LockedOut               = $LockedOut
        PasswordExpired         = $false
        PasswordLastSet         = Get-Date "2026-01-01"
        badPwdCount             = 0
        LastBadPasswordAttempt  = $null
        AccountLockoutTime      = $null
        Description             = ""
        Manager                 = ""
        DistinguishedName       = $DistinguishedName
        MemberOf                = @()
        ObjectGUID              = $ObjectGuid
        whenCreated             = Get-Date "2026-01-01"
        whenChanged             = Get-Date "2026-01-02"
        LastLogonDate           = Get-Date "2026-01-03"
        "mS-DS-ConsistencyGuid" = $ConsistencyGuid
    }

    return $user
}

function New-TestCloudUser {
    param(
        [string]$Id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        [string]$DisplayName = "Jimmy Test",
        [string]$UserPrincipalName = "jtest@tenant.example",
        [string]$Mail = "jtest@tenant.example",
        [string]$MailNickname = "jtest",
        [bool]$AccountEnabled = $true,
        [bool]$OnPremisesSyncEnabled = $true,
        [string]$OnPremisesImmutableId = "anchor==",
        [string]$OnPremisesSamAccountName = "jtest",
        [string]$UsageLocation = "US",
        [object[]]$AssignedLicenses = @()
    )

    return [pscustomobject][ordered]@{
        id                         = $Id
        displayName                = $DisplayName
        userPrincipalName          = $UserPrincipalName
        mail                       = $Mail
        mailNickname               = $MailNickname
        givenName                  = "Jimmy"
        surname                    = "Test"
        accountEnabled             = $AccountEnabled
        onPremisesSyncEnabled      = $OnPremisesSyncEnabled
        onPremisesImmutableId      = $OnPremisesImmutableId
        onPremisesSamAccountName   = $OnPremisesSamAccountName
        usageLocation              = $UsageLocation
        assignedLicenses           = @($AssignedLicenses)
        createdDateTime            = "2026-01-01T00:00:00Z"
        deletedDateTime            = $null
    }
}

function New-TestMailbox {
    param(
        [string]$UserPrincipalName = "jtest@tenant.example",
        [string]$DisplayName = "Jimmy Test",
        [string]$RecipientTypeDetails = "UserMailbox",
        [bool]$HiddenFromAddressListsEnabled = $false,
        [bool]$MessageCopyForSentAsEnabled = $false,
        [bool]$MessageCopyForSendOnBehalfEnabled = $false,
        [string]$ArchiveStatus = "None",
        [string]$ArchiveState = "None"
    )

    return [pscustomobject][ordered]@{
        Identity                            = $UserPrincipalName
        DisplayName                         = $DisplayName
        PrimarySmtpAddress                  = $UserPrincipalName
        RecipientTypeDetails                = $RecipientTypeDetails
        HiddenFromAddressListsEnabled       = $HiddenFromAddressListsEnabled
        MessageCopyForSentAsEnabled         = $MessageCopyForSentAsEnabled
        MessageCopyForSendOnBehalfEnabled   = $MessageCopyForSendOnBehalfEnabled
        ArchiveStatus                       = $ArchiveStatus
        ArchiveState                        = $ArchiveState
        GrantSendOnBehalfTo                 = @()
    }
}

function New-TestMailboxStatistics {
    param(
        [string]$TotalItemSize = "31.54 KB (32,300 bytes)",
        [int]$ItemCount = 4
    )

    return [pscustomobject]@{
        TotalItemSize = $TotalItemSize
        ItemCount     = $ItemCount
    }
}

function New-TestSku {
    param(
        [string]$SkuId = "bbbbbbbb-1111-2222-3333-cccccccccccc",
        [string]$SkuPartNumber = "SPB",
        [int]$Enabled = 10,
        [int]$Consumed = 2,
        [int]$Warning = 0,
        [int]$Suspended = 0,
        [int]$LockedOut = 0,
        [string]$AppliesTo = "User",
        [string]$CapabilityStatus = "Enabled"
    )

    return [pscustomobject]@{
        skuId            = $SkuId
        skuPartNumber    = $SkuPartNumber
        appliesTo        = $AppliesTo
        capabilityStatus = $CapabilityStatus
        consumedUnits    = $Consumed
        prepaidUnits     = [pscustomobject]@{
            enabled   = $Enabled
            warning   = $Warning
            suspended = $Suspended
            lockedOut = $LockedOut
        }
    }
}

function New-TestAssignedLicense {
    param(
        [string]$SkuId = "bbbbbbbb-1111-2222-3333-cccccccccccc"
    )

    return [pscustomobject]@{
        skuId = $SkuId
    }
}

function New-TestLicenseRow {
    param(
        [string]$License = "Microsoft 365 Business Premium",
        [string]$SkuId = "bbbbbbbb-1111-2222-3333-cccccccccccc",
        [string]$SkuPartNumber = "SPB",
        [int]$Available = 8
    )

    return [pscustomobject]@{
        License       = $License
        SkuId         = $SkuId
        SkuPartNumber = $SkuPartNumber
        Available     = $Available
    }
}
