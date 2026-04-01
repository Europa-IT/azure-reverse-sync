<#
.SYNOPSIS
    Syncs Azure AD security groups and their memberships to on-premises Active Directory.
.DESCRIPTION
    For each security group in Azure AD:
      - Creates the group in LocalAD.GroupsOU if it doesn't exist.
      - Stores the Azure Group OID in extensionAttribute1 for reconciliation.
      - Adds/removes members to match Azure AD group membership.
        Members must already exist as on-prem AD users (synced by Sync-Users.ps1).

    Must be dot-sourced after Sync-Users.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg      = $script:Config
$adSrv    = $cfg.LocalAD.Server
$groupsOU = $cfg.LocalAD.GroupsOU

Write-SyncLog "=== Sync-Groups started ==="

# Pre-fetch all managed AD users (those with extensionAttribute1 set) and build a
# DN → Azure OID map. This eliminates per-member Get-ADUser calls inside the group loop,
# reducing AD queries from O(members × groups) to a single upfront fetch.
$managedAdUserMap = @{}  # DistinguishedName → extensionAttribute1
Get-ADUser -Filter { extensionAttribute1 -like '*-*-*-*-*' } `
           -Server $adSrv `
           -Properties extensionAttribute1 |
    ForEach-Object {
        $managedAdUserMap[$_.DistinguishedName] = $_.extensionAttribute1
    }

$azureGroups = Get-MgGroup -All -Filter "securityEnabled eq true" `
                            -Property 'id,displayName,description,mailNickname'

$stats = @{ Created = 0; Updated = 0; Skipped = 0; MembersAdded = 0; MembersRemoved = 0; Errors = 0 }

foreach ($azGroup in $azureGroups) {
    try {
        $adGroup = Test-AdGroupExists -AzureObjectId $azGroup.Id -Server $adSrv

        if (-not $adGroup) {
            # ── Create new AD group ───────────────────────────────────────────
            $groupName = $azGroup.DisplayName
            if ($script:DryRun) {
                Write-SyncLog "[DRYRUN] Would create group: $groupName"
            } else {
                $newGroupParams = @{
                    Server          = $adSrv
                    Name            = $groupName
                    SamAccountName  = ($groupName -replace '[^a-zA-Z0-9_-]', '').Substring(0, [Math]::Min($groupName.Length, 20))
                    Path            = $groupsOU
                    GroupScope      = 'Global'
                    GroupCategory   = 'Security'
                    OtherAttributes = @{ extensionAttribute1 = $azGroup.Id }
                }
                if ($azGroup.Description) { $newGroupParams['Description'] = $azGroup.Description }   
                $adGroup = New-ADGroup @newGroupParams -PassThru
                Write-SyncLog "Created group: $groupName"
            }
            $stats.Created++
        }

        if ($script:DryRun) {
            $stats.Skipped++
            continue
        }

        # ── Reconcile membership ──────────────────────────────────────────────
        $azureMembers = Get-MgGroupMember -GroupId $azGroup.Id -All | Select-Object -ExpandProperty Id

        # Get current on-prem AD members (only users, not nested groups for now)
        $adMembers = @()
        if ($adGroup) {
            $adMembers = Get-ADGroupMember -Identity $adGroup.DistinguishedName -Server $adSrv |
                         Where-Object { $_.objectClass -eq 'user' }
        }

        # Build map: Azure OID → AD user DN for current AD members.
        # Uses the pre-fetched $managedAdUserMap instead of per-member AD queries.
        $adMemberByAzureOid = @{}
        foreach ($adMember in $adMembers) {
            $oid = $managedAdUserMap[$adMember.DistinguishedName]
            if ($oid) { $adMemberByAzureOid[$oid] = $adMember.DistinguishedName }
        }

        # Add missing members
        foreach ($azMemberId in $azureMembers) {
            if (-not $adMemberByAzureOid.ContainsKey($azMemberId)) {
                $adUser = Test-AdUserExists -AzureObjectId $azMemberId -Server $adSrv
                if ($adUser) {
                    Add-ADGroupMember -Identity $adGroup.DistinguishedName `
                                      -Members $adUser.DistinguishedName -Server $adSrv
                    Write-SyncLog "Added $($adUser.UserPrincipalName) to group $($azGroup.DisplayName)"
                    $stats.MembersAdded++
                } else {
                    Write-SyncLog "Skipping member Azure OID $azMemberId — not yet synced to on-prem AD" -Level WARN
                }
            }
        }

        # Remove extra members (in AD but not in Azure)
        foreach ($oid in $adMemberByAzureOid.Keys) {
            if (-not $azureMembers.Contains($oid)) {
                Remove-ADGroupMember -Identity $adGroup.DistinguishedName `
                                     -Members $adMemberByAzureOid[$oid] -Server $adSrv -Confirm:$false
                Write-SyncLog "Removed Azure OID $oid from group $($azGroup.DisplayName)"
                $stats.MembersRemoved++
            }
        }

        $stats.Updated++

    } catch {
        Write-SyncLog "Error processing group $($azGroup.DisplayName): $_" -Level ERROR
        $stats.Errors++
    }
}

Write-SyncLog "=== Sync-Groups complete — Created: $($stats.Created), Updated: $($stats.Updated), MembersAdded: $($stats.MembersAdded), MembersRemoved: $($stats.MembersRemoved), Errors: $($stats.Errors) ==="
