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

# Opt-in (default false): when an Azure user's UPN already belongs to a
# pre-existing on-prem account this tool didn't create, adopt that account
# (stamp it with the Azure OID and manage it) instead of skipping. Read
# defensively so configs predating this key default to false under StrictMode.
$adoptExisting = $false
if ($cfg.Sync.PSObject.Properties['AdoptExistingUsers']) {
    $adoptExisting = $cfg.Sync.AdoptExistingUsers -eq $true
}

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

$stats = @{ Created = 0; Updated = 0; Skipped = 0; Conflicts = 0; Adopted = 0; Errors = 0 }

foreach ($gUser in $graphUsers) {
    try {
        $adAttrs = ConvertTo-AdAttributes -GraphUser $gUser -Config $cfg
        $existing = Test-AdUserExists -AzureObjectId $gUser.Id -Server $adSrv

        if (-not $existing) {
            # -- Resolve UPN collisions with unmanaged accounts ---------------
            # Test-AdUserExists only matches accounts already stamped with this
            # Azure OID. An account that exists with this UPN but no OID stamp
            # (a pre-existing identity, or one created by another process) looks
            # "new" here -- and because UPN uniqueness is enforced forest-wide,
            # New-ADUser would fail with a cryptic 'server is unwilling to
            # process the request'. Detect it up front (forest-wide, via the GC).
            $upnConflict = Get-AdUserByUpn -UserPrincipalName $gUser.UserPrincipalName -Server $adSrv
            if ($upnConflict) {
                if (-not $adoptExisting) {
                    Write-SyncLog ("Skipping $($gUser.UserPrincipalName): an AD account with this UPN " +
                                   "already exists ($($upnConflict.DistinguishedName)) and is not managed " +
                                   "by this tool. Set Sync.AdoptExistingUsers = true to adopt it, or " +
                                   "resolve the conflict manually.") -Level WARN
                    $stats.Conflicts++
                    continue
                }

                # Adopt: only an account in the target domain can be adopted in
                # place -- a forest-wide GC hit in another domain can't be pulled
                # into this sync. Re-fetch from the configured (writable) server
                # by UPN, loading the same properties the update diff needs.
                $adopt = Get-ADUser -Filter "UserPrincipalName -eq '$($gUser.UserPrincipalName)'" `
                                    -Server $adSrv `
                                    -Properties 'msDS-cloudExtensionAttribute1', UserPrincipalName, Enabled,
                                                DisplayName, GivenName, Surname, EmailAddress,
                                                Department, Title, MobilePhone, Office, Company `
                                    -ErrorAction SilentlyContinue
                if (-not $adopt) {
                    Write-SyncLog ("Cannot adopt $($gUser.UserPrincipalName): the colliding account " +
                                   "($($upnConflict.DistinguishedName)) is not in the target domain " +
                                   "($adSrv). Skipping.") -Level WARN
                    $stats.Conflicts++
                    continue
                }
                $adoptOid = [string]$adopt.'msDS-cloudExtensionAttribute1'
                if ($adoptOid -and $adoptOid -ne $gUser.Id) {
                    Write-SyncLog ("Cannot adopt $($gUser.UserPrincipalName): account " +
                                   "$($adopt.DistinguishedName) is already managed under a different " +
                                   "Azure OID ($adoptOid). Skipping.") -Level WARN
                    $stats.Conflicts++
                    continue
                }

                if ($script:DryRun) {
                    Write-SyncLog "Would adopt existing account: $($gUser.UserPrincipalName) ($($adopt.DistinguishedName)) - stamp Azure OID $($gUser.Id)"
                } else {
                    Set-ADUser -Identity $adopt.DistinguishedName -Server $adSrv `
                               -Replace @{ 'msDS-cloudExtensionAttribute1' = $gUser.Id }
                    Write-SyncLog "Adopted existing account: $($gUser.UserPrincipalName) ($($adopt.DistinguishedName)) - stamped Azure OID $($gUser.Id)" -Level WARN
                }
                $stats.Adopted++
                # Reconcile attributes this run by flowing into the update path.
                $existing = $adopt
            }
        }

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

Write-SyncLog "=== Sync-Users complete - Created: $($stats.Created), Updated: $($stats.Updated), Skipped: $($stats.Skipped), Adopted: $($stats.Adopted), Conflicts: $($stats.Conflicts), Errors: $($stats.Errors) ==="
