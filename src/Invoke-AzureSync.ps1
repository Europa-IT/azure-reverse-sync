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
    [string]$ConfigPath = ".\config\sync-config.json",
    [switch]$RegisterTask
)

# -- Diagnostic transcript ----------------------------------------------------
# Captures stdout, stderr, Write-Host output, and uncaught errors to a per-run
# file BEFORE any other code can fail. Anchored to the script's directory (not
# cwd) so it works under the scheduled-task spawn even if -WorkingDirectory
# isn't honored. This is the safety net for diagnosing scheduled-task failures
# where Write-Host output to the spawned console is otherwise lost.
#
# If the primary path can't be written (e.g. permission issue in <repo>\logs\
# under SYSTEM), fall back to %TEMP%\azuresync-emergency.log so the failure
# itself is recorded somewhere.
try {
    $transcriptDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
    if (-not (Test-Path $transcriptDir)) {
        New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
    }
    $transcriptPath = Join-Path $transcriptDir ("transcript-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    Start-Transcript -Path $transcriptPath -Force -ErrorAction Stop | Out-Null
} catch {
    try {
        $emergencyLog = Join-Path $env:TEMP 'azuresync-emergency.log'
        ("{0}`tFailed to start transcript at '{1}': {2}" -f
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $transcriptPath, $_.Exception.Message) |
            Add-Content -Path $emergencyLog -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ( $PSScriptRoot ){
    $ScriptRoot = Split-Path $PSScriptRoot -Parent
} else {
    $ScriptRoot = (Get-Location).Path
}

# -- Load shared module --------------------------------------------------------
$modulePath = Join-Path $scriptRoot 'modules\AzureSync.psm1'
if (-not (Test-Path $modulePath)) {
    throw "AzureSync.psm1 not found at $modulePath. Run from the repo root or ensure the modules\ directory is present."
}
Import-Module $modulePath -Force

# -- Load configuration --------------------------------------------------------
$cfgArgs = @{}
if ($ConfigPath) { $cfgArgs['ConfigPath'] = $ConfigPath }
$script:Config = Get-SyncConfig @cfgArgs

# Resolve DryRun: -DryRun switch takes precedence; config Sync.DryRun is a fallback.
# Set $script:DryRun before any Write-SyncLog calls so the [DRYRUN] prefix is accurate.
$script:DryRun = $DryRun.IsPresent -or ($script:Config.Sync.DryRun -eq $true)
if ($script:Config.Sync.DryRun -eq $true -and -not $DryRun.IsPresent) {
    Write-SyncLog "DryRun enabled via config file (Sync.DryRun = true)." -Level WARN
}

# -- Scheduled task registration (early exit) ----------------------------------
if ($RegisterTask) {
    $taskCfg        = $script:Config.ScheduledTask
    $registerScript = Join-Path $scriptRoot 'src\Register-SyncTask.ps1'

    if (-not (Test-Path $registerScript)) {
        Write-SyncLog "Register-SyncTask.ps1 not found at '$registerScript'." -Level ERROR
        exit 1
    }

    # Hashtable splat (named binding). Array splat is positional in PowerShell --
    # the previous '-Foo','Bar' array was binding by position, sending the TaskName
    # value into the [int]IntervalMinutes parameter and failing with
    # "Cannot convert 'AzureSync' to System.Int32".
    $taskArgs = @{ Force = $true }  # always re-register when called explicitly
    if ($taskCfg.TaskName)        { $taskArgs.TaskName        = $taskCfg.TaskName }
    if ($taskCfg.IntervalMinutes) { $taskArgs.IntervalMinutes = [int]$taskCfg.IntervalMinutes }
    if ($taskCfg.RunAsUser)       { $taskArgs.RunAsUser       = $taskCfg.RunAsUser }
    if ($ConfigPath)              { $taskArgs.ConfigPath      = $ConfigPath }

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
    Write-SyncLog "-- $Name --"
    try {
        . $path
    } catch {
        Write-SyncLog "Step '$Name' failed: $_" -Level ERROR
        $script:overallErrors++
    }
}

# -- Sync ----------------------------------------------------------------------
. (Join-Path $scriptRoot 'src\Connect-GraphApi.ps1')

if (-not $SkipUsers) {
    Invoke-Step 'Sync Users'         'Sync-Users.ps1'
    Invoke-Step 'Sync Account State' 'Sync-AccountState.ps1'
}

if (-not $SkipGroups) {
    Invoke-Step 'Sync Groups' 'Sync-Groups.ps1'
}

# -- Summary -------------------------------------------------------------------
$elapsed = (Get-Date) - $overallStart
Write-SyncLog "================================================================"
Write-SyncLog "azure-reverse-sync finished [$mode] in $([int]$elapsed.TotalSeconds)s - Errors: $overallErrors"
Write-SyncLog "================================================================"

if ($overallErrors -gt 0) { exit 1 } else { exit 0 }
