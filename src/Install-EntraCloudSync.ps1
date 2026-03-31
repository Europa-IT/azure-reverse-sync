<#
.SYNOPSIS
    Silently installs the Microsoft Entra Cloud Sync provisioning agent.
.DESCRIPTION
    The Entra Cloud Sync agent is Microsoft's lightweight provisioning agent that enables
    inbound provisioning from Azure AD to on-prem AD, with Azure AD as the authoritative source.
    Once installed and registered, it handles the privileged sync of NTLM hashes and Kerberos
    key material — something a custom script cannot do via Graph API alone.

    This script:
      1. Validates the installer exists at config.EntraCloudSync.AgentInstallerPath
      2. Silently installs the agent
      3. Logs the next manual step: registering the agent with the Azure tenant

    The installer must be pre-downloaded from the Entra portal:
      Entra ID > Hybrid Management > Microsoft Entra Connect > Cloud Sync > Download agent

    Agent registration requires interactive sign-in by a Hybrid Identity Administrator.
    Run the registration wizard after this script completes.

.NOTES
    Must be dot-sourced after AzureSync.psm1 is loaded and Get-SyncConfig has been called.
    Requires: Run as Administrator
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg           = $script:Config
$installerPath = $cfg.EntraCloudSync.AgentInstallerPath

Write-SyncLog "=== Install-EntraCloudSync started ==="

# ── Validate installer ────────────────────────────────────────────────────────
if (-not (Test-Path $installerPath)) {
    Write-SyncLog @"
Entra Cloud Sync agent installer not found at: $installerPath

To download it:
  1. Sign in to the Azure portal (portal.azure.com)
  2. Navigate to: Entra ID > Hybrid Management > Microsoft Entra Connect > Cloud Sync
  3. Click 'Download agent' and place the installer at: $installerPath
  4. Re-run this script.
"@ -Level ERROR
    return
}

# ── Check if already installed ────────────────────────────────────────────────
$installed = Get-Service -Name 'AADConnectProvisioningAgent' -ErrorAction SilentlyContinue
if ($installed) {
    Write-SyncLog "Entra Cloud Sync agent is already installed (service state: $($installed.Status))."
    Write-SyncLog "If you need to reinstall, uninstall via Programs and Features first."
    return
}

# ── Silent install ────────────────────────────────────────────────────────────
Write-SyncLog "Installing Entra Cloud Sync agent from: $installerPath"

if ($script:DryRun) {
    Write-SyncLog "[DRYRUN] Would run: $installerPath /quiet ACCEPTEULA=1"
} else {
    $proc = Start-Process -FilePath $installerPath `
                          -ArgumentList '/quiet', 'ACCEPTEULA=1' `
                          -Wait -PassThru -Verb RunAs

    if ($proc.ExitCode -ne 0) {
        throw "Agent installer exited with code $($proc.ExitCode). Check the installer log at %TEMP%\AADConnect*.log"
    }

    # Verify service was created
    $svc = Get-Service -Name 'AADConnectProvisioningAgent' -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "Agent service 'AADConnectProvisioningAgent' not found after installation. Installation may have failed silently."
    }

    Write-SyncLog "Entra Cloud Sync agent installed successfully (service: $($svc.Status))."
}

Write-SyncLog ""
Write-SyncLog "NEXT STEP — Register the agent with your Azure tenant:" -Level WARN
Write-SyncLog "  1. Open the Microsoft Entra Provisioning Agent configuration wizard." -Level WARN
Write-SyncLog "     It should have launched automatically, or run:" -Level WARN
Write-SyncLog "     C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\AADConnectProvisioningAgent.Wizard.exe" -Level WARN
Write-SyncLog "  2. Sign in with a Hybrid Identity Administrator account." -Level WARN
Write-SyncLog "  3. Complete the wizard to register this server with your tenant." -Level WARN
Write-SyncLog "  4. Then run: .\src\Invoke-AzureSync.ps1 -SetupEntraCloudSync (without -InstallAgent)" -Level WARN
Write-SyncLog "     to configure the provisioning job via Graph API." -Level WARN
Write-SyncLog ""
Write-SyncLog "=== Install-EntraCloudSync complete ==="
