# CBA and PKINIT Setup Guide

This guide is a companion to [deployment-outline.md](deployment-outline.md) (Phase 5). It
expands the Kerberos enablement phase into actionable, copy-paste-ready steps for a Windows
sysadmin audience.

**End state:** Azure AD users authenticate to on-prem Kerberos resources (CIFS, NFS, HTTP)
using their Entra Certificate-Based Authentication (CBA) certificate. No password hash sync
is required at any point.

---

## Overview and Architecture

### Why not password sync?

The Microsoft Graph API does not expose password hashes, and there is no supported Microsoft
mechanism to sync Kerberos key material from Azure AD to on-prem AD. This is a deliberate
Microsoft design decision, not a tooling gap. Synced users will always have a random,
unusable on-prem password — PKINIT (certificate-based Kerberos) is the only supported
end-user authentication path.

### Trust chain

```
Entra ID (CBA)
    │  User holds certificate issued by Corp Issuing CA
    │  Graph API: UserAuthenticationMethod.Read.All
    ▼
Sync-UserCertificates.ps1
    │  Decodes base64 DER → writes to AD userCertificate (multi-value attribute)
    │  Adds Corp Issuing CA to NTAuth store (certutil -enterprise -addstore)
    ▼
On-prem AD / Windows KDC (kdcsvc)
    │  NTAuth store → KDC trusts PKINIT requests from Corp Issuing CA
    │  userCertificate → KDC resolves PKINIT request to the correct AD account
    ▼
Kerberos TGT issued to user (no password exchange)
    ▼
User accesses CIFS / NFS / HTTP services using Kerberos ticket
```

### Authentication paths

| Path | Mechanism | Configured by |
|---|---|---|
| End-user Kerberos TGT (certificate / PKINIT) | Azure AD CBA cert → AD `userCertificate` → PKINIT | Part 1 + Part 2 |
| Service account (CIFS, NFS, HTTP) | SPN registered in AD; keytab from `ktpass.exe` | Part 3 |

---

## Part 1 — Azure AD Certificate-Based Authentication (CBA)

### 1.1  Prerequisites

- **Azure AD license:** Azure AD P1 or P2, or Microsoft 365 Business Premium. CBA is not
  available on free or Basic tiers. Verify at Entra ID > Licenses.
- **Role:** Global Administrator or Authentication Policy Administrator in Entra ID, to
  configure certificate authorities and the CBA authentication method policy.
- **A PKI issuing CA** — either an enterprise CA (Active Directory Certificate Services) or a
  third-party CA. See Section 1.2 before choosing.
- **User certificates** that contain the user's UPN in the Subject Alternative Name (SAN)
  `otherName` field (OID `1.3.6.1.4.1.311.20.2.3`) or the `rfc822Name` field, matching the
  user's Entra UPN exactly.

### 1.2  Design your PKI: use a dedicated issuing CA

> **Critical:** The CA certificate uploaded to Entra — and later added to the on-prem NTAuth
> store — confers the right to issue domain-logon certificates. **Never add a root CA to
> NTAuth.** Any cert anywhere in that CA hierarchy could then authenticate as an AD user.

Best practice:

- Use a **two-tier PKI**: offline root CA → online issuing CA.
- The issuing CA issues **only** end-user authentication certificates — not TLS, code-signing,
  or other purposes.
- The root CA stays offline.
- The issuing CA's `.cer` file (public cert, no private key, DER-encoded) is what gets
  uploaded to Entra and copied to `CACertificatePath` in `sync-config.json`.

Export the issuing CA certificate:

```powershell
# From the issuing CA server
certutil -ca.cert C:\certs\issuing-ca.cer
```

Or export via MMC > Certificates > Trusted Root Certification Authorities > right-click CA >
All Tasks > Export > DER encoded binary.

### 1.3  Upload the CA to Microsoft Entra ID

1. Azure portal → **Microsoft Entra ID** → **Security** → **Certificate authorities**
2. Click **+ Upload**
3. Upload the issuing CA `.cer` file
4. Set **Certificate authority type** to `Intermediate` (or `Root` only if it is a root CA —
   see Section 1.2)
5. If the CA publishes a CRL: paste the CRL distribution point URL in the provided field

> **CRL reachability:** Entra ID validates certificate revocation via CRL. If the CA's CRL
> distribution point is an internal-only URL (e.g., `http://internal-ca/crl/...`), Entra's
> cloud infrastructure cannot reach it and **all CBA logins will fail**. For internal ADCS CAs,
> publish the CRL to a publicly accessible URL (Azure Blob Storage, a DMZ web server, etc.).
> This is the most common deployment blocker for internal PKI + CBA.

6. Click **Save**

**Verify:** The CA appears in the Certificate authorities list with status Active.

**Reference:** [Configure certificate-based authentication in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-certificate-based-authentication)

### 1.4  Configure the CBA authentication method policy

1. Entra ID → **Security** → **Authentication methods** → **Certificate-based authentication**
2. Toggle to **Enabled**; select **All users** or a target group
3. Under **Certificate bindings**, add a rule:
   - **Binding type:** `PrincipalName`
   - **Certificate field:** `Subject Alternative Name – User Principal Name`
   - **Affinity binding:** `High` (strong authentication binding — the UPN in the cert SAN must
     match the Entra UPN exactly)
4. Under **Authentication strength**, set whether certificate logon satisfies MFA or
   single-factor (affects Conditional Access policies; does not affect the Kerberos flow itself)

> **`userCertificate` vs `altSecurityIdentities`:** This toolset writes to the `userCertificate`
> AD attribute (implicit mapping — the KDC resolves the certificate by subject/SAN). An
> alternative is `altSecurityIdentities` with explicit string mappings like
> `X509:<I>CN=Corp Issuing CA<S>CN=Alice`. `altSecurityIdentities` with the SID extension
> (`X509:<SI>...`) is required in some environments after KB5014754 enforcement (see
> Troubleshooting). For most deployments with UPN-based CBA, `userCertificate` is sufficient.

**Reference:** [Certificate user IDs and binding types](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-certificate-based-authentication-certificateuserids)

### 1.5  Issue certificates to users

#### Option A — ADCS with NDES (managed/domain-joined devices)

Standard enterprise approach. Certificate template requirements:

| Field | Value |
|---|---|
| Key Usage | Digital Signature |
| Enhanced Key Usage | Smart Card Logon (`1.3.6.1.4.1.311.20.2.2`) **and** Client Authentication (`1.3.6.1.5.5.7.3.2`) |
| Subject Alternative Name | UPN (`otherName` with OID `1.3.6.1.4.1.311.20.2.3`) matching the user's Entra UPN |
| Subject | `CN=<displayName>` (the KDC and Entra use the SAN UPN for binding; the subject is secondary) |
| Minimum key size | 2048-bit RSA or P-256 ECDSA |

#### Option B — Third-party CA

Works provided the CA cert is uploaded to Entra (Section 1.3) and the certificate profile meets
the requirements above.

Certificate delivery (Intune certificate profiles, Group Policy auto-enrollment, or manual) is
outside the scope of this toolset.

### 1.6  Verify that users have CBA credentials

Before running the sync, confirm users have registered CBA certificates:

**Entra portal:** Entra ID → Users → (user) → Authentication methods — a "Certificate" entry
should be present.

**PowerShell:**

```powershell
Connect-MgGraph -Scopes 'UserAuthenticationMethod.Read.All'
Get-MgUserAuthenticationCertificateBasedAuthConfiguration -UserId 'alice@corp.example.com'
```

If this returns nothing, the user has no registered CBA certificate. `Sync-UserCertificates.ps1`
will log `No CBA certificate for ... — skipping PKINIT sync` and move on.

---

## Part 2 — On-Prem PKINIT Setup

### 2.1  Prerequisites

- Windows Server with AD DS (2016+ recommended for full AES256 support)
- The sync server must be **domain-joined** with RSAT installed:
  ```powershell
  Install-WindowsFeature RSAT-AD-Tools
  ```
- **Enterprise Admin** permissions — `certutil -enterprise -addstore NTAuth` writes to the
  Configuration naming context, which requires Enterprise Admin (not just Domain Admin).
  This is a common deployment blocker.
- The issuing CA `.cer` file accessible on the sync server at the path configured in
  `PKINIT.CACertificatePath`
- Base user sync already completed (Parts 0–2 of `deployment-outline.md`) — users must exist
  in AD before `Sync-UserCertificates.ps1` can write certificates to them
- Graph permission `UserAuthenticationMethod.Read.All` granted as an Application permission
  with admin consent (see `deployment-outline.md` Phase 0)

### 2.2  Configure sync-config.json — PKINIT section

```json
"PKINIT": {
  "Enabled": true,
  "CACertificatePath": "C:\\certs\\issuing-ca.cer",
  "CertificateSource": "EntraCBA"
}
```

| Field | Description |
|---|---|
| `Enabled` | Set `true` to activate PKINIT sync. When `false`, `Sync-UserCertificates.ps1` exits immediately. |
| `CACertificatePath` | Absolute path to the issuing CA `.cer` file (DER-encoded). Used for one-time NTAuth registration. If the file is not found, NTAuth setup is skipped with a WARN log. |
| `CertificateSource` | Must be `"EntraCBA"`. Reserved for future extension. |

### 2.3  Run Sync-UserCertificates.ps1

**Dry-run first:**

```powershell
.\src\Invoke-AzureSync.ps1 -DryRun -SkipUsers -SkipGroups -SkipKerberos
```

Expected log output:
```
[DRYRUN] Would add CA to NTAuth store: C:\certs\issuing-ca.cer
[DRYRUN] Would write 1 certificate(s) to alice@corp.example.com
```

**Live run (certificates only):**

```powershell
# Run as Administrator (Enterprise Admin required for NTAuth write)
.\src\Invoke-AzureSync.ps1 -SkipUsers -SkipGroups -SkipKerberos
```

**What happens:**

1. Checks `PKINIT.Enabled`; exits immediately if `false`.
2. Reads `CACertificatePath`, computes the CA thumbprint, and checks NTAuth. If the CA is
   absent, runs `certutil -enterprise -addstore NTAuth <caPath>`. This step is idempotent.
3. For every AD user with `extensionAttribute1` set (i.e., every user managed by this
   toolset), fetches CBA certificates from Graph via
   `Get-MgUserAuthenticationCertificateBasedAuthConfiguration`.
4. Decodes the base64 DER `certificateData` and writes the byte array to AD `userCertificate`
   via `Set-ADUser -Replace @{ userCertificate = ... }`.
5. Users without a registered CBA certificate are skipped with a `NoCert` log entry.

### 2.4  Verify the NTAuth store

```powershell
certutil -enterprise -store NTAuth
```

The issuing CA's subject and thumbprint should appear in the output. If absent, PKINIT will
fail — the KDC will reject all certificate authentication attempts.

> **Replication:** NTAuth is stored in the Configuration naming context
> (`CN=NTAuthCertificates,CN=Public Key Services,...`) and replicates to all DCs.
> Force replication before testing:
> ```powershell
> repadmin /syncall /AdeP
> ```

### 2.5  Verify userCertificate in AD

```powershell
Get-ADUser -Identity alice -Properties userCertificate |
    Select-Object -ExpandProperty userCertificate |
    ForEach-Object {
        [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($_) |
        Select-Object Subject, Thumbprint, NotAfter
    }
```

Expected: one or more certificate objects with a future `NotAfter` date.

If `userCertificate` is empty:

1. Confirm the user has a CBA certificate in Entra (Section 1.6).
2. Confirm the user's `extensionAttribute1` is set (run `Sync-Users.ps1` first if not).
3. Confirm `UserAuthenticationMethod.Read.All` is granted and admin-consented.
4. Check `logs\sync.log` for `NoCert` or `ERROR` entries for this user.

### 2.6  KDC configuration notes

Windows KDC supports PKINIT natively on all Windows Server versions (2008+). No additional
configuration is required when the NTAuth store contains a trusted CA and the user has
`userCertificate` populated — PKINIT is active by default.

**AES encryption:** The KDC and `ktpass.exe` both use AES256-CTS-HMAC-SHA1-96. If the domain
Group Policy `Network security: Configure encryption types allowed for Kerberos` has RC4
disabled (recommended), AES256 must be included. This is the default on domain functional level
2008+, and matches the `/crypto AES256-SHA1` flag used by `Set-KerberosSpn.ps1`.

**Advanced KDC logging (for troubleshooting only):** Enable verbose KDC logging via:

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Kdc' `
                 -Name KdcExtraLogLevel -Value 0x1F
```

This writes PKINIT attempt details to the Security event log (Event ID 4768/4769). Reset to
`0x0` after troubleshooting.

### 2.7  Test Kerberos authentication

**Linux/macOS (MIT Kerberos with PKINIT plugin):**

```bash
# Install PKINIT support if needed:
# Debian/Ubuntu: apt install krb5-pkinit
# RHEL/Fedora:   dnf install krb5-pkinit

# Using PEM certificate + key:
kinit -X X509_user_identity=FILE:/path/to/user.pem,/path/to/user.key alice@CORP.EXAMPLE.COM

# Or using PKCS#12:
kinit -X X509_user_identity=PKCS12:/path/to/user.p12 alice@CORP.EXAMPLE.COM

klist  # TGT should show flags including 'P' (PKINIT) or 'pre-authentication: pkinit'
```

MIT Kerberos 1.16+ with the `pkinit` plugin compiled in is required. The Windows KDC
configuration is identical for Linux and Windows clients.

**Windows (smart card / virtual smart card):** Once the NTAuth store and `userCertificate` are
configured, Windows interactive logon using a smart card or Windows Hello for Business (TPM
virtual smart card) will work without additional configuration on the DC side.

**KDC reachability check (no certificate needed):**

```powershell
nltest /sc_verify:corp.example.com
```

---

## Part 3 — Service Account Kerberos (SPN + Keytab)

### 3.1  When this is needed

PKINIT (Part 2) covers end-user TGTs. For Kerberos to authorize access to a **service**, the
service needs its own Kerberos identity:

- A **Service Principal Name (SPN)** on an AD account — tells the KDC which account owns a
  given service identity.
- A **keytab file** — a local file holding the service account's long-term Kerberos keys, used
  by the service daemon to authenticate inbound Kerberos requests without interactive password
  entry.

This part applies to: Samba/CIFS file servers, NFS with Kerberos security (`sec=krb5`), and
web applications using GSSAPI/SPNEGO.

### 3.2  Create service accounts in AD

```powershell
# Run as Domain Admin or Account Operator
New-ADUser -Name 'svc-fileserver' `
           -SamAccountName 'svc-fileserver' `
           -UserPrincipalName 'svc-fileserver@corp.example.com' `
           -Path 'OU=ServiceAccounts,DC=corp,DC=example,DC=com' `
           -Enabled $true `
           -PasswordNeverExpires $true
```

> The service account must exist in AD **before** running `Set-KerberosSpn.ps1`. The script
> checks for the account and skips with a WARN if not found.

> **Password note:** `Set-KerberosSpn.ps1` sets a temporary random password on the service
> account during keytab generation — this is how `ktpass.exe` derives Kerberos keys. After
> `ktpass` runs, the keytab contains those keys and the account's AD password is irrelevant
> for Kerberos service-side authentication. The service process uses the keytab directly.

### 3.3  Configure sync-config.json — Kerberos section

```json
"Kerberos": {
  "Realm": "CORP.EXAMPLE.COM",
  "KeytabOutputPath": "C:\\keytabs",
  "ServiceAccounts": [
    {
      "SamAccountName": "svc-fileserver",
      "FQDN": "fileserver01.corp.example.com",
      "ServiceClass": "cifs"
    },
    {
      "SamAccountName": "svc-nfs",
      "FQDN": "nfsserver01.corp.example.com",
      "ServiceClass": "nfs"
    }
  ]
}
```

| Field | Description |
|---|---|
| `Realm` | Kerberos realm — the AD domain name in **UPPERCASE**. Must match exactly. |
| `KeytabOutputPath` | Directory where keytab files are written. Created automatically if absent. |
| `ServiceAccounts[].SamAccountName` | AD `sAMAccountName` of the service account (no `@domain` suffix). |
| `ServiceAccounts[].FQDN` | DNS name clients use to reach the service. Used to construct the SPN: `<ServiceClass>/<FQDN>@<Realm>`. |
| `ServiceAccounts[].ServiceClass` | `cifs` for SMB, `nfs` for NFS, `http` for SPNEGO/web, `host` for generic host-based services. |

**Multiple SPNs per account:** Add two entries with the same `SamAccountName` and different
`FQDN` values to register multiple SPNs on one account (e.g., short and FQDN forms:
`fileserver01` and `fileserver01.corp.example.com`).

### 3.4  Run Set-KerberosSpn.ps1

```powershell
# Run as Administrator — Domain Admin required for ktpass.exe
.\src\Invoke-AzureSync.ps1 -SkipUsers -SkipGroups -SkipCertificates
```

**What happens for each service account:**

1. Verifies the AD account exists; skips with WARN if not.
2. Registers the SPN via `Set-ADUser -ServicePrincipalNames @{ Add = $spn }`. Idempotent —
   skips if the SPN is already registered.
3. Sets a temporary random password on the account.
4. Runs:
   ```
   ktpass.exe /out <keytab> /mapuser <sam>@<REALM> /princ <spn>@<REALM>
              /pass <tempPw> /crypto AES256-SHA1 /ptype KRB5_NT_PRINCIPAL /mapop set
   ```
5. ACLs the keytab: disables ACL inheritance; grants Administrators and SYSTEM `FullControl`,
   service account `Read`.

> **`/mapop set` side effect:** This flag sets the service account's `userPrincipalName` in AD
> to `<sam>@<REALM>`. This is intentional and required for `ktpass.exe`.

> **Enctype:** `AES256-SHA1` = `AES256-CTS-HMAC-SHA1-96` in MIT Kerberos terminology. In
> `krb5.conf` on Linux, this is listed as `aes256-cts-hmac-sha1-96`. No RC4 keytab generation
> is needed or recommended.

`ktpass.exe` ships with RSAT-AD-Tools:

```powershell
Install-WindowsFeature RSAT-AD-Tools
```

### 3.5  Verify SPNs

```powershell
setspn -L svc-fileserver
# Expected:
# Registered ServicePrincipalNames for CN=svc-fileserver,...:
#     cifs/fileserver01.corp.example.com

# Check for duplicate SPNs across the entire forest (should return nothing):
setspn -X
```

A duplicate SPN (same SPN on two accounts) prevents Kerberos from working and is a frequent
cause of `KRB_AP_ERR_MODIFIED` errors.

### 3.6  Deploy the keytab to the service host

- Keytabs are written to `KeytabOutputPath` on the sync server (e.g., `C:\keytabs\svc-fileserver.keytab`).
- Copy to the service host using a secure channel (PSSession, SCP, SFTP).
- **Linux:** place at the path your service daemon expects; set strict permissions:
  ```bash
  chmod 600 /etc/samba/svc-fileserver.keytab
  chown root /etc/samba/svc-fileserver.keytab
  ```
- **Windows:** copy preserving ACLs; re-apply the ACL if needed.
- The keytab is equivalent to the service account's password for Kerberos purposes.
  **Never commit it to source control.** `*.keytab` is already in `.gitignore`.

### 3.7  Test Kerberos service tickets

**Windows client:**

```powershell
# Access the share (triggers service ticket acquisition)
net use \\fileserver01.corp.example.com\share

# Verify the service ticket was issued
klist
# Look for:  Server: cifs/fileserver01.corp.example.com @ CORP.EXAMPLE.COM
```

**Linux client:**

```bash
# Get a TGT first (via PKINIT or other means)
kinit alice@CORP.EXAMPLE.COM

# Access the CIFS share
smbclient //fileserver01.corp.example.com/share -k

# Verify the service ticket
klist
```

---

## Troubleshooting

### CA not in NTAuth store

**Symptom:** PKINIT authentication fails. On Windows: "The system could not log you on. The
certificate is not trusted." Security event 4769 with failure code `0x19`
(`KDC_ERR_PADATA_TYPE_NOSUPP`) or `0xD` (`KDC_ERR_BADOPTION`).

**Diagnose:**

```powershell
certutil -enterprise -store NTAuth
# CA thumbprint absent → it was not added
```

**Resolution:**

```powershell
# Must be run as Enterprise Admin
certutil -enterprise -addstore NTAuth "C:\certs\issuing-ca.cer"
repadmin /syncall /AdeP  # force replication to all DCs
```

Also confirm `CACertificatePath` in `sync-config.json` points to the correct issuing CA file
(not the root CA, not a different intermediate).

### userCertificate attribute is empty

**Symptom:** PKINIT fails; `Get-ADUser -Properties userCertificate` returns nothing.

**Diagnose:**

```powershell
# Confirm extensionAttribute1 is populated (required for Sync-UserCertificates.ps1 to process the user)
Get-ADUser alice -Properties extensionAttribute1 | Select-Object extensionAttribute1

# Check sync log for this user
Select-String -Path logs\sync.log -Pattern 'alice@corp.example.com'
```

**Resolution:**

- `extensionAttribute1` empty → run `Sync-Users.ps1` first.
- Log shows `NoCert` → user has no registered CBA certificate in Entra (see Section 1.5–1.6).
- Log shows `ERROR` with a Graph exception → verify `UserAuthenticationMethod.Read.All` is
  granted as an Application permission with admin consent.

### SPN duplicate conflict

**Symptom:** `KRB_AP_ERR_MODIFIED` on the client ("The message or signature has been tampered
with"). `setspn -X` shows the same SPN on multiple accounts.

**Resolution:**

```powershell
# Remove the SPN from the wrong account
Set-ADUser -Identity wrong-account -ServicePrincipalNames @{ Remove = 'cifs/fileserver01.corp.example.com' }
# Re-run Set-KerberosSpn.ps1 to re-register on the correct account
```

### Keytab encryption mismatch

**Symptom:** `KRB5KDC_ERR_ETYPE_NOSUPP` ("KDC has no support for encryption type") or
`KRB5_KT_NOTFOUND` ("Key table entry not found").

**Explanation:** The keytab uses AES256-CTS-HMAC-SHA1-96. If the service daemon or domain
policy restricts to RC4/DES, the keys will not match.

**Resolution:**

- Windows GPO: confirm "Network security: Configure encryption types allowed for Kerberos"
  includes `AES256_HMAC_SHA1`.
- Linux Samba: ensure `smb.conf` does not restrict Kerberos enctypes to old ones (modern Samba
  defaults are correct).
- If you must regenerate the keytab after resolving the enctype mismatch, re-run
  `Set-KerberosSpn.ps1` and re-deploy the new keytab to the service host.

### Clock skew errors

**Symptom:** `KRB5KRB_AP_ERR_SKEW` ("Clock skew too great"). Kerberos requires clocks to be
within 5 minutes of each other (default tolerance).

**Resolution:**

- Windows: domain members sync via `W32tm` automatically. Run `w32tm /resync` if needed.
- Linux: `timedatectl status` to verify NTP sync; `chronyc tracking` if using chrony.
- VMs: ensure VM time sync is enabled in VMware Tools / Hyper-V Integration Services.

### Certificate mapping: userCertificate vs altSecurityIdentities

`userCertificate` (written by this toolset) stores raw DER certificate bytes. The Windows KDC
resolves the certificate to an AD user via the subject/SAN — this is **implicit mapping**.

`altSecurityIdentities` stores explicit string mappings, for example:
`X509:<I>CN=Corp Issuing CA<S>CN=Alice`. This is **explicit mapping**.

For most deployments using UPN-based CBA, `userCertificate` is sufficient. However, after
**KB5014754** enforcement (applied by default on Windows Server 2025 DCs and later patch
rollouts), strong certificate mapping may be required. The SID extension form
(`X509:<SI>S-1-5-...`) satisfies strong mapping but requires the CA to embed the user's
on-prem SID in the certificate, or the use of issuer+serial form (`X509:<I>...<SR>...`).

If PKINIT authentication fails with event 39 (KDC strong mapping required) after a recent
Windows Update, consult KB5014754 and consider populating `altSecurityIdentities`.

**Reference:** [KB5014754 — Certificate-based authentication changes on Windows domain controllers](https://support.microsoft.com/en-us/topic/kb5014754-certificate-based-authentication-changes-on-windows-domain-controllers-ad2c23b0-15d8-4340-a468-4d4f3b188f16)

---

## Security Notes

- **Dedicated issuing CA:** Never add a root CA to NTAuth. A compromised root CA private key
  allows issuing domain-logon certificates trusted by every DC in the forest. Use an
  intermediate issuing CA with a narrow EKU policy (Smart Card Logon + Client Authentication).

- **Keytab ACLs:** `Set-KerberosSpn.ps1` disables ACL inheritance and grants only
  Administrators, SYSTEM, and the service account access. Never relax these permissions.
  Possession of the keytab is equivalent to knowing the service account's Kerberos key.

- **Keytab rotation:** When a keytab is regenerated, the old keytab becomes invalid. Plan for
  re-deployment as part of your service account credential rotation policy.

- **Certificate expiry monitoring:** `Sync-UserCertificates.ps1` logs each certificate's expiry
  date. Monitor and renew before expiry — the KDC rejects expired certificates even if they are
  still present in `userCertificate`. Enumerate all managed users' certificate expiry:

  ```powershell
  Get-ADUser -Filter { extensionAttribute1 -like '*-*-*-*-*' } -Properties userCertificate |
  ForEach-Object {
      $upn = $_.UserPrincipalName
      $_.userCertificate | ForEach-Object {
          $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($_)
          [PSCustomObject]@{ UPN = $upn; Expires = $cert.NotAfter; Thumbprint = $cert.Thumbprint }
      }
  } | Sort-Object Expires | Format-Table
  ```

- **Minimum Graph permissions:** The App Registration requires only the four permissions in
  `deployment-outline.md` Phase 0. Do not grant `Directory.ReadWrite.All` or
  `User.ReadWrite.All`.

- **NTAuth forest scope:** NTAuth applies to **all domains in the forest**. Adding a CA to
  NTAuth in one domain enables PKINIT for that CA's certificates everywhere in the forest.
  In multi-domain forests, ensure this is intentional.

- **CA private key protection:** The issuing CA private key must be protected by an HSM or
  hardware-backed key storage. A compromised CA private key allows issuing certificates
  accepted by both Entra CBA and the on-prem KDC.

---

## Reference

| Topic | URL |
|---|---|
| Entra ID CBA overview and configuration | https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-certificate-based-authentication |
| CBA certificate user IDs and binding types | https://learn.microsoft.com/en-us/entra/identity/authentication/concept-certificate-based-authentication-certificateuserids |
| Kerberos authentication overview (Windows Server) | https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-authentication-overview |
| PKINIT on Windows KDC | https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-and-pkinit |
| KB5014754 — Certificate-based authentication changes on Windows DCs | https://support.microsoft.com/en-us/topic/kb5014754-certificate-based-authentication-changes-on-windows-domain-controllers-ad2c23b0-15d8-4340-a468-4d4f3b188f16 |
| certutil NTAuth store management | https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certutil |
| ktpass.exe reference | https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ktpass |
| Deployment outline (this project) | deployment-outline.md |
