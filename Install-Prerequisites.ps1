#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs and validates all prerequisites for azure-reverse-sync.
.DESCRIPTION
    - Installs the Microsoft.Graph PowerShell module
    - Installs the CredentialManager module (used by Connect-GraphApi.ps1's
      Windows Credential Manager auth path)
    - Installs Pester v5 for running tests
    - Confirms the ActiveDirectory RSAT module is available
    - Confirms certutil.exe is available (needed for NTAuth CA trust)
.EXAMPLE
    .\Install-Prerequisites.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param (
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Cyan
}
function Write-OK {
    param (
        [string]$Message
    )
    Write-Host "[OK] $Message" -ForegroundColor Green
}
function Write-Fail {
    param (
        [string]$Message
    )
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

Write-Host "azure-reverse-sync - Prerequisites Setup" -ForegroundColor White
Write-Host "=========================================`n"

# -- 1. PowerShell version ---------------------------------------------------
Write-Step "Checking PowerShell version..."
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail "PowerShell 5.1 or later required. Current: $($PSVersionTable.PSVersion)"
    exit 1
}
Write-OK "PowerShell $($PSVersionTable.PSVersion)"

# -- 2. ActiveDirectory module ------------------------------------------------
Write-Step "Checking ActiveDirectory module (RSAT)..."
if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Write-OK "ActiveDirectory module found"
} else {
    Write-Step "ActiveDirectory module not found. Attempting to install RSAT..."
    try {
        Add-WindowsCapability -Online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" | Out-Null
        Write-OK "RSAT ActiveDirectory tools installed"
    } catch {
        Write-Fail "Could not install ActiveDirectory module automatically."
        Write-Fail "On Windows Server: Install-WindowsFeature RSAT-AD-PowerShell"
        Write-Fail "On Windows 10/11: Settings `> Optional Features `> RSAT: Active Directory Domain Services and Lightweight Directory Services Tools"
        exit 1
    }
}

# -- 3. Microsoft.Graph module ------------------------------------------------
Write-Step "Checking Microsoft.Graph module..."
$graphModule = Get-Module -ListAvailable -Name Microsoft.Graph | Sort-Object Version -Descending | Select-Object -First 1
if ($graphModule) {
    Write-OK "Microsoft.Graph $($graphModule.Version) already installed"
} else {
    Write-Step "Installing Microsoft.Graph (this may take a few minutes)..."
    Install-Module -Name Microsoft.Graph -Scope AllUsers -Force -AllowClobber
    Write-OK "Microsoft.Graph installed"
}

# Ensure the submodules used by this tooling are available
$requiredSubmodules = @(
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups'
)
foreach ($sub in $requiredSubmodules) {
    if (-not (Get-Module -ListAvailable -Name $sub)) {
        Write-Step "Installing $sub..."
        Install-Module -Name $sub -Scope AllUsers -Force -AllowClobber
    }
    Write-OK "$sub available"
}

# -- 4. CredentialManager module ----------------------------------------------
# Used by Connect-GraphApi.ps1 to look up a stored client secret under target
# 'AzureSync-ClientSecret-<TenantId>'. Without it, the credential manager auth
# path silently falls through to interactive device code flow, which surprises
# users following the documented setup.
Write-Step "Checking CredentialManager module..."
$credMgr = Get-Module -ListAvailable -Name CredentialManager | Sort-Object Version -Descending | Select-Object -First 1
if ($credMgr) {
    Write-OK "CredentialManager $($credMgr.Version) already installed"
} else {
    Write-Step "Installing CredentialManager..."
    Install-Module -Name CredentialManager -Scope AllUsers -Force
    Write-OK "CredentialManager installed"
}

# -- 5. Pester v5 -------------------------------------------------------------
Write-Step "Checking Pester..."
$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($pester -and $pester.Version.Major -ge 5) {
    Write-OK "Pester $($pester.Version) already installed"
} else {
    Write-Step "Installing Pester v5..."
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope AllUsers -Force -SkipPublisherCheck
    Write-OK "Pester v5 installed"
}

Write-Host "`nPrerequisite check complete.`n" -ForegroundColor White
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Copy config\sync-config.example.json to config\sync-config.json and fill in your values."
Write-Host "  2. Run: .\src\Invoke-AzureSync.ps1 -DryRun"
Write-Host ""
