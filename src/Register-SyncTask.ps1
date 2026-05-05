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
    [string]$ConfigPath      = '',
    [switch]$Force,
    [switch]$Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# When -Force is passed, treat it as an explicit "do it" intent and suppress
# any Confirm prompts. This matches the convention used by built-in cmdlets
# (Remove-Item -Force, Stop-Process -Force, etc.). -WhatIf is unaffected --
# it flips $WhatIfPreference, not $ConfirmPreference -- so the documented
# -WhatIf example still works.
if ($Force) { $ConfirmPreference = 'None' }

# ── Local logger ─────────────────────────────────────────────────────────────
$ScriptRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $scriptRoot '..\modules\AzureSync.psm1'
if (-not (Test-Path $modulePath)) {
    throw "AzureSync.psm1 not found at $modulePath. Run from the repo root or ensure the modules\ directory is present."
}
Import-Module $modulePath -Force



# ── Resolve the sync script path ─────────────────────────────────────────────
$syncScript = Join-Path $RepoPath 'src\Invoke-AzureSync.ps1'
if (-not (Test-Path $syncScript)) {
    Write-TaskLog "Invoke-AzureSync.ps1 not found at '$syncScript'. Ensure -RepoPath points to the repository root." -Level ERROR
    exit 1
}
$syncScriptFull = (Resolve-Path $syncScript).Path

# ── Unregister path ───────────────────────────────────────────────────────────
if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-TaskLog "Scheduled task '$TaskName' does not exist - nothing to remove." -Level WARN
        exit 0
    }
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-TaskLog "Scheduled task '$TaskName' removed successfully."
        } catch {
            Write-TaskLog "Failed to remove scheduled task '$TaskName': $_" -Level ERROR
            exit 1
        }
    } else {
        Write-TaskLog "Unregister skipped: ShouldProcess returned false (-WhatIf in effect, or Confirm prompt was declined)." -Level WARN
    }
    exit 0
}

# ── Guard against overwriting an existing task ────────────────────────────────
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    Write-TaskLog "Scheduled task '$TaskName' already exists. Use -Force to overwrite." -Level WARN
    Write-TaskLog "Current action: $($existing.Actions[0].Execute) $($existing.Actions[0].Arguments)"
    exit 1
}

# ── Build the action argument string ─────────────────────────────────────────
$syncArgs = @(
    '-NonInteractive',
    '-ExecutionPolicy', 'RemoteSigned',
    '-File', "`"$syncScriptFull`""
)
if ($ConfigPath)      { $syncArgs += '-ConfigPath'; $syncArgs += "`"$ConfigPath`"" }

$actionArguments = $syncArgs -join ' '

Write-TaskLog "Task name    : $TaskName"
Write-TaskLog "Script       : $syncScriptFull"
Write-TaskLog "Arguments    : $actionArguments"
Write-TaskLog "Interval     : every $IntervalMinutes minute(s)"
Write-TaskLog "Run as       : $RunAsUser"

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
    # Non-SYSTEM user without a password supplied - let Register-ScheduledTask prompt
    $taskParams['User'] = $RunAsUser
}

# ── Register ──────────────────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
    try {
        $registered = Register-ScheduledTask @taskParams
        $nextRun    = ($registered | Get-ScheduledTaskInfo).NextRunTime

        Write-TaskLog "Scheduled task '$TaskName' registered successfully."
        Write-TaskLog "  State    : $($registered.State)"
        Write-TaskLog "  Next run : $nextRun"
        Write-TaskLog "  Action   : $($registered.Actions[0].Execute) $($registered.Actions[0].Arguments)"
        Write-TaskLog "To remove this task later, run: .\src\Register-SyncTask.ps1 -Unregister"
    } catch {
        Write-TaskLog "Failed to register scheduled task '$TaskName': $_" -Level ERROR
        exit 1
    }
} else {
    Write-TaskLog "Register skipped: ShouldProcess returned false (-WhatIf in effect, or Confirm prompt was declined)." -Level WARN
}

exit 0
