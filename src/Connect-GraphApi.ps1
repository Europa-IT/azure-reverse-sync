<#
.SYNOPSIS
    Authenticates to Microsoft Graph using the App Registration defined in sync-config.json.
.DESCRIPTION
    Supports three authentication methods (in preference order):
      1. Certificate — CertificateThumbprint in the LocalMachine\My store (preferred, no secret on disk)
      2. Client secret — loaded from Windows Credential Manager via the target name
         "AzureSync-ClientSecret-<TenantId>" (never stored in config)
      3. Interactive device code flow — falls back to browser-based authentication when
         neither certificate nor client secret is available (useful for one-off admin runs)

    Must be dot-sourced AFTER loading AzureSync.psm1 and calling Get-SyncConfig.

    Required Microsoft Graph API permissions (App, not Delegated):
      - User.Read.All
      - Group.Read.All
      - GroupMember.Read.All
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg = $script:Config.AzureAD

Write-SyncLog "Connecting to Microsoft Graph (tenant: $($cfg.TenantId))..."

$requiredScopes = @(
    'User.Read.All',
    'Group.Read.All',
    'GroupMember.Read.All'
)

$connectParams = @{
    ClientId  = $cfg.ClientId
    TenantId  = $cfg.TenantId
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
    Write-SyncLog "Using client secret from config. Use certificate auth in production." -Level WARN
    $secureSecret = $cfg.ClientSecret | ConvertTo-SecureString -AsPlainText -Force
    $credential   = [System.Management.Automation.PSCredential]::new($cfg.ClientId, $secureSecret)
    $connectParams['ClientSecretCredential'] = $credential

} else {
    # ── Try Windows Credential Manager, then fall back to device code flow ────
    $credTarget = "AzureSync-ClientSecret-$($cfg.TenantId)"
    $storedCred = $null
    try {
        $storedCred = Get-StoredCredential -Target $credTarget -ErrorAction SilentlyContinue
    } catch { }

    if ($storedCred) {
        $secureSecret = [System.Net.NetworkCredential]::new('', $storedCred.Password).SecurePassword
        $credential   = [System.Management.Automation.PSCredential]::new($cfg.ClientId, $secureSecret)
        $connectParams['ClientSecretCredential'] = $credential
        Write-SyncLog "Using client secret from Windows Credential Manager (target: $credTarget)"
    } else {
        # ── Interactive device code flow (admin/one-off runs) ─────────────────
        Write-SyncLog "No certificate or client secret found — falling back to interactive device code flow." -Level WARN
        $connectParams['Scopes']         = $requiredScopes
        $connectParams['UseDeviceCode']  = $true
    }
}

Connect-MgGraph @connectParams

$context = Get-MgContext
Write-SyncLog "Connected to Microsoft Graph. AppId: $($context.AppName), Scopes: $($context.Scopes -join ', ')"
