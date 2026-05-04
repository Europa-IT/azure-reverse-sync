<#
.SYNOPSIS
    Syncs Azure AD security groups and their memberships to on-premises Active Directory.
.DESCRIPTION
    For each security group in Azure AD:
      - Creates the group in LocalAD.GroupsOU if it doesn't exist.
      - Stores the Azure Group OID in adminDescription for reconciliation.
        (msDS-cloudExtensionAttribute1 is User-only; adminDescription is available
        on all AD object types via the Top abstract class.)
      - Adds/removes members to match Azure AD group membership.
        Members must already exist as on-prem AD users (synced by Sync-Users.ps1).

    Must be dot-sourced after Sync-Users.ps1.
#>

Set-StrictMode -Version Latest
Set-PSDebug -Strict
$ErrorActionPreference = 'Stop'

$cfg      = $script:Config
$adSrv    = $cfg.LocalAD.Server
$groupsOU = $cfg.LocalAD.GroupsOU

Write-SyncLog "=== Sync-Groups started ==="

$azureGroups = Get-MgGroup -All -Filter "securityEnabled eq true" `
                            -Property 'id,displayName,description,mailNickname'

$stats = @{ Created = 0; Updated = 0; Skipped = 0; MembersAdded = 0; MembersRemoved = 0; Errors = 0 }

foreach ($azGroup in $azureGroups) {
    try {
        $adGroup = Test-AdGroupExists -AzureObjectId $azGroup.Id -Server $adSrv

        if (-not $adGroup) {
            # -- Create new AD group ------------------------------------------
            $groupName = $azGroup.DisplayName
            if ($script:DryRun) {
                Write-SyncLog "Would create group: $groupName"
            } else {
                $sanitizedGroupName = $groupName -replace '[^a-zA-Z0-9_-]', ''
                $newGroupParams = @{
                    Server          = $adSrv
                    Name            = $groupName
                    SamAccountName  = $sanitizedGroupName.Substring(0, [Math]::Min($sanitizedGroupName.Length, 20))
                    Path            = $groupsOU
                    GroupScope      = 'Global'
                    GroupCategory   = 'Security'
                    OtherAttributes = @{ adminDescription = $azGroup.Id }
                }
                if ($azGroup.Description) { $newGroupParams['Description'] = $azGroup.Description }
                $adGroup = New-ADGroup @newGroupParams -PassThru
                Write-SyncLog "Created group: $groupName"
            }
            $stats.Created++
        } else {
            Write-Debug "AD Group $adGroup already exists."
        }

        if ($script:DryRun) {
            $stats.Skipped++
            continue
        }

        # -- Reconcile membership ---------------------------------------------
        # @() ensures $azureMembers is always an array even when Graph returns
        # a single item (bare string) or nothing ($null).
        $azureMembers = @(Get-MgGroupMember -GroupId $azGroup.Id -All | Select-Object -ExpandProperty Id)

        # Get current on-prem AD members (only users, not nested groups for now)
        $adMembers = @()
        if ($adGroup) {
            $adMembers = @(Get-ADGroupMember -Identity $adGroup.DistinguishedName -Server $adSrv |
                         Where-Object { $_.objectClass -eq 'user' })
        }

        # Build map: Azure OID -> AD user DN for current AD group members.
        # Query msDS-cloudExtensionAttribute1 directly on each member rather than
        # using a pre-fetched DN-keyed map; the pre-fetch approach silently produced
        # an empty map when Get-ADGroupMember DN types differed from Get-ADUser keys.
        $adMemberByAzureOid = @{}
        foreach ($adMember in $adMembers) {
            $adUserObj = Get-ADUser -Identity $adMember.DistinguishedName `
                                    -Server $adSrv `
                                    -Properties 'msDS-cloudExtensionAttribute1' `
                                    -ErrorAction SilentlyContinue
            if ($adUserObj -and $adUserObj.'msDS-cloudExtensionAttribute1') {
                $oid = [string]$adUserObj.'msDS-cloudExtensionAttribute1'
                $adMemberByAzureOid[$oid] = $adMember.DistinguishedName
            }
        }

        $ActuallyUpdated = $false

        # Add missing members
        foreach ($azMemberId in $azureMembers) {

            Write-Debug "Checking $azMemberId against $($adGroup.Name)"

            if (-not $adMemberByAzureOid.ContainsKey($azMemberId)) {
                $adUser = Test-AdUserExists -AzureObjectId $azMemberId -Server $adSrv
                if ($adUser) {

                    Write-Debug "User $(adUser.name) matched, needs to be added to group."

                    Add-ADGroupMember -Identity $adGroup.DistinguishedName `
                                      -Members $adUser.DistinguishedName -Server $adSrv
                    Write-SyncLog "Added $($adUser.UserPrincipalName) to group $($azGroup.DisplayName)"
                    $stats.MembersAdded++
                    $ActuallyUpdated = $true
                } else {
                    Write-SyncLog "Skipping member Azure OID $azMemberId - not yet synced to on-prem AD" -Level WARN
                }
            }
        }

        # Remove extra members (in AD but not in Azure)
        foreach ($oid in $adMemberByAzureOid.Keys) {

            Write-Debug "Checking $oid against $(adGroup.name)"

            if ($oid -notin $azureMembers) {

                Write-Debug "$(adMemberByAzureOid[$oid].Name) removed from $($adGroup.Name)"

                Remove-ADGroupMember -Identity $adGroup.DistinguishedName `
                                     -Members $adMemberByAzureOid[$oid] -Server $adSrv -Confirm:$false
                Write-SyncLog "Removed Azure OID $oid from group $($azGroup.DisplayName)"
                $stats.MembersRemoved++
                $ActuallyUpdated = $true
            }
        }

        if ($ActuallyUpdated) {
            $stats.Updated++
        }

    } catch {
        Write-SyncLog "Error processing group $($azGroup.DisplayName): $_" -Level ERROR
        $stats.Errors++
    }
}

Write-SyncLog "=== Sync-Groups complete - Created: $($stats.Created), Updated: $($stats.Updated), MembersAdded: $($stats.MembersAdded), MembersRemoved: $($stats.MembersRemoved), Errors: $($stats.Errors) ==="
