<#
.SYNOPSIS
    Shared helper module for azure-reverse-sync.
.DESCRIPTION
    Provides: Write-SyncLog, Get-SyncConfig, ConvertTo-AdAttributes, Test-AdUserExists,
    New-RandomPassword, and script-level $script:DryRun / $script:Config state.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Module-level state -------------------------------------------------------
# Set by the orchestrator before dot-sourcing sub-scripts.
$script:DryRun         = $false
$script:Config         = $null
# Per-run timestamp used to derive a unique log filename for this process.
# Initialized lazily on first log write.
$script:RunStamp       = $null
# Tracks which configured log templates have already had retention pruned
# in this session, so retention runs at most once per (process, template).
$script:RetentionDone  = @{}

# -- Get-ConfiguredLogPath (private) ------------------------------------------
# Defensively reads $script:Config.<Section>.LogPath. Returns $null if Config
# isn't loaded yet, the section is missing, or the LogPath property is absent.
# StrictMode raises PropertyNotFoundException on plain '.' access to absent
# properties, so we probe via PSObject.Properties first.
function Get-ConfiguredLogPath {
    param(
        [Parameter(Mandatory)][ValidateSet('Sync','ScheduledTask')][string]$Section
    )
    if (-not $script:Config) { return $null }
    if (-not $script:Config.PSObject.Properties[$Section]) { return $null }
    $sectionObj = $script:Config.$Section
    if (-not $sectionObj.PSObject.Properties['LogPath']) { return $null }
    return $sectionObj.LogPath
}

# -- Get-RunStamp (private) ---------------------------------------------------
# ISO-ish timestamp captured once per process; sortable lexicographically.
function Get-RunStamp {
    if (-not $script:RunStamp) {
        $script:RunStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    }
    return $script:RunStamp
}

# -- Resolve-RunLogPath (private) ---------------------------------------------
# Converts a configured LogPath template to this run's filename:
#     .\logs\sync.log  ->  .\logs\sync-2026-05-05_143052.log
function Resolve-RunLogPath {
    param([Parameter(Mandatory)][string]$Template)
    $stamp = Get-RunStamp
    $dir   = Split-Path $Template -Parent
    $base  = [System.IO.Path]::GetFileNameWithoutExtension($Template)
    $ext   = [System.IO.Path]::GetExtension($Template)
    $name  = "$base-$stamp$ext"
    if ($dir) { return (Join-Path $dir $name) }
    return $name
}

# -- Get-LogRetentionConfig (private) -----------------------------------------
# Reads $script:Config.Logging.MaxFiles if present; defaults to 100 (~2 days
# of runs at the default 30-minute interval). Clamped to >= 1 so we never
# delete the file we're about to write.
function Get-LogRetentionConfig {
    $cfg = @{ MaxFiles = 100 }
    if ($script:Config -and $script:Config.PSObject.Properties['Logging']) {
        $logging = $script:Config.Logging
        if ($logging.PSObject.Properties['MaxFiles']) {
            $cfg.MaxFiles = [Math]::Max(1, [int]$logging.MaxFiles)
        }
    }
    return [PSCustomObject]$cfg
}

# -- Invoke-LogRetention (private) --------------------------------------------
# Deletes per-run log files matching the template (e.g. sync-*.log in the same
# directory) beyond the MaxFiles most recent. Sort order is by filename -- the
# yyyy-MM-dd_HHmmss stamp sorts lexicographically the same as chronologically.
# Errors here are reported but never propagated.
function Invoke-LogRetention {
    param(
        [Parameter(Mandatory)][string]$Template
    )
    $dir = Split-Path $Template -Parent
    if (-not $dir) { $dir = '.' }
    if (-not (Test-Path $dir)) { return }

    $base    = [System.IO.Path]::GetFileNameWithoutExtension($Template)
    $ext     = [System.IO.Path]::GetExtension($Template)
    $pattern = "$base-*$ext"

    try {
        $cfg = Get-LogRetentionConfig
        $existing = @(
            Get-ChildItem -Path $dir -Filter $pattern -File -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        )
        if ($existing.Count -le $cfg.MaxFiles) { return }
        $existing | Select-Object -Skip $cfg.MaxFiles | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "[WARN] Log retention failed for '$Template': $_" -ForegroundColor Yellow
    }
}

# -- Write-LogEntry (private) -------------------------------------------------
# Shared core for Write-SyncLog and Write-TaskLog. Formats the line, writes to
# console, then -- if a log template is configured -- resolves the per-run
# filename, appends the entry, and prunes old run logs once per template per
# session.
function Write-LogEntry {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO',
        [string]$LogPath        # configured template; per-run filename derived from this
    )

    $prefix = if ($script:DryRun) { '[DRYRUN] ' } else { '' }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $prefix$Message"

    switch ($Level) {
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        default { Write-Host $entry }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $runPath = Resolve-RunLogPath -Template $LogPath
        $logDir = Split-Path $runPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        # TODO resolve bug here, it is silently failing
        try {
            Add-Content -Path $runPath -Value $entry -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Host ("Error: {0}" -f $_.Exception.Message)
        }

        if (-not $script:RetentionDone[$LogPath]) {
            Invoke-LogRetention -Template $LogPath
            $script:RetentionDone[$LogPath] = $true
        }
    }
}

# -- Write-SyncLog ------------------------------------------------------------
function Write-SyncLog {
    <#
    .SYNOPSIS
        Writes a timestamped log entry for the sync run to the console and to
        Config.Sync.LogPath (if configured).
    .PARAMETER Message
        The log message.
    .PARAMETER Level
        INFO (default), WARN, or ERROR.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    Write-LogEntry -Message $Message -Level $Level -LogPath (Get-ConfiguredLogPath -Section 'Sync')
}

# -- Write-TaskLog ------------------------------------------------------------
function Write-TaskLog {
    <#
    .SYNOPSIS
        Writes a timestamped log entry for task-registration events to the
        console and to Config.ScheduledTask.LogPath (if configured).
    .PARAMETER Message
        The log message.
    .PARAMETER Level
        INFO (default), WARN, or ERROR.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    Write-LogEntry -Message $Message -Level $Level -LogPath (Get-ConfiguredLogPath -Section 'ScheduledTask')
}

# -- Get-SyncConfig -----------------------------------------------------------
function Get-SyncConfig {
    <#
    .SYNOPSIS
        Loads and validates sync-config.json. Returns the config object and sets $script:Config.
    .PARAMETER ConfigPath
        Path to sync-config.json. Defaults to .\config\sync-config.json relative to the
        module root.
    #>
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\sync-config.json')
    )

    $resolved = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue
    if (-not $resolved) {
        throw "Configuration file not found: $ConfigPath`nCopy config\sync-config.example.json to config\sync-config.json and fill in your values."
    }

    $raw = Get-Content $resolved.Path -Raw -Encoding UTF8
    $config = $raw | ConvertFrom-Json

    # Required field validation
    $required = @(
        @{ Path = 'AzureAD.TenantId';    Label = 'AzureAD.TenantId' },
        @{ Path = 'AzureAD.ClientId';    Label = 'AzureAD.ClientId' },
        @{ Path = 'LocalAD.Server';      Label = 'LocalAD.Server' },
        @{ Path = 'LocalAD.TargetOU';    Label = 'LocalAD.TargetOU' },
        @{ Path = 'LocalAD.GroupsOU';    Label = 'LocalAD.GroupsOU' }
    )
    foreach ($r in $required) {
        $parts = $r.Path -split '\.'
        $val = $config
        foreach ($p in $parts) { $val = $val.$p }
        if ([string]::IsNullOrWhiteSpace($val) -or $val -like '<*>') {
            throw "Missing required config value: $($r.Label)"
        }
    }

    $script:Config = $config
    return $config
}

# -- ConvertTo-AdAttributes ---------------------------------------------------
function ConvertTo-AdAttributes {
    <#
    .SYNOPSIS
        Maps a Microsoft Graph user object to a hashtable of on-prem AD attribute names and values.
    .PARAMETER GraphUser
        A user object returned by Get-MgUser.
    .PARAMETER Config
        The sync config object. Uses Config.AttributeMap for the mapping.
    #>
    param(
        [Parameter(Mandatory)][object]$GraphUser,
        [Parameter(Mandatory)][object]$Config
    )

    $map = $Config.AttributeMap
    $attrs = @{}

    # Iterate each mapping defined in config
    foreach ($graphProp in $map.PSObject.Properties.Name) {
        $adAttr = $map.$graphProp
        $value  = $GraphUser.$graphProp
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $attrs[$adAttr] = $value
        }
    }

    return $attrs
}

# -- Test-AdUserExists --------------------------------------------------------
function Test-AdUserExists {
    <#
    .SYNOPSIS
        Returns the AD user object whose msDS-cloudExtensionAttribute1 matches the given Azure OID,
        or $null if not found.
    .PARAMETER AzureObjectId
        The Azure AD object ID stored in msDS-cloudExtensionAttribute1.
    .PARAMETER Server
        The AD domain controller to query.
    #>
    param(
        [Parameter(Mandatory)][string]$AzureObjectId,
        [Parameter(Mandatory)][string]$Server
    )

    try {
        # Load every property Sync-Users.ps1 diffs against. Without these the diff loop
        # reads $null under StrictMode (PropertyNotFoundException) and the per-user
        # try/catch silently increments $stats.Errors.
        $user = Get-ADUser -Filter "msDS-cloudExtensionAttribute1 -eq '$AzureObjectId'" `
                           -Server $Server `
                           -Properties 'msDS-cloudExtensionAttribute1', UserPrincipalName, Enabled,
                                       DisplayName, GivenName, Surname, EmailAddress,
                                       Department, Title, MobilePhone, Office, Company `
                           -ErrorAction SilentlyContinue
        return $user
    } catch {
        return $null
    }
}

# -- Test-AdGroupExists -------------------------------------------------------
function Test-AdGroupExists {
    <#
    .SYNOPSIS
        Returns the AD group whose adminDescription matches the given Azure OID, or $null.
    .DESCRIPTION
        Groups do not carry the msDS-cloudExtensionAttribute1 schema (that auxiliary class is
        User-only). adminDescription is defined on the Top abstract class and is therefore
        available on all AD object types including groups.
    #>
    param(
        [Parameter(Mandatory)][string]$AzureObjectId,
        [Parameter(Mandatory)][string]$Server
    )

    try {
        $group = Get-ADGroup -Filter "adminDescription -eq '$AzureObjectId'" `
                             -Server $Server `
                             -Properties adminDescription `
                             -ErrorAction SilentlyContinue
        return $group
    } catch {
        return $null
    }
}

# -- New-RandomPassword -------------------------------------------------------
function New-RandomPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random 24-character password satisfying AD complexity.
    #>
    $chars  = 'abcdefghijklmnopqrstuvwxyz'
    $upper  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $digits = '0123456789'
    $syms   = '!@#$%^&*()-_=+[]{}|;:,.<>?'
    $all    = $chars + $upper + $digits + $syms

    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)

    # Guarantee at least one of each class
    $pw  = [char]$upper[$bytes[0]  % $upper.Length]
    $pw += [char]$chars[$bytes[1]  % $chars.Length]
    $pw += [char]$digits[$bytes[2] % $digits.Length]
    $pw += [char]$syms[$bytes[3]   % $syms.Length]

    for ($i = 4; $i -lt 24; $i++) {
        $pw += [char]$all[$bytes[$i] % $all.Length]
    }

    # Shuffle
    $arr = $pw.ToCharArray()
    for ($i = $arr.Length - 1; $i -gt 0; $i--) {
        $j = $bytes[($i * 3) % $bytes.Length] % ($i + 1)
        $tmp = $arr[$i]; $arr[$i] = $arr[$j]; $arr[$j] = $tmp
    }

    return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            ($arr -join '' | ConvertTo-SecureString -AsPlainText -Force)
        )
    )
}

# -- New-SecureRandomPassword -------------------------------------------------
function New-SecureRandomPassword {
    <#
    .SYNOPSIS
        Same as New-RandomPassword but returns a SecureString (required by New-ADUser -AccountPassword).
    #>
    return (New-RandomPassword | ConvertTo-SecureString -AsPlainText -Force)
}

Export-ModuleMember -Function @(
    'Write-SyncLog',
    'Write-TaskLog',
    'Get-SyncConfig',
    'ConvertTo-AdAttributes',
    'Test-AdUserExists',
    'Test-AdGroupExists',
    'New-RandomPassword',
    'New-SecureRandomPassword'
)
Export-ModuleMember -Variable @('DryRun', 'Config')
