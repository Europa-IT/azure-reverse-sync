# Deployment Outline

## Overview

This tool writes to production Active Directory. The deployment sequence below gates
each phase on explicit verification steps and uses isolated OUs and dry-run mode to
ensure nothing touches existing user accounts until the final production cutover.

---

## Phases at a Glance

```
Phase 0 — Environment prep (no AD writes)
Phase 1 — Dry-run validation (no AD writes)
Phase 2 — Sandbox OU smoke test (isolated OU, no production users)
Phase 3 — Entra Cloud Sync setup (cloud security group writeback)
Phase 4 — Pilot group rollout (subset of real users, isolated OU)
Phase 5 — Production cutover
Phase 6 — Kerberos / PKINIT enablement
```

Phases 0–3 carry zero risk to deployed assets. Phases 4–5 introduce real users under a
controlled scope. Phase 6 is additive-only (SPNs and keytabs do not modify existing
objects destructively).

---

## Phase 0 — Environment Preparation

**Goal:** Get all dependencies in place without touching AD.

### 0.1  Create an App Registration in Azure AD

1. **Azure portal → Microsoft Entra ID → App registrations → New registration**
   - Name: `azure-reverse-sync` (or similar)
   - Supported account type: *Accounts in this organizational directory only*
2. Note the **Application (client) ID** and **Directory (tenant) ID**.
3. Under **Certificates & secrets**, create a certificate (preferred) or client secret.
   - If certificate: export the public `.cer`, import it here; keep the private key in the
     Windows Certificate Store (`LocalMachine\My`) on the sync server.
   - If secret: store the value in **Windows Credential Manager** under target
     `AzureSync-ClientSecret-<TenantId>`. Do not paste it into `sync-config.json`.
4. Under **API permissions**, add the following **Application** permissions and grant
   admin consent:

   | Permission | Module |
   |---|---|
   | `User.Read.All` | Identity sync |
   | `Group.Read.All` | Group sync |
   | `GroupMember.Read.All` | Group sync |
   | `UserAuthenticationMethod.Read.All` | PKINIT cert sync |
   | `Synchronization.ReadWrite.All` | Entra Cloud Sync job config |
   | `Application.Read.All` | Entra Cloud Sync SP lookup |

### 0.2  Create isolated OUs in on-prem AD

These OUs hold synced objects and are separate from any existing production OUs.

```powershell
# Run on the domain controller or any machine with RSAT
$dc = "DC=corp,DC=example,DC=com"
New-ADOrganizationalUnit -Name "AzureSyncedUsers"  -Path $dc
New-ADOrganizationalUnit -Name "AzureSyncedGroups" -Path $dc
New-ADOrganizationalUnit -Name "AzureSyncedDisabled" -Path $dc
```

For sandbox testing (Phase 2), also create:
```powershell
New-ADOrganizationalUnit -Name "SyncSandbox" -Path $dc
```

### 0.3  Install prerequisites and configure

```powershell
# On the sync server (Run as Administrator)
.\Install-Prerequisites.ps1

Copy-Item config\sync-config.example.json config\sync-config.json
# Edit sync-config.json: fill in TenantId, ClientId, CertificateThumbprint,
# Server, and all OU values from step 0.2
```

### 0.4  Verify Graph connectivity

```powershell
Import-Module .\modules\AzureSync.psm1
$script:Config = Get-SyncConfig
$script:DryRun = $true
. .\src\Connect-GraphApi.ps1
Get-MgUser -Top 1 | Select-Object DisplayName, UserPrincipalName
```

Expected: one Azure AD user displayed. No AD writes have occurred.

---

## Phase 1 — Dry-Run Validation

**Goal:** Confirm the full sync logic produces the correct output without writing anything
to Active Directory.

```powershell
.\src\Invoke-AzureSync.ps1 -DryRun
```

**Review the log** (`logs\sync.log`) and verify:

| Check | Expected log entry |
|---|---|
| Graph connection | `Connected to Microsoft Graph` |
| User creation candidates | `[DRYRUN] Would create user: ...` for each Azure user not yet in AD |
| Group creation candidates | `[DRYRUN] Would create group: ...` |
| Account state | `[DRYRUN] Would disable/enable: ...` for any mismatches |
| Certificate sync | `[DRYRUN] Would write N certificate(s) to ...` |
| Kerberos SPNs | `[DRYRUN] Would register SPN: ...` |

**Go/no-go:** All dry-run entries are plausible (correct UPNs, expected group names,
correct realm). No unexpected `ERROR` lines.

---

## Phase 2 — Sandbox Smoke Test

**Goal:** Perform a live write to the isolated `SyncSandbox` OU using a single test
user. No production users are touched.

### 2.1  Create a test user in Azure AD

Create a test account (e.g., `sync-test-user@corp.example.com`) in Azure AD. This
account must not correspond to any existing on-prem AD user.

### 2.2  Configure sync-config.json to target the sandbox OU

Temporarily set:
```json
"LocalAD": {
  "TargetOU":   "OU=SyncSandbox,DC=corp,DC=example,DC=com",
  "GroupsOU":   "OU=SyncSandbox,DC=corp,DC=example,DC=com",
  "DisabledOU": "OU=SyncSandbox,DC=corp,DC=example,DC=com"
}
```

### 2.3  Run live sync against the sandbox

```powershell
# Skip Kerberos keytab generation for now; that requires a real service account
.\src\Invoke-AzureSync.ps1 -SkipKerberos
```

### 2.4  Verify in AD

```powershell
Get-ADUser -Filter { extensionAttribute1 -like '*' } `
           -SearchBase "OU=SyncSandbox,DC=corp,DC=example,DC=com" `
           -Properties extensionAttribute1, EmailAddress, Department |
    Format-Table Name, UserPrincipalName, extensionAttribute1, Department
```

Expected: the test user exists with correct attributes and `extensionAttribute1` set
to their Azure AD Object ID.

### 2.5  Test account state sync

Disable `sync-test-user` in Azure AD portal. Wait 1 minute, then re-run:
```powershell
.\src\Invoke-AzureSync.ps1 -SkipKerberos -SkipCertificates -SkipGroups
```
Verify the AD account is disabled:
```powershell
Get-ADUser sync-test-user -Properties Enabled | Select-Object Enabled
# Expected: Enabled = False
```

Re-enable the user in Azure AD and confirm it flips back.

**Go/no-go:** User created with correct attributes, account state follows Azure AD,
`extensionAttribute1` is set, no errors in log.

---

## Phase 3 — Entra Cloud Sync Setup

**Goal:** Install and configure the Entra Cloud Sync agent to provision cloud security
groups from Azure AD into on-prem AD (group writeback). This phase has no impact on
user objects or existing AD groups mastered on-prem.

> **Scope note:** Per Microsoft's documentation, Entra Cloud Sync provisions cloud
> security groups to on-prem AD. It does not provision users, and does not sync
> password hashes or Kerberos keys from Azure AD to on-prem AD in any direction.
> See [docs/entra-cloud-sync-setup.md](entra-cloud-sync-setup.md) for details.

Follow [`docs/entra-cloud-sync-setup.md`](entra-cloud-sync-setup.md) in full:

1. Download agent installer → `config.EntraCloudSync.AgentInstallerPath`
2. `.\src\Invoke-AzureSync.ps1 -InstallAgent`
3. Complete the registration wizard (interactive, Hybrid Identity Admin)
4. `.\src\Invoke-AzureSync.ps1 -ConfigureCloudSync`

### Verification (no production impact)

After the first provisioning cycle completes (≈ 40 min, or trigger on-demand):

```powershell
# Confirm a cloud-only test group was written to the groups OU
Get-ADGroup -Filter { extensionAttribute1 -like '*' } `
            -SearchBase "OU=SyncedGroups,DC=corp,DC=example,DC=com" |
    Select-Object Name, SamAccountName
```

**Go/no-go:** Cloud security test group appears in on-prem AD. Agent shows Active in
Entra portal. No user objects or existing AD groups modified.

---

## Phase 4 — Pilot Group Rollout

**Goal:** Sync a controlled subset of real users to the production OUs.

### 4.1  Update sync-config.json to target production OUs

```json
"LocalAD": {
  "TargetOU":   "OU=AzureSyncedUsers,DC=corp,DC=example,DC=com",
  "GroupsOU":   "OU=AzureSyncedGroups,DC=corp,DC=example,DC=com",
  "DisabledOU": "OU=AzureSyncedDisabled,DC=corp,DC=example,DC=com"
}
```

### 4.2  Scope Azure AD to a pilot group (optional but recommended)

If only a subset of users should sync initially, add a group filter in
`Sync-Users.ps1` (or use Entra Cloud Sync's scoping filter for the provisioning job).
This is not yet configurable via `sync-config.json` and requires a small code change
or manual Graph filter.

### 4.3  Run dry-run against production OUs

```powershell
.\src\Invoke-AzureSync.ps1 -DryRun
```

Confirm log shows pilot users only, no unexpected accounts.

### 4.4  Live pilot sync

```powershell
.\src\Invoke-AzureSync.ps1 -SkipKerberos
```

**Verify:**
- Pilot users appear in `OU=AzureSyncedUsers` with correct attributes
- Pilot users can authenticate with Kerberos using Azure AD credentials (via Entra Cloud Sync)
- Existing users in **other** OUs are untouched (confirm with `Get-ADUser` against those OUs)
- Security groups created in `OU=AzureSyncedGroups` with correct memberships

**Rollback:** To undo pilot users, disable their AD accounts and move to `AzureSyncedDisabled` OU.
The users' pre-existing AD objects (in other OUs) are unaffected since this tool only manages
users it created (identified by `extensionAttribute1`).

**Go/no-go:** Pilot users sync correctly, Kerberos works, no unintended AD changes.

---

## Phase 5 — Production Cutover

**Goal:** Enable full sync for all Azure AD users.

### 5.1  Remove any pilot group scope filter

Ensure `Sync-Users.ps1` fetches all users (no group filter).

### 5.2  Final dry-run

```powershell
.\src\Invoke-AzureSync.ps1 -DryRun 2>&1 | Tee-Object logs\pre-cutover-dryrun.log
```

Review `logs\pre-cutover-dryrun.log`. Confirm the count of users to be created matches
expectations. Archive this log.

### 5.3  Live cutover sync

```powershell
.\src\Invoke-AzureSync.ps1 -SkipKerberos
```

Monitor `logs\sync.log` in real time:
```powershell
Get-Content logs\sync.log -Wait
```

### 5.4  Schedule recurring sync

```powershell
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument '-NonInteractive -File "C:\azure-reverse-sync\src\Invoke-AzureSync.ps1" -SkipKerberos'
$trigger  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -StartWhenAvailable
Register-ScheduledTask -TaskName 'AzureSync' -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Highest -User 'CORP\svc-azuresync'
```

**Go/no-go:** All expected users synced, scheduled task running, no ERROR lines in log.

---

## Phase 6 — Kerberos SPN and PKINIT Enablement

**Goal:** Register Kerberos service accounts and optionally enable PKINIT for
certificate-based end-user Kerberos.

These operations are additive: registering SPNs does not remove any existing SPNs on
other accounts, and writing `userCertificate` to a user object does not affect any
existing attributes or Kerberos TGT flows.

### 6.1  Create service accounts in AD

For each entry in `config.Kerberos.ServiceAccounts`:
```powershell
New-ADUser -Name svc-fileserver -SamAccountName svc-fileserver `
           -Path "OU=ServiceAccounts,DC=corp,DC=example,DC=com" `
           -Enabled $true -PasswordNeverExpires $true
```

### 6.2  Run SPN + keytab generation

```powershell
.\src\Invoke-AzureSync.ps1 -SkipUsers -SkipGroups -SkipCertificates
```

Verify:
```powershell
setspn -L svc-fileserver
# Expected: cifs/fileserver01.corp.example.com listed
```

Deploy keytab to the file server (copy from `config.Kerberos.KeytabOutputPath`).
Test with `klist` on a client after accessing the share.

### 6.3  Enable PKINIT certificate sync (optional)

Ensure `config.PKINIT.Enabled = true` and `CACertificatePath` points to the issuing
CA certificate. Then run:

```powershell
.\src\Invoke-AzureSync.ps1 -SkipUsers -SkipGroups -SkipKerberos
```

Verify with `kinit` using a certificate credential on a test user.

### 6.4  Enable full scheduled sync including certificates

Update the scheduled task to remove the `-SkipKerberos` flag (or leave it if SPNs
are managed manually), and remove `-SkipCertificates` if PKINIT was validated.

---

## Rollback Reference

| Scenario | Action |
|---|---|
| Stop all syncing immediately | Disable the `AzureSync` scheduled task and stop the `AADConnectProvisioningAgent` service |
| Undo a bad attribute change | `Set-ADUser -Identity <user> -<Attr> <previous-value>` — only this tool's managed attributes are affected |
| Remove all synced users | `Get-ADUser -Filter { extensionAttribute1 -like '*' } -SearchBase <TargetOU> \| Disable-ADAccount` — existing users in other OUs are untouched |
| Remove a stale SPN | `Set-ADUser svc-fileserver -ServicePrincipalNames @{Remove="cifs/fileserver01.corp.example.com"}` |
| Remove Entra Cloud Sync agent | Uninstall via Programs and Features; delete the provisioning job from the Entra portal |

---

## Go/No-Go Checklist Summary

- [ ] Phase 0: Graph API returns users; no AD errors
- [ ] Phase 1: Dry-run log matches expected user/group set; no ERROR lines
- [ ] Phase 2: Sandbox user created with correct attributes; account state follows Azure AD
- [ ] Phase 3: Cloud security test group appears in on-prem AD; agent Active in portal
- [ ] Phase 4: Pilot users synced; existing AD users in other OUs unmodified
- [ ] Phase 5: Full sync completes; scheduled task running; no errors
- [ ] Phase 6: SPNs verified with `setspn`; keytab deployed; Kerberos ticket confirmed
