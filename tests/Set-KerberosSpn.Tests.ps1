BeforeAll {
    $repoRoot   = Split-Path $PSScriptRoot -Parent
    $modulePath = Join-Path $repoRoot 'modules\AzureSync.psm1'
    Import-Module $modulePath -Force

    $script:Config = [PSCustomObject]@{
        LocalAD  = [PSCustomObject]@{ Server = 'dc01.test' }
        Kerberos = [PSCustomObject]@{
            Realm            = 'CORP.EXAMPLE.COM'
            KeytabOutputPath = 'C:\keytabs'
            ServiceAccounts  = @(
                [PSCustomObject]@{
                    SamAccountName = 'svc-fileserver'
                    FQDN           = 'fileserver01.corp.example.com'
                    ServiceClass   = 'cifs'
                }
            )
        }
        Sync = [PSCustomObject]@{ DryRun = $false; LogPath = '' }
    }
    $script:DryRun = $false
}

Describe 'SPN string formatting' -Tag 'Unit' {

    It 'builds SPN in ServiceClass/FQDN format' {
        $sa  = $script:Config.Kerberos.ServiceAccounts[0]
        $spn = "$($sa.ServiceClass)/$($sa.FQDN)"
        $spn | Should -Be 'cifs/fileserver01.corp.example.com'
    }

    It 'builds Kerberos principal in SPN@REALM format' {
        $sa        = $script:Config.Kerberos.ServiceAccounts[0]
        $realm     = $script:Config.Kerberos.Realm
        $spn       = "$($sa.ServiceClass)/$($sa.FQDN)"
        $principal = "$spn@$realm"
        $principal | Should -Be 'cifs/fileserver01.corp.example.com@CORP.EXAMPLE.COM'
    }

    It 'builds mapuser UPN in SAM@REALM format' {
        $sa      = $script:Config.Kerberos.ServiceAccounts[0]
        $realm   = $script:Config.Kerberos.Realm
        $mapuser = "$($sa.SamAccountName)@$realm"
        $mapuser | Should -Be 'svc-fileserver@CORP.EXAMPLE.COM'
    }
}

Describe 'Set-KerberosSpn DryRun' -Tag 'Unit' {

    BeforeAll { $script:DryRun = $true }
    AfterAll  { $script:DryRun = $false }

    It 'does not call Set-ADUser in DryRun mode' {
        Mock Get-Command { return [PSCustomObject]@{ Source = 'C:\Windows\ktpass.exe' } }
        Mock Test-Path   { return $true }
        Mock Get-ADUser  {
            return [PSCustomObject]@{
                DistinguishedName    = 'CN=svc-fileserver,OU=SvcAccts,DC=test,DC=local'
                ServicePrincipalNames = @()
            }
        }
        Mock Set-ADUser       { }
        Mock Set-ADAccountPassword { }
        Mock Write-SyncLog    { }
        Mock New-Item         { }

        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Set-KerberosSpn.ps1')

        Should -Invoke Set-ADUser -Times 0
    }
}
