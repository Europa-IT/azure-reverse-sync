<#
.SYNOPSIS
    Configures the Entra Cloud Sync provisioning job to write cloud security groups to on-prem AD.
.DESCRIPTION
    Uses the Microsoft Graph synchronization API to:
      1. Find the service principal for the Entra Cloud Sync provisioning app registered
         in this tenant by the agent installation/registration step.
      2. Create (or retrieve) an inbound provisioning job for group writeback.
      3. Start the job so that cloud security groups created in Azure AD are provisioned
         into on-premises Active Directory.

    SCOPE: This script configures group provisioning only (Azure AD cloud security groups
    → on-prem AD). Microsoft Entra Cloud Sync does not support user provisioning or
    password/Kerberos key synchronization in the Azure AD → on-prem AD direction.
    See docs/entra-cloud-sync-setup.md for full scope details.

    Prerequisites:
      - Entra Cloud Sync agent must be installed AND registered with the tenant first.
        Run Install-EntraCloudSync.ps1 and complete the wizard before this script.
      - Graph app registration requires: Synchronization.ReadWrite.All, Application.Read.All

    Must be dot-sourced after Connect-GraphApi.ps1.

    Reference:
      https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-configure-entra-to-active-directory
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg = $script:Config

Write-SyncLog "=== Configure-EntraCloudSync started (group writeback) ==="

# ── Find the provisioning agent's service principal ───────────────────────────
# The agent registers an Enterprise Application whose display name varies by tenant.
# We search by name rather than hard-coding an app ID.
Write-SyncLog "Looking up Entra Cloud Sync service principal..."

$agentSps = Get-MgServicePrincipal -Filter "displayName eq 'Active Directory Outbound Provisioning'" `
                                   -ErrorAction SilentlyContinue

if (-not $agentSps) {
    $agentSps = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Entra Provisioning to Active Directory'" `
                                       -ErrorAction SilentlyContinue
}

if (-not $agentSps) {
    Write-SyncLog @"
Could not find the Entra Cloud Sync service principal in this tenant.

The agent must be installed AND registered with the tenant before running this script.
Steps:
  1. Run: .\src\Install-EntraCloudSync.ps1
  2. Complete the registration wizard with a Hybrid Identity Administrator account,
     selecting the group provisioning (cloud security groups to AD) configuration.
  3. Re-run this script.

To find the correct service principal name in your tenant:
  Get-MgServicePrincipal -All | Where-Object { `$_.DisplayName -like '*Provisioning*' -or `$_.DisplayName -like '*Active Directory*' } | Select-Object DisplayName, Id
"@ -Level ERROR
    return
}

$sp = $agentSps | Select-Object -First 1
Write-SyncLog "Found service principal: $($sp.DisplayName) (ID: $($sp.Id))"

# ── Get or create the provisioning job ───────────────────────────────────────
$templateId = $cfg.EntraCloudSync.ProvisioningJobTemplateId
Write-SyncLog "Checking for existing provisioning job (templateId: $templateId)..."

$existingJobs = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id `
                                                          -ErrorAction SilentlyContinue
$job = $existingJobs | Where-Object { $_.TemplateId -eq $templateId } | Select-Object -First 1

if (-not $job) {
    Write-SyncLog "No existing job found. Creating provisioning job..."

    if ($script:DryRun) {
        Write-SyncLog "[DRYRUN] Would create provisioning job with templateId: $templateId"
        Write-SyncLog "=== Configure-EntraCloudSync complete (dry run) ==="
        return
    }

    $job = New-MgServicePrincipalSynchronizationJob `
               -ServicePrincipalId $sp.Id `
               -TemplateId $templateId

    Write-SyncLog "Created provisioning job: $($job.Id)"
} else {
    Write-SyncLog "Existing provisioning job found: $($job.Id) (status: $($job.Status.Code))"
}

# ── Inspect and log the provisioning schema ───────────────────────────────────
Write-SyncLog "Fetching provisioning schema..."
try {
    $schema = Get-MgServicePrincipalSynchronizationJobSchema `
                  -ServicePrincipalId $sp.Id `
                  -SynchronizationJobId $job.Id

    $ruleCount    = @($schema.SynchronizationRules).Count
    $mappingCount = ($schema.SynchronizationRules | ForEach-Object { $_.ObjectMappings } |
                     ForEach-Object { $_.AttributeMappings }).Count
    Write-SyncLog "Schema: $ruleCount sync rule(s), $mappingCount attribute mapping(s)"
} catch {
    Write-SyncLog "Could not fetch schema (non-fatal): $_" -Level WARN
}

# ── Start the provisioning job ────────────────────────────────────────────────
$jobStatus = $job.Status.Code
if ($jobStatus -eq 'Active') {
    Write-SyncLog "Provisioning job is already active — triggering a manual sync cycle..."
    if (-not $script:DryRun) {
        Invoke-MgServicePrincipalSynchronizationJobProvisionOnDemand `
            -ServicePrincipalId $sp.Id -SynchronizationJobId $job.Id | Out-Null
    }
} else {
    Write-SyncLog "Starting provisioning job (current status: $jobStatus)..."
    if (-not $script:DryRun) {
        Start-MgServicePrincipalSynchronizationJob `
            -ServicePrincipalId $sp.Id -SynchronizationJobId $job.Id
        Write-SyncLog "Provisioning job started."
    } else {
        Write-SyncLog "[DRYRUN] Would start provisioning job $($job.Id)"
    }
}

Write-SyncLog ""
Write-SyncLog "Entra Cloud Sync group provisioning job is running."
Write-SyncLog "Cloud security groups in Azure AD will be written to on-prem AD on each sync cycle."
Write-SyncLog "Monitor provisioning status at: Entra ID > Hybrid Management > Cloud Sync > Logs"
Write-SyncLog ""
Write-SyncLog "NOTE: User provisioning and password/Kerberos key sync from Azure AD to on-prem AD"
Write-SyncLog "are NOT handled by Entra Cloud Sync. Use PKINIT (Sync-UserCertificates.ps1) for"
Write-SyncLog "certificate-based Kerberos authentication that does not require password matching."
Write-SyncLog ""
Write-SyncLog "=== Configure-EntraCloudSync complete ==="
