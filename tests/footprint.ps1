<#
Footprint test: install, enable, disable and uninstall must leave nothing behind.
Windows only. CI runs it on windows-latest under both `powershell` (5.1) and `pwsh`.

Each round starts from the same snapshot and must end with an identical one:
  round 1  install twice, check the command, --enable / --disable, ssh-paste --uninstall
  round 2  install, --enable, install.ps1 -Uninstall
  round 3  install, --enable, install.ps1 through `irm | iex` with SSH_PASTE_UNINSTALL=1
           (also checks that iex leaves nothing in the calling session)
  round 4  only on push builds of xuing/ssh-please-paste-picture: `irm | iex` install from GitHub at
           this commit (SSH_PASTE_REF), then the same uninstall through iex
  round 5  an ssh config that already exists survives --enable and install.ps1 -Uninstall
           byte for byte (it is deleted only when the block says ssh-paste created it)

The snapshot holds the raw HKCU\Environment\Path value (kind and unexpanded text),
the other HKCU\Environment value names, HKCU Uninstall subkeys, the entries under
%LOCALAPPDATA%\Programs (and anything named ssh-paste* there, recursively),
Windows Terminal fragments, %USERPROFILE%\.ssh and the ssh config text, and any
ssh-paste* in %LOCALAPPDATA%\Microsoft\WindowsApps.

It edits the real user profile and restores the starting state in `finally`, even
when a step fails. Outside CI it refuses to run unless -Force is given.

    powershell -ExecutionPolicy Bypass -File tests\footprint.ps1 [-Force]
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($env:OS -ne 'Windows_NT') { Write-Host 'footprint.ps1 runs on Windows only.'; exit 2 }
if (-not $Force -and $env:CI -ne 'true') {
    Write-Host 'footprint.ps1 installs and uninstalls ssh-paste in your real profile (then restores it).'
    Write-Host 'It runs in CI; pass -Force to run it here anyway.'
    exit 2
}

$Repo = Split-Path -Parent $PSScriptRoot
$Installer = Join-Path $Repo 'install.ps1'
$SourcePs1 = Join-Path $Repo 'src\ssh-paste.ps1'
$SourceCmd = Join-Path $Repo 'src\ssh-paste.cmd'
$HostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\ssh-paste'
$ProgramsDir = Join-Path $env:LOCALAPPDATA 'Programs'
$FragmentsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments'
$WindowsAppsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
$SshDir = Join-Path $env:USERPROFILE '.ssh'
$SshConfig = Join-Path $SshDir 'config'
$TestHost = 'localhost'

$sourceText = [System.IO.File]::ReadAllText($SourcePs1)
if ($sourceText -notmatch "(?m)^\`$script:Version\s*=\s*'([^']+)'") { throw 'no $script:Version in src\ssh-paste.ps1' }
$Version = $Matches[1]
# The ssh config markers, read from the core (install.ps1 keeps copies, checked below).
$Markers = @{}
foreach ($markerName in @('BlockBegin', 'BlockEnd', 'BlockCreatedFile')) {
    if ($sourceText -notmatch ("(?m)^\`$script:" + $markerName + "\s*=\s*'([^']+)'")) { throw ('no $script:' + $markerName + ' in src\ssh-paste.ps1') }
    $Markers[$markerName] = $Matches[1]
}
$BlockBegin = $Markers['BlockBegin']
$BlockCreatedFile = $Markers['BlockCreatedFile']

$script:Failures = New-Object System.Collections.ArrayList

function Write-Pass { param([string]$What) Write-Host ('  ok    ' + $What) -ForegroundColor Green }

function Write-Fail {
    param([string]$What, [string]$Detail)
    Write-Host ('  FAIL  ' + $What) -ForegroundColor Red
    if ($Detail) { foreach ($line in ($Detail -split "`r?`n")) { Write-Host ('        ' + $line) } }
    [void]$script:Failures.Add($What)
}

function Test-Check {
    param([bool]$Condition, [string]$What, [string]$Detail)
    if ($Condition) { Write-Pass $What } else { Write-Fail $What $Detail }
    return $Condition
}

# --- snapshot -------------------------------------------------------------------

function Get-Listing {
    # Relative paths under $Path, directories with a trailing '\'.
    param([string]$Path, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Path)) { return @('(absent)') }
    $root = (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd('\') + '\'
    $items = @(Get-ChildItem -LiteralPath $Path -Force -Recurse:$Recurse)
    if ($items.Count -eq 0) { return @('(empty)') }
    return @($items | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length)
            if ($_.PSIsContainer) { $rel + '\' } else { $rel }
        } | Sort-Object)
}

function Get-Footprint {
    $lines = New-Object System.Collections.Generic.List[string]
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        $names = @($key.GetValueNames() | Sort-Object)
        $lines.Add('HKCU\Environment values: ' + ($names -join ', '))
        if ($names -contains 'Path') {
            $lines.Add('HKCU\Environment\Path kind: ' + $key.GetValueKind('Path'))
            $lines.Add('HKCU\Environment\Path raw: ' + [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
        } else {
            $lines.Add('HKCU\Environment\Path: (absent)')
        }
    } finally { $key.Close() }

    $uninstall = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall')
    if ($null -eq $uninstall) {
        $lines.Add('HKCU Uninstall keys: (absent)')
    } else {
        try { $lines.Add('HKCU Uninstall keys: ' + ((@($uninstall.GetSubKeyNames()) | Sort-Object) -join ', ')) } finally { $uninstall.Close() }
    }

    # Other programs may keep large trees under Programs: list its top level, and
    # everything below any ssh-paste* entry.
    foreach ($e in (Get-Listing $ProgramsDir)) { $lines.Add('Programs: ' + $e) }
    if (Test-Path -LiteralPath $ProgramsDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $ProgramsDir -Force -Filter 'ssh-paste*' -Directory)) {
            foreach ($e in (Get-Listing $d.FullName -Recurse)) { $lines.Add('Programs\' + $d.Name + ': ' + $e) }
        }
    }
    foreach ($e in (Get-Listing $FragmentsDir -Recurse)) { $lines.Add('Fragments: ' + $e) }
    if (Test-Path -LiteralPath $WindowsAppsDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $WindowsAppsDir -Force -Filter 'ssh-paste*')) { $lines.Add('WindowsApps: ' + $f.Name) }
    }
    foreach ($e in (Get-Listing $SshDir)) { $lines.Add('.ssh: ' + $e) }
    if (Test-Path -LiteralPath $SshConfig) {
        $bytes = [System.IO.File]::ReadAllBytes($SshConfig)
        $lines.Add('.ssh\config bytes: ' + $bytes.Length)
        foreach ($l in ([System.Text.Encoding]::UTF8.GetString($bytes) -split "`n")) { $lines.Add('.ssh\config| ' + $l.Replace("`r", '<CR>')) }
    } else {
        $lines.Add('.ssh\config: (absent)')
    }
    return , $lines.ToArray()
}

function Compare-Footprint {
    param([string[]]$Before, [string[]]$After, [string]$What)
    if (($Before -join "`n") -ceq ($After -join "`n")) { Write-Pass $What; return $true }
    $diff = @(Compare-Object -ReferenceObject $Before -DifferenceObject $After -CaseSensitive | ForEach-Object {
            if ($_.SideIndicator -eq '<=') { '- ' + $_.InputObject } else { '+ ' + $_.InputObject }
        })
    Write-Fail $What ("left behind (- before, + after):`n" + ($diff -join "`n"))
    return $false
}

# --- exact restore, used between rounds and in finally ---------------------------

function Save-State {
    $state = @{ PathExists = $false; PathKind = $null; PathRaw = $null; ConfigBytes = $null }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        if ($key.GetValueNames() -contains 'Path') {
            $state.PathExists = $true
            $state.PathKind = $key.GetValueKind('Path')
            $state.PathRaw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally { $key.Close() }
    if (Test-Path -LiteralPath $SshConfig) { $state.ConfigBytes = [System.IO.File]::ReadAllBytes($SshConfig) }
    $state.SshDirExisted = Test-Path -LiteralPath $SshDir
    $state.ProgramsExisted = Test-Path -LiteralPath $ProgramsDir
    return $state
}

function Restore-State {
    param($State)
    $saved = $State   # the steps below are script blocks; they read $saved
    $actions = New-Object System.Collections.ArrayList
    $steps = @(
        {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            try {
                $exists = $key.GetValueNames() -contains 'Path'
                if ($saved.PathExists) {
                    $same = $exists -and $key.GetValueKind('Path') -eq $saved.PathKind -and
                        [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq $saved.PathRaw
                    if (-not $same) { $key.SetValue('Path', $saved.PathRaw, $saved.PathKind); [void]$actions.Add('user PATH') }
                } elseif ($exists) {
                    $key.DeleteValue('Path'); [void]$actions.Add('user PATH (deleted)')
                }
            } finally { $key.Close() }
        },
        {
            if ($null -ne $saved.ConfigBytes) {
                $now = $null
                if (Test-Path -LiteralPath $SshConfig) { $now = [System.IO.File]::ReadAllBytes($SshConfig) }
                if ($null -eq $now -or [Convert]::ToBase64String($now) -cne [Convert]::ToBase64String($saved.ConfigBytes)) {
                    [void][System.IO.Directory]::CreateDirectory($SshDir)
                    [System.IO.File]::WriteAllBytes($SshConfig, $saved.ConfigBytes); [void]$actions.Add('ssh config')
                }
            } elseif (Test-Path -LiteralPath $SshConfig) {
                Remove-Item -LiteralPath $SshConfig -Force; [void]$actions.Add('ssh config (deleted)')
            }
        },
        {
            if (-not $saved.SshDirExisted -and (Test-Path -LiteralPath $SshDir) -and @(Get-ChildItem -LiteralPath $SshDir -Force).Count -eq 0) {
                Remove-Item -LiteralPath $SshDir -Force; [void]$actions.Add('.ssh folder')
            }
        },
        {
            if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force; [void]$actions.Add('install folder') }
        },
        {
            if (-not $saved.ProgramsExisted -and (Test-Path -LiteralPath $ProgramsDir) -and @(Get-ChildItem -LiteralPath $ProgramsDir -Force).Count -eq 0) {
                Remove-Item -LiteralPath $ProgramsDir -Force; [void]$actions.Add('Programs folder')
            }
        }
    )
    foreach ($step in $steps) {
        try { & $step } catch { Write-Host ('  restore error: ' + $_.Exception.Message) -ForegroundColor Red }
    }
    if ($actions.Count -gt 0) { Write-Host ('  restored: ' + ($actions -join ', ')) -ForegroundColor Yellow }
}

# --- running things -------------------------------------------------------------

function Invoke-Native {
    # Windows PowerShell 5.1 turns stderr lines into errors; keep them as text.
    param([string]$File, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = @(& $File @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host ('        | ' + $line) -ForegroundColor DarkGray }
    return @{ Code = $code; Output = $output; Text = ($output -join "`n") }
}

function Invoke-Installer {
    param([string[]]$Arguments)
    Write-Host ('  > install.ps1 ' + ($Arguments -join ' '))
    return (Invoke-Native $HostExe (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Installer) + @($Arguments)))
}

function Get-FreshPath {
    # What a newly opened terminal gets: machine PATH, then user PATH, from the registry.
    return ((@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) |
                Where-Object { $_ }) -join ';')
}

function Invoke-Fresh {
    # cmd /c in a new process that sees only the registry PATH, from a neutral folder.
    param([string[]]$CommandLine)
    Write-Host ('  > ' + ($CommandLine -join ' '))
    $savedPath = $env:Path
    Push-Location -LiteralPath ([System.IO.Path]::GetTempPath())
    try {
        $env:Path = Get-FreshPath
        return (Invoke-Native (Join-Path $env:SystemRoot 'System32\cmd.exe') (@('/d', '/c') + $CommandLine))
    } finally {
        $env:Path = $savedPath
        Pop-Location
    }
}

function Invoke-IexDriver {
    # Runs install.ps1 the way `irm ... | iex` does, in a fresh process, and fails
    # (exit 3) when anything leaks into that session.
    param([string]$Mode, [string]$Ref)
    Write-Host ('  > irm install.ps1 | iex   (' + $Mode + $(if ($Ref) { ', SSH_PASTE_REF=' + $Ref } else { '' }) + ')')
    $argv = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Driver, '-Installer', $Installer, '-Mode', $Mode)
    if ($Ref) { $argv += @('-Ref', $Ref) }   # 5.1 drops empty-string arguments to native programs
    return (Invoke-Native $HostExe $argv)
}

$DriverText = @'
param([string]$Installer, [string]$Mode, [string]$Ref)
$ErrorActionPreference = 'Continue'
if ($Mode -eq 'uninstall') { $env:SSH_PASTE_UNINSTALL = '1' } else { $env:SSH_PASTE_UNINSTALL = $null }
if ($Ref) { $env:SSH_PASTE_REF = $Ref } else { $env:SSH_PASTE_REF = $null }
$Uninstall = 'sentinel'
# Functions that modules bring along when PowerShell autoloads them (e.g. Get-FileHash) are not ours.
$beforeFunctions = @(Get-ChildItem function: | Where-Object { -not $_.ModuleName } | ForEach-Object { $_.Name })
$global:LASTEXITCODE = 0
Get-Content -Raw -LiteralPath $Installer | Invoke-Expression
$code = $global:LASTEXITCODE
$leaks = @()
if ($ErrorActionPreference -ne 'Continue') { $leaks += 'ErrorActionPreference=' + $ErrorActionPreference }
if ($Uninstall -ne 'sentinel') { $leaks += 'variable $Uninstall' }
$newFunctions = @(Get-ChildItem function: | Where-Object { -not $_.ModuleName -and $beforeFunctions -notcontains $_.Name } | ForEach-Object { $_.Name })
if ($newFunctions.Count -gt 0) { $leaks += 'functions ' + ($newFunctions -join ',') }
try { $null = $notDefinedAnywhere } catch { $leaks += 'Set-StrictMode' }
if ($leaks.Count -gt 0) { 'LEAKED into the calling session: ' + ($leaks -join '; '); exit 3 }
exit $code
'@

# --- checks shared by the rounds ------------------------------------------------

function Get-UserPathCount {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        if ($key.GetValueNames() -notcontains 'Path') { return 0 }
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { $key.Close() }
    return @($raw -split ';' | Where-Object { $_.TrimEnd('\') -ieq $InstallDir }).Count
}

function Test-Installed {
    param([string]$Round)
    $names = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    [void](Test-Check (($names -join ',') -eq 'ssh-paste.cmd,ssh-paste.ps1') "$Round install folder holds exactly ssh-paste.cmd and ssh-paste.ps1" ('found: ' + ($names -join ', ')))
    if ($names -notcontains 'ssh-paste.ps1') { return }
    # Line endings may differ: a download serves the blob as stored in git, a
    # Windows checkout may have CRLF. Everything else must match.
    $same = ([System.IO.File]::ReadAllText((Join-Path $InstallDir 'ssh-paste.ps1')) -replace "`r`n", "`n") -ceq
        ([System.IO.File]::ReadAllText($SourcePs1) -replace "`r`n", "`n")
    [void](Test-Check $same "$Round installed ssh-paste.ps1 equals src (ignoring line endings)")
    $cmd = [System.IO.File]::ReadAllText((Join-Path $InstallDir 'ssh-paste.cmd'))
    $expected = ([System.IO.File]::ReadAllText($SourceCmd) -replace "`r`n", "`n") -replace "`n", "`r`n"
    [void](Test-Check ($cmd -ceq $expected) "$Round installed ssh-paste.cmd equals src with CRLF line endings")
    $count = Get-UserPathCount
    [void](Test-Check ($count -eq 1) "$Round user PATH has the install folder exactly once" "found $count times")
}

function Test-Enable {
    param([string]$Round)
    $existedBefore = Test-Path -LiteralPath $SshConfig
    $r = Invoke-Fresh @('ssh-paste', '--enable', $TestHost)
    [void](Test-Check ($r.Code -eq 0) "$Round ssh-paste --enable $TestHost exits 0" ('exit code ' + $r.Code))
    $text = ''
    if (Test-Path -LiteralPath $SshConfig) { $text = [System.IO.File]::ReadAllText($SshConfig) }
    $hasBlock = $text.StartsWith($BlockBegin) -and $text.Contains("Host $TestHost") -and
        $text.Contains((Join-Path $InstallDir 'ssh-paste.ps1') + '" --proxy %h %p %n')
    [void](Test-Check $hasBlock "$Round ssh config starts with the block for $TestHost, pointing at the installed script" $text)
    [void](Test-Check ($text -match '(?m)^    ProxyUseFdpass no\r?$') "$Round the block turns ProxyUseFdpass off" $text)
    [void](Test-Check ($text.Contains($BlockCreatedFile) -eq (-not $existedBefore)) "$Round the block has the created-file line exactly when ssh-paste created the config (config existed before: $existedBefore)" $text)
    $ssh = (Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($null -eq $ssh) { Write-Fail "$Round ssh.exe found for ssh -G checks"; return }
    $g = Invoke-Native $ssh.Source @('-G', $TestHost)
    $proxy = @($g.Output | Where-Object { $_ -like 'proxycommand *' })
    [void](Test-Check ($proxy.Count -eq 1 -and $proxy[0] -like '*ssh-paste.ps1*--proxy*') "$Round ssh -G $TestHost resolves our ProxyCommand" ($proxy -join "`n"))
    [void](Test-Check (@($g.Output | Where-Object { $_ -eq 'proxyusefdpass no' }).Count -eq 1) "$Round ssh -G $TestHost resolves ProxyUseFdpass no" ($g.Output -join "`n"))
    $g = Invoke-Native $ssh.Source @('-G', 'other.invalid')
    $proxy = @($g.Output | Where-Object { $_ -like 'proxycommand *' })
    [void](Test-Check ($proxy.Count -eq 0) "$Round ssh -G other.invalid has no ProxyCommand (block ends in Host *)" ($proxy -join "`n"))
}

function Install-Fresh {
    param([string]$Round)
    $r = Invoke-Installer @()
    [void](Test-Check ($r.Code -eq 0) "$Round install.ps1 exits 0" ('exit code ' + $r.Code))
    Test-Installed $Round
}

function Complete-Round {
    param([string]$Round)
    $ok = Compare-Footprint $script:Baseline (Get-Footprint) "$Round nothing left behind"
    if (-not $ok) { Restore-State $script:Saved }   # next round starts clean
}

# --- main -----------------------------------------------------------------------

Write-Host ('footprint test: ssh-paste {0} under {1} {2}' -f $Version, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

$installText = [System.IO.File]::ReadAllText($Installer)
$sameMarkers = $true
foreach ($markerName in $Markers.Keys) {
    if (-not $installText.Contains('$' + $markerName + " = '" + $Markers[$markerName] + "'")) { $sameMarkers = $false }
}
[void](Test-Check $sameMarkers 'install.ps1 uses the same ssh config markers as src\ssh-paste.ps1 (BlockBegin, BlockEnd, BlockCreatedFile)')

if (Test-Path -LiteralPath $InstallDir) { Write-Host "ssh-paste is already installed in $InstallDir; refusing to touch it."; exit 2 }
if ((Test-Path -LiteralPath $SshConfig) -and ([System.IO.File]::ReadAllText($SshConfig)).Contains($BlockBegin)) {
    Write-Host "$SshConfig already has a ssh-paste block; refusing to touch it."; exit 2
}
if ((Get-UserPathCount) -gt 0) { Write-Host 'The user PATH already contains the install folder; refusing to touch it.'; exit 2 }

$script:Saved = Save-State
$script:Baseline = Get-Footprint
$script:Driver = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-footprint-' + [guid]::NewGuid().ToString('N') + '.ps1')
[System.IO.File]::WriteAllText($script:Driver, $DriverText, (New-Object System.Text.UTF8Encoding($false)))

try {
    Write-Host 'round 0: bad options change nothing'
    $r = Invoke-Installer @('-Ref', '../x')
    [void](Test-Check ($r.Code -ne 0) 'round 0: install.ps1 -Ref ../x fails')
    $r = Invoke-Installer @('-NoSuchOption')
    [void](Test-Check ($r.Code -ne 0) 'round 0: install.ps1 -NoSuchOption fails')
    Complete-Round 'round 0:'

    Write-Host 'round 1: ssh-paste --uninstall'
    Install-Fresh 'round 1:'
    $r = Invoke-Installer @()
    [void](Test-Check ($r.Code -eq 0 -and $r.Text -match 'Reinstalled') 'round 1: second install.ps1 run reinstalls in place' $r.Text)
    Test-Installed 'round 1 (after second install):'
    $r = Invoke-Fresh @('where', 'ssh-paste')
    [void](Test-Check ($r.Code -eq 0 -and $r.Output.Count -gt 0 -and $r.Output[0] -ieq (Join-Path $InstallDir 'ssh-paste.cmd')) 'round 1: a new terminal finds ssh-paste.cmd in the install folder first')
    $r = Invoke-Fresh @('ssh-paste', '--version')
    [void](Test-Check ($r.Code -eq 0 -and $r.Text.Trim() -eq $Version) "round 1: ssh-paste --version prints $Version" $r.Text)
    $r = Invoke-Fresh @('ssh-paste', '--proxy')
    [void](Test-Check ($r.Code -eq 2) 'round 1: ssh-paste.cmd passes the exit code through (--proxy without arguments exits 2)' ('exit code ' + $r.Code))
    Test-Enable 'round 1:'
    $r = Invoke-Fresh @('ssh-paste', '--disable')
    [void](Test-Check ($r.Code -eq 0) 'round 1: ssh-paste --disable exits 0' ('exit code ' + $r.Code))
    $configNow = $null
    if (Test-Path -LiteralPath $SshConfig) { $configNow = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($SshConfig)) }
    $configBefore = $null
    if ($null -ne $script:Saved.ConfigBytes) { $configBefore = [Convert]::ToBase64String($script:Saved.ConfigBytes) }
    [void](Test-Check ($configNow -ceq $configBefore) 'round 1: --disable restores the ssh config exactly (or removes it)')
    Test-Enable 'round 1 (enabled again):'
    $r = Invoke-Fresh @('ssh-paste', '--uninstall')
    [void](Test-Check ($r.Code -eq 0 -and $r.Text -notmatch 'batch file cannot be found|cannot find the batch') 'round 1: ssh-paste --uninstall exits 0 and the launcher survives deleting itself' $r.Text)
    Complete-Round 'round 1:'

    Write-Host 'round 2: install.ps1 -Uninstall'
    Install-Fresh 'round 2:'
    Test-Enable 'round 2:'
    $r = Invoke-Installer @('-Uninstall')
    [void](Test-Check ($r.Code -eq 0) 'round 2: install.ps1 -Uninstall exits 0' ('exit code ' + $r.Code))
    $r = Invoke-Installer @('-Uninstall')
    [void](Test-Check ($r.Code -eq 0 -and $r.Text -match 'not installed') 'round 2: a second -Uninstall finds nothing to remove' $r.Text)
    Complete-Round 'round 2:'

    Write-Host 'round 3: irm | iex with SSH_PASTE_UNINSTALL=1'
    Install-Fresh 'round 3:'
    Test-Enable 'round 3:'
    $r = Invoke-IexDriver 'uninstall' ''
    [void](Test-Check ($r.Code -eq 0) 'round 3: uninstall through iex succeeds and leaks nothing into the session' $r.Text)
    Complete-Round 'round 3:'

    Write-Host 'round 5: an existing ssh config is kept'
    if ($null -ne $script:Saved.ConfigBytes) {
        Write-Host '  skipped: this computer has an ssh config of its own, which this round would replace for a moment'
    } else {
        $mine = "Host keepme.invalid`r`n    User keep`r`n"
        [void][System.IO.Directory]::CreateDirectory($SshDir)
        [System.IO.File]::WriteAllText($SshConfig, $mine, (New-Object System.Text.UTF8Encoding($false)))
        Install-Fresh 'round 5:'
        Test-Enable 'round 5:'
        $r = Invoke-Installer @('-Uninstall')
        [void](Test-Check ($r.Code -eq 0) 'round 5: install.ps1 -Uninstall exits 0' ('exit code ' + $r.Code))
        $now = $null
        if (Test-Path -LiteralPath $SshConfig) { $now = [System.IO.File]::ReadAllText($SshConfig) }
        [void](Test-Check ($now -ceq $mine) 'round 5: the config that existed before is back exactly as it was, not deleted' $now)
        Restore-State $script:Saved   # removes the config this round made, and .ssh if it was ours
        Complete-Round 'round 5:'
    }

    if ($env:GITHUB_REPOSITORY -eq 'xuing/ssh-please-paste-picture' -and $env:GITHUB_EVENT_NAME -eq 'push' -and $env:GITHUB_SHA) {
        Write-Host 'round 4: irm | iex install from GitHub at this commit'
        $r = Invoke-IexDriver 'install' $env:GITHUB_SHA
        [void](Test-Check ($r.Code -eq 0) 'round 4: install through iex succeeds and leaks nothing into the session' $r.Text)
        Test-Installed 'round 4:'
        $r = Invoke-IexDriver 'uninstall' ''
        [void](Test-Check ($r.Code -eq 0) 'round 4: uninstall through iex succeeds' $r.Text)
        Complete-Round 'round 4:'
    } else {
        Write-Host 'round 4: skipped (runs only on push builds of xuing/ssh-please-paste-picture)'
    }
} catch {
    Write-Fail ('unexpected error: ' + $_.Exception.Message) ($_.ScriptStackTrace)
} finally {
    Restore-State $script:Saved
    Remove-Item -LiteralPath $script:Driver -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host ('footprint test FAILED ({0}):' -f $script:Failures.Count) -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
Write-Host 'footprint test passed: every round left the computer as it found it.' -ForegroundColor Green
exit 0
