# azure-reverse-sync

PowerShell tooling to sync Azure AD / Microsoft Entra ID users to an on-premises Active Directory server.

## Architecture

```
Azure AD (source of truth)
    │
    └─► This Tool (PowerShell)  ──► on-prem AD  (user attributes, account state,
        Invoke-AzureSync.ps1                     group memberships)
```

## Prerequisites

- Windows Server, domain-joined to the on-prem AD domain
- PowerShell 5.1 or later (run as Administrator)
- RSAT: Active Directory Domain Services and LDS Tools
- An Azure AD **App Registration** (service principal) with these Graph API permissions (Application, not Delegated):
  - `User.Read.All`
  - `Group.Read.All`
  - `GroupMember.Read.All`

Run the prerequisites installer to validate and install required PS modules:

```powershell
.\Install-Prerequisites.ps1
```

---

## Setup

### 1. Configure

```powershell
Copy-Item config\sync-config.example.json config\sync-config.json
# Edit config\sync-config.json — fill in TenantId, ClientId, AD server, OUs, etc.
```

Store your App Registration secret or certificate in **Windows Credential Manager** — never in `sync-config.json`.

### 2. Dry-run preview

```powershell
.\src\Invoke-AzureSync.ps1 -DryRun
```

Logs all planned changes without writing to Active Directory.

### 3. First live sync

```powershell
.\src\Invoke-AzureSync.ps1
```

### 4. Schedule recurring sync

Configure the scheduled task in `sync-config.json` under `ScheduledTask`, then register it:

```powershell
# Register using settings from sync-config.json (TaskName, IntervalMinutes, RunAsUser, etc.)
.\src\Invoke-AzureSync.ps1 -RegisterTask
```

Or call the registration script directly for more control:

```powershell
# Default: every 30 minutes, run as SYSTEM
.\src\Register-SyncTask.ps1

# Every 15 minutes under a dedicated service account
.\src\Register-SyncTask.ps1 -IntervalMinutes 15 -RunAsUser 'CORP\svc-azuresync'

# Preview without registering
.\src\Register-SyncTask.ps1 -WhatIf

# Remove the task
.\src\Register-SyncTask.ps1 -Unregister
```

---

## Usage

```powershell
# First-time setup (elevates, installs prereqs, runs sync)
.\Start-AzureSync.ps1 -DryRun

# Full sync (default)
.\src\Invoke-AzureSync.ps1

# Dry run — no writes to AD
.\src\Invoke-AzureSync.ps1 -DryRun

# Register the scheduled task from sync-config.json
.\src\Invoke-AzureSync.ps1 -RegisterTask
```

---

## Project Structure

```
azure-reverse-sync/
├── config/
│   └── sync-config.example.json       # Configuration template (copy to sync-config.json)
├── src/
│   ├── Invoke-AzureSync.ps1           # Main orchestrator
│   ├── Connect-GraphApi.ps1           # Microsoft Graph authentication
│   ├── Sync-Users.ps1                 # User attribute sync
│   ├── Sync-AccountState.ps1          # Enable/disable accounts
│   ├── Sync-Groups.ps1                # Security group + membership sync
│   └── Register-SyncTask.ps1          # Create/remove the recurring scheduled task
├── modules/
│   └── AzureSync.psm1                 # Shared helpers
├── tests/
│   ├── Invoke-Tests.ps1               # Pester test runner
│   ├── Sync-Users.Tests.ps1
│   ├── Sync-Groups.Tests.ps1
├── logs/                              # Gitignored; sync logs written here
├── Start-AzureSync.ps1                # Entry point: elevates, installs prereqs, runs sync
├── Install-Prerequisites.ps1          # Module installation and validation
└── .gitignore
```

---

## Running Tests

```powershell
.\tests\Invoke-Tests.ps1
```

---

## Security

- **Secrets**: store client secret or certificate private key in Windows Credential Manager, not in `sync-config.json`
- **App Registration**: grant only the minimum Graph permissions listed above; do not use `Directory.ReadWrite.All`
