<#
.SYNOPSIS
    Authenticates to Microsoft Graph using the App Registration defined in sync-config.json.
.DESCRIPTION
    Supports two authentication methods (in preference order):
      1. Certificate — CertificateThumbprint in the LocalMachine\My store (preferred, no secret on disk)
      2. Client secret — loaded from Windows Credential Manager via the target name
         "AzureSync-ClientSecret-<TenantId>" (never stored in config)

    Must be dot-sourced AFTER loading AzureSync.psm1 and calling Get-SyncConfig.

    Required Microsoft Graph API permissions (App, not Delegated):
      - User.Read.All
      - Group.Read.All
      - GroupMember.Read.All
      - UserAuthenticationMethod.Read.All   (for PKINIT cert fetch)
      - Synchronization.ReadWrite.All        (for Entra Cloud Sync job management)
      - Application.Read.All                 (for Entra Cloud Sync SP lookup)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg = $script:Config.AzureAD

Write-SyncLog "Connecting to Microsoft Graph (tenant: $($cfg.TenantId))..."

$connectParams = @{
    ClientId = $cfg.ClientId
    TenantId = $cfg.TenantId
    NoWelcome = $true
}

if (-not [string]::IsNullOrWhiteSpace($cfg.CertificateThumbprint)) {
    # ── Certificate auth (preferred) ──────────────────────────────────────────
    $cert = Get-Item "Cert:\LocalMachine\My\$($cfg.CertificateThumbprint)" -ErrorAction SilentlyContinue
    if (-not $cert) {
        throw "Certificate with thumbprint '$($cfg.CertificateThumbprint)' not found in LocalMachine\My store."
    }
    $connectParams['Certificate'] = $cert
    Write-SyncLog "Using certificate auth (thumbprint: $($cfg.CertificateThumbprint.Substring(0,8))...)"

} elseif (-not [string]::IsNullOrWhiteSpace($cfg.ClientSecret)) {
    # ── Client secret (fallback — only for dev; production should use cert) ───
    Write-SyncLog "WARNING: Using client secret from config. Use certificate auth in production." -Level WARN
    $secureSecret = $cfg.ClientSecret | ConvertTo-SecureString -AsPlainText -Force
    $credential   = [System.Management.Automation.PSCredential]::new($cfg.ClientId, $secureSecret)
    $connectParams['ClientSecretCredential'] = $credential

} else {
    # ── Try Windows Credential Manager ────────────────────────────────────────
    $credTarget = "AzureSync-ClientSecret-$($cfg.TenantId)"
    try {
        Add-Type -AssemblyName System.Web
        $storedCred = [System.Net.NetworkCredential]::new(
            '', (Get-StoredCredential -Target $credTarget).Password
        )
        $secureSecret = $storedCred.SecurePassword
        $credential   = [System.Management.Automation.PSCredential]::new($cfg.ClientId, $secureSecret)
        $connectParams['ClientSecretCredential'] = $credential
        Write-SyncLog "Using client secret from Windows Credential Manager (target: $credTarget)"
    } catch {
        throw "No authentication method available. Set CertificateThumbprint in config, or store the client secret in Windows Credential Manager under target '$credTarget'."
    }
}

Connect-MgGraph @connectParams

$context = Get-MgContext
Write-SyncLog "Connected to Microsoft Graph. AppId: $($context.AppName), Scopes: $($context.Scopes -join ', ')"
