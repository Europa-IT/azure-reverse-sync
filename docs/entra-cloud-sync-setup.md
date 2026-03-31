# Entra Cloud Sync Setup — Cloud Security Group Writeback to On-Prem AD

This guide covers the one-time setup required to configure **Microsoft Entra Cloud Sync**
to provision cloud security groups from Azure AD into on-prem Active Directory.

## What Entra Cloud Sync does (and does not do) in this project

Per Microsoft's official documentation
([learn.microsoft.com/entra/identity/hybrid/cloud-sync/how-to-configure-entra-to-active-directory](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-configure-entra-to-active-directory)):

> *"You can use Microsoft Entra Cloud Sync to provision cloud security groups to
> on-premises Active Directory Domain Services (AD DS)."*

| Synced by Entra Cloud Sync agent | Synced by this tool (`Invoke-AzureSync.ps1`) |
|---|---|
| Cloud security groups → on-prem AD groups | User attributes (display name, email, department, etc.) |
| Group membership for those groups | Account enable/disable state |
| | Security group memberships (via `Sync-Groups.ps1`) |
| | PKINIT certificates (`userCertificate`) |
| | Kerberos SPNs + keytab files |

**What Entra Cloud Sync does NOT do:**

- User provisioning from Azure AD to on-prem AD — not a supported scenario
- Password hash synchronization from Azure AD to on-prem AD — not supported
- Kerberos key synchronization from Azure AD to on-prem AD — not supported

Password hash sync flows in one direction only: **on-prem AD → Azure AD**, via the
classic AAD Connect / Cloud Sync agent configuration. There is no supported Microsoft
mechanism to reverse this flow.

**Kerberos authentication for end users:** Use PKINIT (`Sync-UserCertificates.ps1`).
Users authenticate to the on-prem KDC with their Azure AD certificate rather than a
password, eliminating the password-matching requirement entirely. See the
[PKINIT section of README.md](../README.md#kerberos-authentication-paths).

---

## When to use this setup

Set up Entra Cloud Sync group writeback when you have cloud-only security groups in
Azure AD (not sourced from on-prem AD) that need to be available in on-prem AD for:

- Resource ACLs on on-prem file servers
- On-prem application group membership checks
- Kerberos resource authorization (group SID in PAC)

If your security groups are already mastered in on-prem AD and synced up to Azure AD
via AAD Connect, you do not need this step — `Sync-Groups.ps1` handles those via the
Graph API already.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Azure AD role | **Hybrid Identity Administrator** |
| On-prem AD role | **Domain Admin** or delegated Create/Write/Delete on the groups OU |
| Windows Server | Domain-joined; .NET Framework 4.7.2 or later |
| Network | Outbound HTTPS (443) to `*.msappproxy.net` and `*.servicebus.windows.net` |
| This tool configured | `sync-config.json` must exist with valid `AzureAD` and `LocalAD` values |

---

## Step 1 — Grant additional Graph permissions

`Configure-EntraCloudSync.ps1` calls the Graph synchronization API to create and start
the provisioning job. Add these two permissions to the App Registration defined in
`sync-config.json`:

In the Azure portal: **App registrations → your app → API permissions → Add**

| Permission | Type |
|---|---|
| `Synchronization.ReadWrite.All` | Application |
| `Application.Read.All` | Application |

Grant admin consent after adding both.

---

## Step 2 — Download the agent installer

1. Sign in to the Azure portal as a Hybrid Identity Administrator.
2. Navigate to: **Microsoft Entra ID → Hybrid Management → Microsoft Entra Connect → Cloud Sync**
3. Click **Download agent**.
4. Save `AADConnectProvisioningAgentSetup.exe` to the path in `sync-config.json`:
   ```json
   "EntraCloudSync": {
     "AgentInstallerPath": "C:\\temp\\AADConnectProvisioningAgentSetup.exe"
   }
   ```

---

## Step 3 — Install the agent

Run on the domain-joined Windows Server **as Administrator**:

```powershell
.\src\Invoke-AzureSync.ps1 -InstallAgent
```

Verify:
```powershell
Get-Service AADConnectProvisioningAgent
# Expected: Status = Running
```

---

## Step 4 — Register the agent with your tenant (interactive)

Registration requires an interactive sign-in by a **Hybrid Identity Administrator** and
cannot be scripted.

If the wizard did not open automatically after installation:
```
C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\AADConnectProvisioningAgent.Wizard.exe
```

In the wizard:
1. Sign in with a Hybrid Identity Administrator account.
2. Select the **group provisioning** configuration (cloud security groups to AD).
3. Provide on-prem AD credentials when prompted.
4. Complete and close the wizard.

Verify in the Entra portal:
> **Entra ID → Hybrid Management → Microsoft Entra Connect → Cloud Sync → Agents**

The agent should appear as **Active**.

---

## Step 5 — Configure the provisioning job

```powershell
.\src\Invoke-AzureSync.ps1 -ConfigureCloudSync
```

This runs `Configure-EntraCloudSync.ps1`, which:
1. Finds the service principal registered by the agent (searched by display name).
2. Creates a provisioning job with template `AAD2ADProvisioning` if one does not exist.
3. Starts the job.

### If the service principal lookup fails

The SP display name varies across tenant configurations. Find the correct name:

```powershell
Connect-MgGraph -Scopes Application.Read.All
Get-MgServicePrincipal -All |
    Where-Object { $_.DisplayName -like '*Provisioning*' -or $_.DisplayName -like '*Active Directory*' } |
    Select-Object DisplayName, Id
```

Update the filter string in `Configure-EntraCloudSync.ps1` to match your tenant.

### If the template ID is wrong

Find available templates for the registered SP:

```powershell
$sp = Get-MgServicePrincipal -Filter "displayName eq 'Active Directory Outbound Provisioning'"
Get-MgServicePrincipalSynchronizationTemplate -ServicePrincipalId $sp.Id |
    Select-Object Id, FactoryTag
```

Set the correct value in `sync-config.json`:
```json
"EntraCloudSync": {
  "ProvisioningJobTemplateId": "<correct-id>"
}
```

---

## Step 6 — Verify

**In the Entra portal:**
> Entra ID → Hybrid Management → Microsoft Entra Connect → Cloud Sync → Configuration → Logs

A successful cycle shows green status for provisioned groups.

**In on-prem AD**, verify a cloud security group was written:
```powershell
Get-ADGroup -Filter { extensionAttribute1 -like '*' } `
            -SearchBase "OU=SyncedGroups,DC=corp,DC=example,DC=com" |
    Select-Object Name, SamAccountName
```

**Check agent service health:**
```powershell
Get-Service AADConnectProvisioningAgent | Select-Object Name, Status, StartType
```

**Trigger a manual on-demand sync:**
```powershell
Connect-MgGraph
$sp  = Get-MgServicePrincipal -Filter "displayName eq 'Active Directory Outbound Provisioning'"
$job = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id | Select-Object -First 1
Invoke-MgServicePrincipalSynchronizationJobProvisionOnDemand `
    -ServicePrincipalId $sp.Id -SynchronizationJobId $job.Id
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent shows as inactive in portal | Registration not completed | Re-run the wizard |
| Script can't find the SP | Display name differs in this tenant | Run the SP lookup above; update filter in script |
| Job creation fails with template error | Wrong `ProvisioningJobTemplateId` | Run template lookup above; update config |
| Cloud group not appearing in AD | Provisioning cycle not yet run | Trigger on-demand sync; check portal logs |
| Agent service stops unexpectedly | Firewall blocking `*.msappproxy.net` | Check outbound HTTPS from the sync server |

---

## Relationship to this tool

Entra Cloud Sync and `Invoke-AzureSync.ps1` run independently on separate schedules:

```
Every 30–60 min (Task Scheduler):
  .\src\Invoke-AzureSync.ps1    ← user attributes, account state, PKINIT certs, SPNs

Continuously (Windows Service):
  AADConnectProvisioningAgent   ← cloud security groups → on-prem AD
```

Both write to the same on-prem AD domain but to different object types (users vs. groups
created from cloud-only groups), so there are no write conflicts.
