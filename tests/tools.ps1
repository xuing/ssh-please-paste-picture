<#
Installs (when missing) and imports the PowerShell modules the checks need, at the
versions this repository is tested with. Every script that needs Pester or
PSScriptAnalyzer calls this file, so the versions live here and nowhere else.

  ./tests/tools.ps1 -Name Pester, PSScriptAnalyzer

Set TOOLS_LATEST=true (the weekly scheduled CI run does) to take the newest release
instead, so that a new Pester or PSScriptAnalyzer that breaks us shows up on a
schedule rather than on someone's pull request. Pester stays on major version 5,
the one the tests are written for.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('Pester', 'PSScriptAnalyzer')]
    [string[]]$Name
)

$ErrorActionPreference = 'Stop'

$pins = @{
    Pester           = '5.9.1'
    PSScriptAnalyzer = '1.25.0'
}
$latest = ($env:TOOLS_LATEST -eq 'true')

foreach ($module in $Name) {
    if ($latest) {
        $install = @{ Name = $module }
        if ($module -eq 'Pester') { $install.MaximumVersion = '5.99.99' }
        Install-Module @install -Scope CurrentUser -Force -SkipPublisherCheck
        $candidates = @(Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending)
        if ($module -eq 'Pester') { $candidates = @($candidates | Where-Object { $_.Version.Major -eq 5 }) }
        if ($candidates.Count -eq 0) { throw "$module is not available" }
        Import-Module $candidates[0].Path -Force
    } else {
        $version = $pins[$module]
        if (-not (Get-Module -ListAvailable -Name $module | Where-Object { $_.Version -eq [version]$version })) {
            Install-Module -Name $module -RequiredVersion $version -Scope CurrentUser -Force -SkipPublisherCheck
        }
        Import-Module -Name $module -RequiredVersion $version -Force
    }
    Write-Host ('{0} {1}' -f $module, (Get-Module $module).Version)
}
