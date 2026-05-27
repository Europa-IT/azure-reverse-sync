BeforeAll {
    $repoRoot  = Split-Path $PSScriptRoot -Parent
    $modulePath = Join-Path $repoRoot 'modules\AzureSync.psm1'
    Import-Module $modulePath -Force

    # Minimal config for tests
    $script:Config = [PSCustomObject]@{
        LocalAD      = [PSCustomObject]@{ Server = 'dc01.test'; TargetOU = 'OU=Test,DC=test,DC=local'; GroupsOU = ''; DisabledOU = '' }
        AttributeMap = [PSCustomObject]@{
            DisplayName       = 'DisplayName'
            GivenName         = 'GivenName'
            Surname           = 'Surname'
            UserPrincipalName = 'UserPrincipalName'
            Mail              = 'EmailAddress'
            Department        = 'Department'
            JobTitle          = 'Title'
            MobilePhone       = 'MobilePhone'
        }
        Sync         = [PSCustomObject]@{ DryRun = $false; FilterGroupId = ''; LicensedUsersOnly = $false }
        AzureAD      = [PSCustomObject]@{ TenantId = 'test-tenant'; ClientId = 'test-client'; CertificateThumbprint = '' }
    }
    $script:DryRun = $false
}

Describe 'ConvertTo-AdAttributes' -Tag 'Unit' {

    It 'maps all defined Graph properties to AD attribute names' {
        $graphUser = [PSCustomObject]@{
            DisplayName       = 'Jane Doe'
            GivenName         = 'Jane'
            Surname           = 'Doe'
            UserPrincipalName = 'jane.doe@corp.example.com'
            Mail              = 'jane.doe@corp.example.com'
            Department        = 'Engineering'
            JobTitle          = 'Software Engineer'
            MobilePhone       = '+1-555-0100'
        }

        $result = ConvertTo-AdAttributes -GraphUser $graphUser -Config $script:Config

        $result['DisplayName']  | Should -Be 'Jane Doe'
        $result['GivenName']    | Should -Be 'Jane'
        $result['Surname']      | Should -Be 'Doe'
        $result['EmailAddress'] | Should -Be 'jane.doe@corp.example.com'
        $result['Department']   | Should -Be 'Engineering'
        $result['Title']        | Should -Be 'Software Engineer'
        $result['MobilePhone']  | Should -Be '+1-555-0100'
    }

    It 'omits null or empty Graph properties' {
        $graphUser = [PSCustomObject]@{
            DisplayName       = 'Bob Smith'
            GivenName         = 'Bob'
            Surname           = 'Smith'
            UserPrincipalName = 'bob@test.local'
            Mail              = $null
            Department        = ''
            JobTitle          = $null
            MobilePhone       = ''
        }

        $result = ConvertTo-AdAttributes -GraphUser $graphUser -Config $script:Config

        $result.ContainsKey('EmailAddress') | Should -BeFalse
        $result.ContainsKey('Department')   | Should -BeFalse
        $result.ContainsKey('Title')        | Should -BeFalse
        $result.ContainsKey('MobilePhone')  | Should -BeFalse
    }
}

Describe 'New-RandomPassword' -Tag 'Unit' {

    It 'returns a string of at least 24 characters' {
        $pw = New-RandomPassword
        $pw.Length | Should -BeGreaterOrEqual 24
    }

    It 'contains at least one uppercase letter' {
        $pw = New-RandomPassword
        $pw -cmatch '[A-Z]' | Should -BeTrue
    }

    It 'contains at least one digit' {
        $pw = New-RandomPassword
        $pw -match '\d' | Should -BeTrue
    }

    It 'contains at least one symbol' {
        $pw = New-RandomPassword
        $pw -match '[!@#$%^&*()\-_=+\[\]{}|;:,.<>?]' | Should -BeTrue
    }

    It 'returns a different password on each call' {
        $pw1 = New-RandomPassword
        $pw2 = New-RandomPassword
        $pw1 | Should -Not -Be $pw2
    }
}

Describe 'Sync-Users (DryRun)' -Tag 'Unit' {

    BeforeAll {
        $script:DryRun = $true
        Mock Get-MgUser {
            return @(
                [PSCustomObject]@{
                    Id = 'azure-oid-001'; DisplayName = 'Alice Test'; GivenName = 'Alice';
                    Surname = 'Test'; UserPrincipalName = 'alice@corp.test'; Mail = 'alice@corp.test';
                    Department = 'IT'; JobTitle = 'Admin'; MobilePhone = ''; OfficeLocation = '';
                    CompanyName = ''; AccountEnabled = $true
                }
            )
        }
        Mock Test-AdUserExists { return $null }
        Mock Get-AdUserByUpn { return $null }
        Mock Get-AdUserBySamAccountName { return $null }
        Mock New-ADUser { }
        Mock Set-ADUser { }
        Mock Write-SyncLog { }
        Mock New-SecureRandomPassword { return ('Password123!' | ConvertTo-SecureString -AsPlainText -Force) }
    }

    AfterAll { $script:DryRun = $false }

    It 'does not call New-ADUser in DryRun mode' {
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Sync-Users.ps1')
        Should -Invoke New-ADUser -Times 0
    }
}

Describe 'Sync-Users collision (AdoptExistingUsers = false)' -Tag 'Unit' {

    BeforeAll {
        $script:DryRun = $false
        Mock Get-MgUser {
            return @(
                [PSCustomObject]@{
                    Id = 'azure-oid-777'; DisplayName = 'Dave Conflict'; GivenName = 'Dave';
                    Surname = 'Conflict'; UserPrincipalName = 'dave@corp.test'; Mail = 'dave@corp.test';
                    Department = ''; JobTitle = ''; MobilePhone = ''; OfficeLocation = '';
                    CompanyName = ''; AccountEnabled = $true
                }
            )
        }
        Mock Test-AdUserExists { return $null }       # not yet managed by this tool
        Mock Get-AdUserByUpn {                          # a pre-existing account owns the UPN
            return [PSCustomObject]@{
                DistinguishedName               = 'CN=Dave,OU=Staff,DC=corp,DC=test'
                UserPrincipalName               = 'dave@corp.test'
                'msDS-cloudExtensionAttribute1' = $null
            }
        }
        Mock Get-AdUserBySamAccountName { return $null }
        Mock New-ADUser { }
        Mock Set-ADUser { }
        Mock Write-SyncLog { }
        Mock New-SecureRandomPassword { return ('Password123!' | ConvertTo-SecureString -AsPlainText -Force) }
    }

    AfterAll { $script:DryRun = $false }

    It 'does not create or modify a user when a collision exists and adoption is off' {
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Sync-Users.ps1')
        Should -Invoke New-ADUser -Times 0
        Should -Invoke Set-ADUser -Times 0
    }
}

Describe 'Sync-Users UPN collision (AdoptExistingUsers = true)' -Tag 'Unit' {

    BeforeAll {
        $script:DryRun = $false
        $script:Config.Sync = [PSCustomObject]@{ DryRun = $false; FilterGroupId = ''; LicensedUsersOnly = $false; AdoptExistingUsers = $true }
        Mock Get-MgUser {
            return @(
                [PSCustomObject]@{
                    Id = 'azure-oid-888'; DisplayName = 'Erin Adopt'; GivenName = 'Erin';
                    Surname = 'Adopt'; UserPrincipalName = 'erin@corp.test'; Mail = 'erin@corp.test';
                    Department = ''; JobTitle = ''; MobilePhone = ''; OfficeLocation = '';
                    CompanyName = ''; AccountEnabled = $true
                }
            )
        }
        Mock Test-AdUserExists { return $null }       # no OID-stamped account yet
        Mock Get-AdUserByUpn {                          # pre-existing account owns the UPN (forest-wide hit)
            return [PSCustomObject]@{
                DistinguishedName               = 'CN=Erin,OU=Staff,DC=corp,DC=test'
                UserPrincipalName               = 'erin@corp.test'
                'msDS-cloudExtensionAttribute1' = $null
            }
        }
        Mock Get-ADUser {                               # target-domain re-fetch for adoption
            return [PSCustomObject]@{
                DistinguishedName               = 'CN=Erin,OU=Staff,DC=corp,DC=test'
                UserPrincipalName               = 'erin@corp.test'
                Enabled                         = $true
                DisplayName                     = 'Erin Adopt'
                GivenName                       = 'Erin'
                Surname                         = 'Adopt'
                EmailAddress                    = 'erin@corp.test'
                Department                      = $null
                Title                           = $null
                MobilePhone                     = $null
                Office                          = $null
                Company                         = $null
                'msDS-cloudExtensionAttribute1' = $null
            }
        }
        Mock Set-ADUser { }
        Mock New-ADUser { }
        Mock Write-SyncLog { }
        Mock New-SecureRandomPassword { return ('Password123!' | ConvertTo-SecureString -AsPlainText -Force) }
    }

    AfterAll {
        $script:DryRun = $false
        $script:Config.Sync = [PSCustomObject]@{ DryRun = $false; FilterGroupId = ''; LicensedUsersOnly = $false }
    }

    It 'stamps the Azure OID via Set-ADUser and does not create a new user' {
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Sync-Users.ps1')
        Should -Invoke Set-ADUser -Times 1
        Should -Invoke New-ADUser -Times 0
    }
}

Describe 'Sync-Users SamAccountName collision (AdoptExistingUsers = true)' -Tag 'Unit' {

    BeforeAll {
        $script:DryRun = $false
        $script:Config.Sync = [PSCustomObject]@{ DryRun = $false; FilterGroupId = ''; LicensedUsersOnly = $false; AdoptExistingUsers = $true }
        Mock Get-MgUser {
            return @(
                [PSCustomObject]@{
                    Id = 'azure-oid-999'; DisplayName = 'Frank SamMatch'; GivenName = 'Frank';
                    Surname = 'SamMatch'; UserPrincipalName = 'fsam@windhamcountyvt.gov'; Mail = 'fsam@windhamcountyvt.gov';
                    Department = ''; JobTitle = ''; MobilePhone = ''; OfficeLocation = '';
                    CompanyName = ''; AccountEnabled = $true
                }
            )
        }
        Mock Test-AdUserExists { return $null }       # no OID-stamped account yet
        Mock Get-AdUserByUpn { return $null }           # no account has the Azure (.gov) UPN
        Mock Get-AdUserBySamAccountName {               # but 'fsam' login exists under an older UPN suffix
            return [PSCustomObject]@{
                DistinguishedName               = 'CN=Frank,OU=Staff,DC=corp,DC=test'
                UserPrincipalName               = 'fsam@windhamcountyvt.com'
                'msDS-cloudExtensionAttribute1' = $null
            }
        }
        Mock Get-ADUser {                               # writable re-fetch by DN
            return [PSCustomObject]@{
                DistinguishedName               = 'CN=Frank,OU=Staff,DC=corp,DC=test'
                UserPrincipalName               = 'fsam@windhamcountyvt.com'
                Enabled                         = $true
                DisplayName                     = 'Frank SamMatch'
                GivenName                       = 'Frank'
                Surname                         = 'SamMatch'
                EmailAddress                    = 'fsam@windhamcountyvt.gov'
                Department                      = $null
                Title                           = $null
                MobilePhone                     = $null
                Office                          = $null
                Company                         = $null
                'msDS-cloudExtensionAttribute1' = $null
            }
        }
        Mock Set-ADUser { }
        Mock New-ADUser { }
        Mock Write-SyncLog { }
        Mock New-SecureRandomPassword { return ('Password123!' | ConvertTo-SecureString -AsPlainText -Force) }
    }

    AfterAll {
        $script:DryRun = $false
        $script:Config.Sync = [PSCustomObject]@{ DryRun = $false; FilterGroupId = ''; LicensedUsersOnly = $false }
    }

    It 'adopts a SAM-matched account instead of failing on New-ADUser' {
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Sync-Users.ps1')
        Should -Invoke Set-ADUser -Times 1
        Should -Invoke New-ADUser -Times 0
    }
}
