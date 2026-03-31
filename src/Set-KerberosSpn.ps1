<#
.SYNOPSIS
    Registers Kerberos Service Principal Names (SPNs) in AD and exports keytab files.
.DESCRIPTION
    For each service account entry in config.Kerberos.ServiceAccounts:
      1. Registers the SPN (e.g., cifs/fileserver01.corp.example.com) on the AD service account.
      2. Exports a keytab file using ktpass.exe (AES256-SHA1 encryption).
      3. ACLs the keytab file so only the service account and Administrators can read it.

    Keytabs are placed in config.Kerberos.KeytabOutputPath.
    The service account must already exist in AD before running this script.

    Keytab files must never be committed to source control (.gitignore includes *.keytab).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg     = $script:Config
$adSrv   = $cfg.LocalAD.Server
$realm   = $cfg.Kerberos.Realm.ToUpper()
$outPath = $cfg.Kerberos.KeytabOutputPath

Write-SyncLog "=== Set-KerberosSpn started ==="

# Ensure ktpass.exe is available
$ktpass = Get-Command ktpass.exe -ErrorAction SilentlyContinue
if (-not $ktpass) {
    Write-SyncLog "ktpass.exe not found on PATH. Install RSAT-AD-Tools or run from a domain controller." -Level ERROR
    return
}

if (-not (Test-Path $outPath)) {
    if ($script:DryRun) {
        Write-SyncLog "[DRYRUN] Would create keytab output directory: $outPath"
    } else {
        New-Item -ItemType Directory -Path $outPath -Force | Out-Null
        Write-SyncLog "Created keytab output directory: $outPath"
    }
}

$stats = @{ SPNsRegistered = 0; KeytabsExported = 0; Skipped = 0; Errors = 0 }

# TODO Modify logic to automatically register users synced from Azure AD as service accounts
foreach ($sa in $cfg.Kerberos.ServiceAccounts) {
    $sam         = $sa.SamAccountName
    $fqdn        = $sa.FQDN
    $svcClass    = $sa.ServiceClass
    $spn         = "$svcClass/$fqdn"
    $principal   = "$spn@$realm"
    $keytabFile  = Join-Path $outPath "$sam.keytab"
    $upnForKtpass = "$sam@$realm"

    Write-SyncLog "Processing service account: $sam (SPN: $spn)"

    try {
        # ── Verify the service account exists in AD ───────────────────────────
        $adSvcAccount = Get-ADUser -Filter { SamAccountName -eq $sam } -Server $adSrv -ErrorAction SilentlyContinue
        if (-not $adSvcAccount) {
            Write-SyncLog "Service account '$sam' not found in AD — skipping." -Level WARN
            $stats.Skipped++
            continue
        }

        # ── Register SPN ──────────────────────────────────────────────────────
        $existingSpns = $adSvcAccount | Select-Object -ExpandProperty ServicePrincipalNames
        if ($existingSpns -notcontains $spn) {
            if ($script:DryRun) {
                Write-SyncLog "[DRYRUN] Would register SPN: $spn on $sam"
            } else {
                Set-ADUser -Identity $adSvcAccount.DistinguishedName -Server $adSrv `
                           -ServicePrincipalNames @{ Add = $spn }
                Write-SyncLog "Registered SPN: $spn on $sam"
            }
            $stats.SPNsRegistered++
        } else {
            Write-SyncLog "SPN already registered: $spn on $sam"
        }

        if ($script:DryRun) {
            Write-SyncLog "[DRYRUN] Would export keytab: $keytabFile"
            $stats.Skipped++
            continue
        }

        # ── Export keytab via ktpass.exe ──────────────────────────────────────
        # /pass * prompts for password interactively, which is required by ktpass when
        # called non-interactively we pass a placeholder and reset the password after.
        # For non-interactive use we set a known password on the service account first.
        $tempPw = New-RandomPassword
        Set-ADAccountPassword -Identity $adSvcAccount.DistinguishedName `
                              -NewPassword ($tempPw | ConvertTo-SecureString -AsPlainText -Force) `
                              -Reset -Server $adSrv

        $ktpassArgs = @(
            '/out', $keytabFile,
            '/mapuser', $upnForKtpass,
            '/princ', $principal,
            '/pass', $tempPw,
            '/crypto', 'AES256-SHA1',
            '/ptype', 'KRB5_NT_PRINCIPAL',
            '/mapop', 'set'
        )

        $result = & ktpass.exe @ktpassArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "ktpass.exe failed (exit $LASTEXITCODE): $result"
        }
        Write-SyncLog "Exported keytab: $keytabFile"
        $stats.KeytabsExported++

        # ── ACL the keytab: only SYSTEM, Administrators, and the service account ──
        $acl = Get-Acl -Path $keytabFile
        $acl.SetAccessRuleProtection($true, $false)  # disable inheritance

        $adminRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            'BUILTIN\Administrators', 'FullControl', 'Allow'
        )
        $systemRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow'
        )
        $svcRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            "$env:USERDOMAIN\$sam", 'Read', 'Allow'
        )
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($systemRule)
        $acl.AddAccessRule($svcRule)
        Set-Acl -Path $keytabFile -AclObject $acl
        Write-SyncLog "ACL applied to keytab: Administrators+SYSTEM (Full), $sam (Read)"

    } catch {
        Write-SyncLog "Error processing service account $sam`: $_" -Level ERROR
        $stats.Errors++
    }
}

Write-SyncLog "=== Set-KerberosSpn complete — SPNs: $($stats.SPNsRegistered), Keytabs: $($stats.KeytabsExported), Skipped: $($stats.Skipped), Errors: $($stats.Errors) ==="
Write-SyncLog "Keytab location: $outPath — ensure this path is accessible only to authorized service accounts."
