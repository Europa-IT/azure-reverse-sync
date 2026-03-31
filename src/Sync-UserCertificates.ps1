<#
.SYNOPSIS
    Syncs Azure AD user certificates to on-prem AD for PKINIT (certificate-based Kerberos).
.DESCRIPTION
    For each Azure AD user with a Certificate-Based Authentication (CBA) certificate:
      - Fetches the certificate's public bytes via the Graph authenticaiton methods API.
      - Writes the certificate to the on-prem AD user's userCertificate attribute.

    On first run (or when CACertificatePath is set), adds the issuing CA certificate to the
    enterprise NTAuth store so the on-prem KDC trusts PKINIT authentication from that CA.

    After this script runs, users can obtain Kerberos TGTs using their Azure AD certificate
    (via kinit -X X509_user_identity=... or Windows Smart Card / Virtual Smart Card logon)
    without needing their on-prem AD password to match at all.

    Must be dot-sourced after Sync-Users.ps1 (users must exist in AD before certs are written).

    Required Graph permission: UserAuthenticationMethod.Read.All
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg   = $script:Config
$adSrv = $cfg.LocalAD.Server

if (-not $cfg.PKINIT.Enabled) {
    Write-SyncLog "PKINIT sync disabled in config — skipping."
    return
}

Write-SyncLog "=== Sync-UserCertificates (PKINIT) started ==="

# ── One-time: trust the issuing CA in the NTAuth store ───────────────────────
$caPath = $cfg.PKINIT.CACertificatePath
if ($caPath -and (Test-Path $caPath)) {
    $ntauthCheck = & certutil -enterprise -store NTAuth 2>&1
    $caThumbprint = (Get-PfxCertificate -FilePath $caPath).Thumbprint
    if ($ntauthCheck -notmatch $caThumbprint) {
        Write-SyncLog "Adding issuing CA to NTAuth store: $caPath"
        if (-not $script:DryRun) {
            $result = & certutil -enterprise -addstore NTAuth $caPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-SyncLog "certutil NTAuth add failed: $result" -Level ERROR
            } else {
                Write-SyncLog "CA added to NTAuth store (thumbprint: $caThumbprint)"
            }
        } else {
            Write-SyncLog "[DRYRUN] Would add CA to NTAuth store: $caPath"
        }
    } else {
        Write-SyncLog "CA already trusted in NTAuth store (thumbprint: $caThumbprint)"
    }
} elseif ($caPath) {
    Write-SyncLog "PKINIT.CACertificatePath '$caPath' not found — skipping NTAuth setup." -Level WARN
}

# ── Per-user certificate sync ─────────────────────────────────────────────────
$managedAdUsers = Get-ADUser -Filter { extensionAttribute1 -like '*-*-*-*-*' } `
                             -Server $adSrv `
                             -Properties extensionAttribute1, UserPrincipalName, userCertificate

$stats = @{ Synced = 0; NoCert = 0; Skipped = 0; Errors = 0 }

foreach ($adUser in $managedAdUsers) {
    $azureOid = $adUser.extensionAttribute1
    try {
        # Fetch certificate methods for this user from Graph
        $certMethods = Get-MgUserAuthenticationCertificateBasedAuthConfiguration `
                           -UserId $azureOid -ErrorAction SilentlyContinue

        # Fallback: try the authentication methods endpoint
        if (-not $certMethods) {
            $authMethods = Get-MgUserAuthenticationMethod -UserId $azureOid -ErrorAction SilentlyContinue
            $certMethods = $authMethods | Where-Object { $_.'@odata.type' -like '*certificateBasedAuth*' }
        }

        if (-not $certMethods -or @($certMethods).Count -eq 0) {
            Write-SyncLog "No CBA certificate for $($adUser.UserPrincipalName) — skipping PKINIT sync."
            $stats.NoCert++
            continue
        }

        $newCerts = [System.Collections.Generic.List[byte[]]]::new()
        foreach ($method in $certMethods) {
            # certificateData is a Base64-encoded DER certificate
            if ($method.certificateData -or $method.AdditionalProperties.certificateData) {
                $b64 = if ($method.certificateData) { $method.certificateData } `
                       else { $method.AdditionalProperties.certificateData }
                $certBytes = [Convert]::FromBase64String($b64)
                $newCerts.Add($certBytes)

                $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
                Write-SyncLog "Certificate for $($adUser.UserPrincipalName): thumbprint=$($cert.Thumbprint), expires=$($cert.NotAfter.ToString('yyyy-MM-dd'))"
            }
        }

        if ($newCerts.Count -eq 0) {
            $stats.NoCert++
            continue
        }

        if ($script:DryRun) {
            Write-SyncLog "[DRYRUN] Would write $($newCerts.Count) certificate(s) to $($adUser.UserPrincipalName)"
            $stats.Skipped++
            continue
        }

        # Write all certificates to the AD userCertificate multi-value attribute
        Set-ADUser -Identity $adUser.DistinguishedName -Server $adSrv `
                   -Replace @{ userCertificate = $newCerts.ToArray() }

        Write-SyncLog "Wrote $($newCerts.Count) PKINIT certificate(s) to $($adUser.UserPrincipalName)"
        $stats.Synced++

    } catch {
        Write-SyncLog "Error syncing certificate for $($adUser.UserPrincipalName): $_" -Level ERROR
        $stats.Errors++
    }
}

Write-SyncLog "=== Sync-UserCertificates complete — Synced: $($stats.Synced), NoCert: $($stats.NoCert), Skipped: $($stats.Skipped), Errors: $($stats.Errors) ==="
