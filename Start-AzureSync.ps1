<#
.SYNOPSIS
    Entry point for azure-reverse-sync. Elevates to Administrator if needed,
    sets execution policy, installs prerequisites, then runs the sync.
.DESCRIPTION
    Run this script directly - it handles everything:
      1. Re-launches itself as Administrator if not already elevated.
      2. Sets the process execution policy to RemoteSigned for this session.
      3. Runs Install-Prerequisites.ps1 to ensure all required modules are present.
      4. Runs Invoke-AzureSync.ps1 with any arguments passed to this script.

.PARAMETER DryRun
    Passed through to Invoke-AzureSync.ps1. Logs all planned changes without
    writing anything to Active Directory.

.PARAMETER SkipUsers
    Passed through to Invoke-AzureSync.ps1.

.PARAMETER SkipGroups
    Passed through to Invoke-AzureSync.ps1.

.PARAMETER RegisterTask
    Passed through to Invoke-AzureSync.ps1. Registers the recurring scheduled
    task using the ScheduledTask section of sync-config.json, then exits.

.PARAMETER ConfigPath
    Passed through to Invoke-AzureSync.ps1.

.PARAMETER SkipPrerequisites
    Skip the Install-Prerequisites.ps1 step. Use after the first successful run.

.PARAMETER Debug
    Standard PowerShell common parameter (enabled via [CmdletBinding]).
    Passed through to Invoke-AzureSync.ps1, where it enables a per-run
    Start-Transcript that captures stdout/stderr/errors to
    logs\transcript-<stamp>.log. Useful for diagnosing failures where
    console output would otherwise be lost (scheduled-task spawns, etc.).

.EXAMPLE
    # First-time setup and dry run
    .\Start-AzureSync.ps1 -DryRun

.EXAMPLE
    # Normal sync, prerequisites already installed
    .\Start-AzureSync.ps1 -SkipPrerequisites

.EXAMPLE
    # Capture a forensic transcript for troubleshooting
    .\Start-AzureSync.ps1 -DryRun -Debug
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipUsers,
    [switch]$SkipGroups,
    [switch]$RegisterTask,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\sync-config.json'),
    [switch]$SkipPrerequisites
)

Set-StrictMode -Off

# ── 1. Elevate to Administrator if needed ────────────────────────────────────
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Not running as Administrator - relaunching elevated..." -ForegroundColor Yellow

    # Rebuild the argument list to pass through to the elevated process
    $argList = @("-NoProfile", "-ExecutionPolicy", "RemoteSigned", "-File", "`"$PSCommandPath`"")
    if ($DryRun)                          { $argList += '-DryRun' }
    if ($SkipUsers)                       { $argList += '-SkipUsers' }
    if ($SkipGroups)                      { $argList += '-SkipGroups' }
    if ($RegisterTask)                    { $argList += '-RegisterTask' }
    if ($SkipPrerequisites)               { $argList += '-SkipPrerequisites' }
    if ($PSBoundParameters['Debug'])      { $argList += '-Debug' }
    if ($ConfigPath)                      { $argList += "-ConfigPath `"$ConfigPath`"" }

    # -PassThru + .ExitCode is the only reliable way to bring the elevated
    # process's exit code back to the parent. Start-Process is a cmdlet, not
    # a native command, so it never sets $LASTEXITCODE.
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $proc.ExitCode
}

# ── 2. Set execution policy for this session ─────────────────────────────────
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force

# ── 3. Resolve paths relative to this script's location ─────────────────────
$repoRoot        = $PSScriptRoot
$prereqScript    = Join-Path $repoRoot 'Install-Prerequisites.ps1'
$syncScript      = Join-Path $repoRoot 'src\Invoke-AzureSync.ps1'

foreach ($path in $prereqScript, $syncScript) {
    if (-not (Test-Path $path)) {
        Write-Host "[ERROR] Required script not found: $path" -ForegroundColor Red
        exit 1
    }
}

# ── 4. Install prerequisites ─────────────────────────────────────────────────
if (-not $SkipPrerequisites) {
    Write-Host "`n=== Installing prerequisites ===" -ForegroundColor Cyan
    & $prereqScript
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Prerequisites script failed (exit $LASTEXITCODE). Aborting sync." -ForegroundColor Red
        exit $LASTEXITCODE
    }
} else {
    Write-Host "Skipping prerequisites (SkipPrerequisites specified)." -ForegroundColor DarkGray
}

# ── 5. Run the sync ───────────────────────────────────────────────────────────
Write-Host "`n=== Starting sync ===" -ForegroundColor Cyan

$syncArgs = @{ ConfigPath = $ConfigPath }
if ($DryRun)                     { $syncArgs.DryRun       = $true }
if ($SkipUsers)                  { $syncArgs.SkipUsers    = $true }
if ($SkipGroups)                 { $syncArgs.SkipGroups   = $true }
if ($RegisterTask)               { $syncArgs.RegisterTask = $true }
if ($PSBoundParameters['Debug']) { $syncArgs.Debug        = $true }

& $syncScript @syncArgs
Read-Host "Completed with exit code $LASTEXITCODE, press Enter to exit"
exit $LASTEXITCODE
