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
Phase 2 — Production cutover
```

Phases 0 and 1 carry zero risk to deployed assets. Phase 2 begins writing users and groups to the on-prem AD environment.
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

**Go/no-go:** All dry-run entries are plausible (correct UPNs, expected group names,
correct realm). No unexpected `ERROR` lines.

---

## Phase 2 — Production Cutover

**Goal:** Enable full sync for all Azure AD users.

### 2.1  Final dry-run

```powershell
.\src\Invoke-AzureSync.ps1 -DryRun 2>&1 | Tee-Object logs\pre-cutover-dryrun.log
```

Review `logs\pre-cutover-dryrun.log`. Confirm the count of users to be created matches
expectations. Archive this log.

### 2.2  Live cutover sync

```powershell
.\src\Invoke-AzureSync.ps1 
```

Monitor `logs\sync.log` in real time:
```powershell
Get-Content logs\sync.log -Wait
```

### 2.3  Schedule recurring sync

Configure `ScheduledTask` in `sync-config.json` (TaskName, IntervalMinutes, RunAsUser), then register it:

```powershell
# Register using settings from sync-config.json
.\src\Invoke-AzureSync.ps1 -RegisterTask
```

Or call the script directly for more control:

```powershell
# Every 15 minutes, run as a dedicated service account
.\src\Register-SyncTask.ps1 -IntervalMinutes 15 -RunAsUser 'CORP\svc-azuresync'

# Preview without registering
.\src\Register-SyncTask.ps1 -WhatIf
```

**Go/no-go:** All expected users synced, scheduled task running, no ERROR lines in log.

## Rollback Reference

| Scenario | Action |
|---|---|
| Stop all syncing immediately | Disable the `AzureSync` scheduled task |
| Undo a bad attribute change | `Set-ADUser -Identity <user> -<Attr> <previous-value>` — only this tool's managed attributes are affected |
| Remove all synced users | `Get-ADUser -Filter { extensionAttribute1 -like '*' } -SearchBase <TargetOU> \| Disable-ADAccount` — existing users in other OUs are untouched |

---

## Go/No-Go Checklist Summary

- [ ] Phase 0: Graph API returns users; no AD errors
- [ ] Phase 1: Dry-run log matches expected user/group set; no ERROR lines
- [ ] Phase 2: Full sync completes; scheduled task running; no errors
