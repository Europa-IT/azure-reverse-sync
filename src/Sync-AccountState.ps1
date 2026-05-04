<#
.SYNOPSIS
    Syncs Azure AD account to on-premises Active Directory.
.DESCRIPTION
    For every on-prem AD user that was created by this tool (identified by extensionAttribute1
    containing an Azure AD Object ID):

      - If the Azure AD account is disabled  → Disable-ADAccount
      - If the Azure AD account is enabled   → Enable-ADAccount
      - If the user no longer exists in Azure AD and DisableDeletedUsers = true
          → Disable-ADAccount + move to DisabledOU

    Must be dot-sourced after Sync-Users.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg        = $script:Config
$adSrv      = $cfg.LocalAD.Server
$disabledOU = $cfg.LocalAD.DisabledOU

Write-SyncLog "=== Sync-AccountState started ==="

# Fetch all on-prem users that have extensionAttribute1 set (managed by this tool)
$managedAdUsers = Get-ADUser -Filter { extensionAttribute1 -like '*-*-*-*-*' } `
                             -Server $adSrv `
                             -Properties extensionAttribute1, Enabled, DistinguishedName

# Fetch all Azure AD users once and build an OID → accountEnabled map.
# This single call replaces both the ID-set lookup and the per-user Get-MgUser calls below,
# reducing Graph API round-trips from N+1 (one per managed AD user) to 1.
$azureUserMap = @{}
Get-MgUser -All -Property 'id,accountEnabled' | ForEach-Object {
    $azureUserMap[$_.Id] = $_.AccountEnabled
}

$stats = @{ Enabled = 0; Disabled = 0; MovedToDisabled = 0; Skipped = 0; Errors = 0 }

foreach ($adUser in $managedAdUsers) {
    $azureOid = $adUser.extensionAttribute1
    try {
        if (-not $azureUserMap.ContainsKey($azureOid)) {
            # ── User removed from Azure AD ────────────────────────────────────
            if ($cfg.Sync.DisableDeletedUsers) {
                if ($script:DryRun) {
                    Write-SyncLog "Would disable+move deleted user: $($adUser.UserPrincipalName)"
                } else {
                    Disable-ADAccount -Identity $adUser.DistinguishedName -Server $adSrv
                    Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $disabledOU -Server $adSrv
                    Write-SyncLog "Disabled+moved deleted Azure user: $($adUser.UserPrincipalName)" -Level WARN
                }
                $stats.Disabled++
                $stats.MovedToDisabled++
            }
            continue
        }

        # ── User exists in Azure AD - sync enabled state ──────────────────────
        $shouldBeEnabled = $azureUserMap[$azureOid]

        if ($shouldBeEnabled -and -not $adUser.Enabled) {
            if ($script:DryRun) {
                Write-SyncLog "Would enable: $($adUser.UserPrincipalName)"
            } else {
                Enable-ADAccount -Identity $adUser.DistinguishedName -Server $adSrv
                Write-SyncLog "Enabled: $($adUser.UserPrincipalName)"
            }
            $stats.Enabled++

        } elseif (-not $shouldBeEnabled -and $adUser.Enabled) {
            if ($script:DryRun) {
                Write-SyncLog "Would disable: $($adUser.UserPrincipalName)"
            } else {
                Disable-ADAccount -Identity $adUser.DistinguishedName -Server $adSrv
                Write-SyncLog "Disabled: $($adUser.UserPrincipalName)"
            }
            $stats.Disabled++

        } else {
            $stats.Skipped++
        }

    } catch {
        Write-SyncLog "Error processing account state for $($adUser.UserPrincipalName): $_" -Level ERROR
        $stats.Errors++
    }
}

Write-SyncLog "=== Sync-AccountState complete - Enabled: $($stats.Enabled), Disabled: $($stats.Disabled), Moved: $($stats.MovedToDisabled), Skipped: $($stats.Skipped), Errors: $($stats.Errors) ==="
