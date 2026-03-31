# Entra Cloud Sync Setup — Azure AD as Authoritative Source

This guide covers the one-time setup required to configure **Microsoft Entra Cloud Sync** so that Azure AD is the authoritative source for on-premises Active Directory user credentials (NTLM hashes and Kerberos AES keys).

Without this step, this tool can sync user attributes and groups to on-prem AD, but end users will **not** be able to obtain Kerberos TGTs using their Azure AD password. See [PKINIT](../README.md#kerberos-authentication-paths) as an alternative that avoids the password requirement entirely.

---

## What Entra Cloud Sync does in this setup

| Synced by Entra Cloud Sync agent | Synced by this tool (`Invoke-AzureSync.ps1`) |
|---|---|
| NTLM password hashes | Display name, email, department, title, phone |
| Kerberos AES encryption keys | Security group memberships |
| Core user object creation (optional) | Account enable/disable state |
| | PKINIT certificates (`userCertificate`) |
| | Kerberos SPNs + keytab files |

The agent runs as a Windows service and maintains its own sync cycle. This tool's scripts run separately on a schedule and do not conflict with the agent.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Azure AD role | **Hybrid Identity Administrator** (for agent registration and provisioning job creation) |
| On-prem AD role | **Domain Admin** or delegated write access to the target OU |
| Windows Server | Domain-joined; .NET Framework 4.7.2 or later |
| Network | Outbound HTTPS (443) to `*.msappproxy.net` and `*.servicebus.windows.net` |
| This tool configured | `sync-config.json` must exist with valid `AzureAD` and `LocalAD` values |

---

## Step 1 — Prepare the Azure AD App Registration

The Entra Cloud Sync agent registers its own Enterprise Application in your tenant during setup. For the **Graph API calls** in `Configure-EntraCloudSync.ps1` to manage the provisioning job, your existing App Registration (defined in `sync-config.json`) needs two additional permissions:

In the Azure portal, go to **App registrations → your app → API permissions** and add:

| Permission | Type | Why |
|---|---|---|
| `Synchronization.ReadWrite.All` | Application | Create and start the provisioning job |
| `Application.Read.All` | Application | Look up the agent's service principal |

Grant admin consent after adding both.

---

## Step 2 — Download the agent installer

1. Sign in to the [Azure portal](https://portal.azure.com) as a Hybrid Identity Administrator.
2. Navigate to: **Microsoft Entra ID → Hybrid Management → Microsoft Entra Connect → Cloud Sync**
3. Click **Download agent**.
4. Save the installer (`AADConnectProvisioningAgentSetup.exe`) to the path set in `sync-config.json`:
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

This silently installs the `AADConnectProvisioningAgent` Windows service. The script will print the next step when complete.

**Verify installation:**
```powershell
Get-Service AADConnectProvisioningAgent
```
Expected status: `Running`.

---

## Step 4 — Register the agent with your tenant (interactive)

After installation, the registration wizard must be completed interactively by a **Hybrid Identity Administrator**. It cannot be fully scripted because it requires an OAuth device-code or browser authentication flow.

If the wizard did not open automatically:
```
C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\AADConnectProvisioningAgent.Wizard.exe
```

In the wizard:
1. Sign in with a Hybrid Identity Administrator account.
2. Select **Microsoft Entra ID → Active Directory** (the Azure AD to on-prem AD direction — not the reverse).
3. Provide the on-prem AD credentials when prompted (Domain Admin or delegated).
4. Complete and close the wizard.

**Verify registration** in the Entra portal:
> Entra ID → Hybrid Management → Microsoft Entra Connect → Cloud Sync → Agents

The agent should appear as **Active**.

---

## Step 5 — Configure the provisioning job

Once the agent is registered, run:

```powershell
.\src\Invoke-AzureSync.ps1 -ConfigureCloudSync
```

This calls `Configure-EntraCloudSync.ps1`, which:
1. Finds the service principal the agent registered (searched by display name, not hard-coded app ID).
2. Creates a provisioning job with template `AAD2ADProvisioning` if one does not already exist.
3. Starts the job.

### If the service principal lookup fails

`Configure-EntraCloudSync.ps1` searches for the SP by two display names:
- `Microsoft Entra Provisioning to Active Directory`
- `Active Directory Outbound Provisioning`

If neither matches (display names vary across tenant configurations), find the correct name manually:

```powershell
Connect-MgGraph -Scopes Application.Read.All
Get-MgServicePrincipal -All | Where-Object { $_.DisplayName -like '*Provisioning*' -or $_.DisplayName -like '*Active Directory*' } |
    Select-Object DisplayName, Id, AppId
```

Update the filter string in `Configure-EntraCloudSync.ps1` to match your tenant's display name.

### If the provisioning job template ID is wrong

The template ID `AAD2ADProvisioning` is the standard value for Azure AD → on-prem AD inbound provisioning. If job creation fails with a template error, find the correct ID from the available templates:

```powershell
$sp = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Entra Provisioning to Active Directory'"
Get-MgServicePrincipalSynchronizationTemplate -ServicePrincipalId $sp.Id |
    Select-Object Id, FactoryTag
```

Set the correct value in `sync-config.json`:
```json
"EntraCloudSync": {
  "ProvisioningJobTemplateId": "<correct-template-id>"
}
```

---

## Step 6 — Verify

**In the Entra portal:**
> Entra ID → Hybrid Management → Microsoft Entra Connect → Cloud Sync → Configuration → Logs

A successful sync cycle shows green status entries for provisioned users.

**On a domain-joined Windows client, test a synced user:**
```cmd
runas /user:CORP\username cmd
```
Or on Linux with `krb5-user` installed:
```bash
kinit username@CORP.EXAMPLE.COM
klist
```
A TGT should be issued by the on-prem KDC using the user's Azure AD password.

**Check agent service health:**
```powershell
Get-Service AADConnectProvisioningAgent | Select-Object Name, Status, StartType
```

**Trigger a manual on-demand sync** (useful after first setup):
```powershell
# Get the job ID first
Connect-MgGraph
$sp  = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Entra Provisioning to Active Directory'"
$job = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id | Select-Object -First 1

# Trigger on-demand
Invoke-MgServicePrincipalSynchronizationJobProvisionOnDemand -ServicePrincipalId $sp.Id -SynchronizationJobId $job.Id
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent shows as inactive in portal | Registration not completed | Re-run the wizard: `AADConnectProvisioningAgent.Wizard.exe` |
| `Configure-EntraCloudSync.ps1` can't find the SP | SP display name differs in this tenant | Run the manual SP lookup above and update the filter |
| Job creation fails with template error | Wrong `ProvisioningJobTemplateId` | Run the template lookup above and update config |
| Users sync to AD but `kinit` fails | Kerberos keys not yet synced | Wait one full agent sync cycle (≈ 40 min); check portal logs |
| `kinit` fails with `KDC_ERR_PREAUTH_FAILED` | Password mismatch on the on-prem AD object | The agent has not yet synced this user's keys; trigger an on-demand sync |
| Agent service stops unexpectedly | Proxy/firewall blocking `*.msappproxy.net` | Check outbound HTTPS connectivity from the sync server |

---

## Relationship to this tool

Entra Cloud Sync and `Invoke-AzureSync.ps1` run independently and do not share state. The recommended operating model:

```
Every 30–60 min (Task Scheduler):
  .\src\Invoke-AzureSync.ps1         ← attributes, groups, certs, SPNs

Continuously (Windows Service):
  AADConnectProvisioningAgent        ← password hashes, Kerberos keys
```

Both write to the same on-prem AD users (identified by `extensionAttribute1` = Azure OID). There is no write conflict because each pipeline owns different attributes.
