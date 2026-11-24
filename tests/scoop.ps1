<#
Scoop end to end: the manifest that .github/scripts/scoop-manifest.sh writes for a release,
installed with the real Scoop from a local copy of release files. Windows only; CI runs it on
windows-latest under `powershell` (5.1) and `pwsh`.

  1  scoop install: ssh-paste --version through Scoop's shim says 0.1.0
  2  --enable writes the path of apps\ssh-paste\current into the ProxyCommand
  3  --update and --uninstall leave a Scoop install to Scoop: they say so, change nothing
  4  scoop update to 0.1.1 keeps the ssh config block (the uninstaller hook runs during an
     update too, and must not disable), and the ProxyCommand's script is now 0.1.1
  5  scoop uninstall runs ssh-paste --disable: the block (and the config it created) is gone
  6  a block that another install wrote (the repository's script stands in) survives
     scoop install and scoop uninstall
  7  with Scoop's no_junction setting, --enable refuses (no path survives scoop update)
  8  when --disable fails (this script holds ~/.ssh/config open, unshared), scoop uninstall
     stops and keeps ssh-paste

It installs Scoop when it is missing, from ScoopInstaller/Install at a pinned commit, and
serves the release files from http://127.0.0.1 with Python. It edits the real profile
(~\scoop, ~\.ssh), so it runs in CI only, and restores ~\.ssh at the end.

    powershell -ExecutionPolicy Bypass -File tests\scoop.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($env:OS -ne 'Windows_NT') { Write-Host 'scoop.ps1 runs on Windows only.'; exit 2 }
if ($env:CI -ne 'true') {
    Write-Host 'scoop.ps1 installs Scoop and ssh-paste in your real profile. It runs in CI (CI=true).'
    exit 2
}

$Repo = Split-Path -Parent $PSScriptRoot
$script:Failures = 0
function Pass { param([string]$Text) Write-Host ('  ok    ' + $Text) }
function Fail { param([string]$Text) Write-Host ('  FAIL  ' + $Text); $script:Failures++ }
function Check {
    param($Got, $Want, [string]$Text)
    if ([string]$Got -ceq [string]$Want) { Pass $Text } else { Fail ($Text + "`n        expected: " + $Want + "`n        got:      " + $Got) }
}
function Section { param([string]$Text) Write-Host ''; Write-Host ('== ' + $Text) }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-scoop-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($work)
$sshDir = Join-Path $env:USERPROFILE '.ssh'
$sshSaved = Join-Path $work 'ssh-saved'
if (Test-Path -LiteralPath $sshDir) { Copy-Item -LiteralPath $sshDir -Destination $sshSaved -Recurse }
$config = Join-Path $sshDir 'config'
$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
$server = $null

function Invoke-Bash {
    # Git's bash (not WSL's) runs the release scripts, with forward slashes in paths.
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & $bash @($Arguments | ForEach-Object { $_.Replace('\', '/') })
    if ($LASTEXITCODE -ne 0) { throw ('bash ' + ($Arguments -join ' ') + ' failed') }
    return ($out -join "`n")
}

function New-Release {
    # A folder like a release's: ssh-paste.ps1 stamped with VERSION, ssh-paste.cmd, SHA256SUMS.
    param([string]$Version)
    $dir = Join-Path $work ('serve\v' + $Version)
    [void][System.IO.Directory]::CreateDirectory($dir)
    [void](Invoke-Bash @((Join-Path $Repo '.github\scripts\stamp-version.sh'), (Join-Path $Repo 'src\ssh-paste.ps1'), (Join-Path $dir 'ssh-paste.ps1'), $Version))
    Copy-Item -LiteralPath (Join-Path $Repo 'src\ssh-paste.cmd') -Destination $dir
    $lines = foreach ($f in @('ssh-paste.ps1', 'ssh-paste.cmd')) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dir $f)).Hash.ToLowerInvariant() + '  ' + $f
    }
    [System.IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS'), (($lines -join "`n") + "`n"))
    return $dir
}

function Write-Manifest {
    param([string]$Version, [string]$Path)
    $json = Invoke-Bash @((Join-Path $Repo '.github\scripts\scoop-manifest.sh'), $Version, ('http://127.0.0.1:8765/v' + $Version), (Join-Path $work ('serve\v' + $Version + '\SHA256SUMS')))
    [System.IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Shim {
    # ssh-paste through Scoop's shim, as a user runs it; stdout and stderr together.
    # Windows PowerShell turns redirected stderr into errors, which 'Stop' would throw.
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $shim = Join-Path $env:USERPROFILE 'scoop\shims\ssh-paste.cmd'
    $out = & $shim @Arguments 2>&1 | ForEach-Object { [string]$_ }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

function Invoke-Scoop {
    # Scoop runs in this session; its own errors are judged by the checks, not by 'Stop'.
    $ErrorActionPreference = 'Continue'
    scoop @args
    Write-Host ('scoop ' + ($args -join ' ') + ': exit ' + $LASTEXITCODE)
}

function Get-ConfigText {
    if (Test-Path -LiteralPath $config) { return [System.IO.File]::ReadAllText($config) }
    return ''
}

try {
    Section 'Scoop'
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        $installer = Join-Path $work 'install-scoop.ps1'
        Invoke-WebRequest -UseBasicParsing -OutFile $installer -Uri 'https://raw.githubusercontent.com/ScoopInstaller/Install/1e2f334083d609986d8c8bc9e31ae8e87c39fab4/install.ps1'
        & $installer -RunAsAdmin
        if (-not $?) { throw 'the Scoop installer failed' }
        $env:PATH = (Join-Path $env:USERPROFILE 'scoop\shims') + ';' + $env:PATH
    }
    Write-Host ('scoop: ' + (Get-Command scoop).Source)
    if (Test-Path -LiteralPath $config) { Remove-Item -LiteralPath $config -Force }

    $null = New-Release '0.1.0'
    $null = New-Release '0.1.1'
    $server = Start-Process -PassThru -WindowStyle Hidden -FilePath 'python' -ArgumentList @('-m', 'http.server', '8765', '--bind', '127.0.0.1', '--directory', (Join-Path $work 'serve'))
    $deadline = (Get-Date).AddSeconds(30)
    while ($true) {
        try { $null = Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8765/v0.1.0/SHA256SUMS'; break } catch { if ((Get-Date) -gt $deadline) { throw 'the local release server did not start' }; Start-Sleep -Milliseconds 200 }
    }
    $manifest = Join-Path $work 'ssh-paste.json'
    Write-Manifest '0.1.0' $manifest

    Section '1: scoop install'
    Invoke-Scoop install $manifest
    Check (Invoke-Shim @('--version')).Text '0.1.0' 'ssh-paste --version through the shim'

    Section '2: --enable'
    $r = Invoke-Shim @('--enable', 'localhost')
    Check $r.Code 0 '--enable localhost'
    $app = Join-Path $env:USERPROFILE 'scoop\apps\ssh-paste'
    $current = Join-Path $app 'current\ssh-paste.ps1'
    if ((Get-ConfigText).Contains('-File "' + $current + '" --proxy')) { Pass 'the ProxyCommand calls apps\ssh-paste\current, which scoop update keeps' } else { Fail ('ssh config: ' + (Get-ConfigText)) }
    $ErrorActionPreference = 'Continue'
    $null = & (Join-Path $app '0.1.0\ssh-paste.cmd') --enable 127.0.0.1 2>&1
    $ErrorActionPreference = 'Stop'
    if ((Get-ConfigText).Contains('-File "' + $current + '" --proxy') -and -not (Get-ConfigText).Contains('\0.1.0\')) { Pass 'called from the version folder, --enable still writes the current path' } else { Fail ('ssh config: ' + (Get-ConfigText)) }

    Section '3: --update and --uninstall under Scoop'
    $r = Invoke-Shim @('--update')
    Check $r.Code 1 '--update exits 1'
    if ($r.Text.Contains('scoop update ssh-paste')) { Pass 'and says scoop update ssh-paste' } else { Fail ('--update said: ' + $r.Text) }
    $r = Invoke-Shim @('--uninstall')
    Check $r.Code 1 '--uninstall exits 1'
    if ($r.Text.Contains('scoop uninstall ssh-paste')) { Pass 'and says scoop uninstall ssh-paste' } else { Fail ('--uninstall said: ' + $r.Text) }
    if (Test-Path -LiteralPath $current) { Pass 'the files are still there' } else { Fail 'the files were removed' }
    if ((Get-ConfigText).Contains('--proxy')) { Pass 'the ssh config block is still there' } else { Fail 'the ssh config block was removed' }

    Section '4: scoop update to 0.1.1'
    Write-Manifest '0.1.1' $manifest
    Invoke-Scoop update ssh-paste
    Check (Invoke-Shim @('--version')).Text '0.1.1' 'ssh-paste --version after the update'
    if ((Get-ConfigText).Contains('-File "' + $current + '" --proxy')) { Pass 'the update kept the ssh config block' } else { Fail ('ssh config after the update: ' + (Get-ConfigText)) }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Check ((& $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $current --version) -join '') '0.1.1' 'the ProxyCommand script is the new version'

    Section '5: scoop uninstall'
    Invoke-Scoop uninstall ssh-paste
    if (Test-Path -LiteralPath $config) { Fail ('the ssh config is still there: ' + (Get-ConfigText)) } else { Pass 'the ssh config ssh-paste created is gone' }
    if (Test-Path -LiteralPath $app) { Fail 'apps\ssh-paste is still there' } else { Pass 'apps\ssh-paste is gone' }

    Section '6: a block of another install survives scoop uninstall'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $standalone = Join-Path $Repo 'src\ssh-paste.ps1'
    $ErrorActionPreference = 'Continue'
    $null = & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $standalone --enable localhost 2>&1
    $ErrorActionPreference = 'Stop'
    if ((Get-ConfigText).Contains('-File "' + $standalone + '" --proxy')) { Pass 'the stand-in install enabled localhost' } else { Fail ('ssh config: ' + (Get-ConfigText)) }
    Invoke-Scoop install $manifest
    Invoke-Scoop uninstall ssh-paste
    if ((Get-ConfigText).Contains('-File "' + $standalone + '" --proxy')) { Pass 'scoop uninstall left the other install''s block alone' } else { Fail ('ssh config: ' + (Get-ConfigText)) }
    $ErrorActionPreference = 'Continue'
    $null = & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $standalone --disable 2>&1
    $ErrorActionPreference = 'Stop'

    Section '7: no_junction'
    Invoke-Scoop config no_junction true
    Invoke-Scoop install $manifest
    $r = Invoke-Shim @('--enable', 'localhost')
    if ($r.Code -ne 0 -and $r.Text.Contains('no_junction') -and $r.Text.Contains('wrapper mode')) { Pass '--enable refuses and points to wrapper mode' } else { Fail ('--enable: exit ' + $r.Code + ': ' + $r.Text) }
    if ((Get-ConfigText).Contains('--proxy')) { Fail ('it wrote a block: ' + (Get-ConfigText)) } else { Pass 'no ssh config block was written' }
    Invoke-Scoop uninstall ssh-paste
    Invoke-Scoop config rm no_junction

    Section '8: a failed --disable stops scoop uninstall'
    Invoke-Scoop install $manifest
    Check (Invoke-Shim @('--enable', 'localhost')).Code 0 '--enable localhost'
    # Scoop runs in this session, so the hook's error reaches this script; in a terminal it
    # stops scoop uninstall with that message.
    $stopped = ''
    $lock = [System.IO.File]::Open($config, 'Open', 'ReadWrite', 'None')
    try { Invoke-Scoop uninstall ssh-paste } catch { $stopped = $_.Exception.Message } finally { $lock.Dispose() }
    Write-Host ('scoop uninstall stopped with: ' + $stopped)
    if ($stopped -match 'config') { Pass 'scoop uninstall stops with an error about the ssh config' } else { Fail ('scoop uninstall did not stop: ' + $stopped) }
    if (Test-Path -LiteralPath $current) { Pass 'ssh-paste stays installed' } else { Fail 'ssh-paste was removed while the ssh config still calls it' }
    if ((Get-ConfigText).Contains('-File "' + $current + '" --proxy')) { Pass 'and the ssh config still calls an existing file' } else { Fail ('ssh config: ' + (Get-ConfigText)) }
    Invoke-Scoop uninstall ssh-paste
    if ((Test-Path -LiteralPath $app) -or (Get-ConfigText).Contains('--proxy')) { Fail 'the second scoop uninstall did not finish' } else { Pass 'once the config is free, scoop uninstall finishes' }
} catch {
    Fail ('stopped: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
} finally {
    if ($null -ne $server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    if (Test-Path -LiteralPath $sshDir) { Remove-Item -LiteralPath $sshDir -Recurse -Force }
    if (Test-Path -LiteralPath $sshSaved) { Copy-Item -LiteralPath $sshSaved -Destination $sshDir -Recurse }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'scoop.ps1: all checks passed'; exit 0 }
Write-Host ('scoop.ps1: ' + $script:Failures + ' check(s) failed')
exit 1
