<#
.SYNOPSIS
    Runs all Pester v5 tests for azure-reverse-sync.
.EXAMPLE
    .\tests\Invoke-Tests.ps1
    .\tests\Invoke-Tests.ps1 -Tag Unit
    .\tests\Invoke-Tests.ps1 -Verbose
#>
param(
    [string[]]$Tag,
    [string]$TestPath = $PSScriptRoot
)

$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    throw "Pester v5+ required. Run: Install-Module Pester -MinimumVersion 5.0.0 -Force"
}
Import-Module Pester -MinimumVersion 5.0.0

$config = New-PesterConfiguration
$config.Run.Path        = $TestPath
$config.Output.Verbosity = 'Detailed'
if ($Tag) { $config.Filter.Tag = $Tag }

Invoke-Pester -Configuration $config
