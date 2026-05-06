<#
.SYNOPSIS
    Syncs Azure AD users to on-premises Active Directory.
.DESCRIPTION
    For each user in Azure AD:
      - Creates a new AD user if one with the matching Azure OID (msDS-cloudExtensionAttribute1) does not exist.
      - Updates an existing AD user's attributes if any have changed.
      - Stores the Azure AD Object ID in msDS-cloudExtensionAttribute1 for stable identity reconciliation.

    Account enable/disable logic is handled separately by Sync-AccountState.ps1.
    Must be dot-sourced after Connect-GraphApi.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg      = $script:Config
$adSrv    = $cfg.LocalAD.Server
$targetOU = $cfg.LocalAD.TargetOU

Write-SyncLog "=== Sync-Users started ==="

$filterGroupId     = $cfg.Sync.FilterGroupId
$licensedUsersOnly = $cfg.Sync.LicensedUsersOnly -eq $true

if ($filterGroupId) {
    # -- Scope to members of a specific Azure AD group ------------------------
    Write-SyncLog "Fetching users from filter group: $filterGroupId"
    $groupMemberIds = Get-MgGroupMember -GroupId $filterGroupId -All | Select-Object -ExpandProperty Id
    $graphUsers = foreach ($memberId in $groupMemberIds) {
        Get-MgUser -UserId $memberId -Property @(
            'id','displayName','givenName','surname','userPrincipalName',
            'mail','department','jobTitle','mobilePhone','officeLocation',
            'companyName','accountEnabled','assignedLicenses'
        ) -ErrorAction SilentlyContinue
    }
} elseif ($licensedUsersOnly) {
    # -- Licensed users: Graph filter requires ConsistencyLevel header ---------
    Write-SyncLog "Fetching licensed users only (LicensedUsersOnly = true)"
    $graphUsers = Get-MgUser -All `
        -Filter 'assignedLicenses/$count ne 0' `
        -ConsistencyLevel eventual `
        -CountVariable userCount `
        -Property @(
            'id','displayName','givenName','surname','userPrincipalName',
            'mail','department','jobTitle','mobilePhone','officeLocation',
            'companyName','accountEnabled','assignedLicenses'
        )
} else {
    $graphUsers = Get-MgUser -All -Property @(
        'id','displayName','givenName','surname','userPrincipalName',
        'mail','department','jobTitle','mobilePhone','officeLocation',
        'companyName','accountEnabled'
    )
}

# Always exclude guest accounts regardless of filter mode
$graphUsers = @($graphUsers) | Where-Object { $_.UserPrincipalName -notlike '*#EXT#*' }
Write-SyncLog "Users to sync: $(@($graphUsers).Count)"

# Publish the set of Azure user IDs that passed the sync filter so
# Sync-Groups.ps1 can distinguish "this group member was filtered out
# of the sync intentionally" from "this is a real on-prem AD gap."
# Both scripts share the orchestrator's $script: scope via dot-sourcing.
$script:SyncableUserIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($u in $graphUsers) { [void]$script:SyncableUserIds.Add([string]$u.Id) }

$stats = @{ Created = 0; Updated = 0; Skipped = 0; Errors = 0 }

foreach ($gUser in $graphUsers) {
    try {
        $adAttrs = ConvertTo-AdAttributes -GraphUser $gUser -Config $cfg
        $existing = Test-AdUserExists -AzureObjectId $gUser.Id -Server $adSrv

        if (-not $existing) {
            # -- Create new AD user -------------------------------------------
            # Strip characters not allowed in SamAccountName (e.g. apostrophes, dots,
            # spaces) before truncating, matching the sanitization Sync-Groups.ps1
            # already applies to group names. Truncate via Math.Min so a sanitized
            # value shorter than the original doesn't blow Substring with an
            # ArgumentOutOfRangeException.
            $samLocal   = $gUser.UserPrincipalName -replace '@.*', ''
            $samAccount = $samLocal -replace '[^a-zA-Z0-9_-]', ''
            $samAccount = $samAccount.Substring(0, [Math]::Min($samAccount.Length, 20))

            $newUserParams = @{
                Server                 = $adSrv
                Path                   = $targetOU
                SamAccountName         = $samAccount
                UserPrincipalName      = $gUser.UserPrincipalName
                Name                   = $gUser.DisplayName
                DisplayName            = $gUser.DisplayName
                GivenName              = $gUser.GivenName
                Surname                = $gUser.Surname
                EmailAddress           = $gUser.Mail
                Enabled                = $true
                ChangePasswordAtLogon  = $true
                OtherAttributes        = @{ 'msDS-cloudExtensionAttribute1' = $gUser.Id }
            }

            # Add optional mapped attributes
            foreach ($key in @('Department','Title','MobilePhone','Office','Company')) {
                if ($adAttrs.ContainsKey($key)) { $newUserParams[$key] = $adAttrs[$key] }
            }

            if ($script:DryRun) {
                Write-SyncLog "Would create user: $($gUser.UserPrincipalName) (SAM: $samAccount)"
            } else {
                $tempPw = New-SecureRandomPassword
                New-ADUser @newUserParams -AccountPassword $tempPw
                Write-SyncLog "Created user: $($gUser.UserPrincipalName) (SAM: $samAccount)"
            }
            $stats.Created++

        } else {
            # -- Update existing AD user --------------------------------------
            $setParams = @{ Server = $adSrv; Identity = $existing.DistinguishedName }
            $changes   = @{}

            # Set-ADUser parameter name -> Graph user property name. Keys are also the
            # ADUser property names exposed by Get-ADUser when loaded via -Properties,
            # so the same map drives both the diff and the splatted Set-ADUser call.
            $fieldMap = @{
                DisplayName  = 'DisplayName'
                GivenName    = 'GivenName'
                Surname      = 'Surname'
                EmailAddress = 'Mail'
                Department   = 'Department'
                Title        = 'JobTitle'
                MobilePhone  = 'MobilePhone'
                Office       = 'OfficeLocation'
                Company      = 'CompanyName'
            }

            foreach ($adParam in $fieldMap.Keys) {
                $graphVal = $gUser.($fieldMap[$adParam])
                $adVal    = $existing.$adParam
                if ($graphVal -and $graphVal -ne $adVal) {
                    $changes[$adParam] = $graphVal
                }
            }

            if ($changes.Count -gt 0) {
                if ($script:DryRun) {
                    Write-SyncLog "Would update $($gUser.UserPrincipalName): $($changes.Keys -join ', ')"
                } else {
                    Set-ADUser @setParams @changes
                    Write-SyncLog "Updated $($gUser.UserPrincipalName): $($changes.Keys -join ', ')"
                }
                $stats.Updated++
            } else {
                $stats.Skipped++
            }
        }
    } catch {
        Write-SyncLog "Error processing user $($gUser.UserPrincipalName): $_" -Level ERROR
        $stats.Errors++
    }
}

Write-SyncLog "=== Sync-Users complete - Created: $($stats.Created), Updated: $($stats.Updated), Skipped: $($stats.Skipped), Errors: $($stats.Errors) ==="
