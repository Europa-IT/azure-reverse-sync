#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Main orchestrator for azure-reverse-sync.
.DESCRIPTION
    Connects to Microsoft Graph and runs the configured sync operations against
    on-premises Active Directory. All sub-scripts are dot-sourced in order.

.PARAMETER DryRun
    Log all planned changes without writing anything to Active Directory.
    Useful for validating configuration before first live run.

.PARAMETER SkipUsers
    Skip user attribute sync and account state sync.

.PARAMETER SkipGroups
    Skip security group and membership sync.

.PARAMETER SkipCertificates
    Skip PKINIT certificate sync.

.PARAMETER SkipKerberos
    Skip SPN registration and keytab export.

.PARAMETER ConfigPath
    Path to sync-config.json. Defaults to .\config\sync-config.json.

.EXAMPLE
    # Dry run to preview all changes
    .\src\Invoke-AzureSync.ps1 -DryRun

.EXAMPLE
    # Normal scheduled sync
    .\src\Invoke-AzureSync.ps1

.EXAMPLE
    # Sync only users and groups, skip certificates and Kerberos
    .\src\Invoke-AzureSync.ps1 -SkipCertificates -SkipKerberos
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [switch]$SkipUsers,
    [switch]$SkipGroups,
    [switch]$SkipCertificates,
    [switch]$SkipKerberos,
    [string]$ConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot ? (Split-Path $PSScriptRoot -Parent) : (Get-Location).Path

# ── Load shared module ────────────────────────────────────────────────────────
$modulePath = Join-Path $scriptRoot 'modules\AzureSync.psm1'
if (-not (Test-Path $modulePath)) {
    throw "AzureSync.psm1 not found at $modulePath. Run from the repo root or ensure the modules\ directory is present."
}
Import-Module $modulePath -Force

# ── Load configuration ────────────────────────────────────────────────────────
$cfgArgs = @{}
if ($ConfigPath) { $cfgArgs['ConfigPath'] = $ConfigPath }
$script:Config = Get-SyncConfig @cfgArgs
$script:DryRun = $DryRun.IsPresent

if ($script:Config.Sync.DryRun -eq $true -and -not $DryRun) {
    Write-SyncLog "DryRun enabled via config file." -Level WARN
    $script:DryRun = $true
}

$mode = if ($script:DryRun) { 'DRY RUN' } else { 'LIVE' }
Write-SyncLog "================================================================"
Write-SyncLog "azure-reverse-sync started [$mode] — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-SyncLog "================================================================"

$overallStart = Get-Date
$overallErrors = 0

function Invoke-Step {
    param([string]$Name, [string]$ScriptFile)
    $path = Join-Path $scriptRoot "src\$ScriptFile"
    Write-SyncLog ""
    Write-SyncLog "── $Name ──"
    try {
        . $path
    } catch {
        Write-SyncLog "Step '$Name' failed: $_" -Level ERROR
        $script:overallErrors++
    }
}

# ── Sync ──────────────────────────────────────────────────────────────────────
. (Join-Path $scriptRoot 'src\Connect-GraphApi.ps1')

if (-not $SkipUsers) {
    Invoke-Step 'Sync Users'         'Sync-Users.ps1'
    Invoke-Step 'Sync Account State' 'Sync-AccountState.ps1'
}

if (-not $SkipGroups) {
    Invoke-Step 'Sync Groups' 'Sync-Groups.ps1'
}

if (-not $SkipCertificates) {
    Invoke-Step 'Sync User Certificates (PKINIT)' 'Sync-UserCertificates.ps1'
}

if (-not $SkipKerberos) {
    Invoke-Step 'Set Kerberos SPNs + Keytabs' 'Set-KerberosSpn.ps1'
}

# ── Summary ───────────────────────────────────────────────────────────────────
$elapsed = (Get-Date) - $overallStart
Write-SyncLog ""
Write-SyncLog "================================================================"
Write-SyncLog "azure-reverse-sync finished [$mode] in $([int]$elapsed.TotalSeconds)s — Errors: $overallErrors"
Write-SyncLog "================================================================"

if ($overallErrors -gt 0) { exit 1 } else { exit 0 }
