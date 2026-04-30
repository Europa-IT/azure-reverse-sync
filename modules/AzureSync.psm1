<#
.SYNOPSIS
    Shared helper module for azure-reverse-sync.
.DESCRIPTION
    Provides: Write-SyncLog, Get-SyncConfig, ConvertTo-AdAttributes, Test-AdUserExists,
    New-RandomPassword, and script-level $script:DryRun / $script:Config state.
#>

Set-StrictMode -Version Latest

# ── Module-level state ────────────────────────────────────────────────────────
# Set by the orchestrator before dot-sourcing sub-scripts.
$script:DryRun = $false
$script:Config = $null

# ── Write-SyncLog ─────────────────────────────────────────────────────────────
function Write-SyncLog {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to the console and to the log file defined in config.
    .PARAMETER Message
        The log message.
    .PARAMETER Level
        INFO (default), WARN, or ERROR.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $prefix = if ($script:DryRun) { '[DRYRUN] ' } else { '' }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $prefix$Message"

    switch ($Level) {
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        default { Write-Host $entry }
    }

    if ($script:Config -and $script:Config.Sync.LogPath) {
        $logDir = Split-Path $script:Config.Sync.LogPath -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $script:Config.Sync.LogPath -Value $entry -Encoding UTF8
    }
}

# ── Get-SyncConfig ────────────────────────────────────────────────────────────
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

# ── ConvertTo-AdAttributes ────────────────────────────────────────────────────
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

# ── Test-AdUserExists ─────────────────────────────────────────────────────────
function Test-AdUserExists {
    <#
    .SYNOPSIS
        Returns the AD user object whose extensionAttribute1 matches the given Azure OID,
        or $null if not found.
    .PARAMETER AzureObjectId
        The Azure AD object ID stored in extensionAttribute1.
    .PARAMETER Server
        The AD domain controller to query.
    #>
    param(
        [Parameter(Mandatory)][string]$AzureObjectId,
        [Parameter(Mandatory)][string]$Server
    )

    try {
        $user = Get-ADUser -Filter { extensionAttribute1 -eq $AzureObjectId } `
                           -Server $Server `
                           -Properties extensionAttribute1, UserPrincipalName, Enabled `
                           -ErrorAction SilentlyContinue
        return $user
    } catch {
        return $null
    }
}

# ── Test-AdGroupExists ────────────────────────────────────────────────────────
function Test-AdGroupExists {
    <#
    .SYNOPSIS
        Returns the AD group whose extensionAttribute1 matches the given Azure OID, or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$AzureObjectId,
        [Parameter(Mandatory)][string]$Server
    )

    try {
        $group = Get-ADGroup -Filter { extensionAttribute1 -eq $AzureObjectId } `
                             -Server $Server `
                             -Properties extensionAttribute1 `
                             -ErrorAction SilentlyContinue
        return $group
    } catch {
        return $null
    }
}

# ── New-RandomPassword ────────────────────────────────────────────────────────
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

# ── New-SecureRandomPassword ──────────────────────────────────────────────────
function New-SecureRandomPassword {
    <#
    .SYNOPSIS
        Same as New-RandomPassword but returns a SecureString (required by New-ADUser -AccountPassword).
    #>
    return (New-RandomPassword | ConvertTo-SecureString -AsPlainText -Force)
}

Export-ModuleMember -Function @(
    'Write-SyncLog',
    'Get-SyncConfig',
    'ConvertTo-AdAttributes',
    'Test-AdUserExists',
    'Test-AdGroupExists',
    'New-RandomPassword',
    'New-SecureRandomPassword'
)
Export-ModuleMember -Variable @('DryRun', 'Config')
