<#
The one command that says whether a change is ready. Run it before every commit; CI
runs the same stages (tests/lint.ps1, tests/run-pester.ps1, tests/mac/unit.test.js,
tests/e2e-linux.sh, tests/footprint.ps1), so a green check.ps1 means the same as a
green CI. The macOS client's tests that need a Mac (tests/mac/*.sh) run in CI.

  ./check.ps1                 lint, then the unit tests
  ./check.ps1 -E2E            also tests/e2e-linux.sh: a throwaway sshd on Linux
                              (needs bash, ssh, sshd, python3 and pwsh on PATH)
  ./check.ps1 -Footprint      also tests/footprint.ps1 (Windows only). It edits the real
                              user profile and restores it, so outside CI it needs -Force.

Every stage runs even when an earlier one fails. The last lines say which stages ran,
which did not and why, and the exit code is 1 when any stage failed. A stage you asked
for with -E2E or -Footprint that cannot run counts as failed: it must not look like a pass.

Run it from Windows PowerShell 5.1 and from PowerShell 7 when you change src/ or
install.ps1; the unit tests run in whichever shell started this script.
#>
param(
    [switch]$E2E,
    [switch]$Footprint,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$onWindows = ($env:OS -eq 'Windows_NT')
$thisShell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Stage, [string]$Status, [string]$Note)
    [void]$results.Add([pscustomobject]@{ Stage = $Stage; Status = $Status; Note = $Note })
}

function Invoke-Stage {
    # Runs a command, shows its output and records ok or failed from its exit code.
    param([string]$Stage, [string]$FilePath, [string[]]$Arguments)
    Write-Host ''
    Write-Host ('=== {0}' -f $Stage)
    $global:LASTEXITCODE = 0
    try {
        & $FilePath @Arguments
        $code = $LASTEXITCODE
    } catch {
        Write-Host $_.Exception.Message
        $code = 1
    }
    if ($code -eq 0) { Add-Result $Stage 'ok' '' } else { Add-Result $Stage 'FAILED' ('exit code ' + $code) }
}

function Get-HostArguments {
    param([string]$Script, [string[]]$More)
    $a = @('-NoLogo', '-NoProfile', '-NonInteractive')
    if ($onWindows) { $a += @('-ExecutionPolicy', 'Bypass') }
    return @($a + @('-File', $Script) + @($More))
}

Set-Location -LiteralPath $repo

Invoke-Stage 'lint' $thisShell (Get-HostArguments (Join-Path $repo 'tests/lint.ps1'))

$ps51 = $null
if ($onWindows) { $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
if ($onWindows -and $PSVersionTable.PSEdition -eq 'Core' -and (Test-Path -LiteralPath $ps51)) {
    Invoke-Stage 'parse (Windows PowerShell 5.1)' $ps51 (Get-HostArguments (Join-Path $repo 'tests/lint.ps1') @('-Check', 'Parse'))
} elseif ($onWindows -and $PSVersionTable.PSEdition -ne 'Core') {
    Add-Result 'parse (Windows PowerShell 5.1)' 'ok' 'the lint stage already ran under 5.1'
} else {
    Add-Result 'parse (Windows PowerShell 5.1)' 'not run' 'needs Windows; CI runs it'
}

Invoke-Stage 'unit tests' $thisShell (Get-HostArguments (Join-Path $repo 'tests/run-pester.ps1'))

# The logic of the macOS client (src/ssh-paste.js) and the test tables both clients share.
$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $node) {
    Add-Result 'unit tests (macOS client, node)' 'not run' 'node was not found; CI runs it'
} else {
    Invoke-Stage 'unit tests (macOS client, node)' $node.Source @('--test', (Join-Path $repo 'tests/mac/unit.test.js'))
}

if ($E2E) {
    $bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $bash) {
        Add-Result 'e2e (sshd on Linux)' 'FAILED' 'asked for with -E2E, but bash was not found'
    } else {
        Invoke-Stage 'e2e (sshd on Linux)' $bash.Source @((Join-Path $repo 'tests/e2e-linux.sh'))
    }
} else {
    Add-Result 'e2e (sshd on Linux)' 'not run' 'pass -E2E'
}

if ($Footprint) {
    if (-not $onWindows) {
        Add-Result 'footprint' 'FAILED' 'asked for with -Footprint, but it runs on Windows only'
    } else {
        $more = @()
        if ($Force) { $more += '-Force' }
        Invoke-Stage 'footprint' $thisShell (Get-HostArguments (Join-Path $repo 'tests/footprint.ps1') $more)
    }
} else {
    Add-Result 'footprint' 'not run' 'pass -Footprint (Windows only)'
}

Write-Host ''
Write-Host '=== summary'
foreach ($r in $results) {
    $line = '{0,-9} {1}' -f $r.Status, $r.Stage
    if ($r.Note) { $line += '  (' + $r.Note + ')' }
    Write-Host $line
}
$failed = @($results | Where-Object { $_.Status -eq 'FAILED' })
if ($failed.Count -gt 0) {
    Write-Host ('check: {0} stage(s) failed' -f $failed.Count)
    exit 1
}
Write-Host 'check: ok (stages marked "not run" were not checked)'
