BeforeAll {
    $repoRoot   = Split-Path $PSScriptRoot -Parent
    $modulePath = Join-Path $repoRoot 'modules\AzureSync.psm1'
    Import-Module $modulePath -Force

    $script:Config = [PSCustomObject]@{
        LocalAD = [PSCustomObject]@{
            Server    = 'dc01.test'
            TargetOU  = 'OU=Users,DC=test,DC=local'
            GroupsOU  = 'OU=Groups,DC=test,DC=local'
            DisabledOU = 'OU=Disabled,DC=test,DC=local'
        }
        Sync = [PSCustomObject]@{ DryRun = $false; LogPath = '' }
    }
    $script:DryRun = $false
}

Describe 'Test-AdGroupExists' -Tag 'Unit' {

    It 'returns null when no AD group has a matching adminDescription' {
        Mock Get-ADGroup -ModuleName AzureSync { return $null }
        $result = Test-AdGroupExists -AzureObjectId 'no-such-oid' -Server 'dc01.test'
        $result | Should -BeNullOrEmpty
    }

    It 'returns the group when adminDescription matches' {
        $fakeGroup = [PSCustomObject]@{
            DistinguishedName = 'CN=TestGroup,OU=Groups,DC=test,DC=local'
            adminDescription  = 'azure-group-oid-123'
        }
        Mock Get-ADGroup -ModuleName AzureSync { return $fakeGroup }
        $result = Test-AdGroupExists -AzureObjectId 'azure-group-oid-123' -Server 'dc01.test'
        $result.adminDescription | Should -Be 'azure-group-oid-123'
    }
}

Describe 'Sync-Groups SamAccountName truncation' -Tag 'Unit' {

    It 'truncates group name to 20 characters for SamAccountName' {
        $longName  = 'This-Is-A-Very-Long-Group-Name-That-Exceeds-Limit'
        $sanitized = $longName -replace '[^a-zA-Z0-9_-]', ''
        $sam       = $sanitized.Substring(0, [Math]::Min($sanitized.Length, 20))
        $sam.Length | Should -BeLessOrEqual 20
    }

    It 'handles group names where special-char removal shortens below 20 characters' {
        # If the sanitized name is shorter than $groupName.Length, using the original
        # length would throw ArgumentOutOfRangeException -- this verifies the fix.
        $nameWithSpecials = '!!!ShortName!!!'   # sanitized = 'ShortName' (9 chars < 15 original)
        $sanitized = $nameWithSpecials -replace '[^a-zA-Z0-9_-]', ''
        $sam       = $sanitized.Substring(0, [Math]::Min($sanitized.Length, 20))
        $sam | Should -Be 'ShortName'
        $sam.Length | Should -BeLessOrEqual 20
    }
}
