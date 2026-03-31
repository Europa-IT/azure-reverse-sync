BeforeAll {
    $repoRoot   = Split-Path $PSScriptRoot -Parent
    $modulePath = Join-Path $repoRoot 'modules\AzureSync.psm1'
    Import-Module $modulePath -Force

    $script:Config = [PSCustomObject]@{
        LocalAD = [PSCustomObject]@{ Server = 'dc01.test' }
        PKINIT  = [PSCustomObject]@{
            Enabled           = $true
            CACertificatePath = ''     # empty = skip NTAuth step in tests
            CertificateSource = 'EntraCBA'
        }
        Sync    = [PSCustomObject]@{ DryRun = $false; LogPath = '' }
    }
    $script:DryRun = $false
}

Describe 'PKINIT certificate byte conversion' -Tag 'Unit' {

    It 'round-trips a certificate through Base64 to byte array' {
        # Create a minimal self-signed cert for byte-conversion testing
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateSelfSigned(
            [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=TestUser'),
            [System.Security.Cryptography.RSA]::Create(2048),
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,
            [DateTimeOffset]::UtcNow,
            [DateTimeOffset]::UtcNow.AddYears(1)
        )
        $b64       = [Convert]::ToBase64String($cert.RawData)
        $certBytes = [Convert]::FromBase64String($b64)
        $certBytes  | Should -Not -BeNullOrEmpty
        $certBytes.Length | Should -Be $cert.RawData.Length
    }
}

Describe 'Sync-UserCertificates disabled' -Tag 'Unit' {

    It 'returns early when PKINIT.Enabled is false' {
        $script:Config.PKINIT.Enabled = $false
        Mock Get-ADUser       { }
        Mock Write-SyncLog    { }

        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Sync-UserCertificates.ps1')

        Should -Invoke Get-ADUser -Times 0
        $script:Config.PKINIT.Enabled = $true   # restore
    }
}
