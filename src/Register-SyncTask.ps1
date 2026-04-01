#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers a Windows Scheduled Task that runs Invoke-AzureSync.ps1 on a recurring schedule.
.DESCRIPTION
    Creates (or removes) a scheduled task named 'AzureSync' (or a custom name) in the
    Windows Task Scheduler. The task runs Invoke-AzureSync.ps1 as Administrator on a
    repeating interval, starting shortly after registration.

    Run this script once after validating the sync works correctly with -DryRun.
    Subsequent calls with -Force will re-register the task (useful to update the interval
    or sync flags without manually editing the task).

.PARAMETER TaskName
    Name of the scheduled task. Defaults to 'AzureSync'.

.PARAMETER RepoPath
    Absolute path to the repository root (the folder containing src\, config\, etc.).
    Defaults to the parent directory of this script.

.PARAMETER IntervalMinutes
    How often the sync runs, in minutes. Defaults to 30.

.PARAMETER RunAsUser
    The Windows account the task runs under. Defaults to 'SYSTEM'.
    For a dedicated service account use the form 'DOMAIN\svc-azuresync'.
    SYSTEM requires no password; a service account requires -RunAsPassword.

.PARAMETER RunAsPassword
    Password for RunAsUser when not using SYSTEM or a Group Managed Service Account.
    Accepts a SecureString. If omitted for a non-SYSTEM user, the cmdlet will prompt.

.PARAMETER SkipKerberos
    Pass -SkipKerberos to Invoke-AzureSync.ps1. Use if Kerberos SPN/keytab management
    is handled separately or not needed on this schedule.

.PARAMETER SkipCertificates
    Pass -SkipCertificates to Invoke-AzureSync.ps1.

.PARAMETER ConfigPath
    Pass a custom -ConfigPath to Invoke-AzureSync.ps1. If omitted, Invoke-AzureSync.ps1
    uses its default (.\config\sync-config.json relative to the repo root).

.PARAMETER Force
    Overwrite an existing task with the same name without prompting.

.PARAMETER Unregister
    Remove the scheduled task instead of creating it.

.EXAMPLE
    # Register with defaults: every 30 minutes, run as SYSTEM
    .\src\Register-SyncTask.ps1

.EXAMPLE
    # Every 15 minutes, run as a dedicated service account
    .\src\Register-SyncTask.ps1 -IntervalMinutes 15 -RunAsUser 'CORP\svc-azuresync'

.EXAMPLE
    # Skip Kerberos on the scheduled run (managed separately)
    .\src\Register-SyncTask.ps1 -SkipKerberos -Force

.EXAMPLE
    # Preview what would be registered without writing anything
    .\src\Register-SyncTask.ps1 -WhatIf

.EXAMPLE
    # Remove the task
    .\src\Register-SyncTask.ps1 -Unregister
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName        = 'AzureSync',
    [string]$RepoPath        = (Split-Path $PSScriptRoot -Parent),
    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes    = 30,
    [string]$RunAsUser       = 'SYSTEM',
    [SecureString]$RunAsPassword,
    [switch]$SkipKerberos,
    [switch]$SkipCertificates,
    [string]$ConfigPath      = '',
    [switch]$Force,
    [switch]$Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve the sync script path ─────────────────────────────────────────────
$syncScript = Join-Path $RepoPath 'src\Invoke-AzureSync.ps1'
if (-not (Test-Path $syncScript)) {
    throw "Invoke-AzureSync.ps1 not found at '$syncScript'. Ensure -RepoPath points to the repository root."
}
$syncScriptFull = (Resolve-Path $syncScript).Path

# ── Unregister path ───────────────────────────────────────────────────────────
if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "Scheduled task '$TaskName' does not exist — nothing to remove." -ForegroundColor Yellow
        exit 0
    }
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
    }
    exit 0
}

# ── Guard against overwriting an existing task ────────────────────────────────
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    Write-Host "Scheduled task '$TaskName' already exists. Use -Force to overwrite." -ForegroundColor Yellow
    Write-Host "Current action: $($existing.Actions[0].Execute) $($existing.Actions[0].Arguments)"
    exit 1
}

# ── Build the action argument string ─────────────────────────────────────────
$syncArgs = @(
    '-NonInteractive',
    '-ExecutionPolicy', 'RemoteSigned',
    '-File', "`"$syncScriptFull`""
)
if ($SkipKerberos)    { $syncArgs += '-SkipKerberos' }
if ($SkipCertificates){ $syncArgs += '-SkipCertificates' }
if ($ConfigPath)      { $syncArgs += '-ConfigPath'; $syncArgs += "`"$ConfigPath`"" }

$actionArguments = $syncArgs -join ' '

Write-Host "Task name    : $TaskName" -ForegroundColor Cyan
Write-Host "Script       : $syncScriptFull" -ForegroundColor Cyan
Write-Host "Arguments    : $actionArguments" -ForegroundColor Cyan
Write-Host "Interval     : every $IntervalMinutes minute(s)" -ForegroundColor Cyan
Write-Host "Run as       : $RunAsUser" -ForegroundColor Cyan

# ── Build task components ─────────────────────────────────────────────────────
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $actionArguments `
    -WorkingDirectory $RepoPath

# Start ~60 seconds from now, then repeat every IntervalMinutes
$startTime = (Get-Date).AddSeconds(60)
$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At $startTime `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$settings = New-ScheduledTaskSettingsSet `
    -RunOnlyIfNetworkAvailable `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

$taskParams = @{
    TaskName  = $TaskName
    Action    = $action
    Trigger   = $trigger
    Settings  = $settings
    RunLevel  = 'Highest'
    Force     = $Force.IsPresent
}

# ── Set run-as identity ───────────────────────────────────────────────────────
if ($RunAsUser -eq 'SYSTEM') {
    $taskParams['User'] = 'SYSTEM'
} elseif ($RunAsPassword) {
    $plainPassword = [System.Net.NetworkCredential]::new('', $RunAsPassword).Password
    $taskParams['User']     = $RunAsUser
    $taskParams['Password'] = $plainPassword
} else {
    # Non-SYSTEM user without a password supplied — let Register-ScheduledTask prompt
    $taskParams['User'] = $RunAsUser
}

# ── Register ──────────────────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {

    $registered = Register-ScheduledTask @taskParams

    # Verify
    $nextRun    = ($registered | Get-ScheduledTaskInfo).NextRunTime

    Write-Host "`nScheduled task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host "  State        : $($registered.State)"
    Write-Host "  Next run     : $nextRun"
    Write-Host "  Action       : $($registered.Actions[0].Execute) $($registered.Actions[0].Arguments)"
    Write-Host "`nTo remove this task later, run:"
    Write-Host "  .\src\Register-SyncTask.ps1 -Unregister" -ForegroundColor DarkGray
}
