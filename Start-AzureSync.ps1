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

.PARAMETER ConfigPath
    Passed through to Invoke-AzureSync.ps1.

.PARAMETER SkipPrerequisites
    Skip the Install-Prerequisites.ps1 step. Use after the first successful run.

.EXAMPLE
    # First-time setup and dry run
    .\Start-AzureSync.ps1 -DryRun

.EXAMPLE
    # Normal sync, prerequisites already installed
    .\Start-AzureSync.ps1 -SkipPrerequisites
#>

param(
    [switch]$DryRun,
    [switch]$SkipUsers,
    [switch]$SkipGroups,
    [string]$ConfigPath = '',
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
    if ($DryRun)            { $argList += '-DryRun' }
    if ($SkipUsers)         { $argList += '-SkipUsers' }
    if ($SkipGroups)        { $argList += '-SkipGroups' }
    if ($SkipPrerequisites) { $argList += '-SkipPrerequisites' }
    if ($ConfigPath)        { $argList += "-ConfigPath `"$ConfigPath`"" }

    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
    exit $LASTEXITCODE
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

$syncArgs = @()
if ($DryRun)           { $syncArgs += '-DryRun' }
if ($SkipUsers)        { $syncArgs += '-SkipUsers' }
if ($SkipGroups)       { $syncArgs += '-SkipGroups' }
if ($ConfigPath)       { $syncArgs += '-ConfigPath'; $syncArgs += $ConfigPath }

# Debug
write-host $syncArgs

& $syncScript @syncArgs
Read-Host "Completed with exit code $LASTEXITCODE, press Enter to exit"
exit $LASTEXITCODE
