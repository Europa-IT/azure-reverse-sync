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

#### Sync filters (optional)

The `Sync` block accepts these knobs:

- `LicensedUsersOnly` (default `false`) — only sync Azure users with at least one assigned license.
- `FilterGroupId` (default `""`) — only sync members of this Azure AD group. Overrides `LicensedUsersOnly` when set.
- `DisableDeletedUsers` (default `true`) — when an Azure user is deleted, disable the on-prem account and move it to `LocalAD.DisabledOU`.
- `AdoptExistingUsers` (default `false`) — controls what happens when an Azure user collides with a pre-existing on-prem object this tool didn't create. A collision is matched by UPN (forest-wide, via the Global Catalog) or by the derived SamAccountName (target domain, across all object classes). `true` adopts a colliding **user** account: stamps it with the Azure OID, aligns its UPN to the Azure UPN when they differ, and manages it going forward. `false` skips it with a warning. Adoption only touches user accounts in the target domain and never overwrites an account already managed under a different Azure OID. If the SamAccountName is owned by a non-user object (a group or computer), the user is **always** skipped with a warning — it can be neither created nor adopted — regardless of this setting.

Guest accounts (`*#EXT#*` UPNs) are always excluded regardless of filter mode.

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

## Logging

Each run writes a timestamped log file under the directory configured in `Logging.LogPath`:

```
logs\Sync-2026-05-06_143020.log              # one file per Invoke-AzureSync.ps1 run
logs\ScheduledTask-2026-05-06_143020.log     # one file per Register-SyncTask.ps1 run
```

Relative `Logging.LogPath` values anchor to the repo root, so logs land in the same place regardless of how the orchestrator was invoked (interactive shell, self-elevated, scheduled task as SYSTEM, remote session).

`Logging.MaxFiles` (default `100`) keeps the most recent N files per template and prunes the rest once per run. The default of 100 covers ~2 days at the default 30-minute interval.

### Forensic transcripts (`-Debug`)

When troubleshooting scheduled-task failures or any context where console output would otherwise be lost, pass `-Debug`:

```powershell
.\Start-AzureSync.ps1 -DryRun -Debug
.\src\Invoke-AzureSync.ps1 -Debug
```

This starts a `Start-Transcript` at orchestrator entry, capturing stdout/stderr/errors to `logs\transcript-<stamp>.log` for the run. Transcripts are not auto-pruned; delete them manually when no longer needed.

---

## Project Structure

```
azure-reverse-sync/
├── config/
│   └── sync-config.example.json       # Configuration template (copy to sync-config.json)
├── docs/
│   └── deployment-outline.md          # Phased deployment guide
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
├── logs/                              # Gitignored; per-run sync logs written here
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
