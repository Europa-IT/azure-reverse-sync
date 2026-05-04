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

.PARAMETER ConfigPath
    Path to sync-config.json. Defaults to .\config\sync-config.json.

.PARAMETER RegisterTask
    Register (or re-register) the Windows Scheduled Task using settings from
    config.ScheduledTask, then exit without running a sync. Calls
    Register-SyncTask.ps1 with -Force so repeated calls are safe.

.EXAMPLE
    # Dry run to preview all changes
    .\src\Invoke-AzureSync.ps1 -DryRun

.EXAMPLE
    # Normal scheduled sync
    .\src\Invoke-AzureSync.ps1

.EXAMPLE
    # Register the scheduled task using settings from sync-config.json
    .\src\Invoke-AzureSync.ps1 -RegisterTask
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [switch]$SkipUsers,
    [switch]$SkipGroups,
    [string]$ConfigPath = '.\config\sync-config.json',
    [switch]$RegisterTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ( $PSScriptRoot ){
    $ScriptRoot = Split-Path $PSScriptRoot -Parent
} else {
    $ScriptRoot = (Get-Location).Path
}

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

# Resolve DryRun: -DryRun switch takes precedence; config Sync.DryRun is a fallback.
# Set $script:DryRun before any Write-SyncLog calls so the [DRYRUN] prefix is accurate.
$script:DryRun = $DryRun.IsPresent -or ($script:Config.Sync.DryRun -eq $true)
if ($script:Config.Sync.DryRun -eq $true -and -not $DryRun.IsPresent) {
    Write-SyncLog "DryRun enabled via config file (Sync.DryRun = true)." -Level WARN
}

# ── Scheduled task registration (early exit) ──────────────────────────────────
if ($RegisterTask) {
    $taskCfg        = $script:Config.ScheduledTask
    $registerScript = Join-Path $scriptRoot 'src\Register-SyncTask.ps1'

    if (-not (Test-Path $registerScript)) {
        Write-SyncLog "Register-SyncTask.ps1 not found at '$registerScript'." -Level ERROR
        exit 1
    }

    $taskArgs = @('-Force')  # always re-register when called explicitly
    if ($taskCfg.TaskName)         { $taskArgs += '-TaskName';         $taskArgs += $taskCfg.TaskName }
    if ($taskCfg.IntervalMinutes)  { $taskArgs += '-IntervalMinutes';  $taskArgs += [string]$taskCfg.IntervalMinutes }
    if ($taskCfg.RunAsUser)        { $taskArgs += '-RunAsUser';        $taskArgs += $taskCfg.RunAsUser }
    if ($ConfigPath)               { $taskArgs += '-ConfigPath'; $taskArgs += $ConfigPath }

    Write-SyncLog "Registering scheduled task with config from ScheduledTask section..."
    & $registerScript @taskArgs
    exit $LASTEXITCODE
}

$mode = if ($script:DryRun) { 'DRY RUN' } else { 'LIVE' }
Write-SyncLog "================================================================"
Write-SyncLog "azure-reverse-sync started [$mode] - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
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

# ── Summary ───────────────────────────────────────────────────────────────────
$elapsed = (Get-Date) - $overallStart
Write-SyncLog ""
Write-SyncLog "================================================================"
Write-SyncLog "azure-reverse-sync finished [$mode] in $([int]$elapsed.TotalSeconds)s - Errors: $overallErrors"
Write-SyncLog "================================================================"

if ($overallErrors -gt 0) { exit 1 } else { exit 0 }
