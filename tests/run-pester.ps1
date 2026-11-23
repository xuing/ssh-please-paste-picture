<#
Runs tests/ssh-paste.Tests.ps1 the same way everywhere: check.ps1, CI and
tests/e2e-linux.sh all call this file. It always runs the whole Pester file, because
the repository guard tests live in it.

  ./tests/run-pester.ps1                    unit tests (everything except E2E)
  ./tests/run-pester.ps1 -Tag E2E           the end-to-end tests (needs SSH_PASTE_E2E_HOST)

Writes NUnit results to TestResults/<Name>.xml (git ignores the folder; CI uploads it),
prints GitHub-formatted output under Actions, and appends a line to the job summary.
Exits 1 when a test fails. With -Tag, skipped tests also fail the run: an E2E run that
skipped its tests (no host, wrong tag) must not look like a pass.
#>
param(
    [string[]]$Tag,
    [string]$Name = 'pester'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'tools.ps1') -Name Pester
Write-Host ('PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $(if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }))

$resultDir = Join-Path $repo 'TestResults'
[void][System.IO.Directory]::CreateDirectory($resultDir)
$resultFile = Join-Path $resultDir ($Name + '.xml')

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $repo 'tests/ssh-paste.Tests.ps1'
$config.Run.PassThru = $true
if ($Tag) { $config.Filter.Tag = $Tag } else { $config.Filter.ExcludeTag = @('E2E') }
$config.Output.Verbosity = 'Detailed'
if ($env:GITHUB_ACTIONS -eq 'true') { $config.Output.CIFormat = 'GithubActions' }
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $resultFile

$result = Invoke-Pester -Configuration $config
$line = '{0}: passed {1}, failed {2}, skipped {3}' -f $Name, $result.PassedCount, $result.FailedCount, $result.SkippedCount
Write-Host $line
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ('- ' + $line) }

$bad = ($result.FailedCount -gt 0) -or ($result.PassedCount -eq 0) -or ($Tag -and $result.SkippedCount -gt 0)
if ($result.Result -ne 'Passed') { $bad = $true }
if ($bad) { exit 1 }
