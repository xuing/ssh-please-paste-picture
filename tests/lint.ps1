<#
Static checks. CI (.github/workflows/ci.yml) and check.ps1 run this same file, so a
local pass means the same thing as a CI pass.

  ./tests/lint.ps1                  all four checks (PowerShell 7, or 5.1 for a quick look)
  ./tests/lint.ps1 -Check Parse     only the parse check; CI runs it under Windows PowerShell 5.1

  Ascii     scripts, manifests, .cmd, .sh, .js, .json, the macOS launcher and workflow files
            hold only printable ASCII
  Forms     no command-line forms that antivirus heuristics flag
  Spawn     src/ starts programs only through New-ChildStartInfo
  Analyzer  PSScriptAnalyzer with ./PSScriptAnalyzerSettings.psd1
  Parse     every .ps1 and .psd1 parses with the PowerShell that runs this file

Exits 1 when any check finds a problem. Under GitHub Actions each problem is also an
annotation on the file.
#>
param(
    [ValidateSet('All', 'Ascii', 'Forms', 'Spawn', 'Analyzer', 'Parse')]
    [string[]]$Check = 'All'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $repo
try {
    $inActions = ($env:GITHUB_ACTIONS -eq 'true')
    $script:Problems = 0

    function Write-Problem {
        param([string]$File, [int]$Line, [string]$Message)
        $script:Problems++
        Write-Host ('{0}:{1}: {2}' -f $File, $Line, $Message)
        if ($inActions) { Write-Host ('::error file={0},line={1}::{2}' -f $File, $Line, $Message) }
    }

    function Get-RepoFile {
        # Tracked files plus new files that are not ignored, so a check run before the
        # first commit still sees them. Without git, every file outside .git.
        param([string[]]$Pattern)
        $names = @()
        if (Get-Command git -ErrorAction SilentlyContinue) {
            # No pathspec: PowerShell on Linux expands wildcards in native arguments itself.
            $names = @(git ls-files --cached --others --exclude-standard 2> $null)
        }
        if ($LASTEXITCODE -ne 0 -or $names.Count -eq 0) {
            $names = @(Get-ChildItem -Recurse -File |
                    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
                    ForEach-Object { $_.FullName.Substring($repo.Length + 1).Replace('\', '/') })
        }
        $names = @($names | Where-Object { $name = $_; @($Pattern | Where-Object { $name -like $_ }).Count -gt 0 })
        return @($names | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)
    }

    $all = ($Check -contains 'All')

    if ($all -or $Check -contains 'Ascii') {
        Write-Host '== Ascii: files hold only printable ASCII'
        # Windows PowerShell 5.1 reads a file without a byte order mark as ANSI, so a
        # single non-ASCII character in a script would be mis-decoded on user machines.
        $files = Get-RepoFile '*.ps1', '*.psd1', '*.cmd', '*.sh', '*.yml', '*.js', '*.json', 'src/ssh-paste-mac'
        foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo $file))
            $line = 1
            for ($i = 0; $i -lt $bytes.Length; $i++) {
                $b = $bytes[$i]
                if ($b -eq 10) { $line++; continue }
                if ($b -gt 126 -or ($b -lt 32 -and $b -ne 9 -and $b -ne 13)) {
                    Write-Problem $file $line ('byte {0} is not printable ASCII' -f $b)
                    break
                }
            }
        }
        Write-Host ('{0} file(s) checked' -f $files.Count)
    }

    if ($all -or $Check -contains 'Forms') {
        Write-Host '== Forms: no command-line forms that antivirus heuristics flag'
        # Encoded commands, hidden windows and abbreviated parameters are what malware
        # uses; security tools score them even in honest scripts. Tests and workflows
        # mention them on purpose and are left out.
        $pattern = '(?i)-EncodedCommand|-WindowStyle|\s-(ep|nop|noni|enc|w)\s'
        $files = @(Get-RepoFile '*.ps1', '*.cmd' | Where-Object { $_ -notlike 'tests/*' })
        foreach ($file in $files) {
            foreach ($hit in @(Select-String -LiteralPath $file -Pattern $pattern)) {
                Write-Problem $file $hit.LineNumber $hit.Line.Trim()
            }
        }
        Write-Host ('{0} file(s) checked' -f $files.Count)
    }

    if ($all -or $Check -contains 'Spawn') {
        Write-Host '== Spawn: src/ starts programs only through New-ChildStartInfo'
        # A program we start inherits our environment. In ssh mode that carries
        # Win32-OpenSSH's private variables, which made the upload ssh read the
        # session's pipes (LESSONS.md). New-ChildStartInfo is the one place that
        # cleans the environment, so no other code may build a ProcessStartInfo
        # or call Start-Process.
        $files = @(Get-RepoFile '*.ps1' | Where-Object { $_ -like 'src/*' })
        $count = 0
        foreach ($file in $files) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$tokens, [ref]$errors)
            # Every form that starts a program: Start-Process, a ProcessStartInfo built
            # by New-Object or ::new, [Process]::Start(...) on anything but the
            # helper's result, a $psi not made by the helper, and the call operator
            # (& or .) on anything but a script block literal.
            $found = $ast.FindAll({
                    param($n)
                    if ($n -is [System.Management.Automation.Language.CommandAst]) {
                        $name = $n.GetCommandName()
                        if ($name -eq 'Start-Process') { return $true }
                        if ($name -eq 'New-Object' -and $n.Extent.Text -match 'ProcessStartInfo') { return $true }
                        if ($n.InvocationOperator -ne 'Unknown' -and $n.CommandElements[0] -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
                        return $false
                    }
                    if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static) {
                        $type = $n.Expression.Extent.Text
                        $member = $n.Member.Extent.Text
                        if ($type -match 'ProcessStartInfo' -and $member -eq 'new') { return $true }
                        if ($type -match '(?i)Diagnostics\.Process\]$|^\[Process\]$' -and $member -eq 'Start') {
                            $arg = ($n.Arguments | ForEach-Object { $_.Extent.Text }) -join ','
                            return -not ($arg -eq '$psi' -or $arg -match 'New-ChildStartInfo')
                        }
                        return $false
                    }
                    if ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$psi') {
                        return ($n.Right.Extent.Text -notmatch '^New-ChildStartInfo\b' -and $n.Right.Extent.Text -notmatch '^New-Object System\.Diagnostics\.ProcessStartInfo$')
                    }
                    return $false
                }, $true)
            foreach ($hit in $found) {
                $count++
                $owner = $hit.Parent
                while ($null -ne $owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
                $insideHelper = ($null -ne $owner -and $owner.Name -eq 'New-ChildStartInfo')
                $isNewObject = ($hit -is [System.Management.Automation.Language.CommandAst] -and $hit.GetCommandName() -eq 'New-Object') -or
                    ($hit -is [System.Management.Automation.Language.AssignmentStatementAst])
                if (-not ($insideHelper -and $isNewObject)) {
                    Write-Problem $file $hit.Extent.StartLineNumber ('start programs through New-ChildStartInfo: ' + $hit.Extent.Text.Split("`n")[0])
                }
            }
        }
        Write-Host ('{0} process start(s) checked' -f $count)
    }

    if ($all -or $Check -contains 'Analyzer') {
        Write-Host '== Analyzer: PSScriptAnalyzer'
        & (Join-Path $PSScriptRoot 'tools.ps1') -Name PSScriptAnalyzer
        # The Pester file is checked by running it, not by the analyzer: its
        # BeforeDiscovery variables look unused to a static rule.
        $files = @(Get-RepoFile '*.ps1', '*.psd1' | Where-Object { $_ -notlike '*.Tests.ps1' })
        $count = 0
        foreach ($file in $files) {
            $found = @(Invoke-ScriptAnalyzer -Path $file -Settings (Join-Path $repo 'PSScriptAnalyzerSettings.psd1'))
            foreach ($r in $found) { Write-Problem $file $r.Line ('{0}: {1}' -f $r.RuleName, $r.Message) }
            $count += $found.Count
        }
        Write-Host ('{0} file(s) analyzed, {1} finding(s)' -f $files.Count, $count)
    }

    if ($all -or $Check -contains 'Parse') {
        Write-Host ('== Parse: every PowerShell file parses ({0} {1})' -f $(if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }), $PSVersionTable.PSVersion)
        $files = Get-RepoFile '*.ps1', '*.psd1'
        foreach ($file in $files) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$null, [ref]$errors)
            foreach ($e in $errors) { Write-Problem $file $e.Extent.StartLineNumber $e.Message }
        }
        Write-Host ('{0} file(s) checked' -f $files.Count)
    }

    if ($script:Problems -gt 0) {
        Write-Host ('lint: {0} problem(s)' -f $script:Problems)
        exit 1
    }
    Write-Host 'lint: ok'
} finally {
    Pop-Location
}
