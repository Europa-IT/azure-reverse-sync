<#
.SYNOPSIS
    Shared helper module for azure-reverse-sync.
.DESCRIPTION
    Provides: Write-SyncLog, Get-SyncConfig, ConvertTo-AdAttributes, Test-AdUserExists,
    New-RandomPassword, and script-level $script:DryRun / $script:Config state.
#>

Set-StrictMode -Version Latest

# -- Module-level state -------------------------------------------------------
# Set by the orchestrator before dot-sourcing sub-scripts.
$script:DryRun = $false
$script:Config = $null

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

# -- Get-LogRotationConfig (private) ------------------------------------------
# Returns rotation parameters, reading from $script:Config.Logging if present,
# falling back to sensible defaults otherwise. No config changes are required
# for rotation to work -- it just uses the defaults.
function Get-LogRotationConfig {
    $rot = @{ MaxSizeMb = 10; MaxFiles = 5 }
    if ($script:Config -and $script:Config.PSObject.Properties['Logging']) {
        $logging = $script:Config.Logging
        if ($logging.PSObject.Properties['MaxSizeMb']) { $rot.MaxSizeMb = [int]$logging.MaxSizeMb }
        if ($logging.PSObject.Properties['MaxFiles'])  { $rot.MaxFiles  = [int]$logging.MaxFiles }
    }
    return [PSCustomObject]$rot
}

# -- Invoke-LogRotation (private) ---------------------------------------------
# If $LogPath is larger than MaxSizeMb, rotates: log.(N-1) -> log.N, ..., log -> log.1.
# Drops the oldest archive (log.MaxFiles) before shifting. Errors here are
# reported to the console but never propagated -- a logging-infrastructure
# failure must not break the calling sync run.
function Invoke-LogRotation {
    param(
        [Parameter(Mandatory)][string]$LogPath
    )
    if (-not (Test-Path $LogPath -PathType Leaf)) { return }
    $rot = Get-LogRotationConfig
    if ((Get-Item $LogPath).Length -lt ($rot.MaxSizeMb * 1MB)) { return }

    try {
        # Drop the oldest archive if it already exists.
        $oldest = "$LogPath.$($rot.MaxFiles)"
        if (Test-Path $oldest) { Remove-Item $oldest -Force }

        # Shift each archive up by one slot: log.(N-1) -> log.N, ..., log.1 -> log.2.
        for ($i = $rot.MaxFiles - 1; $i -ge 1; $i--) {
            $src = "$LogPath.$i"
            $dst = "$LogPath.$($i + 1)"
            if (Test-Path $src) { Move-Item $src $dst -Force }
        }

        # Promote the active log to log.1.
        Move-Item $LogPath "$LogPath.1" -Force
    } catch {
        Write-Host "[WARN] Log rotation failed for '$LogPath': $_" -ForegroundColor Yellow
    }
}

# -- Write-LogEntry (private) -------------------------------------------------
# Shared core for Write-SyncLog and Write-TaskLog. Formats the line, writes to
# console, then (if a log path is provided) rotates and appends to file.
function Write-LogEntry {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO',
        [string]$LogPath
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
        $logDir = Split-Path $LogPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Invoke-LogRotation -LogPath $LogPath
        Add-Content -Path $LogPath -Value $entry -Encoding UTF8
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
