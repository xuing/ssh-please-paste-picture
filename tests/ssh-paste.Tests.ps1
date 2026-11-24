<#
Pester 5 tests for src/ssh-paste.ps1. Keep this file ASCII (Windows PowerShell 5.1
reads a file without a BOM as ANSI); non-ASCII test data is built from code points.

  Invoke-Pester tests/ssh-paste.Tests.ps1 -ExcludeTagFilter E2E     unit tests (any OS)
  Invoke-Pester tests/ssh-paste.Tests.ps1 -TagFilter E2E            real ssh, see "E2E" below

Tags
  Windows  needs Windows (clipboard, P/Invoke); the clipboard tests overwrite the
           clipboard, so they also need $env:CI or $env:SSH_PASTE_TEST_CLIPBOARD=1
  Unix     runs the server-side script through real shells (sh, bash, dash, ...)
  E2E      needs $env:SSH_PASTE_E2E_HOST (a host ssh can reach without a prompt):
             SSH_PASTE_E2E_KEY     optional, passed as -i
             SSH_PASTE_E2E_CONFIG  optional, passed as -F
             SSH_PASTE_SSH         optional, the ssh to use (default: ssh on PATH)

Home sandbox
  The whole run happens with USERPROFILE, HOME, APPDATA and LOCALAPPDATA pointing at a
  temporary folder and with every SSH_PASTE_* variable unset, so a test can never read
  or change the real profile, and the tester's own settings cannot change a result. The
  variables listed in $script:KeptVariables are the test inputs described above and stay.
  Run the whole file (tests/run-pester.ps1 or check.ps1): the repository guard tests at
  the end live in it.
#>

BeforeDiscovery {
    $onWindows = ($env:OS -eq 'Windows_NT')
    $onUnix = -not $onWindows
    $e2eHost = $env:SSH_PASTE_E2E_HOST
    # Login shells that can be asked to run the upload command string, if installed.
    $unixShells = @()
    if ($onUnix) {
        foreach ($name in @('sh', 'bash', 'dash', 'zsh', 'fish', 'ksh', 'tcsh')) {
            $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $found) { $unixShells += @{ Shell = $name; ShellPath = $found.Source } }
        }
    }
    # The tables in tests/cases.json, which the node tests of the macOS client
    # (tests/mac/unit.test.js) run too. Each case becomes a hashtable for -ForEach;
    # an Effective map becomes a hashtable, as Test-InteractiveSsh takes it.
    $sharedCases = @{}
    $json = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'cases.json')))
    foreach ($table in $json.PSObject.Properties) {
        if ($table.Name -eq 'about') { continue }
        $sharedCases[$table.Name] = @(foreach ($case in @($table.Value)) {
                $h = @{}
                foreach ($field in $case.PSObject.Properties) {
                    $value = $field.Value
                    if ($field.Name -eq 'Effective') {
                        $map = @{}
                        foreach ($setting in $value.PSObject.Properties) { $map[$setting.Name] = [string]$setting.Value }
                        $value = $map
                    } elseif ($field.Name -eq 'Argv') {
                        $value = [string[]]@($value)
                    }
                    $h[$field.Name] = $value
                }
                $h
            })
    }
}

BeforeAll {
    # --- home sandbox (see the header) ---------------------------------------------
    $script:SandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-home-' + [guid]::NewGuid().ToString('N'))
    $script:RealHome = $env:USERPROFILE
    $script:HomeVariables = @('USERPROFILE', 'HOME', 'APPDATA', 'LOCALAPPDATA')
    # Inputs of the opt-in tests: the clipboard switch, and the E2E host and its options.
    $script:KeptVariables = @('SSH_PASTE_TEST_CLIPBOARD', 'SSH_PASTE_E2E_HOST', 'SSH_PASTE_E2E_KEY', 'SSH_PASTE_E2E_CONFIG', 'SSH_PASTE_REPO')
    if ($env:SSH_PASTE_E2E_HOST) { $script:KeptVariables += 'SSH_PASTE_SSH' }
    $script:SavedVariables = @{}
    foreach ($name in $script:HomeVariables + @(Get-ChildItem Env: | Where-Object { $_.Name -like 'SSH_PASTE_*' -and $script:KeptVariables -notcontains $_.Name } | ForEach-Object { $_.Name })) {
        $script:SavedVariables[$name] = [System.Environment]::GetEnvironmentVariable($name)
    }
    foreach ($name in @($script:SavedVariables.Keys)) {
        # Remove-Item, not SetEnvironmentVariable($null): .NET on Unix keeps an empty value.
        if ($name -like 'SSH_PASTE_*') { Remove-Item -LiteralPath ('Env:' + $name) }
    }
    $script:SandboxRoaming = Join-Path (Join-Path $script:SandboxRoot 'AppData') 'Roaming'
    $script:SandboxLocal = Join-Path (Join-Path $script:SandboxRoot 'AppData') 'Local'
    foreach ($dir in @($script:SandboxRoot, $script:SandboxRoaming, $script:SandboxLocal)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $env:USERPROFILE = $script:SandboxRoot
    $env:HOME = $script:SandboxRoot
    $env:APPDATA = $script:SandboxRoaming
    $env:LOCALAPPDATA = $script:SandboxLocal

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CorePath = Join-Path $script:RepoRoot 'src/ssh-paste.ps1'
    . $script:CorePath

    $script:OnWindows = ($env:OS -eq 'Windows_NT')

    # The PowerShell that runs this file; used to start ssh-paste as a child process.
    function Get-ThisPowerShell {
        return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    }

    # Runs a program, feeds it bytes on stdin, returns exit code, stdout and stderr.
    function Invoke-Process {
        param(
            [string]$FilePath,
            [string[]]$Arguments,
            [byte[]]$InputBytes,
            [string]$WorkingDirectory,
            [int]$TimeoutSeconds = 60
        )
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        Set-ProcessArguments $psi $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        # No byte order mark on stdin (Windows PowerShell 5.1 with a UTF-8 console), as in the core.
        $restoreEncoding = $null
        if ($null -ne $psi.PSObject.Properties['StandardInputEncoding']) {
            $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
        } else {
            try { if ([Console]::InputEncoding.GetPreamble().Length -gt 0) { $restoreEncoding = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } } catch { $restoreEncoding = $null }
        }
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        try {
            try { [void]$process.Start() } finally { if ($null -ne $restoreEncoding) { try { [Console]::InputEncoding = $restoreEncoding } catch { } } }
            $out = $process.StandardOutput.ReadToEndAsync()
            $err = $process.StandardError.ReadToEndAsync()
            try {
                if ($null -ne $InputBytes -and $InputBytes.Length -gt 0) {
                    $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
                    $process.StandardInput.BaseStream.Flush()
                }
            } catch { }
            try { $process.StandardInput.Close() } catch { }
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try { $process.Kill() } catch { }
                throw "timed out after $TimeoutSeconds s: $FilePath"
            }
            $process.WaitForExit()
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
        } finally {
            $process.Dispose()
        }
    }

    function Invoke-SshPaste {
        # Black-box run of the script itself in a child PowerShell.
        param([string[]]$Arguments)
        $argv = @('-NoLogo', '-NoProfile')
        if ($script:OnWindows) { $argv += @('-ExecutionPolicy', 'Bypass') }
        $argv += @('-File', $script:CorePath)
        $argv += $Arguments
        return (Invoke-Process -FilePath (Get-ThisPowerShell) -Arguments $argv)
    }

    function Get-Sha256Hex {
        param([byte[]]$Bytes)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()) } finally { $sha.Dispose() }
    }

    function Format-ArgList {
        param([string[]]$Items)
        return (ConvertTo-Json -Compress -InputObject @($Items))
    }

    function Get-RoundTrip {
        # Quote the items, put "prog" in front, parse the line back.
        param([string[]]$Items)
        $line = 'prog ' + (Join-NativeArguments $Items)
        $parts = @(Split-CommandLine $line)
        return , @($parts | Select-Object -Skip 1)
    }

    function Format-Options {
        param($Parsed)
        $items = @($Parsed.Options | ForEach-Object { if ($null -eq $_.Value) { $_.Flag } else { $_.Flag + '=' + $_.Value } })
        return ($items -join ' ')
    }
}

AfterAll {
    foreach ($name in @($script:SavedVariables.Keys)) {
        if ($null -eq $script:SavedVariables[$name]) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        } else {
            [System.Environment]::SetEnvironmentVariable($name, $script:SavedVariables[$name])
        }
    }
    Remove-Item -LiteralPath $script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'home sandbox' {
    It 'points the home variables at the sandbox, not the real profile' {
        foreach ($name in $script:HomeVariables) {
            $value = [System.Environment]::GetEnvironmentVariable($name)
            $value | Should -BeLike ($script:SandboxRoot + '*') -Because "$name must not be the real one"
        }
        if ($script:RealHome) { $env:USERPROFILE | Should -Not -Be $script:RealHome }
    }

    It 'leaves no SSH_PASTE_ variable set except the documented test inputs' {
        $stray = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'SSH_PASTE_*' -and $script:KeptVariables -notcontains $_.Name } | ForEach-Object { $_.Name })
        $stray | Should -BeNullOrEmpty
    }

    It 'resolves the ssh config path inside the sandbox' {
        (Get-SshConfigPath) | Should -BeLike ($script:SandboxRoot + '*')
    }
}

Describe 'source file' {
    It 'is pure ASCII' {
        $bytes = [System.IO.File]::ReadAllBytes($script:CorePath)
        $bad = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 126 -or ($bytes[$i] -lt 32 -and $bytes[$i] -ne 9 -and $bytes[$i] -ne 10 -and $bytes[$i] -ne 13)) { $bad += $i } }
        $bad.Count | Should -Be 0 -Because "non-ASCII or control bytes at offsets: $($bad -join ', ')"
    }

    It 'has no byte order mark' {
        $bytes = [System.IO.File]::ReadAllBytes($script:CorePath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    }

    It 'parses without errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:CorePath, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0 -Because (@($errors | ForEach-Object { $_.ToString() }) -join '; ')
    }

    It 'does not use syntax that Windows PowerShell 5.1 cannot parse' {
        # Ternary, ??, ?. and && / || between pipelines are PowerShell 7 only.
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:CorePath, [ref]$tokens, [ref]$null)
        $bad = @($tokens | Where-Object { @('QuestionQuestion', 'QuestionDot', 'QuestionMark', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionQuestionEquals') -contains $_.Kind.ToString() })
        $bad.Count | Should -Be 0 -Because (@($bad | ForEach-Object { $_.Extent.StartLineNumber.ToString() + ': ' + $_.Text }) -join '; ')
    }

    It 'does not use automatic variables that only exist in PowerShell 7 (an error under strict mode in 5.1)' {
        $text = [System.IO.File]::ReadAllText($script:CorePath)
        $text | Should -Not -Match '\$Is(Windows|Linux|MacOS|Coreclr)\b'
    }

    It 'does not use the command-line forms that antivirus heuristics flag' {
        $text = [System.IO.File]::ReadAllText($script:CorePath)
        $text | Should -Not -Match '(?i)-EncodedCommand'
        $text | Should -Not -Match '(?i)-WindowStyle'
        $text | Should -Not -Match '(?i)\s-(ep|nop|noni|w|enc)\s'
    }

    It 'can be dot-sourced for tests: functions load, main does not run' {
        $script:Version | Should -Match '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'
    }

    It 'this test file is ASCII too' {
        $bytes = [System.IO.File]::ReadAllBytes($PSCommandPath)
        @($bytes | Where-Object { $_ -gt 126 }).Count | Should -Be 0
    }
}

Describe 'RemoteScript (the command that runs on the server)' {
    It 'contains no single quote or backslash' {
        $script:RemoteScript.Contains("'") | Should -BeFalse
        $script:RemoteScript.Contains('\') | Should -BeFalse
    }

    It 'contains no exclamation mark (csh and tcsh take it for history substitution)' {
        $script:RemoteScript.Contains('!') | Should -BeFalse
    }

    It 'is one line of printable ASCII without double quotes or backticks' {
        $script:RemoteScript | Should -Match '^[ -~]+$'
        $script:RemoteScript.Contains('"') | Should -BeFalse
        $script:RemoteScript.Contains('`') | Should -BeFalse
    }

    It 'takes the hash, byte count, extension, minutes to keep, folder and class as $1 to $6' {
        $script:RemoteScript | Should -Match 'n=\$2;'
        $script:RemoteScript | Should -Match 'k=\$\{4:-1440\}; d=\$\{5:-/tmp\}; c=\$\{6:-\};'
        $script:RemoteScript | Should -Match ('h=' + [regex]::Escape('[0-9a-f]' * 32) + ';')
        $script:RemoteScript | Should -Match '\$d/ssh-paste-\$c\$1\.\$e'
    }

    It 'takes the folder as given (the client sends an absolute one), and makes it when missing' {
        $script:RemoteScript | Should -Not -Match 'HOME'
        $script:RemoteScript | Should -Match '\[ -d \$d \] \|\| mkdir -p \$d 2> /dev/null \|\| \{ echo nodir; exit 5; \}'
    }

    It 'uses a folder other than /tmp only when it is yours, not a link, and ls -ld shows no group or other write and no ACL' {
        # Anything ls does not show as safe (an error, an ACL +) counts as not private.
        $script:RemoteScript | Should -Match 'if \[ \$d = /tmp \]; then :; elif \[ -h \$d \]; then echo notprivate; exit 6; elif \[ -O \$d \]; then m=\$\(ls -ld \$d 2> /dev/null\); case \$\{m%% \*\} in d\?\?\?\?-\?\?-\? \| d\?\?\?\?-\?\?-\?\. \| d\?\?\?\?-\?\?-\?@\) ;; \*\) echo notprivate; exit 6;; esac; else echo notprivate; exit 6; fi;'
        $script:RemoteScript.IndexOf('notprivate') | Should -BeLessThan $script:RemoteScript.IndexOf('mktemp')
    }

    It 'prunes images only when the minutes to keep are a number above 0' {
        $script:RemoteScript | Should -Match 'if \[ \$k -gt 0 \] 2> /dev/null; then for x in'
    }

    It 'makes private files: umask, no globbing, a temp file from mktemp' {
        $script:RemoteScript | Should -Match '^umask 077;'
        $script:RemoteScript | Should -Match 'set -fC'
        $script:RemoteScript | Should -Match 't=\$\(mktemp \$d/ssh-paste-tmp\.XXXXXXXXXX 2> /dev/null\) \|\| \{ echo nodir; exit 3; \};'
        $script:RemoteScript | Should -Not -Match '\$\$'
    }

    It 'rejects a short upload with "short N" and exit 4 before it publishes anything' {
        $script:RemoteScript | Should -Match 'echo short \$s; exit 4'
        $script:RemoteScript.IndexOf('exit 4') | Should -BeLessThan $script:RemoteScript.IndexOf('mv -f')
    }

    It 'prunes only this user''s regular files with exactly its own names: images of its class older than $4 minutes, temp files older than a day' {
        # ssh-paste-<class><32 hex digits>[-<uid>].<ext> and mktemp's ssh-paste-tmp.<10 letters or digits>,
        # so a same-user file such as ssh-paste-notes.png, or an image of another --keep, is never deleted.
        # $d/ makes find enter /tmp when it is a symbolic link, as on macOS (/private/tmp).
        $script:RemoteScript | Should -Match 'u=\$\(id -u\); a=\[A-Za-z0-9\];'
        $script:RemoteScript | Should -Match 'for p in ssh-paste-\$c\$h\.\$x ssh-paste-\$c\$h-\$u\.\$x; do find \$d/ -maxdepth 1 -type f -user \$u -name \$p -mmin \+\$k -exec rm -f \{\} \+'
        $script:RemoteScript | Should -Match ('find \$d/ -maxdepth 1 -type f -user \$u -name ssh-paste-tmp\.' + [regex]::Escape('$a' * 10) + ' -mmin \+1440 -exec rm -f \{\} \+')
        $script:RemoteScript | Should -Not -Match 'find \$d '
        $script:RemoteScript | Should -Not -Match '-name ssh-paste-\*'
    }

    It 'publishes the content name, or a per-user name when another user owns it' {
        $script:RemoteScript | Should -Match 'e=\$\{3:-png\}'
        $script:RemoteScript | Should -Match 'for f in \$d/ssh-paste-\$c\$1\.\$e \$d/ssh-paste-\$c\$1-\$u\.\$e;'
        $script:RemoteScript | Should -Match 'echo \$n \$f; exit 0'
    }

    It 'reuses a file only when its bytes are equal (cmp -s), not just its size' {
        $script:RemoteScript | Should -Match 'cmp -s \$t \$f'
    }

    It 'reuses a file only if it is still there after touch -c, which never makes an empty one' {
        # A prune by another upload may delete the copy between cmp and touch; the script then publishes its own.
        $script:RemoteScript | Should -Match 'cmp -s \$t \$f && touch -c \$f && \[ -f \$f \]; then rm -f \$t; echo \$n \$f; exit 0; fi;'
    }
}

Describe 'ConvertTo-NativeArgument' {
    It 'leaves a plain word alone' {
        ConvertTo-NativeArgument 'plain' | Should -BeExactly 'plain'
        ConvertTo-NativeArgument 'C:\dir\file.txt' | Should -BeExactly 'C:\dir\file.txt'
        ConvertTo-NativeArgument 'a=b,c;d' | Should -BeExactly 'a=b,c;d'
    }

    It 'quotes the empty string' {
        ConvertTo-NativeArgument '' | Should -BeExactly '""'
    }

    It 'quotes whitespace' {
        ConvertTo-NativeArgument 'a b' | Should -BeExactly '"a b"'
        ConvertTo-NativeArgument "a`tb" | Should -BeExactly "`"a`tb`""
    }

    It 'escapes embedded quotes' {
        ConvertTo-NativeArgument 'say "hi"' | Should -BeExactly '"say \"hi\""'
        ConvertTo-NativeArgument '"' | Should -BeExactly '"\""'
    }

    It 'doubles backslashes before a quote and at the end of a quoted argument' {
        ConvertTo-NativeArgument 'a\"b' | Should -BeExactly '"a\\\"b"'
        ConvertTo-NativeArgument 'C:\Program Files\x\' | Should -BeExactly '"C:\Program Files\x\\"'
    }

    It 'keeps backslashes that are not before a quote' {
        ConvertTo-NativeArgument 'a\b c' | Should -BeExactly '"a\b c"'
    }
}

Describe 'Join-NativeArguments' {
    It 'joins with single spaces' {
        Join-NativeArguments @('-o', 'a b', '') | Should -BeExactly '-o "a b" ""'
    }

    It 'returns an empty string for nothing' {
        Join-NativeArguments @() | Should -BeExactly ''
        Join-NativeArguments $null | Should -BeExactly ''
    }
}

Describe 'Join-NativeArguments and Split-CommandLine round trip' {
    BeforeDiscovery {
        $e9 = [string][char]0xE9
        $cjk = [string][char]0x65E5 + [string][char]0x672C
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $cases = @(
            @{ Name = 'one plain word'; Items = @('plain') }
            @{ Name = 'nothing'; Items = @() }
            @{ Name = 'a space'; Items = @('with space') }
            @{ Name = 'an empty string'; Items = @('') }
            @{ Name = 'two empty strings'; Items = @('', '') }
            @{ Name = 'empty strings between words'; Items = @('a', '', 'b', '') }
            @{ Name = 'quotes'; Items = @('say "hi"') }
            @{ Name = 'a lone quote'; Items = @('"') }
            @{ Name = 'two quotes'; Items = @('""') }
            @{ Name = 'one backslash'; Items = @('\') }
            @{ Name = 'two backslashes'; Items = @('\\') }
            @{ Name = 'trailing backslash with a space'; Items = @('C:\Program Files\x\') }
            @{ Name = 'trailing backslash without a space'; Items = @('C:\dir\') }
            @{ Name = 'backslash before a quote'; Items = @('a\"b') }
            @{ Name = 'two backslashes before a quote'; Items = @('a\\"b c') }
            @{ Name = 'three backslashes before a quote'; Items = @('a\\\"b') }
            @{ Name = 'leading and trailing spaces'; Items = @(' lead', 'trail ') }
            @{ Name = 'a tab'; Items = @("tab`there") }
            @{ Name = 'a newline'; Items = @("line1`nline2") }
            @{ Name = 'accented letters'; Items = @("caf$e9 cr${e9}me") }
            @{ Name = 'CJK text'; Items = @("$cjk $cjk", $cjk) }
            @{ Name = 'an emoji outside the BMP'; Items = @("smile $emoji now") }
            @{ Name = 'a ProxyCommand option'; Items = @('-o', 'ProxyCommand=powershell.exe -File "C:\a b\x.ps1" --proxy %h %p %n') }
            @{ Name = 'a Windows path with spaces and a quote'; Items = @('C:\Users\Jo Doe\"x y"\') }
            @{ Name = 'a long argument'; Items = @(('ab "c" \ ' * 600)) }
        )
    }

    It 'round-trips <Name>' -ForEach $cases {
        $back = Get-RoundTrip $Items
        Format-ArgList $back | Should -BeExactly (Format-ArgList $Items)
    }

    It 'round-trips the real upload command' {
        $parsed = Split-SshArguments @('-i', 'C:\Users\Jo Doe\.ssh\id key', '-p', '2222', 'user@host')
        $argv = Get-UploadSshArguments -Parsed $parsed -Hash '0123456789abcdef0123456789abcdef' -Size 5000 -SshVersion ([version]'9.0')
        $back = Get-RoundTrip $argv
        Format-ArgList $back | Should -BeExactly (Format-ArgList $argv)
        $back[-1] | Should -Match "^sh -c 'umask 077;.* ssh-paste 0123456789abcdef0123456789abcdef 5000 png 1440 '/tmp'$"
    }

    It 'round-trips 1000 random argument lists' {
        $rng = New-Object System.Random 20260101
        $alphabet = @('a', 'b', ' ', ' ', '"', '\', '\', "`t", '-', '=', '%')
        $failures = @()
        for ($n = 0; $n -lt 1000; $n++) {
            $items = @()
            $count = $rng.Next(0, 5)
            for ($k = 0; $k -lt $count; $k++) {
                $len = $rng.Next(0, 10)
                $sb = New-Object System.Text.StringBuilder
                for ($c = 0; $c -lt $len; $c++) { [void]$sb.Append($alphabet[$rng.Next(0, $alphabet.Count)]) }
                $items += $sb.ToString()
            }
            $back = Get-RoundTrip $items
            if ((Format-ArgList $back) -cne (Format-ArgList $items)) { $failures += (Format-ArgList $items) }
        }
        $failures.Count | Should -Be 0 -Because ('first failure: ' + ($failures | Select-Object -First 1))
    }
}

Describe 'Split-CommandLine' {
    It 'splits on spaces and tabs' {
        Format-ArgList (Split-CommandLine "ssh  -p`t22   host") | Should -BeExactly '["ssh","-p","22","host"]'
    }

    It 'treats backslashes in the program name literally' {
        Format-ArgList (Split-CommandLine 'C:\Windows\System32\OpenSSH\ssh.exe -V') | Should -BeExactly '["C:\\Windows\\System32\\OpenSSH\\ssh.exe","-V"]'
    }

    It 'handles a quoted program name with spaces' {
        Format-ArgList (Split-CommandLine '"C:\Program Files\OpenSSH\ssh.exe" host') | Should -BeExactly '["C:\\Program Files\\OpenSSH\\ssh.exe","host"]'
    }

    It 'applies the backslash and quote rules' {
        Format-ArgList (Split-CommandLine 'p "a b" a\"b a\\b "c\\"') | Should -BeExactly '["p","a b","a\"b","a\\\\b","c\\"]'
    }

    It 'returns nothing for an empty line' {
        @(Split-CommandLine '').Count | Should -Be 0
    }
}

Describe 'Set-ProcessArguments' {
    BeforeAll {
        # The real function takes a ProcessStartInfo, which on PowerShell 7 always has
        # ArgumentList. To run the Windows PowerShell 5.1 branch here, take the real
        # function body from the source and drop only the parameter's type, so that a
        # plain object without ArgumentList can be passed.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CorePath, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq 'Set-ProcessArguments' }, $true)
        $typed = '[System.Diagnostics.ProcessStartInfo]$StartInfo'
        $script:FakeFunctionText = $fn.Extent.Text.Replace($typed, '$StartInfo').Replace('function Set-ProcessArguments', 'function Set-ProcessArgumentsUntyped')
        $script:FakeIsValid = ($fn.Extent.Text.Contains($typed) -and $script:FakeFunctionText.Contains('function Set-ProcessArgumentsUntyped'))
        . ([scriptblock]::Create($script:FakeFunctionText))
    }

    It 'could extract the real function for the 5.1 branch test' {
        $script:FakeIsValid | Should -BeTrue -Because 'the parameter list of Set-ProcessArguments changed; update this test'
    }

    It 'fills ArgumentList when the runtime has it, otherwise Arguments' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $items = @('-o', 'a b', '', 'say "hi"', 'C:\dir with space\')
        Set-ProcessArguments $psi $items
        if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
            Format-ArgList @($psi.ArgumentList) | Should -BeExactly (Format-ArgList $items)
            $psi.Arguments | Should -BeExactly ''
        } else {
            $psi.Arguments | Should -BeExactly (Join-NativeArguments $items)
        }
    }

    It 'builds the Arguments string when there is no ArgumentList (Windows PowerShell 5.1 path)' {
        $items = @('-o', 'a b', '', 'say "hi"', 'C:\dir with space\')
        $fake = [pscustomobject]@{ Arguments = '' }
        $fake.PSObject.Properties['ArgumentList'] | Should -BeNullOrEmpty
        Set-ProcessArgumentsUntyped $fake $items
        $fake.Arguments | Should -BeExactly '-o "a b" "" "say \"hi\"" "C:\dir with space\\"'
        Format-ArgList @((Split-CommandLine ('prog ' + $fake.Arguments)) | Select-Object -Skip 1) | Should -BeExactly (Format-ArgList $items)
    }

    It 'uses ArgumentList when the object has one (PowerShell 7 path)' {
        $fake = [pscustomobject]@{ Arguments = ''; ArgumentList = (New-Object System.Collections.Generic.List[string]) }
        Set-ProcessArgumentsUntyped $fake @('a b', 'c')
        Format-ArgList @($fake.ArgumentList) | Should -BeExactly '["a b","c"]'
        $fake.Arguments | Should -BeExactly ''
    }

    It 'accepts no arguments on both paths' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        { Set-ProcessArguments $psi $null } | Should -Not -Throw
        $fake = [pscustomobject]@{ Arguments = 'old' }
        Set-ProcessArgumentsUntyped $fake $null
        $fake.Arguments | Should -BeExactly ''
    }
}

Describe 'Split-SshArguments' {
    It 'finds the destination' {
        $p = Split-SshArguments @('myhost')
        $p.Destination | Should -BeExactly 'myhost'
        @($p.Options).Count | Should -Be 0
        @($p.Command).Count | Should -Be 0
    }

    It 'returns no destination for no arguments' {
        $p = Split-SshArguments @()
        $p.Destination | Should -BeNullOrEmpty
        (Split-SshArguments $null).Destination | Should -BeNullOrEmpty
    }

    It 'reads an option argument that is glued to the letter' {
        $p = Split-SshArguments @('-p2222', 'h')
        Format-Options $p | Should -BeExactly 'p=2222'
        $p.Destination | Should -BeExactly 'h'
    }

    It 'reads an option argument that is a separate token' {
        Format-Options (Split-SshArguments @('-p', '2222', '-i', 'C:\k y', 'h')) | Should -BeExactly 'p=2222 i=C:\k y'
    }

    It 'reads -oKey=Value glued and separate' {
        Format-Options (Split-SshArguments @('-oPort=22', 'h')) | Should -BeExactly 'o=Port=22'
        Format-Options (Split-SshArguments @('-o', 'Port=22', 'h')) | Should -BeExactly 'o=Port=22'
    }

    It 'splits clusters of flags' {
        Format-Options (Split-SshArguments @('-vT', 'h')) | Should -BeExactly 'v T'
        Format-Options (Split-SshArguments @('-vvv', 'h')) | Should -BeExactly 'v v v'
    }

    It 'lets a cluster end in an option with an argument' {
        Format-Options (Split-SshArguments @('-vp2222', 'h')) | Should -BeExactly 'v p=2222'
        Format-Options (Split-SshArguments @('-vp', '2222', 'h')) | Should -BeExactly 'v p=2222'
        Format-Options (Split-SshArguments @('-tti', 'key', 'h')) | Should -BeExactly 't t i=key'
    }

    It 'distinguishes -t from -T and -N from -n' {
        Format-Options (Split-SshArguments @('-t', '-T', '-N', '-n', 'h')) | Should -BeExactly 't T N n'
    }

    It 'accepts options after the destination' {
        $p = Split-SshArguments @('h', '-p', '22', '-v')
        $p.Destination | Should -BeExactly 'h'
        Format-Options $p | Should -BeExactly 'p=22 v'
        @($p.Command).Count | Should -Be 0
    }

    It 'remembers which side of the destination each option was on' {
        $p = Split-SshArguments @('-p', '1', '-vi', 'k', 'alice@h', '-o', 'User=bob', '-t')
        $sides = @($p.Options | ForEach-Object { $_.Flag + ':' + $_.After })
        ($sides -join ' ') | Should -BeExactly 'p:False v:False i:False o:True t:True'
        $p.Destination | Should -BeExactly 'alice@h'
    }

    It 'marks every option as before the destination when the destination comes last' {
        $p = Split-SshArguments @('-v', '-p', '1', 'h')
        @($p.Options | Where-Object { $_.After }).Count | Should -Be 0
    }

    It 'does not read options after the first word of the command' {
        $p = Split-SshArguments @('h', '-v', 'ls', '-l', '-o', 'x')
        Format-Options $p | Should -BeExactly 'v'
        Format-ArgList $p.Command | Should -BeExactly '["ls","-l","-o","x"]'
    }

    It 'starts the command at the first word after the destination' {
        $p = Split-SshArguments @('-p', '22', 'h', 'echo', '-n', 'hi there')
        $p.Destination | Should -BeExactly 'h'
        Format-Options $p | Should -BeExactly 'p=22'
        Format-ArgList $p.Command | Should -BeExactly '["echo","-n","hi there"]'
    }

    It 'treats everything after -- as destination and command' {
        $p = Split-SshArguments @('-v', '--', 'h', 'ls', '-l')
        $p.Destination | Should -BeExactly 'h'
        Format-Options $p | Should -BeExactly 'v'
        Format-ArgList $p.Command | Should -BeExactly '["ls","-l"]'
    }

    It 'handles -- after the destination' {
        $p = Split-SshArguments @('h', '--', '-l')
        $p.Destination | Should -BeExactly 'h'
        Format-ArgList $p.Command | Should -BeExactly '["-l"]'
    }

    It 'keeps ssh:// URIs as the destination unchanged' {
        $p = Split-SshArguments @('ssh://user@host:2222/')
        $p.Destination | Should -BeExactly 'ssh://user@host:2222/'
    }

    It 'throws when an option is missing its argument' {
        { Split-SshArguments @('-p') } | Should -Throw '*-p needs an argument*'
        { Split-SshArguments @('-vi') } | Should -Throw '*-i needs an argument*'
        { Split-SshArguments @('h', '-o') } | Should -Throw '*-o needs an argument*'
    }

    It 'throws on an unknown option' {
        { Split-SshArguments @('-j', 'h') } | Should -Throw '*unknown ssh option -j*'
        { Split-SshArguments @('-vH', 'h') } | Should -Throw '*unknown ssh option -H*'
    }

    It 'does not parse options that belong to the remote command' {
        $p = Split-SshArguments @('h', 'ls', '-j')
        Format-ArgList $p.Command | Should -BeExactly '["ls","-j"]'
    }

    It 'takes the value of a flag with an argument even if it looks like an option' {
        Format-Options (Split-SshArguments @('-o', '-weird', 'h')) | Should -BeExactly 'o=-weird'
    }

    It 'covers every flag in ssh.c getopt string' {
        foreach ($letter in '1246ACGKMNTVXYZafgknqstvxy'.ToCharArray()) {
            Format-Options (Split-SshArguments @("-$letter", 'h')) | Should -BeExactly ([string]$letter)
        }
        foreach ($letter in 'BDEFIJLOPQRSWbceilmopw'.ToCharArray()) {
            Format-Options (Split-SshArguments @(("-$letter" + 'x'), 'h')) | Should -BeExactly ("$letter=x")
        }
    }
}

Describe 'Test-InteractiveSsh' {
    It '<Name>' -ForEach $sharedCases.interactive {
        $p = Split-SshArguments $Argv
        Test-InteractiveSsh $p | Should -Be $Expected
    }

    # ssh skips white space before the keyword of an -o setting, so ' RequestTTY=no' is RequestTTY=no.
    # Test-InteractiveSsh trims the key (Get-SshOptionKey) but not the value: with the leading space,
    # '-o " RequestTTY=no"' is read as the value "requesttty=no", which is neither no nor false.
    # Patch, line 170: $value = ([string](($o.Value.TrimStart()) -split '[=\s]+', 2)[-1]).Trim().ToLowerInvariant()
    It 'reads an -o setting with white space before its name, as ssh does' {
        Test-InteractiveSsh (Split-SshArguments @('-o', ' RequestTTY=no', 'host')) | Should -BeFalse
        Test-InteractiveSsh (Split-SshArguments @('-o', ' StdinNull=yes', 'host')) | Should -BeFalse
        Test-InteractiveSsh (Split-SshArguments @('-o', ' SessionType=none', 'host')) | Should -BeFalse
    }

    It 'takes the effective ssh -G settings into account: <Name>' -ForEach $sharedCases.interactiveEffective {
        Test-InteractiveSsh (Split-SshArguments $Argv) $Effective | Should -Be $Expected
    }

    It 'treats a $null effective map like no map' {
        Test-InteractiveSsh (Split-SshArguments @('host')) $null | Should -BeTrue
        Test-InteractiveSsh (Split-SshArguments @('host', 'uname')) $null | Should -BeFalse
    }

    It 'is false for null' {
        Test-InteractiveSsh $null | Should -BeFalse
    }

    It 'is case sensitive about -t and -T' {
        Test-InteractiveSsh (Split-SshArguments @('-T', 'host', 'cmd')) | Should -BeFalse
        Test-InteractiveSsh (Split-SshArguments @('-t', 'host', 'cmd')) | Should -BeTrue
    }

    It 'lets the last of -t and -T win, as ssh does: <Name>' -ForEach $sharedCases.lastTtyWins {
        Test-InteractiveSsh (Split-SshArguments $Argv) | Should -Be $Expected
    }

    It 'is false when -N, -W, -f and the like come after the destination too' {
        Test-InteractiveSsh (Split-SshArguments @('host', '-N')) | Should -BeFalse
        Test-InteractiveSsh (Split-SshArguments @('host', '-W', 'x:22')) | Should -BeFalse
    }

    It 'is false for an empty destination' {
        Test-InteractiveSsh ([pscustomobject]@{ Destination = ''; Options = @(); Command = @() }) | Should -BeFalse
    }
}

Describe 'Get-UploadSshArguments' {
    BeforeAll {
        $script:Hash = '0123456789abcdef0123456789abcdef'
        function Get-Upload {
            param([string[]]$Argv, [switch]$NoProxy, $SshVersion, [long]$Size = 1234, [hashtable]$Pin)
            return @(Get-UploadSshArguments -Parsed (Split-SshArguments $Argv) -Hash $script:Hash -Size $Size -NoProxy:$NoProxy -SshVersion $SshVersion -Pin $Pin)
        }
        function Get-OptionPart {
            # Everything except the last argument, which is the remote command text.
            param([string[]]$Arguments)
            return @($Arguments | Select-Object -SkipLast 1)
        }
    }

    It 'starts with -T -x and then the hardening options' {
        $a = Get-Upload @('host')
        $a[0] | Should -BeExactly '-T'
        $a[1] | Should -BeExactly '-x'
        $joined = $a -join ' '
        foreach ($o in @('BatchMode=yes', 'PermitLocalCommand=no', 'ClearAllForwardings=yes', 'RemoteCommand=none',
                'RequestTTY=no', 'ForwardAgent=no', 'ControlMaster=no', 'ControlPath=none', 'ConnectTimeout=10',
                'ServerAliveInterval=10', 'ServerAliveCountMax=2', 'LogLevel=ERROR')) {
            $joined | Should -Match ('-o ' + [regex]::Escape($o))
        }
    }

    It 'puts every hardening option before any option from the user, on either side of the destination' {
        # ssh keeps the first value it sees for an option, so ours must come first.
        # (BatchMode, ControlMaster and the like are dropped from the user's options, not just outranked.)
        $a = Get-Upload @('-o', 'ConnectTimeout=99', '-F', 'cfg', 'host', '-o', 'ServerAliveInterval=99')
        [array]::IndexOf($a, 'ConnectTimeout=10') | Should -BeGreaterThan 0
        [array]::IndexOf($a, 'ConnectTimeout=10') | Should -BeLessThan ([array]::IndexOf($a, 'ConnectTimeout=99'))
        [array]::IndexOf($a, 'ServerAliveInterval=10') | Should -BeLessThan ([array]::IndexOf($a, 'ServerAliveInterval=99'))
        [array]::IndexOf($a, 'LogLevel=ERROR') | Should -BeLessThan ([array]::IndexOf($a, '-F'))
        $a | Should -Not -Contain 'ControlMaster=auto'
    }

    It 'keeps options that identify the server and the credentials' {
        $a = Get-Upload @('-4', '-C', '-i', 'C:\k y', '-p', '2222', '-l', 'me', '-F', 'cfg', '-o', 'IdentitiesOnly=yes', '-b', '10.0.0.1', '-c', 'aes128-ctr', '-m', 'hmac-sha2-256', 'host')
        $a | Should -Contain '-4'
        $a | Should -Contain '-C'
        foreach ($pair in @(@('-i', 'C:\k y'), @('-p', '2222'), @('-l', 'me'), @('-F', 'cfg'), @('-o', 'IdentitiesOnly=yes'), @('-b', '10.0.0.1'), @('-c', 'aes128-ctr'), @('-m', 'hmac-sha2-256'))) {
            $i = [array]::LastIndexOf($a, $pair[0])
            $i | Should -BeGreaterThan 1
            $a[$i + 1] | Should -BeExactly $pair[1]
        }
    }

    It 'keeps the user options in their original order' {
        $a = Get-Upload @('-p', '1', '-i', 'k', '-l', 'u', 'host')
        $positions = @([array]::LastIndexOf($a, '-p'), [array]::LastIndexOf($a, '-i'), [array]::LastIndexOf($a, '-l'))
        $positions[0] | Should -BeLessThan $positions[1]
        $positions[1] | Should -BeLessThan $positions[2]
    }

    Context 'options before and after the destination' {
        # ssh applies the destination's user@ and :port between its two option
        # passes, so `alice@h -o User=bob` means bob: the -o must stay after it.
        It 'keeps an option after the destination after it' {
            $a = Get-Upload @('alice@h', '-o', 'User=bob')
            $d = [array]::IndexOf($a, 'alice@h')
            $d | Should -BeGreaterThan 1
            $o = [array]::LastIndexOf($a, 'User=bob')
            $o | Should -BeGreaterThan $d
            $a[$o - 1] | Should -BeExactly '-o'
        }

        It 'keeps an option before the destination before it' {
            $a = Get-Upload @('-o', 'User=bob', 'alice@h')
            $d = [array]::IndexOf($a, 'alice@h')
            [array]::LastIndexOf($a, 'User=bob') | Should -BeLessThan $d
        }

        It 'splits a mixed command line at the destination and keeps each side in order' {
            $a = Get-Upload @('-p', '1', '-i', 'k1', 'alice@h', '-l', 'zed', '-i', 'k2')
            $d = [array]::IndexOf($a, 'alice@h')
            $d | Should -BeGreaterThan 1
            [array]::IndexOf($a, '-p') | Should -BeLessThan ([array]::IndexOf($a, 'k1'))
            [array]::IndexOf($a, 'k1') | Should -BeLessThan $d
            [array]::IndexOf($a, '-l') | Should -BeGreaterThan $d
            [array]::IndexOf($a, 'zed') | Should -BeLessThan ([array]::LastIndexOf($a, '-i'))
            [array]::LastIndexOf($a, 'k2') | Should -Be ($a.Count - 2)
            $a[$a.Count - 1] | Should -Match '^sh -c '
        }

        It 'never uses -- to end the options' {
            (Get-Upload @('-p', '22', 'user@host')) | Should -Not -Contain '--'
            (Get-Upload @('user@host', '-p', '22')) | Should -Not -Contain '--'
        }

        It 'puts the destination right before the options that came after it, and the command last' {
            $a = Get-Upload @('host', '-p', '22')
            $a[$a.Count - 4] | Should -BeExactly 'host'
            $a[$a.Count - 3] | Should -BeExactly '-p'
            $a[$a.Count - 2] | Should -BeExactly '22'
            $a[$a.Count - 1] | Should -Match '^sh -c '
        }
    }

    Context 'options that ssh-paste pins for ssh 8.7 and newer' {
        It 'adds StdinNull, SessionType and ForkAfterAuthentication from ssh <Version> on' -ForEach @(
            @{ Version = '8.7'; Expected = $true }
            @{ Version = '8.8'; Expected = $true }
            @{ Version = '8.10'; Expected = $true }
            @{ Version = '9.9'; Expected = $true }
            @{ Version = '10.0'; Expected = $true }
            @{ Version = '8.6'; Expected = $false }
            @{ Version = '7.9'; Expected = $false }
            @{ Version = '8.1'; Expected = $false }
        ) {
            $a = Get-Upload @('host') -SshVersion ([version]$Version)
            $joined = ' ' + ($a -join ' ') + ' '
            foreach ($pin in @('StdinNull=no', 'SessionType=default', 'ForkAfterAuthentication=no')) {
                ($joined.Contains(' ' + $pin + ' ')) | Should -Be $Expected -Because "$pin with ssh $Version"
            }
        }

        It 'adds none of them when the version is unknown' {
            $joined = (Get-Upload @('host') -SshVersion $null) -join ' '
            $joined | Should -Not -Match 'StdinNull|SessionType|ForkAfterAuthentication'
        }

        It 'puts the pins before the user options, so the user cannot override them' {
            $a = Get-Upload @('-o', 'StdinNull=yes', '-o', 'SessionType=none', 'host') -SshVersion ([version]'9.0')
            [array]::IndexOf($a, 'StdinNull=no') | Should -BeGreaterThan 0
            [array]::IndexOf($a, 'StdinNull=no') | Should -BeLessThan ([array]::IndexOf($a, 'host'))
            $a | Should -Not -Contain 'StdinNull=yes'
            $a | Should -Not -Contain 'SessionType=none'
        }
    }

    Context 'user -o settings that are dropped' {
        It 'drops every setting in the drop list, in any case, on either side, in every spelling' {
            $leaked = @()
            foreach ($key in $script:SshDropOptions) {
                $variants = @(
                    @('-o', ($key + '=USERVAL'), 'host'),
                    @('-o', ($key.ToUpperInvariant() + '=USERVAL'), 'host'),
                    @('-o', ($key + ' USERVAL'), 'host'),
                    @(('-o' + $key + '=USERVAL'), 'host'),
                    @('host', '-o', ($key + '=USERVAL')),
                    @('host', '-o', ($key + ' = USERVAL'))
                )
                foreach ($argv in $variants) {
                    $joined = (Get-OptionPart (Get-Upload $argv)) -join ' '
                    if ($joined.Contains('USERVAL')) { $leaked += ($argv -join ' ') }
                }
            }
            $leaked.Count | Should -Be 0 -Because ('leaked: ' + ($leaked -join ' | '))
        }

        It 'lists the settings that would break or redirect the upload connection' {
            foreach ($key in @('requesttty', 'remotecommand', 'localforward', 'remoteforward', 'dynamicforward', 'controlmaster',
                    'controlpath', 'controlpersist', 'forwardagent', 'forwardx11', 'batchmode', 'stdinnull', 'sessiontype',
                    'forkafterauthentication', 'proxyusefdpass', 'loglevel', 'permitlocalcommand', 'localcommand')) {
                $script:SshDropOptions | Should -Contain $key
            }
            foreach ($key in $script:SshDropOptions) { $key | Should -BeExactly $key.ToLowerInvariant() }
        }

        It 'keeps the other -o settings, including ProxyCommand and ProxyJump when the proxy is not ours' {
            $a = Get-Upload @('-o', 'IdentitiesOnly=yes', '-o', 'ProxyCommand=ssh -W %h:%p jump', '-o', 'ProxyJump=j2', '-o', 'HostKeyAlgorithms=ssh-ed25519', 'host')
            $a | Should -Contain 'IdentitiesOnly=yes'
            $a | Should -Contain 'ProxyCommand=ssh -W %h:%p jump'
            $a | Should -Contain 'ProxyJump=j2'
            $a | Should -Contain 'HostKeyAlgorithms=ssh-ed25519'
        }

        It 'drops the options that would change what the upload connection does' {
            $a = Get-Upload @('-A', '-X', '-Y', '-g', '-k', '-q', '-v', '-a', '-t', '-L', '1:h:2', '-R', '3:h:4', '-D', '5', '-E', 'log', '-S', 'ctl', '-w', '0:0', '-e', '^', '-s', '-V', 'host')
            $joined = ' ' + ((Get-OptionPart $a) -join ' ') + ' '
            foreach ($bad in @(' -A ', ' -X ', ' -Y ', ' -g ', ' -k ', ' -q ', ' -v ', ' -a ', ' -t ', ' -L ', ' -R ', ' -D ', ' -E ', ' -S ', ' -w ', ' -e ', ' -s ', ' -V ')) {
                $joined | Should -Not -MatchExactly ([regex]::Escape($bad)) -Because "$bad must not reach the upload connection"
            }
            $joined | Should -Not -Match ' 1:h:2 '
        }

        It 'does not let the user turn the command into something else' {
            $a = Get-Upload @('-N', '-f', '-W', 'x:1', 'host')
            ((Get-OptionPart $a) -join ' ') | Should -Not -MatchExactly ' -[NfW] '
        }
    }

    Context 'with -NoProxy (ssh-paste is the ProxyCommand of this connection)' {
        It 'keeps -J without -NoProxy and drops it with -NoProxy' {
            $a = Get-Upload @('-J', 'jump', 'host')
            $a | Should -Contain '-J'
            $a[[array]::IndexOf($a, '-J') + 1] | Should -BeExactly 'jump'
            $b = Get-Upload @('-J', 'jump', 'host') -NoProxy
            $b | Should -Not -Contain '-J'
            $b | Should -Not -Contain 'jump'
        }

        It 'drops ProxyCommand and ProxyJump settings on either side of the destination, in any case' {
            $b = Get-Upload @('-o', 'ProxyCommand=evil', '-o', 'proxyjump=evil2', 'host', '-o', 'PROXYCOMMAND=evil3', '-oProxyJump=evil4', '-J', 'evil5') -NoProxy
            ((Get-OptionPart $b) -join ' ') | Should -Not -Match 'evil'
        }

        It 'adds ProxyCommand=none only with -NoProxy, before the user options' {
            $a = Get-Upload @('host')
            ($a -join ' ') | Should -Not -Match 'ProxyCommand'
            $b = Get-Upload @('-o', 'IdentitiesOnly=yes', 'host') -NoProxy
            [array]::IndexOf($b, 'ProxyCommand=none') | Should -BeGreaterThan 0
            [array]::IndexOf($b, 'ProxyCommand=none') | Should -BeLessThan ([array]::IndexOf($b, 'IdentitiesOnly=yes'))
        }
    }

    Context 'with -Pin (ssh mode: upload to the address the relay is connected to)' {
        BeforeAll {
            $script:Pin = @{ HostName = '203.0.113.7'; Port = 2200; HostKeyAlias = '[myhost]:2200' }
        }

        It 'adds HostName, Port, HostKeyAlias, CheckHostIP=no and CanonicalizeHostname=no' {
            $a = Get-Upload @('host') -NoProxy -Pin $script:Pin
            foreach ($o in @('HostName=203.0.113.7', 'Port=2200', 'HostKeyAlias=[myhost]:2200', 'CheckHostIP=no', 'CanonicalizeHostname=no')) {
                $i = [array]::IndexOf($a, $o)
                $i | Should -BeGreaterThan 1 -Because $o
                $a[$i - 1] | Should -BeExactly '-o' -Because $o
            }
        }

        It 'puts them right after ProxyCommand=none and before every user option and the destination' {
            $a = Get-Upload @('-p', '2222', '-o', 'HostName=evil', '-o', 'IdentitiesOnly=yes', 'me@host', '-o', 'Port=1') -NoProxy -Pin $script:Pin
            $none = [array]::IndexOf($a, 'ProxyCommand=none')
            $none | Should -BeGreaterThan 0
            $a[$none + 1] | Should -BeExactly '-o'
            $a[$none + 2] | Should -BeExactly 'HostName=203.0.113.7'
            $last = [array]::IndexOf($a, 'CanonicalizeHostname=no')
            $last | Should -BeGreaterThan $none
            foreach ($user in @('-p', 'HostName=evil', 'IdentitiesOnly=yes', 'me@host', 'Port=1')) {
                [array]::IndexOf($a, $user) | Should -BeGreaterThan $last -Because "$user comes from the user, so ssh must see ours first"
            }
        }

        It 'adds none of them without a pin' {
            ((Get-Upload @('host') -NoProxy) -join ' ') | Should -Not -Match 'HostName=|Port=|HostKeyAlias|CheckHostIP|CanonicalizeHostname'
            ((Get-Upload @('host')) -join ' ') | Should -Not -Match 'HostKeyAlias|CheckHostIP|CanonicalizeHostname'
        }

        It 'works without -NoProxy too, and keeps the command last' {
            $a = Get-Upload @('host') -Pin $script:Pin
            $a | Should -Contain 'HostKeyAlias=[myhost]:2200'
            $a | Should -Not -Contain 'ProxyCommand=none'
            $a[$a.Count - 1] | Should -Match '^sh -c '
        }
    }

    It 'makes the last argument exactly the sh -c command with the hash, the size, the minutes to keep and the folder' {
        $a = Get-Upload @('host') -Size 4321
        $a[$a.Count - 1] | Should -BeExactly ("sh -c '" + $script:RemoteScript + "' ssh-paste " + $script:Hash + " 4321 png 1440 '/tmp'")
    }

    It 'passes --keep as minutes and as the class of the name, and an absolute --dir in single quotes' {
        $parsed = Split-SshArguments @('host')
        $a = @(Get-UploadSshArguments -Parsed $parsed -Hash $script:Hash -Size 9 -Keep 'never' -Dir '/home/u/shots')
        $a[$a.Count - 1] | Should -BeExactly ("sh -c '" + $script:RemoteScript + "' ssh-paste " + $script:Hash + " 9 png 0 '/home/u/shots' knever-")
        { Get-UploadSshArguments -Parsed $parsed -Hash $script:Hash -Size 9 -Dir '~/shots' } | Should -Throw '*bad --dir*'
        $a = @(Get-UploadSshArguments -Parsed $parsed -Hash $script:Hash -Size 9 -Keep '2h')
        $a[$a.Count - 1] | Should -BeExactly ("sh -c '" + $script:RemoteScript + "' ssh-paste " + $script:Hash + " 9 png 120 '/tmp' k2h-")
        { Get-UploadSshArguments -Parsed $parsed -Hash $script:Hash -Size 9 -Dir "/tmp'x" } | Should -Throw '*bad --dir*'
        { Get-UploadSshArguments -Parsed $parsed -Hash $script:Hash -Size 9 -Keep '1w' } | Should -Throw '*--keep*'
    }

    It 'does not pass the remote command of the user session along' {
        $a = Get-Upload @('host', 'rm', '-rf', '/')
        ($a -join ' ') | Should -Not -Match 'rm -rf'
        $a[$a.Count - 2] | Should -BeExactly 'host'
    }

    It 'rejects anything that is not 32 lower-case hex digits' {
        $parsed = Split-SshArguments @('host')
        $good = '0123456789abcdef0123456789abcdef'
        foreach ($bad in @('', 'abc', '../x.png', '0123456789abcdef0123456789abcdef.png', '0123456789abcdef0123456789abcde',
                '0123456789abcdef0123456789abcdef0', '0123456789ABCDEF0123456789ABCDEF', '0123456789abcdef0123456789abcdeg',
                ($good + "`n"), ("`n" + $good), (' ' + $good), ($good + ' x'), ($good + ';id'), ('/tmp/' + $good), ('$(id)' + $good.Substring(5)))) {
            { Get-UploadSshArguments -Parsed $parsed -Hash $bad -Size 1 } | Should -Throw '*bad image hash*' -Because "'$bad' must be rejected"
        }
        { Get-UploadSshArguments -Parsed $parsed -Hash $good -Size 1 } | Should -Not -Throw
    }
}

Describe 'Get-ImageHash' {
    It 'is the first 16 bytes of SHA-256 in lower-case hex' {
        Get-ImageHash ([byte[]]@()) | Should -BeExactly 'e3b0c44298fc1c149afbf4c8996fb924'
        Get-ImageHash ([System.Text.Encoding]::ASCII.GetBytes('abc')) | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223'
    }

    It 'is always 32 lower-case hex digits, so it is a valid remote name' {
        $rng = New-Object System.Random 7
        foreach ($size in @(1, 2, 100, 5000)) {
            $bytes = New-Object byte[] $size
            $rng.NextBytes($bytes)
            Get-ImageHash $bytes | Should -Match '^[0-9a-f]{32}$'
        }
    }

    It 'differs when one byte differs' {
        $a = [byte[]](1..50)
        $b = [byte[]](1..50)
        $b[49] = 99
        Get-ImageHash $a | Should -Not -BeExactly (Get-ImageHash $b)
    }
}

Describe 'Copied image files (CF_HDROP)' {
    BeforeAll {
        function New-Drop {
            param([string[]]$Paths, [bool]$Wide)
            $enc = [System.Text.Encoding]::ASCII
            if ($Wide) { $enc = [System.Text.Encoding]::Unicode }
            $body = $enc.GetBytes((($Paths -join [char]0) + [char]0 + [char]0))
            $head = New-Object byte[] 20
            [BitConverter]::GetBytes(20).CopyTo($head, 0)
            [BitConverter]::GetBytes([int]$Wide).CopyTo($head, 16)
            return , ([byte[]]($head + $body))
        }
        $script:DropDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-drop-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:DropDir)
        $script:ImgA = Join-Path $script:DropDir 'shot one.png'
        $script:ImgB = Join-Path $script:DropDir 'photo.JPG'
        $script:Txt = Join-Path $script:DropDir 'notes.txt'
        [System.IO.File]::WriteAllBytes($script:ImgA, [byte[]](1..120))
        [System.IO.File]::WriteAllBytes($script:ImgB, [byte[]](1..90))
        [System.IO.File]::WriteAllText($script:Txt, 'x')
    }
    AfterAll { Remove-Item -LiteralPath $script:DropDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads the paths of a wide (Unicode) drop list' {
        @(ConvertFrom-DropFiles (New-Drop @($script:ImgA, $script:ImgB) $true)) | Should -Be @($script:ImgA, $script:ImgB)
    }
    It 'reads the paths of an ANSI drop list' {
        @(ConvertFrom-DropFiles (New-Drop @($script:ImgA) $false)) | Should -Be @($script:ImgA)
    }
    It 'returns nothing for bytes that are not a drop list' {
        @(ConvertFrom-DropFiles ([byte[]](1..10))).Count | Should -Be 0
        @(ConvertFrom-DropFiles $null).Count | Should -Be 0
    }
    It 'turns image files into upload items with their lowercase extension and content hash' {
        $items = Read-ImageFiles @($script:ImgA, $script:ImgB)
        $items.Count | Should -Be 2
        $items[0].Ext | Should -BeExactly 'png'
        $items[1].Ext | Should -BeExactly 'jpg'
        $items[1].Hash | Should -BeExactly (Get-ImageHash ([System.IO.File]::ReadAllBytes($script:ImgB)))
    }
    It 'leaves the files alone when one of them is not an image, is missing, or there are too many' {
        Read-ImageFiles @($script:ImgA, $script:Txt) | Should -BeNullOrEmpty
        Read-ImageFiles @((Join-Path $script:DropDir 'missing.png')) | Should -BeNullOrEmpty
        Read-ImageFiles @(1..($script:MaxCopiedFiles + 1) | ForEach-Object { $script:ImgA }) | Should -BeNullOrEmpty
    }
    It 'accepts only the image extensions it uploads' {
        foreach ($e in @('png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp')) { Get-ImageFileExtension ('a.' + $e.ToUpperInvariant()) | Should -BeExactly $e }
        Get-ImageFileExtension 'a.exe' | Should -BeNullOrEmpty
        { Get-UploadSshArguments -Parsed (Split-SshArguments @('h')) -Hash ('a' * 32) -Size 1 -Ext 'exe' } | Should -Throw '*bad image extension*'
    }
    It 'pastes the remote paths of all files, separated by spaces, once every file is uploaded' {
        Mock Send-Image { return ('/tmp/ssh-paste-' + $Hash + '.' + $Ext) }
        $w = @{ SshPath = 'ssh'; SshVersion = $null; Parsed = (Split-SshArguments @('h')); NoProxy = $false; Pin = $null; Uploaded = @{}; Failed = @{}; WakeAt = [DateTime]::MaxValue }
        $items = Read-ImageFiles @($script:ImgA, $script:ImgB)
        $text = Get-UploadedPath $w @{ Items = $items }
        $text | Should -BeExactly ('/tmp/ssh-paste-' + $items[0].Hash + '.png /tmp/ssh-paste-' + $items[1].Hash + '.jpg')
        Should -Invoke Send-Image -Times 2 -Exactly
    }
    It 'with SSH_PASTE_DEBUG set, uploads with -v and drops LogLevel=ERROR together with its -o' {
        Mock Send-Image { $script:DebugArgs = $Arguments; return ('/tmp/ssh-paste-' + $Hash + '.' + $Ext) }
        $w = @{ SshPath = 'ssh'; SshVersion = $null; Parsed = (Split-SshArguments @('h')); NoProxy = $false; Pin = $null; Uploaded = @{}; Failed = @{}; WakeAt = [DateTime]::MaxValue }
        $item = (Read-ImageFiles @($script:ImgA))[0]
        $plain = @(Get-UploadSshArguments -Parsed $w.Parsed -Hash $item.Hash -Size $item.Bytes.Length -Ext $item.Ext)
        $i = [Array]::IndexOf([object[]]$plain, 'LogLevel=ERROR')
        $env:SSH_PASTE_DEBUG = '1'
        try { Get-UploadedItemPath $w $item | Should -Not -BeNullOrEmpty } finally { Remove-Item Env:SSH_PASTE_DEBUG }
        $expected = @('-v') + @(for ($k = 0; $k -lt $plain.Count; $k++) { if ($k -ne $i - 1 -and $k -ne $i) { $plain[$k] } })
        @($script:DebugArgs) | Should -BeExactly $expected
    }
    It 'uploads nothing more in the session after a failure that trying again cannot fix, and says why' {
        Mock Send-Image { throw 'ssh exited with 255: xu@h: Permission denied (password,keyboard-interactive).' }
        $w = @{ SshPath = 'ssh'; SshVersion = $null; Parsed = (Split-SshArguments @('h')); NoProxy = $false; Pin = $null; Uploaded = @{}; Failed = @{}; Blocked = $null; WakeAt = [DateTime]::MaxValue }
        $items = Read-ImageFiles @($script:ImgA, $script:ImgB)
        Get-UploadedPath $w @{ Items = $items } | Should -BeNullOrEmpty
        $w.Blocked | Should -BeExactly 'h wants a password or a one-time code (password,keyboard-interactive), which uploads cannot type, so ssh-paste cannot upload to it'
        Get-UploadedPath $w @{ Items = @($items[1]) } | Should -BeNullOrEmpty
        Should -Invoke Send-Image -Times 1 -Exactly
        Test-UploadFailing $w @{ Items = @(@{ Hash = 'another' }) } | Should -BeTrue
        Get-FailureSummary $w | Should -BeExactly ('ssh-paste: screenshot paste was off for this session: ' + $w.Blocked)
    }
    It 'tries again later when the server takes keys (the user may load one with ssh-add)' {
        Mock Send-Image { throw 'ssh exited with 255: xu@h: Permission denied (publickey,password).' }
        $w = @{ SshPath = 'ssh'; SshVersion = $null; Parsed = (Split-SshArguments @('h')); NoProxy = $false; Pin = $null; Uploaded = @{}; Failed = @{}; Blocked = $null; WakeAt = [DateTime]::MaxValue }
        $state = @{ Items = (Read-ImageFiles @($script:ImgA)) }
        Get-UploadedPath $w $state | Should -BeNullOrEmpty
        $w.Blocked | Should -BeNullOrEmpty
        foreach ($f in @($w.Failed.Values)) { $f.At = $f.At.AddMinutes(-1) }   # the 30-second backoff ran out
        Get-UploadedPath $w $state | Should -BeNullOrEmpty
        Should -Invoke Send-Image -Times 2 -Exactly
        Get-FailureSummary $w | Should -BeExactly 'ssh-paste: 1 screenshot upload(s) failed: h did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add; ssh-paste --doctor h shows how'
    }
    It 'pastes nothing while one of the files failed to upload' {
        Mock Send-Image { if ($Ext -eq 'jpg') { throw 'ssh exited with 255: refused' }; return ('/tmp/ssh-paste-' + $Hash + '.' + $Ext) }
        $w = @{ SshPath = 'ssh'; SshVersion = $null; Parsed = (Split-SshArguments @('h')); NoProxy = $false; Pin = $null; Uploaded = @{}; Failed = @{}; WakeAt = [DateTime]::MaxValue }
        Get-UploadedPath $w @{ Items = (Read-ImageFiles @($script:ImgA, $script:ImgB)) } | Should -BeNullOrEmpty
        $w.Failed.Count | Should -Be 1
    }
}

Describe 'Read-UploadReply' {
    BeforeAll {
        $script:H = '0123456789abcdef0123456789abcdef'
        $script:P = '/tmp/ssh-paste-0123456789abcdef0123456789abcdef.png'
    }

    It 'returns the path of a good reply' {
        Read-UploadReply "1234 $($script:P)`n" 1234 $script:H | Should -BeExactly $script:P
    }

    It 'accepts the per-user name that the server uses when another user owns the main name' {
        $mine = '/tmp/ssh-paste-0123456789abcdef0123456789abcdef-1000.png'
        Read-UploadReply "1234 $mine`n" 1234 $script:H | Should -BeExactly $mine
        $big = '/tmp/ssh-paste-0123456789abcdef0123456789abcdef-4294967295.png'
        Read-UploadReply "1234 $big`n" 1234 $script:H | Should -BeExactly $big
    }

    It 'accepts CRLF and a reply without a final newline' {
        Read-UploadReply "1234 $($script:P)`r`n" 1234 $script:H | Should -BeExactly $script:P
        Read-UploadReply "1234 $($script:P)" 1234 $script:H | Should -BeExactly $script:P
    }

    It 'ignores noise lines before the reply (login banners, motd, shell startup output)' {
        $text = "Welcome to Ubuntu`n`nLast login: Mon Nov 23`nsome rc output`n1234 $($script:P)`n`n"
        Read-UploadReply $text 1234 $script:H | Should -BeExactly $script:P
    }

    It 'rejects a reply whose size differs' {
        { Read-UploadReply "1233 $($script:P)" 1234 $script:H } | Should -Throw '*size mismatch*sent 1234*server has 1233*'
    }

    It 'throws on "short N" and says how much arrived' {
        { Read-UploadReply "short 10`n" 1234 $script:H } | Should -Throw '*received 10 of 1234 bytes*'
        { Read-UploadReply "banner`nshort 0`r`n" 1234 $script:H } | Should -Throw '*received 0 of 1234 bytes*'
    }

    It 'rejects a path that is not this image''s name: <Name>' -ForEach $sharedCases.badReplyPaths {
        { Read-UploadReply "1234 $Path" 1234 $script:H } | Should -Throw '*unexpected path*'
    }

    It 'rejects an empty reply' {
        { Read-UploadReply '' 1 $script:H } | Should -Throw '*no reply*'
        { Read-UploadReply "  `n`r`n " 1 $script:H } | Should -Throw '*no reply*'
        { Read-UploadReply $null 1 $script:H } | Should -Throw '*no reply*'
    }

    It 'rejects a last line that is not a reply, even if an earlier line looks like one' {
        { Read-UploadReply "1234 $($script:P)`nConnection closed." 1234 $script:H } | Should -Throw '*unexpected reply*Connection closed*'
        { Read-UploadReply 'Permission denied' 1 $script:H } | Should -Throw '*unexpected reply*'
        { Read-UploadReply "1234 $($script:P) extra" 1234 $script:H } | Should -Throw '*unexpected reply*'
        { Read-UploadReply "abc $($script:P)" 1234 $script:H } | Should -Throw '*unexpected reply*'
        { Read-UploadReply "short" 1234 $script:H } | Should -Throw '*unexpected reply*'
        { Read-UploadReply "short x" 1234 $script:H } | Should -Throw '*unexpected reply*'
    }

    It 'handles sizes beyond 32 bits' {
        Read-UploadReply "5000000000 $($script:P)" 5000000000 $script:H | Should -BeExactly $script:P
    }
}

Describe 'Test-HostResolves' {
    It 'finds localhost and an IP address, and not a name that cannot exist' {
        Test-HostResolves 'localhost' | Should -BeTrue
        Test-HostResolves '127.0.0.1' | Should -BeTrue
        Test-HostResolves 'no-such-host.invalid' | Should -BeFalse
    }
}

Describe 'Test-HostAlias' {
    It 'accepts <Name>' -ForEach $sharedCases.hostAliasAccept {
        Test-HostAlias $Value | Should -BeTrue
    }

    It 'rejects <Name>' -ForEach $sharedCases.hostAliasReject {
        Test-HostAlias $Value | Should -BeFalse
    }
}

Describe 'Get-ProxyCommandLine' {
    BeforeAll {
        # Join-Path rejects a drive that does not exist, so on Linux use a rooted path.
        $script:HadSystemRoot = [bool]$env:SystemRoot
        if (-not $script:HadSystemRoot) { $env:SystemRoot = '/winroot' }
        $script:Sep = '[\\/]'
    }
    AfterAll {
        if (-not $script:HadSystemRoot) { Remove-Item Env:\SystemRoot -ErrorAction SilentlyContinue }
    }

    It 'runs Windows PowerShell with the script and the ssh tokens' {
        $line = Get-ProxyCommandLine 'C:\Users\me\AppData\Local\Programs\ssh-paste\ssh-paste.ps1'
        $line | Should -Match '^.*powershell\.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\\Users\\me\\AppData\\Local\\Programs\\ssh-paste\\ssh-paste\.ps1" --proxy %h %p %n$'
    }

    It 'uses the in-box Windows PowerShell under SystemRoot' {
        $line = Get-ProxyCommandLine 'C:\x\ssh-paste.ps1'
        $sep = $script:Sep
        $line | Should -Match ('^' + [regex]::Escape($env:SystemRoot) + $sep + 'System32' + $sep + 'WindowsPowerShell' + $sep + 'v1\.0' + $sep + 'powershell\.exe ')
    }

    It 'quotes a path with spaces' {
        $line = Get-ProxyCommandLine 'C:\Users\Jo Doe\my tools\ssh-paste.ps1'
        $line | Should -Match ' -File "C:\\Users\\Jo Doe\\my tools\\ssh-paste\.ps1" --proxy '
    }

    It 'doubles percent signs in the script path, because ssh expands %' {
        $line = Get-ProxyCommandLine 'C:\50%off\100%\ssh-paste.ps1'
        $line | Should -Match ' -File "C:\\50%%off\\100%%\\ssh-paste\.ps1" '
        $line | Should -Not -Match '50%off'
    }

    It 'doubles percent signs in SystemRoot too' {
        $old = $env:SystemRoot
        try {
            if ($script:OnWindows) { $env:SystemRoot = 'C:\Win%dir' } else { $env:SystemRoot = '/Win%dir' }
            (Get-ProxyCommandLine 'C:\x\ssh-paste.ps1') | Should -Match '^(C:)?[\\/]Win%%dir[\\/]System32'
        } finally { $env:SystemRoot = $old }
    }

    It 'has a program that ends in .exe followed by a space (how Win32-OpenSSH finds the program)' {
        $line = Get-ProxyCommandLine 'C:\a b\ssh-paste.ps1'
        $line.IndexOf('.exe ') | Should -BeGreaterThan 0
        $line.Substring(0, $line.IndexOf('.exe ')) | Should -Not -Match '"'
    }

    It 'uses full parameter names and nothing that antivirus heuristics flag' {
        $line = Get-ProxyCommandLine 'C:\x\ssh-paste.ps1'
        $line | Should -Not -Match '(?i)-EncodedCommand|-WindowStyle|-Command'
        $line | Should -Not -Match '\s-(ep|nop|noni|w|enc)\s'
    }
}

Describe 'Get-ManagedBlock: the hosts' {
    BeforeAll {
        $script:Begin = $script:BlockBegin
        $script:End = $script:BlockEnd
    }

    It 'is empty for nothing' {
        @((Get-ManagedBlock $null).Hosts).Count | Should -Be 0
        @((Get-ManagedBlock '').Hosts).Count | Should -Be 0
    }

    It 'is empty when there is no block' {
        @((Get-ManagedBlock "Host a`n  HostName x`n").Hosts).Count | Should -Be 0
    }

    It 'lists the hosts of the block and skips Host *' {
        $text = "$($script:Begin)`nHost a b`n    ProxyCommand x`nHost *`n$($script:End)`nHost other`n"
        Format-ArgList ((Get-ManagedBlock $text).Hosts) | Should -BeExactly '["a","b"]'
    }

    It 'ignores Host lines outside the block' {
        $text = "Host before`n$($script:Begin)`nHost a`n    ProxyCommand x`nHost *`n$($script:End)`nHost after`n"
        Format-ArgList ((Get-ManagedBlock $text).Hosts) | Should -BeExactly '["a"]'
    }

    It 'reads CRLF files' {
        $text = "$($script:Begin)`r`nHost a`r`n    ProxyCommand x`r`nHost *`r`n$($script:End)`r`n"
        Format-ArgList ((Get-ManagedBlock $text).Hosts) | Should -BeExactly '["a"]'
    }

    It 'does not mistake a marker with other text for the block' {
        @((Get-ManagedBlock "# >>> ssh-paste something else >>>`nHost a`n").Hosts).Count | Should -Be 0
    }
}

Describe 'Set-ManagedBlock' {
    BeforeAll {
        $script:Proxy = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File "C:\x y\ssh-paste.ps1" --proxy %h %p %n'
        function Add-Block { param([string]$Text, [string[]]$Hosts, [switch]$CreatedFile) return (Set-ManagedBlock $Text $Hosts $script:Proxy -CreatedFile:$CreatedFile) }
        function Remove-Block { param([string]$Text) return (Set-ManagedBlock $Text @() $script:Proxy) }
        function Convert-ToCrLf { param([string]$Text) return ($Text -replace "`r?`n", "`r`n") }
        function Get-OccurrenceCount { param([string]$Text, [string]$Needle) return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count }
    }

    It 'writes the documented block into an empty config' {
        $expected = "# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>`n" +
            "Host myhost`n" +
            "    ProxyCommand $($script:Proxy)`n" +
            "    ProxyUseFdpass no`n" +
            "Host *`n" +
            "# <<< ssh-paste <<<`n"
        Add-Block '' @('myhost') | Should -BeExactly $expected
    }

    It 'writes the created-file line right after the begin marker with -CreatedFile' {
        $expected = "# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>`n" +
            "# ssh-paste created this file; it is deleted when the last host is disabled.`n" +
            "Host myhost`n" +
            "    ProxyCommand $($script:Proxy)`n" +
            "    ProxyUseFdpass no`n" +
            "Host *`n" +
            "# <<< ssh-paste <<<`n"
        Add-Block '' @('myhost') -CreatedFile | Should -BeExactly $expected
        (Add-Block '' @('myhost')).Contains($script:BlockCreatedFile) | Should -BeFalse
    }

    It 'turns ProxyUseFdpass off, so ssh never expects a file descriptor back from the proxy' {
        (Add-Block '' @('a')) | Should -Match '(?m)^    ProxyUseFdpass no$'
    }

    It 'removes a block that has the created-file line, returning the original text exactly' {
        foreach ($orig in @('', "Host a`n  HostName x`n", "Host a`r`n  HostName x", "`n")) {
            $withBlock = Add-Block $orig @('h1', 'h2') -CreatedFile
            (Get-ManagedBlock $withBlock).CreatedFile | Should -BeTrue
            Remove-Block $withBlock | Should -BeExactly $orig
        }
    }

    It 'drops the created-file line on rewrite unless the caller passes it again' {
        $once = Add-Block '' @('a') -CreatedFile
        $info = Get-ManagedBlock $once
        (Set-ManagedBlock $once @('a', 'b') $script:Proxy -CreatedFile:$info.CreatedFile) | Should -Match ([regex]::Escape($script:BlockCreatedFile))
        (Set-ManagedBlock $once @('a', 'b') $script:Proxy) | Should -Not -Match ([regex]::Escape($script:BlockCreatedFile))
    }

    It 'treats a null config like an empty one' {
        Add-Block $null @('a') | Should -BeExactly (Add-Block '' @('a'))
        Remove-Block $null | Should -BeExactly ''
    }

    It 'lists several hosts on one Host line' {
        (Add-Block '' @('a', 'b', 'c')) | Should -Match "(?m)^Host a b c$"
    }

    It 'puts the block first and the user config after it' {
        $orig = "Host work`n  HostName 10.0.0.1`n  User me`n"
        $new = Add-Block $orig @('work')
        $new.StartsWith($script:BlockBegin + "`n") | Should -BeTrue
        $new.EndsWith($script:BlockEnd + "`n" + $orig) | Should -BeTrue
    }

    It 'removes everything it added and returns the original text exactly: <Name>' -ForEach $sharedCases.blockRoundTrip {
        $added = Add-Block $Text @('myhost')
        ((Get-ManagedBlock $added).Hosts) | Should -Contain 'myhost'
        Remove-Block $added | Should -BeExactly $Text
    }

    It 'uses CRLF for the whole block when the file uses CRLF' {
        $orig = Convert-ToCrLf "Host a`n  HostName x`n"
        $new = Add-Block $orig @('myhost')
        $new | Should -Match "`r`n"
        ([regex]::Matches($new, "(?<!`r)`n")).Count | Should -Be 0
        Remove-Block $new | Should -BeExactly $orig
    }

    It 're-adding replaces the block instead of stacking blocks' {
        $orig = "Host a`n  HostName x`n"
        $once = Add-Block $orig @('myhost')
        $twice = Set-ManagedBlock $once @('myhost', 'other') $script:Proxy
        Get-OccurrenceCount $twice $script:BlockBegin | Should -Be 1
        Get-OccurrenceCount $twice $script:BlockEnd | Should -Be 1
        Format-ArgList ((Get-ManagedBlock $twice).Hosts) | Should -BeExactly '["myhost","other"]'
        Remove-Block $twice | Should -BeExactly $orig
    }

    It 'adding the same hosts twice gives the same text' {
        $orig = "Host a`n  HostName x`n"
        $once = Add-Block $orig @('myhost')
        Set-ManagedBlock $once @('myhost') $script:Proxy | Should -BeExactly $once
    }

    It 'removing one of two hosts keeps the other' {
        $orig = "Host a`n  HostName x`n"
        $both = Add-Block $orig @('h1', 'h2')
        $one = Set-ManagedBlock $both @('h2') $script:Proxy
        Format-ArgList ((Get-ManagedBlock $one).Hosts) | Should -BeExactly '["h2"]'
        Remove-Block $one | Should -BeExactly $orig
    }

    It 'leaves a file without a block unchanged' {
        foreach ($text in @('', "Host a`n", "Host a`r`n  HostName x", "`n")) {
            Remove-Block $text | Should -BeExactly $text
        }
    }

    It 'keeps global options in scope for every host: they follow the trailing Host *' {
        $orig = "ServerAliveInterval 30`nAddKeysToAgent yes`n`nHost a`n  HostName x`n"
        $new = Add-Block $orig @('myhost')
        $lines = $new -split "`n"
        $star = [array]::IndexOf($lines, 'Host *')
        $star | Should -BeGreaterThan 0
        $lines[$star + 1] | Should -BeExactly $script:BlockEnd
        $lines[$star + 2] | Should -BeExactly 'ServerAliveInterval 30'
        # The block's own Host line comes before Host *, so the options after the block
        # belong to "Host *" -- the same scope they had at the top of the file.
        $lines[1] | Should -BeExactly 'Host myhost'
    }

    It 'does not touch text before or after a block that the user edited around' {
        $block = Add-Block '' @('a')
        $text = $block + "Host mine`n  User me`n"
        Remove-Block $text | Should -BeExactly "Host mine`n  User me`n"
    }

    It 'throws when the block has no end marker, and does not change anything' {
        $broken = "$($script:BlockBegin)`nHost a`n    ProxyCommand x`nHost b`n"
        { Set-ManagedBlock $broken @() $script:Proxy } | Should -Throw '*no end marker*'
        { Set-ManagedBlock $broken @('a') $script:Proxy } | Should -Throw '*no end marker*'
    }

    It 'only recognises the markers as whole lines' {
        $text = "# note: $($script:BlockBegin)`nHost a`n"
        Remove-Block $text | Should -BeExactly $text
    }

    It 'writes ASCII only' {
        $text = Add-Block '' @('a')
        $text | Should -Match '^[\x20-\x7e\r\n]+$'
    }
}

Describe 'paste settings (--keep, --dir)' {
    It 'takes --keep <Value> as <Minutes> minutes' -ForEach $sharedCases.keepAccept {
        ConvertTo-KeepMinutes $Value | Should -Be $Minutes
    }

    It 'refuses --keep "<Value>"' -ForEach $sharedCases.keepReject {
        { ConvertTo-KeepMinutes $Value } | Should -Throw '*--keep*'
    }

    It 'takes --dir <Value>' -ForEach $sharedCases.dirAccept {
        Test-ServerDirectory $Value | Should -BeTrue
    }

    It 'refuses --dir "<Value>"' -ForEach $sharedCases.dirReject {
        Test-ServerDirectory $Value | Should -BeFalse
    }

    It 'checks the path the server answers: <Name>' -ForEach $sharedCases.replyPaths {
        $hash = $Path -replace '^.*ssh-paste-([0-9a-f]{32}).*$', '$1'
        if ($Ok) { Read-UploadReply ('9 ' + $Path) 9 '0123456789abcdef0123456789abcdef' 'png' $Dir $Class | Should -BeExactly $Path }
        else { { Read-UploadReply ('9 ' + $Path) 9 '0123456789abcdef0123456789abcdef' 'png' $Dir $Class } | Should -Throw '*unexpected*' }
    }

    It 'reads ssh mode and its settings from the ProxyCommand of ssh -G: <Name>' -ForEach $sharedCases.sshModeSettings {
        $effective = @{}
        if ($null -ne $Line) { $effective['proxycommand'] = $Line }
        $got = Get-SshModeSettings $effective
        if ($null -eq $Keep) { $got | Should -BeNullOrEmpty }
        else { $got.Keep | Should -BeExactly $Keep; $got.Dir | Should -BeExactly $Dir }
    }

    It 'reads what an ssh error says, and whether trying again can help: <Name>' -ForEach $sharedCases.sshFailures {
        $f = Get-SshFailure $Text
        if ($null -eq $Kind) { $f | Should -BeNullOrEmpty }
        else { $f.Kind | Should -BeExactly $Kind }
        if ($null -ne $Methods) {
            Format-ArgList $f.Methods | Should -BeExactly (Format-ArgList $Methods)
            $f.KeyLogin | Should -Be $KeyLogin
            $f.Typed | Should -Be $Typed
        }
        Test-FailureFinal $f | Should -Be $Final
    }

    It 'gives the key setup commands [-p PORT] [USER@]HOST from the --doctor arguments: <Name>' -ForEach $sharedCases.keySetupTargets {
        $s = Get-KeySetupTarget (Split-SshArguments $SshArgs)
        $s.Target | Should -BeExactly $Target
        $s.Dropped | Should -Be $Dropped
    }

    It 'chooses the language as git does, then the system language: <Name>' -ForEach $sharedCases.uiLanguages {
        $environment = @{}
        foreach ($p in $Env.PSObject.Properties) { $environment[$p.Name] = [string]$p.Value }
        Get-UiLanguage $environment @($System) @('zh-CN') | Should -BeExactly $Expected
    }

    It 'falls back to the English text, and fills {0}, {1}' {
        $saved = $script:Messages
        try {
            $script:Messages = $null
            Get-Text 'Enabled for: {0}' 'h1, h2' | Should -BeExactly 'Enabled for: h1, h2'
            $script:Messages = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
            $script:Messages['Enabled for: {0}'] = 'X {0} Y'
            Get-Text 'Enabled for: {0}' 'h1' | Should -BeExactly 'X h1 Y'
            Get-Text 'not there {0}' 'a' | Should -BeExactly 'not there a'
            Get-Text 'two {0} {1}' 'a' 'b' | Should -BeExactly 'two a b'
        } finally { $script:Messages = $saved }
    }

    It 'speaks the chosen language when run, and English with SSH_PASTE_LANG=en' -Skip:$onWindows {
        # Run as a user runs it (Initialize-Language happens only then). Not on Windows: a runner's
        # console code page may not show Chinese, and the script then keeps English by design.
        $script = Join-Path $script:RepoRoot 'src/ssh-paste.ps1'
        $old = $env:SSH_PASTE_LANG
        try {
            $env:SSH_PASTE_LANG = 'zh-CN'
            $zh = (& pwsh -NoProfile -File $script --help) -join "`n"
            $env:SSH_PASTE_LANG = 'en'
            $en = (& pwsh -NoProfile -File $script --help) -join "`n"
        } finally { $env:SSH_PASTE_LANG = $old }
        $zh | Should -Match '[\u4e00-\u9fff]'
        $en | Should -Not -Match '[^\x00-\x7f]'
        $en | Should -Match 'Start:'
    }

    It 'reads the catalogs it carries' {
        $data = ConvertFrom-Json $script:LocaleData
        @($data.PSObject.Properties | ForEach-Object { $_.Name }) | Should -Contain 'zh-CN'
    }

    It 'writes words as a command line to type again: <Name>' -ForEach $sharedCases.shellWords {
        Format-ShellWords $Words | Should -BeExactly $Expected
    }

    It 'quotes a single quote the PowerShell way' {
        Format-ShellWords @("it's") | Should -BeExactly "'it''s'"
    }

    It 'refuses --enable for a host only when the server refused the login: <Name>' -ForEach $sharedCases.enableRefusals {
        $r = Get-EnableRefusal 'h' $Said
        ($null -ne $r) | Should -Be $Refuse
    }

    It 'says whether uploads to a host log in, and what to do: <Name>' -ForEach $sharedCases.loginReports {
        Get-LoginReport $HostName $Said | Should -BeExactly $Expected
    }

    It 'prints the commands that set up a key on Windows, with the host and the command the READMEs show' {
        $lines = @(Get-KeySetupLines '-p 2222 build')
        $lines | Should -Contain '    ssh-keygen -t ed25519'
        $lines | Should -Contain ('    Get-Content $HOME\.ssh\id_ed25519.pub | ssh -p 2222 build "' + $script:KeyInstallCommand + '"')
        $lines | Should -Contain '    ssh-paste --doctor -p 2222 build'
        foreach ($readme in @('README.md', 'README.zh-CN.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $readme))
            $text.Contains('Get-Content $HOME\.ssh\id_ed25519.pub | ssh myhost "' + $script:KeyInstallCommand + '"') | Should -BeTrue -Because "$readme shows the same command"
        }
    }

    It 'says what --disable removed, or that the host was not enabled: <Name>' -ForEach $sharedCases.disableMessages {
        Get-DisableMessage $Managed $Asked | Should -BeExactly $Expected
    }

    It 'makes --dir absolute with the home folder on the server: <Name>' -ForEach $sharedCases.absoluteDirs {
        if ($null -ne $Expected) { ConvertTo-AbsoluteDirectory $Dir $ServerHome | Should -BeExactly $Expected }
        else { { ConvertTo-AbsoluteDirectory $Dir $ServerHome } | Should -Throw '*cannot use*' }
    }

    It 'reads the settings of a ProxyCommand line: <Name>' -ForEach $sharedCases.proxySettings {
        $s = Get-ProxySettings $Line
        $s.Keep | Should -BeExactly $Keep
        $s.Dir | Should -BeExactly $Dir
    }

    It 'reads leading --keep and --dir in any order, once each, and stops at the first other argument' {
        $r = Read-PasteSettings @('--dir', '~/s', '--keep', '2h', '-p', '22', 'host')
        $r.Keep | Should -BeExactly '2h'
        $r.Dir | Should -BeExactly '~/s'
        Format-ArgList $r.Rest | Should -BeExactly '["-p","22","host"]'
        $r = Read-PasteSettings @('host', '--keep', '2h')
        $r.Keep | Should -BeNullOrEmpty
        Format-ArgList $r.Rest | Should -BeExactly '["host","--keep","2h"]'
        { Read-PasteSettings @('--keep', '1d', '--keep', '2d', 'h') } | Should -Throw '*given twice*'
        { Read-PasteSettings @('--dir') } | Should -Throw '*needs a value*'
        { Read-PasteSettings @('--dir', 'C:\x', 'h') } | Should -Throw '*quote ~*'
        (Read-PasteSettings @('--dir', '/data/x/', 'h')).Dir | Should -BeExactly '/data/x'
        (Read-PasteSettings @('--dir', '~/', 'h')).Dir | Should -BeExactly '~'
        { Read-PasteSettings @('--dir', '/', 'h') } | Should -Throw '*--dir takes*'
        { Read-PasteSettings @('--keep', '', 'h') } | Should -Throw '*--keep*'
    }

    It 'names the class of an image after its --keep, and none for the default' {
        Get-KeepClass '1d' | Should -BeExactly ''
        Get-KeepClass $null | Should -BeExactly ''
        Get-KeepClass '7d' | Should -BeExactly 'k7d-'
        Get-KeepClass 'never' | Should -BeExactly 'knever-'
    }

    It 'groups hosts case-sensitively, also a host named keys' {
        $want = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        $want['build'] = @{ Keep = '1d'; Dir = '/tmp' }
        $want['BUILD'] = @{ Keep = '1d'; Dir = '/data/Shots' }
        $want['keys'] = @{ Keep = '1d'; Dir = '/data/shots' }
        $old = $env:SystemRoot
        try {
            $env:SystemRoot = '/Windows'
            $groups = @(Get-SettingsGroups $want 'C:\p\ssh-paste.ps1')
        } finally { $env:SystemRoot = $old }
        $groups.Count | Should -Be 3
        Format-ArgList $groups[1].Hosts | Should -BeExactly '["BUILD"]'
        Format-ArgList $groups[2].Hosts | Should -BeExactly '["keys"]'
    }

    It 'writes --keep and --dir into the ProxyCommand only when they are not the defaults' {
        $old = $env:SystemRoot
        try {
            $env:SystemRoot = '/Windows'   # Join-Path needs no drive on Linux
            $base = Get-ProxyCommandLine 'C:\p\ssh-paste.ps1'
            Get-ProxyCommandLine 'C:\p\ssh-paste.ps1' '1d' '/tmp' | Should -BeExactly $base
            Get-ProxyCommandLine 'C:\p\ssh-paste.ps1' 'never' '~/shots' | Should -BeExactly ($base + ' --keep never --dir ~/shots')
            $s = Get-ProxySettings (Get-ProxyCommandLine 'C:\p\ssh-paste.ps1' '30m' '/data/x')
            $s.Keep | Should -BeExactly '30m'
            $s.Dir | Should -BeExactly '/data/x'
        } finally { $env:SystemRoot = $old }
    }

    It 'pastes a path again without a new upload for at most half of --keep, and 6 hours at most' {
        Get-UploadCacheHours 1440 | Should -Be 6
        Get-UploadCacheHours 0 | Should -Be 6
        Get-UploadCacheHours 60 | Should -Be 0.5
        Get-UploadCacheHours 30 | Should -Be 0.25
    }

    It 'says when the server cannot write to the folder' {
        { Read-UploadReply 'nodir' 9 '0123456789abcdef0123456789abcdef' 'png' '~/shots' } | Should -Throw '*cannot write to the folder ~/shots*'
        { Read-UploadReply 'notprivate' 9 '0123456789abcdef0123456789abcdef' 'png' '/data/x' } | Should -Throw '*not yours alone*'
    }
}

Describe 'Get-ManagedBlock' {
    BeforeAll {
        $script:Begin = $script:BlockBegin
        $script:End = $script:BlockEnd
        $script:Created = $script:BlockCreatedFile
    }

    It 'is not present, with no hosts, for nothing or for a config without a block' {
        foreach ($text in @($null, '', "Host a`n  HostName x`n")) {
            $b = Get-ManagedBlock $text
            $b.Present | Should -BeFalse
            @($b.Hosts).Count | Should -Be 0
            $b.ProxyCommand | Should -BeNullOrEmpty
            $b.CreatedFile | Should -BeFalse
        }
    }

    It 'reads the hosts, the ProxyCommand and the created-file flag of a block' {
        $text = "$($script:Begin)`n$($script:Created)`nHost a b`n    ProxyCommand C:\x\powershell.exe -File y --proxy %h %p %n`n    ProxyUseFdpass no`nHost *`n$($script:End)`nHost other`n    ProxyCommand not-ours`n"
        $b = Get-ManagedBlock $text
        $b.Present | Should -BeTrue
        Format-ArgList $b.Hosts | Should -BeExactly '["a","b"]'
        $b.ProxyCommand | Should -BeExactly 'C:\x\powershell.exe -File y --proxy %h %p %n'
        $b.CreatedFile | Should -BeTrue
    }

    It 'reads each Host line with its own ProxyCommand as a group, and Set-ManagedBlock writes them back' {
        $groups = @(@{ Hosts = @('a', 'b'); ProxyCommand = 'P1 --proxy %h %p %n' }, @{ Hosts = @('c'); ProxyCommand = 'P1 --proxy %h %p %n --keep 7d --dir ~/s' })
        $text = Set-ManagedBlock "Host other`n" -Groups $groups -CreatedFile
        $text | Should -Match '(?s)^# >>> .*\nHost a b\n    ProxyCommand P1 --proxy %h %p %n\n    ProxyUseFdpass no\nHost c\n    ProxyCommand P1 --proxy %h %p %n --keep 7d --dir ~/s\n    ProxyUseFdpass no\nHost \*\n# <<< ssh-paste <<<\nHost other\n$'
        $b = Get-ManagedBlock $text
        Format-ArgList $b.Hosts | Should -BeExactly '["a","b","c"]'
        @($b.Groups).Count | Should -Be 2
        $b.Groups[1].ProxyCommand | Should -BeExactly 'P1 --proxy %h %p %n --keep 7d --dir ~/s'
        (Get-ProxySettings $b.Groups[1].ProxyCommand).Keep | Should -BeExactly '7d'
        (Get-ProxySettings $b.Groups[0].ProxyCommand).Dir | Should -BeExactly '/tmp'
        Set-ManagedBlock $text -Groups @(@{ Hosts = @(); ProxyCommand = 'x' }) | Should -BeExactly "Host other`n"
    }

    It 'has CreatedFile false when the block lacks the line' {
        $text = "$($script:Begin)`nHost a`n    ProxyCommand x`nHost *`n$($script:End)`n"
        (Get-ManagedBlock $text).CreatedFile | Should -BeFalse
    }

    It 'ignores the created-file line outside the block' {
        $text = "$($script:Created)`n$($script:Begin)`nHost a`n    ProxyCommand x`nHost *`n$($script:End)`n$($script:Created)`n"
        (Get-ManagedBlock $text).CreatedFile | Should -BeFalse
    }

    It 'ignores Host and ProxyCommand lines outside the block' {
        $text = "Host before`n    ProxyCommand before-cmd`n$($script:Begin)`nHost a`n    ProxyCommand x`nHost *`n$($script:End)`nHost after`n    ProxyCommand after-cmd`n"
        $b = Get-ManagedBlock $text
        Format-ArgList $b.Hosts | Should -BeExactly '["a"]'
        $b.ProxyCommand | Should -BeExactly 'x'
    }

    It 'reads CRLF files' {
        $text = "$($script:Begin)`r`n$($script:Created)`r`nHost a`r`n    ProxyCommand x`r`nHost *`r`n$($script:End)`r`n"
        $b = Get-ManagedBlock $text
        $b.Present | Should -BeTrue
        $b.CreatedFile | Should -BeTrue
        $b.ProxyCommand | Should -BeExactly 'x'
        Format-ArgList $b.Hosts | Should -BeExactly '["a"]'
    }

    It 'reads back what Set-ManagedBlock writes, with and without -CreatedFile' {
        $proxy = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File "C:\x y\ssh-paste.ps1" --proxy %h %p %n'
        foreach ($flag in @($true, $false)) {
            $text = Set-ManagedBlock "Host z`n  User me`n" @('h1', 'h2') $proxy -CreatedFile:$flag
            $b = Get-ManagedBlock $text
            $b.Present | Should -BeTrue
            $b.CreatedFile | Should -Be $flag
            $b.ProxyCommand | Should -BeExactly $proxy
            Format-ArgList $b.Hosts | Should -BeExactly '["h1","h2"]'
        }
    }

    It 'is not fooled by a marker with other text' {
        (Get-ManagedBlock "# >>> ssh-paste something else >>>`nHost a`n").Present | Should -BeFalse
    }
}

Describe 'Get-FailureSummary' {
    It 'is null with no watcher or no failures' {
        Get-FailureSummary $null | Should -BeNullOrEmpty
        Get-FailureSummary @{ Failed = @{} } | Should -BeNullOrEmpty
    }

    It 'counts the failures and shows the message of the last one' {
        $summary = Get-FailureSummary @{ Failed = @{ 'aaa' = @{ Message = 'ssh exited with 255: Permission denied'; At = [DateTime]::UtcNow } } }
        $summary | Should -Match '^ssh-paste: 1 screenshot upload\(s\) failed: ssh exited with 255: Permission denied$'
    }

    It 'picks the newest of several failures, whatever the hash order' {
        $now = [DateTime]::UtcNow
        $failed = @{
            'aaa' = @{ Message = 'newest'; At = $now }
            'bbb' = @{ Message = 'oldest'; At = $now.AddMinutes(-5) }
            'ccc' = @{ Message = 'middle'; At = $now.AddMinutes(-1) }
        }
        $summary = Get-FailureSummary @{ Failed = $failed }
        $summary | Should -Match '3 screenshot upload\(s\) failed: newest$'
    }
}

Describe 'Get-SshPath' {
    It 'honours SSH_PASTE_SSH' {
        $old = $env:SSH_PASTE_SSH
        try {
            $env:SSH_PASTE_SSH = '/opt/custom/ssh'
            Get-SshPath | Should -BeExactly '/opt/custom/ssh'
        } finally {
            if ($null -eq $old) { Remove-Item Env:\SSH_PASTE_SSH -ErrorAction SilentlyContinue } else { $env:SSH_PASTE_SSH = $old }
        }
    }
}

Describe 'ssh config editing (Update-SshConfig, Invoke-Enable, Invoke-Disable)' {
    BeforeAll {
        Mock Test-HostResolves { $true }   # the hosts in these tests are made up
        # --enable checks each host's login once; here every host logs in, with home /home/u.
        Mock Test-ServerLogin { @{ Home = '/home/u'; Error = $null } }
        Mock Get-SshPath { 'ssh' }
        Mock Get-SshVersion { [version]'9.6' }
        $script:HomeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-cfg-' + [guid]::NewGuid().ToString('N'))
        $script:SshDir = Join-Path $script:HomeDir '.ssh'
        $script:Cfg = Join-Path $script:SshDir 'config'
        $script:ProxyLine = 'PROXY-ONE'
        $script:Resolved = @{}

        function Reset-Home {
            Remove-Item -LiteralPath $script:HomeDir -Recurse -Force -ErrorAction SilentlyContinue
            [void](New-Item -ItemType Directory -Path $script:HomeDir)
        }
        function Write-Config {
            param([string]$Text, [switch]$Bom)
            [void][System.IO.Directory]::CreateDirectory($script:SshDir)
            [System.IO.File]::WriteAllText($script:Cfg, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
        }
        function Read-Config { return [System.IO.File]::ReadAllText($script:Cfg) }
        function Get-ConfigBytes { return [System.IO.File]::ReadAllBytes($script:Cfg) }
        function Invoke-Quiet { param([scriptblock]$Block) return (& $Block 6> $null) }
    }

    BeforeEach {
        Reset-Home
        $script:ProxyLine = 'PROXY-ONE'
        $script:Resolved = @{}
        Mock Get-SshConfigPath { return $script:Cfg }
        Mock Get-ProxyCommandLine { return $script:ProxyLine }
        Mock Get-ResolvedSshConfig { return $script:Resolved }
        Mock Write-Info { }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:HomeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Update-SshConfig' {
        It 'creates the folder and the file when there was none' {
            Update-SshConfig $script:Cfg $null "Host a`n"
            Read-Config | Should -BeExactly "Host a`n"
        }

        It 'writes UTF-8 without a byte order mark when the file had none' {
            Write-Config "Host a`n"
            Update-SshConfig $script:Cfg (Read-TextFile $script:Cfg) "Host b`n"
            $bytes = Get-ConfigBytes
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            Read-Config | Should -BeExactly "Host b`n"
        }

        It 'keeps the byte order mark when the file had one' {
            Write-Config "Host a`n" -Bom
            Update-SshConfig $script:Cfg (Read-TextFile $script:Cfg) "Host b`n"
            $bytes = Get-ConfigBytes
            $bytes[0] | Should -Be 0xEF
            $bytes[1] | Should -Be 0xBB
            $bytes[2] | Should -Be 0xBF
            Read-Config | Should -BeExactly "Host b`n"
        }

        It 'refuses when the file changed since it was read, and leaves it alone' {
            Write-Config "one`n"
            { Update-SshConfig $script:Cfg "zero`n" "new`n" } | Should -Throw '*changed while ssh-paste was editing*'
            Read-Config | Should -BeExactly "one`n"
        }

        It 'refuses when the file appeared after it was read as absent' {
            Write-Config "appeared`n"
            { Update-SshConfig $script:Cfg $null "new`n" } | Should -Throw '*changed while ssh-paste was editing*'
            Read-Config | Should -BeExactly "appeared`n"
        }

        It 'leaves no temporary file next to the config' {
            Write-Config "a`n"
            Update-SshConfig $script:Cfg (Read-TextFile $script:Cfg) "b`n"
            @(Get-ChildItem -LiteralPath $script:SshDir -Force | ForEach-Object { $_.Name }) | Should -BeExactly @('config')
        }

        It 'deletes the file with -Delete, but only if it is unchanged' {
            Write-Config "a`n"
            { Update-SshConfig $script:Cfg "other`n" $null -Delete } | Should -Throw '*changed while*'
            Test-Path -LiteralPath $script:Cfg | Should -BeTrue
            Update-SshConfig $script:Cfg "a`n" $null -Delete
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }

        It 'treats a missing file and an empty text as the same baseline' {
            Update-SshConfig $script:Cfg '' "Host a`n"
            Read-Config | Should -BeExactly "Host a`n"
        }

        It 'treats an empty file and a $null baseline as the same, too' {
            Write-Config ''
            Update-SshConfig $script:Cfg $null "Host a`n"
            Read-Config | Should -BeExactly "Host a`n"
        }

        It 'refuses a baseline of $null when the file holds text, and an empty baseline when it holds text' {
            Write-Config "one`n"
            { Update-SshConfig $script:Cfg $null "new`n" } | Should -Throw '*changed while ssh-paste was editing*'
            { Update-SshConfig $script:Cfg '' "new`n" } | Should -Throw '*changed while ssh-paste was editing*'
            Read-Config | Should -BeExactly "one`n"
        }

        It 'compares case-sensitively' {
            Write-Config "Host A`n"
            { Update-SshConfig $script:Cfg "host a`n" "new`n" } | Should -Throw '*changed while*'
            Read-Config | Should -BeExactly "Host A`n"
        }

        It 'does not touch files next to the config whose names look like temporary files, and adds none' {
            Write-Config "a`n"
            $siblings = @('config.ssh-paste', 'config.ssh-paste-tmp', 'config.tmp', 'config.ssh-paste-12345678')
            foreach ($n in $siblings) { [System.IO.File]::WriteAllText((Join-Path $script:SshDir $n), 'mine') }
            Update-SshConfig $script:Cfg "a`n" "b`n"
            Update-SshConfig $script:Cfg "b`n" "c`n"
            foreach ($n in $siblings) { [System.IO.File]::ReadAllText((Join-Path $script:SshDir $n)) | Should -BeExactly 'mine' }
            @(Get-ChildItem -LiteralPath $script:SshDir -Force).Count | Should -Be ($siblings.Count + 1)
            Read-Config | Should -BeExactly "c`n"
        }

        It 'refuses, and leaves the config and the folder as they were, when the file changes after the temp file is written' {
            Write-Config "one`n"
            $script:Reads = 0
            # The first read is the check at the start; the second is the re-check just before the replace.
            Mock Read-TextFile {
                $script:Reads++
                if ($script:Reads -ge 2) { return "someone else wrote this`n" }
                return [System.IO.File]::ReadAllText($Path)
            }
            { Update-SshConfig $script:Cfg "one`n" "new`n" } | Should -Throw '*changed while ssh-paste was editing*'
            Read-Config | Should -BeExactly "one`n"
            @(Get-ChildItem -LiteralPath $script:SshDir -Force | ForEach-Object { $_.Name }) | Should -BeExactly @('config')
        }

        It 'refuses when the file appears between the check and the replace, and removes its temp file' {
            $script:Reads = 0
            Mock Read-TextFile {
                $script:Reads++
                if ($script:Reads -ge 2) { return "appeared`n" }
                return $null
            }
            { Update-SshConfig $script:Cfg $null "new`n" } | Should -Throw '*changed while ssh-paste was editing*'
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:SshDir -Force).Count | Should -Be 0
        }
    }

    Context 'Invoke-Enable' {
        It 'writes the block, with the created-file line, when there was no config' {
            Invoke-Enable @('h1') | Should -Be 0
            $text = Read-Config
            $text.StartsWith($script:BlockBegin + "`n" + $script:BlockCreatedFile + "`n") | Should -BeTrue
            $text | Should -Match '(?m)^Host h1$'
            $text | Should -Match '(?m)^    ProxyCommand PROXY-ONE$'
            $text | Should -Match '(?m)^    ProxyUseFdpass no$'
            $text | Should -Match '(?m)^Host \*$'
            (Get-ManagedBlock $text).CreatedFile | Should -BeTrue
        }

        It 'does not write the created-file line into a config that already existed (even an empty one)' {
            foreach ($existing in @("Host a`n  HostName x`n", '')) {
                Write-Config $existing
                Invoke-Enable @('h1') | Should -Be 0
                $block = Get-ManagedBlock (Read-Config)
                $block.Present | Should -BeTrue
                $block.CreatedFile | Should -BeFalse
                Remove-Item -LiteralPath $script:Cfg -Force
            }
        }

        It 'puts the block first and the user''s config after it' {
            $orig = "Host work`n  HostName 10.0.0.1`n"
            Write-Config $orig
            [void](Invoke-Enable @('h1'))
            (Read-Config).EndsWith($script:BlockEnd + "`n" + $orig) | Should -BeTrue
        }

        It 'adds a second host to the same block and keeps the created-file line' {
            [void](Invoke-Enable @('h1'))
            [void](Invoke-Enable @('h2'))
            $block = Get-ManagedBlock (Read-Config)
            Format-ArgList $block.Hosts | Should -BeExactly '["h1","h2"]'
            $block.CreatedFile | Should -BeTrue
            ([regex]::Matches((Read-Config), [regex]::Escape($script:BlockBegin))).Count | Should -Be 1
        }

        It 'changes nothing when every host is already enabled' {
            [void](Invoke-Enable @('h1'))
            $before = Read-Config
            Invoke-Enable @('h1') | Should -Be 0
            Read-Config | Should -BeExactly $before
        }

        It 'refuses a host that already has a ProxyJump or ProxyCommand, and writes nothing' {
            foreach ($key in @('proxyjump', 'proxycommand')) {
                $script:Resolved = @{ $key = 'somewhere' }
                { Invoke-Enable @('h1') } | Should -Throw "*already uses $key*"
                Test-Path -LiteralPath $script:Cfg | Should -BeFalse
            }
            $script:Resolved = @{ proxyjump = 'none'; proxycommand = 'none' }
            Invoke-Enable @('h1') | Should -Be 0
        }

        It 'refuses user@host and option-like names' {
            foreach ($bad in @('me@h', '-oProxyCommand=x', 'a b', '*')) {
                { Invoke-Enable @($bad) } | Should -Throw '*use a host name or a Host alias*'
            }
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }

        It 'explains the usage without a host' {
            { Invoke-Enable @() } | Should -Throw '*usage: ssh-paste --enable*'
        }

        It 'checks the login of each host once, and says that uploads log in' {
            Invoke-Enable @('h1', 'h2', 'h1') | Should -Be 0
            Should -Invoke Test-ServerLogin -Times 2 -Exactly
            Should -Invoke Write-Info -ParameterFilter { $Message -ceq 'h1: uploads log in without a password' } -Exactly 1
        }

        It 'refuses a host whose uploads the server refuses, shows the key commands, and writes nothing' {
            Mock Test-ServerLogin { @{ Home = $null; Error = 'xu@h1: Permission denied (publickey,password).' } }
            $err = $null
            try { Invoke-Enable @('h1') } catch { $err = $_.Exception.Message }
            $err | Should -BeLike 'nothing changed in ~/.ssh/config:*'
            $err | Should -BeLike '*h1 did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add*'
            $err | Should -Not -BeLike '*shows how*'
            $err | Should -BeLike ('*ssh h1 "' + $script:KeyInstallCommand + '"*')
            $err | Should -BeLike '*Then run again: ssh-paste --enable h1'
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }

        It 'changes nothing when one host is refused, not even another host''s --keep, and gives the whole command again' {
            [void](Invoke-Enable @('h1'))
            $before = [System.IO.File]::ReadAllBytes($script:Cfg)
            Mock Test-ServerLogin { if ($Parsed.Destination -ceq 'h2') { @{ Home = $null; Error = 'ssh exited with 255: xu@h2: Permission denied (password).' } } else { @{ Home = '/home/u'; Error = $null } } }
            { Invoke-Enable @('--keep', 'never', 'h1', 'h2') } | Should -Throw '*h2 wants a password or a one-time code (password)*Then run again: ssh-paste --enable --keep never h1 h2'
            [System.IO.File]::ReadAllBytes($script:Cfg) | Should -Be $before
        }

        It 'reports every host''s problem together, not just the first' {
            Mock Test-ServerLogin {
                if ($Parsed.Destination -ceq 'h1') { @{ Home = $null; Error = 'ssh exited with 255: ssh: connect to host h1 port 22: Connection refused' } }
                else { @{ Home = $null; Error = 'ssh exited with 255: xu@h2: Permission denied (publickey).' } }
            }
            $err = $null
            try { Invoke-Enable @('--dir', '~/shots', 'h1', 'h2') } catch { $err = $_.Exception.Message }
            $err | Should -BeLike '*cannot ask h1 for its home folder*'
            $err | Should -BeLike '*h2 did not accept a key for uploads*'
            $err | Should -BeLike "*Then run again: ssh-paste --enable --dir '~/shots' h1 h2"
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }

        It 'enables a host it cannot check now (offline, or its host key not accepted yet), and says so' {
            Mock Test-ServerLogin { @{ Home = $null; Error = 'ssh: connect to host h1 port 22: Connection refused' } }
            Invoke-Enable @('h1') | Should -Be 0
            Format-ArgList (Get-ManagedBlock (Read-Config)).Hosts | Should -BeExactly '["h1"]'
            Should -Invoke Write-Info -ParameterFilter { $Message -clike 'could not check the login to h1 now*' } -Exactly 1
        }

        It 'refuses --dir ~/... when it cannot log in to ask for the home folder, and writes nothing' {
            Mock Test-ServerLogin { @{ Home = $null; Error = 'ssh: connect to host h1 port 22: Connection timed out' } }
            { Invoke-Enable @('--dir', '~/shots', 'h1') } | Should -Throw '*cannot ask h1 for its home folder (could not check the login to h1 now*); give an absolute --dir*'
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }
    }

    Context 'Invoke-Enable with --keep and --dir' {
        BeforeEach {
            Mock Get-ProxyCommandLine {
                $l = 'PROXY --proxy %h %p %n'
                if ($Keep -and $Keep -cne '1d') { $l += ' --keep ' + $Keep }
                if ($Dir -and $Dir -cne '/tmp') { $l += ' --dir ' + $Dir }
                return $l
            }
        }

        It 'gives the settings to the hosts named, each group on its own Host line' {
            Invoke-Enable @('--keep', '7d', '--dir', '~/shots', 'h1') | Should -Be 0
            Invoke-Enable @('h2') | Should -Be 0
            $b = Get-ManagedBlock (Read-Config)
            @($b.Groups).Count | Should -Be 2
            Format-ArgList $b.Groups[0].Hosts | Should -BeExactly '["h1"]'
            $b.Groups[0].ProxyCommand | Should -BeExactly 'PROXY --proxy %h %p %n --keep 7d --dir /home/u/shots'
            Should -Invoke Test-ServerLogin -Times 1 -Exactly -ParameterFilter { $Parsed.Destination -ceq 'h1' }
            Format-ArgList $b.Groups[1].Hosts | Should -BeExactly '["h2"]'
            $b.Groups[1].ProxyCommand | Should -BeExactly 'PROXY --proxy %h %p %n'
        }

        It 'keeps the settings of an enabled host that the new command does not give, and changes the ones it gives' {
            [void](Invoke-Enable @('--keep', '7d', '--dir', '~/shots', 'h1'))
            $before = Read-Config
            Invoke-Enable @('h1') | Should -Be 0
            Read-Config | Should -BeExactly $before
            [void](Invoke-Enable @('--keep', 'never', 'h1'))
            $h1 = Get-ProxySettings (@((Get-ManagedBlock (Read-Config)).Groups | Where-Object { @($_.Hosts) -ccontains 'h1' })[0].ProxyCommand)
            $h1.Keep | Should -BeExactly 'never'
            $h1.Dir | Should -BeExactly '/home/u/shots'
        }

        It 'puts hosts with the same settings on one Host line' {
            [void](Invoke-Enable @('--keep', '2h', 'h1'))
            [void](Invoke-Enable @('h2'))
            [void](Invoke-Enable @('--keep', '2h', 'h2'))
            $b = Get-ManagedBlock (Read-Config)
            @($b.Groups).Count | Should -Be 1
            Format-ArgList $b.Groups[0].Hosts | Should -BeExactly '["h1","h2"]'
        }

        It 'refuses a bad --keep or --dir and writes nothing' {
            { Invoke-Enable @('--keep', '1w', 'h1') } | Should -Throw '*--keep takes*'
            { Invoke-Enable @('--dir', 'shots', 'h1') } | Should -Throw '*--dir takes*'
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }

        It 'treats Host aliases case-sensitively, as ssh does' {
            Mock Get-ProxyCommandLine { 'PROXY --proxy %h %p %n' }
            [void](Invoke-Enable @('build'))
            [void](Invoke-Enable @('BUILD'))
            Format-ArgList (Get-ManagedBlock (Read-Config)).Hosts | Should -BeExactly '["build","BUILD"]'
            [void](Invoke-Disable @('BUILD'))
            Format-ArgList (Get-ManagedBlock (Read-Config)).Hosts | Should -BeExactly '["build"]'
            Should -Invoke Write-Info -ParameterFilter { $Message -ceq 'Disabled for: BUILD' } -Exactly 1
        }

        It '--disable of one host keeps the other host''s line as it is' {
            [void](Invoke-Enable @('--keep', '7d', 'h1'))
            [void](Invoke-Enable @('h2'))
            [void](Invoke-Disable @('h2'))
            $b = Get-ManagedBlock (Read-Config)
            Format-ArgList $b.Hosts | Should -BeExactly '["h1"]'
            $b.Groups[0].ProxyCommand | Should -BeExactly 'PROXY --proxy %h %p %n --keep 7d'
        }
    }

    Context 'Invoke-Disable' {
        It 'says so and changes nothing when there is no block' {
            Write-Config "Host a`n"
            Invoke-Disable @() | Should -Be 0
            Read-Config | Should -BeExactly "Host a`n"
        }

        It 'does nothing when there is no config at all' {
            Invoke-Disable @() | Should -Be 0
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }

        It 'deletes a config that ssh-paste created, and the .ssh folder that is empty again' {
            [void](Invoke-Enable @('h1', 'h2'))
            Invoke-Disable @() | Should -Be 0
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
            Test-Path -LiteralPath $script:SshDir | Should -BeFalse
        }

        It 'deletes the config when the last host is disabled one by one' {
            [void](Invoke-Enable @('h1', 'h2'))
            [void](Invoke-Disable @('h1'))
            Test-Path -LiteralPath $script:Cfg | Should -BeTrue
            [void](Invoke-Disable @('h2'))
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
        }

        It 'keeps the .ssh folder when it holds other files' {
            [void](Invoke-Enable @('h1'))
            Set-Content -LiteralPath (Join-Path $script:SshDir 'known_hosts') -Value 'x'
            [void](Invoke-Disable @())
            Test-Path -LiteralPath $script:Cfg | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:SshDir 'known_hosts') | Should -BeTrue
        }

        It 'keeps a config that the user added to after ssh-paste created it, minus the block' {
            [void](Invoke-Enable @('h1'))
            Write-Config ((Read-Config) + "Host mine`n  User me`n")
            [void](Invoke-Disable @())
            Read-Config | Should -BeExactly "Host mine`n  User me`n"
        }

        It 'never deletes a config that existed before, even if only our block is left in it' {
            foreach ($existing in @('', "`n", "Host a`n  HostName x`n")) {
                Write-Config $existing
                [void](Invoke-Enable @('h1'))
                [void](Invoke-Disable @())
                Test-Path -LiteralPath $script:Cfg | Should -BeTrue
                Read-Config | Should -BeExactly $existing
            }
        }

        It 'removes only the named hosts and keeps the ProxyCommand line that is already in the block' {
            [void](Invoke-Enable @('h1', 'h2'))
            $script:ProxyLine = 'PROXY-TWO'
            Invoke-Disable @('h1') | Should -Be 0
            $block = Get-ManagedBlock (Read-Config)
            Format-ArgList $block.Hosts | Should -BeExactly '["h2"]'
            $block.ProxyCommand | Should -BeExactly 'PROXY-ONE'
            $block.CreatedFile | Should -BeTrue
        }

        It 'puts the original file back byte for byte (CRLF and a byte order mark included)' {
            $orig = "Host a`r`n  HostName x`r`n"
            Write-Config $orig -Bom
            $before = Get-ConfigBytes
            [void](Invoke-Enable @('h1'))
            [void](Invoke-Disable @())
            ([Convert]::ToBase64String((Get-ConfigBytes))) | Should -BeExactly ([Convert]::ToBase64String($before))
        }
    }
}

Describe 'install.ps1' {
    BeforeAll {
        $script:InstallPath = Join-Path $script:RepoRoot 'install.ps1'

        function Get-StringAssignments {
            # name -> value for every `$name = 'literal'` (a `script:` prefix is dropped), by AST.
            param([string]$Path)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
            $map = @{}
            foreach ($a in $found) {
                $right = $a.Right
                if ($right -is [System.Management.Automation.Language.PipelineAst] -and $right.PipelineElements.Count -eq 1) { $right = $right.PipelineElements[0] }
                if ($right -is [System.Management.Automation.Language.CommandExpressionAst] -and $right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $name = $a.Left.VariablePath.UserPath -replace '^script:', ''
                    if (-not $map.ContainsKey($name)) { $map[$name] = $right.Expression.Value }
                }
            }
            return $map
        }

        # The installer keeps its functions inside one script block, so they cannot be
        # dot-sourced. Take the ones that touch the ssh config out of the syntax tree
        # and run them in a script block that gets the installer's own marker strings.
        $installAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallPath, [ref]$null, [ref]$null)
        $names = @('Write-Line', 'Write-FileAtomic', 'Remove-ManagedBlockText', 'Remove-EmptyDirectory', 'Remove-ConfigBlock')
        $texts = foreach ($name in $names) {
            $fn = $installAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            if ($null -eq $fn) { throw "install.ps1 has no function $name" }
            $fn.Extent.Text
        }
        $script:InstallStrings = Get-StringAssignments $script:InstallPath
        $code = 'param($BlockBegin, $BlockEnd, $BlockCreatedFile, [string]$Mode, [string]$Arg)' + "`n" + ($texts -join "`n") + "`n" +
            'if ($Mode -eq ''text'') { Remove-ManagedBlockText $Arg } else { Remove-ConfigBlock $Arg }'
        $script:InstallerBlock = [scriptblock]::Create($code)

        function Invoke-InstallerText {
            param([string]$Text)
            return (& $script:InstallerBlock $script:InstallStrings.BlockBegin $script:InstallStrings.BlockEnd $script:InstallStrings.BlockCreatedFile 'text' $Text)
        }
        function Invoke-InstallerConfigResult {
            param([string]$Path)
            $r = & $script:InstallerBlock $script:InstallStrings.BlockBegin $script:InstallStrings.BlockEnd $script:InstallStrings.BlockCreatedFile 'file' $Path 6> $null
            return $r
        }
        $script:Proxy = 'PROXY'
    }

    Context 'the file' {
        It 'is pure ASCII, has no byte order mark and parses' {
            $bytes = [System.IO.File]::ReadAllBytes($script:InstallPath)
            @($bytes | Where-Object { $_ -gt 126 -or ($_ -lt 32 -and $_ -ne 9 -and $_ -ne 10 -and $_ -ne 13) }).Count | Should -Be 0
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($script:InstallPath, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because (@($errors | ForEach-Object { $_.ToString() }) -join '; ')
        }

        It 'does not use syntax that Windows PowerShell 5.1 cannot parse' {
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($script:InstallPath, [ref]$tokens, [ref]$null)
            $bad = @($tokens | Where-Object { @('QuestionQuestion', 'QuestionDot', 'QuestionMark', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionQuestionEquals') -contains $_.Kind.ToString() })
            $bad.Count | Should -Be 0 -Because (@($bad | ForEach-Object { $_.Extent.StartLineNumber.ToString() + ': ' + $_.Text }) -join '; ')
        }

        It 'does not use the old project name' {
            $text = [System.IO.File]::ReadAllText($script:InstallPath)
            $text | Should -Not -Match '(?i)snipferry'
        }
    }

    Context 'ssh config markers' {
        It 'uses the same <Name> as src/ssh-paste.ps1 (compared through the syntax trees)' -ForEach @(
            @{ Name = 'BlockBegin' }
            @{ Name = 'BlockEnd' }
            @{ Name = 'BlockCreatedFile' }
        ) {
            $core = Get-StringAssignments $script:CorePath
            $core.ContainsKey($Name) | Should -BeTrue -Because "src/ssh-paste.ps1 must assign `$script:$Name"
            $script:InstallStrings.ContainsKey($Name) | Should -BeTrue -Because "install.ps1 must assign `$$Name"
            $core[$Name].Length | Should -BeGreaterThan 10
            $script:InstallStrings[$Name] | Should -BeExactly $core[$Name]
        }

        It 'footprint.ps1 reads the markers from the core, not from a copy' {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tests/footprint.ps1'))
            $text | Should -Match 'BlockBegin'
            $text | Should -Match 'BlockCreatedFile'
        }
    }

    Context 'the default ref' {
        It 'is one assignment of main, which publish.yml replaces with the tag' {
            $text = [System.IO.File]::ReadAllText($script:InstallPath)
            ([regex]::Matches($text, "(?m)^    \`$DefaultRef = 'main'\r?$")).Count | Should -Be 1
            $script:InstallStrings.DefaultRef | Should -BeExactly 'main'
            ([regex]::Matches($text, "'main'")).Count | Should -Be 1 -Because 'every other use must go through $DefaultRef'
            $text | Should -Match '\$Ref = \$DefaultRef'
        }

        It 'is what publish.yml edits' {
            $yml = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github/workflows/publish.yml'))
            $yml | Should -Match 'DefaultRef'
        }

        It 'documents the release download as the way to install' {
            $text = [System.IO.File]::ReadAllText($script:InstallPath)
            $text | Should -Match 'irm https://github\.com/xuing/ssh-please-paste-picture/releases/latest/download/install\.ps1 \| iex'
        }
    }

    Context 'a release install' {
        BeforeAll {
            # Get-SourceFiles runs here with a fake Get-WebBytes that serves $Web.Files and records the URLs.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallPath, [ref]$null, [ref]$null)
            $fnTexts = foreach ($name in @('Get-Sha256Hex', 'Assert-ListedSha256', 'Get-SourceFiles')) {
                $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
                if ($null -eq $fn) { throw "install.ps1 has no function $name" }
                $fn.Extent.Text
            }
            $code = 'param($DefaultRef, $Ref, $Web, $DownloadBase, $ReleaseBase, $ReleaseTag)' + "`n" + '$ScriptDir = $null' + "`n" + ($fnTexts -join "`n") + @'

function Get-WebBytes {
    param([string]$Url)
    [void]$Web.Asked.Add($Url)
    if (-not $Web.Files.ContainsKey($Url)) { throw "404 $Url" }
    return , $Web.Files[$Url]
}
Get-SourceFiles $Ref
'@
            $script:SourceBlock = [scriptblock]::Create($code)
            $script:Release = 'https://github.com/xuing/ssh-please-paste-picture/releases/download/v0.1.7/'
            $script:Raw = 'https://raw.githubusercontent.com/xuing/ssh-please-paste-picture/'
            function Get-Hex {
                param([byte[]]$Bytes)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try { return (([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()) } finally { $sha.Dispose() }
            }
            function New-Web {
                # A release v0.1.7 whose SHA256SUMS lists the two payload files and install.ps1.
                $ps1 = [System.Text.Encoding]::ASCII.GetBytes("`$script:Version = '0.1.7'`n")
                $cmd = [System.Text.Encoding]::ASCII.GetBytes("ssh-paste.ps1`n")
                $sums = "{0}  ssh-paste.ps1`n{1} *ssh-paste.cmd`n{2}  install.ps1`n" -f (Get-Hex $ps1), (Get-Hex $cmd).ToUpperInvariant(), ('0' * 64)
                $files = @{}
                $files[$script:Release + 'ssh-paste.ps1'] = $ps1
                $files[$script:Release + 'ssh-paste.cmd'] = $cmd
                $files[$script:Release + 'SHA256SUMS'] = [System.Text.Encoding]::ASCII.GetBytes($sums)
                $files[$script:Raw + 'main/src/ssh-paste.ps1'] = [System.Text.Encoding]::ASCII.GetBytes("raw ps1`n")
                $files[$script:Raw + 'main/src/ssh-paste.cmd'] = [System.Text.Encoding]::ASCII.GetBytes("raw cmd`n")
                $files[$script:Raw + 'v0.1.7/src/ssh-paste.ps1'] = [System.Text.Encoding]::ASCII.GetBytes("raw tag ps1`n")
                $files[$script:Raw + 'v0.1.7/src/ssh-paste.cmd'] = [System.Text.Encoding]::ASCII.GetBytes("raw tag cmd`n")
                return @{ Files = $files; Asked = (New-Object System.Collections.ArrayList) }
            }
            function Get-Source {
                param([string]$DefaultRef, [string]$Ref, $Web)
                return (& $script:SourceBlock $DefaultRef $Ref $Web $script:InstallStrings.DownloadBase $script:InstallStrings.ReleaseBase $script:InstallStrings.ReleaseTag)
            }
        }

        It 'downloads the files attached to the release and checks them against its SHA256SUMS' {
            $web = New-Web
            $s = Get-Source 'v0.1.7' '' $web
            $s.Tag | Should -BeExactly 'v0.1.7'
            [System.Text.Encoding]::ASCII.GetString($s.Ps1) | Should -Match "Version = '0.1.7'"
            @($web.Asked) | Should -Contain ($script:Release + 'SHA256SUMS')
            @($web.Asked | Where-Object { $_ -like '*raw.githubusercontent.com*' }).Count | Should -Be 0
        }

        It 'refuses a file that is not what SHA256SUMS lists' {
            $web = New-Web
            $web.Files[$script:Release + 'ssh-paste.ps1'] = [System.Text.Encoding]::ASCII.GetBytes("`$script:Version = '0.0.0-dev'`n")
            { Get-Source 'v0.1.7' '' $web } | Should -Throw '*ssh-paste.ps1 does not match SHA256SUMS*'
            $web = New-Web
            $web.Files[$script:Release + 'ssh-paste.cmd'] = [System.Text.Encoding]::ASCII.GetBytes("changed`n")
            { Get-Source 'v0.1.7' '' $web } | Should -Throw '*ssh-paste.cmd does not match SHA256SUMS*'
        }

        It 'refuses a release whose SHA256SUMS does not list a payload file' {
            $web = New-Web
            $web.Files[$script:Release + 'SHA256SUMS'] = [System.Text.Encoding]::ASCII.GetBytes(('{0}  install.ps1' -f ('0' * 64)))
            { Get-Source 'v0.1.7' '' $web } | Should -Throw '*does not list ssh-paste.ps1*'
        }

        It 'takes src/ from the raw ref for main, for a branch and for an explicit ref, and reads no SHA256SUMS then' {
            foreach ($case in @(@('main', ''), @('main', 'v0.1.7'), @('v0.1.7', 'main'))) {
                $web = New-Web
                $s = Get-Source $case[0] $case[1] $web
                $s.Tag | Should -BeNullOrEmpty
                @($web.Asked | Where-Object { $_ -like '*SHA256SUMS' -or $_ -like '*/releases/download/*' }).Count | Should -Be 0 -Because ($case -join ' / ')
            }
        }

        It 'checks that the release ships the version of its tag before it installs anything' {
            $text = [System.IO.File]::ReadAllText($script:InstallPath)
            $text | Should -Match '\$version -ne \$source\.Tag\.Substring\(1\)'
        }
    }

    Context 'Remove-ManagedBlockText' {
        BeforeAll {
            function New-WithBlock {
                param([string]$Text, [switch]$CreatedFile)
                return (Set-ManagedBlock $Text @('h1', 'h2') $script:Proxy -CreatedFile:$CreatedFile)
            }
        }

        It 'reports nothing removed for a config without a block' {
            foreach ($text in @('', "Host a`n", "Host a`r`n  User x", "# note: $($script:BlockBegin)`n")) {
                $r = Invoke-InstallerText $text
                $r.Removed | Should -BeFalse
                $r.Text | Should -BeExactly $text
                $r.CreatedFile | Should -BeFalse
            }
        }

        It 'gives the original text back after a block written by the core: <Name>' -ForEach @(
            @{ Name = 'empty file'; Text = '' }
            @{ Name = 'LF file'; Text = "Host a`n  HostName x`n`nHost b`n  HostName y`n" }
            @{ Name = 'no trailing newline'; Text = "Host a`n  HostName x" }
            @{ Name = 'blank lines first'; Text = "`n`n# my hosts`nHost a`n" }
            @{ Name = 'CRLF file'; Text = "Host a`r`n  HostName x`r`n`r`nHost b`r`n  HostName y`r`n" }
            @{ Name = 'CRLF without trailing newline'; Text = "Host a`r`n  HostName x" }
            @{ Name = 'global options first'; Text = "ServerAliveInterval 30`n`nHost a`n  HostName x`n" }
        ) {
            foreach ($created in @($true, $false)) {
                $withBlock = New-WithBlock $Text -CreatedFile:$created
                $r = Invoke-InstallerText $withBlock
                $r.Removed | Should -BeTrue
                $r.CreatedFile | Should -Be $created
                $r.Text | Should -BeExactly $Text
                # the same result as the core's own removal
                (Set-ManagedBlock $withBlock @() $script:Proxy) | Should -BeExactly $r.Text
            }
        }

        It 'leaves other text and other line endings alone' {
            $text = "Host a`n  User x`r`n" + (New-WithBlock '' -CreatedFile) + "`r`nHost b`n"
            $r = Invoke-InstallerText $text
            $r.Text | Should -BeExactly "Host a`n  User x`r`n`r`nHost b`n"
        }

        It 'throws when the block has no end marker' {
            { Invoke-InstallerText "$($script:BlockBegin)`nHost a`n" } | Should -Throw '*no end marker*'
        }

        It 'only takes whole-line markers' {
            $text = "x $($script:BlockBegin)`nHost a`n"
            (Invoke-InstallerText $text).Removed | Should -BeFalse
        }
    }

    Context 'Remove-ConfigBlock (what -Uninstall does to the ssh config)' {
        BeforeAll {
            $script:Home2 = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-inst-' + [guid]::NewGuid().ToString('N'))
            function Initialize-Home {
                Remove-Item -LiteralPath $script:Home2 -Recurse -Force -ErrorAction SilentlyContinue
                [void](New-Item -ItemType Directory -Path (Join-Path $script:Home2 '.ssh'))
                return (Join-Path $script:Home2 '.ssh/config')
            }
            function Write-Bytes { param([string]$Path, [byte[]]$Bytes) [System.IO.File]::WriteAllBytes($Path, $Bytes) }
            function Get-Utf8 { param([string]$Text) return ,[System.Text.Encoding]::UTF8.GetBytes($Text) }
        }
        AfterAll { Remove-Item -LiteralPath $script:Home2 -Recurse -Force -ErrorAction SilentlyContinue }

        It 'returns false and touches nothing when there is no config or no block' {
            $cfg = Initialize-Home
            Invoke-InstallerConfigResult $cfg | Should -BeFalse
            Write-Bytes $cfg (Get-Utf8 "Host a`n")
            Invoke-InstallerConfigResult $cfg | Should -BeFalse
            [System.IO.File]::ReadAllText($cfg) | Should -BeExactly "Host a`n"
        }

        It 'deletes a config whose block says ssh-paste created it, and the empty .ssh folder' {
            $cfg = Initialize-Home
            Write-Bytes $cfg (Get-Utf8 (Set-ManagedBlock '' @('h1') $script:Proxy -CreatedFile))
            Invoke-InstallerConfigResult $cfg | Should -BeTrue
            Test-Path -LiteralPath $cfg | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Home2 '.ssh') | Should -BeFalse
        }

        It 'keeps the .ssh folder when it holds something else' {
            $cfg = Initialize-Home
            Write-Bytes $cfg (Get-Utf8 (Set-ManagedBlock '' @('h1') $script:Proxy -CreatedFile))
            Set-Content -LiteralPath (Join-Path $script:Home2 '.ssh/id_x') -Value 'k'
            [void](Invoke-InstallerConfigResult $cfg)
            Test-Path -LiteralPath $cfg | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Home2 '.ssh/id_x') | Should -BeTrue
        }

        It 'never deletes a config without the created-file line, even if only the block is left' {
            $cfg = Initialize-Home
            Write-Bytes $cfg (Get-Utf8 (Set-ManagedBlock '' @('h1') $script:Proxy))
            Invoke-InstallerConfigResult $cfg | Should -BeTrue
            Test-Path -LiteralPath $cfg | Should -BeTrue
            (Get-Item -LiteralPath $cfg).Length | Should -Be 0
        }

        It 'keeps what the user added to a config that ssh-paste created' {
            $cfg = Initialize-Home
            Write-Bytes $cfg (Get-Utf8 ((Set-ManagedBlock '' @('h1') $script:Proxy -CreatedFile) + "Host mine`n  User me`n"))
            [void](Invoke-InstallerConfigResult $cfg)
            [System.IO.File]::ReadAllText($cfg) | Should -BeExactly "Host mine`n  User me`n"
        }

        It 'keeps a byte order mark, CRLF line endings and bytes that are not UTF-8' {
            $cfg = Initialize-Home
            $orig = [byte[]](@(0x48, 0x6F, 0x73, 0x74, 0x20, 0x61, 0x0D, 0x0A, 0x23, 0x20, 0xE9, 0xFF, 0x0D, 0x0A))   # "Host a", "# <E9><FF>" in CRLF
            $block = Get-Utf8 ((Set-ManagedBlock '' @('h1') $script:Proxy) -replace "`r?`n", "`r`n")
            $bom = [byte[]]@(0xEF, 0xBB, 0xBF)
            Write-Bytes $cfg ([byte[]](@($bom) + @($block) + @($orig)))
            Invoke-InstallerConfigResult $cfg | Should -BeTrue
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($cfg)) | Should -BeExactly ([Convert]::ToBase64String([byte[]](@($bom) + @($orig))))
        }

        It 'leaves no temporary file behind' {
            $cfg = Initialize-Home
            Write-Bytes $cfg (Get-Utf8 ((Set-ManagedBlock '' @('h1') $script:Proxy -CreatedFile) + "Host mine`n"))
            [void](Invoke-InstallerConfigResult $cfg)
            @(Get-ChildItem -LiteralPath (Join-Path $script:Home2 '.ssh') -Force | ForEach-Object { $_.Name }) | Should -BeExactly @('config')
        }

        It 'throws, and changes nothing, when the block has no end marker' {
            $cfg = Initialize-Home
            $broken = "$($script:BlockBegin)`nHost a`n"
            Write-Bytes $cfg (Get-Utf8 $broken)
            { Invoke-InstallerConfigResult $cfg } | Should -Throw '*no end marker*'
            [System.IO.File]::ReadAllText($cfg) | Should -BeExactly $broken
        }

        It 'does to the config what ssh-paste --disable does: <Name>' -ForEach @(
            @{ Name = 'created by ssh-paste'; Existing = $null; Extra = '' }
            @{ Name = 'created, then edited by the user'; Existing = $null; Extra = "Host mine`n  User me`n" }
            @{ Name = 'existing config'; Existing = "Host a`n  HostName x`n"; Extra = '' }
            @{ Name = 'existing empty config'; Existing = ''; Extra = '' }
            @{ Name = 'existing CRLF config'; Existing = "Host a`r`n  HostName x`r`n"; Extra = '' }
        ) {
            $theirs = Join-Path $script:Home2 'core'
            $ours = Join-Path $script:Home2 'installer'
            foreach ($d in @($theirs, $ours)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; [void](New-Item -ItemType Directory -Path (Join-Path $d '.ssh')) }
            $createdFile = ($null -eq $Existing)
            $baseText = ''
            if (-not $createdFile) { $baseText = $Existing }
            $text = (Set-ManagedBlock $baseText @('h1') $script:Proxy -CreatedFile:$createdFile) + $Extra
            Write-Bytes (Join-Path $theirs '.ssh/config') (Get-Utf8 $text)
            Write-Bytes (Join-Path $ours '.ssh/config') (Get-Utf8 $text)

            $script:CoreCfg = Join-Path $theirs '.ssh/config'
            Mock Get-SshConfigPath { return $script:CoreCfg }
            Mock Write-Info { }
            [void](Invoke-Disable @())
            [void](Invoke-InstallerConfigResult (Join-Path $ours '.ssh/config'))

            (Test-Path -LiteralPath (Join-Path $ours '.ssh/config')) | Should -Be (Test-Path -LiteralPath $script:CoreCfg)
            (Test-Path -LiteralPath (Join-Path $ours '.ssh')) | Should -Be (Test-Path -LiteralPath (Join-Path $theirs '.ssh'))
            if (Test-Path -LiteralPath $script:CoreCfg) {
                [System.IO.File]::ReadAllText((Join-Path $ours '.ssh/config')) | Should -BeExactly ([System.IO.File]::ReadAllText($script:CoreCfg))
            }
        }
    }
}

Describe 'Get-SshOptionKey' {
    It 'is the lower-cased name before "=" or white space: <Value>' -ForEach $sharedCases.optionKey {
        Get-SshOptionKey $Value | Should -BeExactly $Expected
    }

    # ssh skips white space before the keyword (readconf.c, process_config_line), so
    # " RequestTTY=force" is a RequestTTY setting and must not slip past the drop list.
    It 'ignores white space before the name, as ssh does' {
        Get-SshOptionKey '  RequestTTY=force' | Should -BeExactly 'requesttty'
        Get-SshOptionKey "`tProxyJump a" | Should -BeExactly 'proxyjump'
        Get-SshOptionKey '   ' | Should -BeExactly ''
    }

    It 'lets Get-UploadSshArguments drop a setting written with white space before its name' {
        $parsed = Split-SshArguments @('-o', '  RequestTTY=force', '-o', "`tRemoteCommand rm -rf x", 'host', '-o', ' StdinNull=yes')
        $a = @(Get-UploadSshArguments -Parsed $parsed -Hash ('0' * 32) -Size 1)
        (($a | Select-Object -SkipLast 1) -join ' ') | Should -Not -Match 'force|rm -rf|StdinNull=yes'
    }
}

Describe 'ConvertFrom-SshG' {
    It 'turns "key value" lines into a map with lower-case keys' {
        $m = ConvertFrom-SshG "user alice`nHostName 10.0.0.1`nPORT 2222`n"
        $m['user'] | Should -BeExactly 'alice'
        $m['hostname'] | Should -BeExactly '10.0.0.1'
        $m['port'] | Should -BeExactly '2222'
        $m.Keys.Count | Should -Be 3
    }

    It 'keeps the first value of a repeated key, as ssh does (identityfile, ...)' {
        $m = ConvertFrom-SshG "identityfile ~/.ssh/id_ed25519`nidentityfile ~/.ssh/id_rsa`nrequesttty auto`nRequestTTY force`n"
        $m['identityfile'] | Should -BeExactly '~/.ssh/id_ed25519'
        $m['requesttty'] | Should -BeExactly 'auto'
    }

    It 'keeps spaces inside a value' {
        (ConvertFrom-SshG 'remotecommand top -b -n 1')['remotecommand'] | Should -BeExactly 'top -b -n 1'
        (ConvertFrom-SshG 'proxycommand ssh -W %h:%p jump')['proxycommand'] | Should -BeExactly 'ssh -W %h:%p jump'
    }

    It 'reads CRLF output (ssh.exe on Windows)' {
        $m = ConvertFrom-SshG "requesttty auto`r`nsessiontype default`r`nstdinnull no`r`n"
        $m['requesttty'] | Should -BeExactly 'auto'
        $m['sessiontype'] | Should -BeExactly 'default'
        $m['stdinnull'] | Should -BeExactly 'no'
    }

    It 'skips empty lines and lines without a value, and gives an empty map for empty text' {
        $m = ConvertFrom-SshG "`n`nuser bob`nlonelykey`n   `n"
        $m.Keys.Count | Should -Be 1
        $m['user'] | Should -BeExactly 'bob'
        (ConvertFrom-SshG '').Keys.Count | Should -Be 0
        (ConvertFrom-SshG $null).Keys.Count | Should -Be 0
    }

    It 'is the shape Test-InteractiveSsh reads' {
        $m = ConvertFrom-SshG "requesttty false`nsessiontype default`n"
        Test-InteractiveSsh (Split-SshArguments @('host')) $m | Should -BeFalse
    }
}

Describe 'Get-TrimmedPng' {
    BeforeAll {
        function Add-PngChunk {
            param($List, [string]$Type, [byte[]]$Data)
            $length = $Data.Length
            $List.AddRange([byte[]]@([byte](($length -shr 24) -band 255), [byte](($length -shr 16) -band 255), [byte](($length -shr 8) -band 255), [byte]($length -band 255)))
            $List.AddRange([System.Text.Encoding]::ASCII.GetBytes($Type))
            $List.AddRange($Data)
            $List.AddRange([byte[]]@(1, 2, 3, 4))   # the CRC is not checked
        }
        function New-PngBytes {
            param([int]$DataSize = 40, [byte[]]$IdatData)
            $list = New-Object 'System.Collections.Generic.List[byte]'
            $list.AddRange([byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
            Add-PngChunk $list 'IHDR' (New-Object byte[] 13)
            if ($null -eq $IdatData) { $IdatData = [byte[]](1..$DataSize | ForEach-Object { [byte]($_ % 251) }) }
            Add-PngChunk $list 'IDAT' $IdatData
            Add-PngChunk $list 'IEND' (New-Object byte[] 0)
            return , $list.ToArray()
        }
        $script:Exact = New-PngBytes
    }

    It 'returns an exact PNG unchanged' {
        $r = Get-TrimmedPng $script:Exact
        ($r -is [byte[]]) | Should -BeTrue
        $r.Length | Should -Be $script:Exact.Length
        ($r -join ',') | Should -BeExactly ($script:Exact -join ',')
    }

    It 'cuts the padding that clipboard memory blocks carry after IEND' {
        foreach ($pad in @(1, 7, 100, 4096)) {
            $padded = New-Object byte[] ($script:Exact.Length + $pad)
            [Array]::Copy($script:Exact, $padded, $script:Exact.Length)
            $r = Get-TrimmedPng $padded
            $r.Length | Should -Be $script:Exact.Length -Because "$pad padding bytes"
            ($r -join ',') | Should -BeExactly ($script:Exact -join ',')
        }
    }

    It 'cuts padding that looks like another chunk' {
        $padded = [byte[]](@($script:Exact) + @(0, 0, 0, 0) + @([System.Text.Encoding]::ASCII.GetBytes('IEND')) + @(9, 9, 9, 9))
        (Get-TrimmedPng $padded).Length | Should -Be $script:Exact.Length
    }

    It 'returns $null for a PNG that is cut short, wherever the cut is' {
        $bad = @()
        for ($n = 0; $n -lt $script:Exact.Length; $n++) {
            $part = New-Object byte[] $n
            if ($n -gt 0) { [Array]::Copy($script:Exact, $part, $n) }
            if ($null -ne (Get-TrimmedPng $part)) { $bad += $n }
        }
        $bad.Count | Should -Be 0 -Because ('accepted lengths: ' + ($bad -join ','))
    }

    It 'returns $null when there is no IEND chunk, even with the right signature and a final chunk' {
        $list = New-Object 'System.Collections.Generic.List[byte]'
        $list.AddRange([byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
        Add-PngChunk $list 'IHDR' (New-Object byte[] 13)
        Add-PngChunk $list 'IDAT' (New-Object byte[] 10)
        Get-TrimmedPng ($list.ToArray()) | Should -BeNullOrEmpty
    }

    It 'does not stop at the letters IEND inside the image data' {
        $data = [byte[]](@(5, 5) + @([System.Text.Encoding]::ASCII.GetBytes('IEND')) + @(0, 0, 0, 0, 6, 6))
        $png = New-PngBytes -IdatData $data
        (Get-TrimmedPng $png).Length | Should -Be $png.Length
    }

    It 'returns $null when a chunk claims to be longer than the data' {
        $png = [byte[]]$script:Exact.Clone()
        $png[8] = 0xFF; $png[9] = 0xFF; $png[10] = 0xFF; $png[11] = 0xFF   # IHDR length 4 GB - 1
        Get-TrimmedPng $png | Should -BeNullOrEmpty
    }

    It 'returns $null for data that is not a PNG: <Name>' -ForEach @(
        @{ Name = 'a JPEG'; Bytes = [byte[]](@(0xFF, 0xD8, 0xFF, 0xE0) + @(1..60)) }
        @{ Name = 'a BMP'; Bytes = [byte[]](@(0x42, 0x4D) + @(1..60)) }
        @{ Name = 'zeros'; Bytes = (New-Object byte[] 64) }
        @{ Name = 'text'; Bytes = [System.Text.Encoding]::ASCII.GetBytes('this is not a png file at all, just text') }
        @{ Name = 'fewer than 20 bytes'; Bytes = [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) }
        @{ Name = 'an empty array'; Bytes = [byte[]]@() }
    ) {
        Get-TrimmedPng $Bytes | Should -BeNullOrEmpty
    }

    It 'returns $null when one signature byte is wrong' {
        for ($k = 0; $k -lt 8; $k++) {
            $png = [byte[]]$script:Exact.Clone()
            $png[$k] = [byte](($png[$k] + 1) % 256)
            Get-TrimmedPng $png | Should -BeNullOrEmpty -Because "signature byte $k"
        }
    }

    It 'returns $null for $null' {
        Get-TrimmedPng $null | Should -BeNullOrEmpty
    }

    It 'handles a real PNG and trims zero padding after it' {
        $real = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==')
        (Get-TrimmedPng $real).Length | Should -Be $real.Length
        $padded = New-Object byte[] ($real.Length + 64)
        [Array]::Copy($real, $padded, $real.Length)
        (Get-TrimmedPng $padded).Length | Should -Be $real.Length
    }
}

Describe 'ConvertFrom-Dib' {
    It 'returns $null for nothing or for a header that is too short (before any image API is used)' {
        ConvertFrom-Dib $null | Should -BeNullOrEmpty
        ConvertFrom-Dib ([byte[]]@()) | Should -BeNullOrEmpty
        ConvertFrom-Dib (New-Object byte[] 39) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-NativeCapture' {
    It 'returns the exit code and keeps stdout and stderr apart' {
        $r = Invoke-NativeCapture (Get-ThisPowerShell) @('-NoLogo', '-NoProfile', '-Command', "[Console]::Out.Write('to-out'); [Console]::Error.Write('to-err'); exit 3") 60
        $r.ExitCode | Should -Be 3
        $r.Out | Should -BeExactly 'to-out'
        $r.Err | Should -BeExactly 'to-err'
    }

    It 'closes the child''s stdin, so a program that reads it sees the end at once' {
        $r = Invoke-NativeCapture (Get-ThisPowerShell) @('-NoLogo', '-NoProfile', '-Command', "[Console]::Out.Write('[' + [Console]::In.ReadToEnd() + ']')") 60
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeExactly '[]'
    }

    It 'does not deadlock on a lot of output on both streams' {
        $r = Invoke-NativeCapture (Get-ThisPowerShell) @('-NoLogo', '-NoProfile', '-Command', "[Console]::Out.Write('x' * 300000); [Console]::Error.Write('y' * 300000)") 60
        $r.ExitCode | Should -Be 0
        $r.Out.Length | Should -Be 300000
        $r.Err.Length | Should -Be 300000
    }

    It 'kills a program that does not finish in time and says so' {
        $started = [DateTime]::UtcNow
        { Invoke-NativeCapture (Get-ThisPowerShell) @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 60') 2 } | Should -Throw '*did not finish in 2 seconds*'
        ([DateTime]::UtcNow - $started).TotalSeconds | Should -BeLessThan 30
    }

    It 'throws when the program does not exist' {
        { Invoke-NativeCapture (Join-Path ([System.IO.Path]::GetTempPath()) 'ssh-paste-no-such-program') @() 5 } | Should -Throw
    }
}

Describe 'Get-UploadedPath' {
    BeforeAll {
        $script:State = @{ Hash = '0123456789abcdef0123456789abcdef'; Png = [byte[]](1..40) }
        $script:ImagePath = '/tmp/ssh-paste-0123456789abcdef0123456789abcdef.png'
        function New-TestWatcher {
            return @{ SshPath = 'ssh'; SshVersion = [version]'9.0'; Parsed = (Split-SshArguments @('-p', '2222', 'alice@h')); NoProxy = $false; Pin = $null
                WakeAt = [DateTime]::MaxValue; Uploaded = @{}; Failed = @{} }
        }
        function Assert-Wake {
            # $W.WakeAt is about $Seconds from now (the clock moves a little while a test runs).
            param($W, [double]$Seconds)
            $left = ($W.WakeAt - [DateTime]::UtcNow).TotalSeconds
            $left | Should -BeGreaterThan ($Seconds - 10)
            $left | Should -BeLessThan ($Seconds + 2)
        }
    }

    It 'uploads once per image and then answers from the cache' {
        Mock Send-Image { return $script:ImagePath }
        $w = New-TestWatcher
        Get-UploadedPath $w $script:State | Should -BeExactly $script:ImagePath
        Get-UploadedPath $w $script:State | Should -BeExactly $script:ImagePath
        Should -Invoke Send-Image -Times 1 -Exactly
        $w.Uploaded[$script:State.Hash].Path | Should -BeExactly $script:ImagePath
    }

    It 'passes the hash, the size and the user''s options on to the upload' {
        Mock Send-Image { return $script:ImagePath }
        $w = New-TestWatcher
        [void](Get-UploadedPath $w $script:State)
        Should -Invoke Send-Image -Times 1 -Exactly -ParameterFilter {
            $Hash -ceq '0123456789abcdef0123456789abcdef' -and $Png.Length -eq 40 -and
            $Arguments[$Arguments.Count - 1].EndsWith(" ssh-paste 0123456789abcdef0123456789abcdef 40 png 1440 '/tmp'") -and
            $Arguments -contains '-p' -and $Arguments -contains 'alice@h' -and $Arguments -contains 'StdinNull=no'
        }
    }

    It 'passes the watcher''s --keep and --dir on to the upload and to the reply check' {
        Mock Send-Image { return $script:ImagePath }
        $w = New-TestWatcher
        $w.Keep = '30m'
        $w.Class = 'k30m-'
        $w.Dir = '/home/u/shots'
        [void](Get-UploadedPath $w $script:State)
        Should -Invoke Send-Image -Times 1 -Exactly -ParameterFilter {
            $Arguments[$Arguments.Count - 1].EndsWith(" 40 png 30 '/home/u/shots' k30m-") -and $Dir -ceq '/home/u/shots' -and $Class -ceq 'k30m-'
        }
    }

    It 'counts the cache from the end of the upload' {
        Mock Send-Image { Start-Sleep -Milliseconds 300; return $script:ImagePath }
        $w = New-TestWatcher
        $before = [DateTime]::UtcNow
        [void](Get-UploadedPath $w $script:State)
        ($w.Uploaded['0123456789abcdef0123456789abcdef'].At - $before).TotalMilliseconds | Should -BeGreaterOrEqual 250
    }

    It 'uploads to the pinned address when the watcher has a pin, and not otherwise' {
        Mock Send-Image { return $script:ImagePath }
        $w = New-TestWatcher
        $w.NoProxy = $true
        $w.Pin = @{ HostName = '203.0.113.7'; Port = 2200; HostKeyAlias = '[h]:2200' }
        [void](Get-UploadedPath $w $script:State)
        Should -Invoke Send-Image -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains 'HostName=203.0.113.7' -and $Arguments -contains 'Port=2200' -and $Arguments -contains 'HostKeyAlias=[h]:2200' -and $Arguments -contains 'ProxyCommand=none'
        }
        $plain = New-TestWatcher
        [void](Get-UploadedPath $plain $script:State)
        Should -Invoke Send-Image -Times 1 -Exactly -ParameterFilter { @($Arguments | Where-Object { $_ -like 'HostKeyAlias=*' }).Count -eq 0 }
    }

    It 'uploads again after the cache time, so the server''s day-old cleanup never removes a path we paste' {
        Mock Send-Image { return $script:ImagePath }
        $w = New-TestWatcher
        [void](Get-UploadedPath $w $script:State)
        $w.Uploaded[$script:State.Hash].At = [DateTime]::UtcNow.AddHours(-($script:UploadCacheHours + 1))
        [void](Get-UploadedPath $w $script:State)
        Should -Invoke Send-Image -Times 2 -Exactly
    }

    It 'asks to be woken when the upload is due for a refresh (upload time + the cache hours)' {
        Mock Send-Image { return $script:ImagePath }
        $w = New-TestWatcher
        [void](Get-UploadedPath $w $script:State)
        Assert-Wake $w ($script:UploadCacheHours * 3600)
        $w.WakeAt | Should -Be $w.Uploaded[$script:State.Hash].At.AddHours($script:UploadCacheHours)
        # A cache hit keeps the wake time tied to the upload, not to the call.
        $w.WakeAt = [DateTime]::MaxValue
        [void](Get-UploadedPath $w $script:State)
        $w.WakeAt | Should -Be $w.Uploaded[$script:State.Hash].At.AddHours($script:UploadCacheHours)
    }

    Context 'a failing upload' {
        BeforeEach {
            Mock Send-Image { throw 'ssh exited with 255: Permission denied' }
        }

        It 'returns nothing and does not throw, even where the beep itself fails (no sound device, Linux)' {
            $w = New-TestWatcher
            { [void](Get-UploadedPath $w $script:State) } | Should -Not -Throw
            Get-UploadedPath (New-TestWatcher) $script:State | Should -BeNullOrEmpty
        }

        It 'is not retried right away, and records the message, the time and a count of 1' {
            $w = New-TestWatcher
            Get-UploadedPath $w $script:State | Should -BeNullOrEmpty
            Get-UploadedPath $w $script:State | Should -BeNullOrEmpty
            Should -Invoke Send-Image -Times 1 -Exactly
            $f = $w.Failed[$script:State.Hash]
            $f.Message | Should -Match 'Permission denied'
            $f.At | Should -BeOfType ([datetime])
            $f.Count | Should -Be 1
            $w.Uploaded.ContainsKey($script:State.Hash) | Should -BeFalse
        }

        It 'asks to be woken when the retry is due, and keeps that time on a call that does not retry' {
            $w = New-TestWatcher
            [void](Get-UploadedPath $w $script:State)
            Assert-Wake $w $script:RetryFailedSeconds
            $at = $w.WakeAt
            $w.WakeAt = [DateTime]::MaxValue
            [void](Get-UploadedPath $w $script:State)
            $w.WakeAt | Should -Be $w.Failed[$script:State.Hash].At.AddSeconds($script:RetryFailedSeconds)
        }

        It 'retries after the pause and counts the failures' {
            $w = New-TestWatcher
            [void](Get-UploadedPath $w $script:State)
            $w.Failed[$script:State.Hash].At = [DateTime]::UtcNow.AddSeconds(-($script:RetryFailedSeconds + 1))
            [void](Get-UploadedPath $w $script:State)
            Should -Invoke Send-Image -Times 2 -Exactly
            $w.Failed[$script:State.Hash].Count | Should -Be 2
        }

        It 'waits <Delay> s after failure number <Count> (30 s doubling, at most 30 min)' -ForEach @(
            @{ Count = 1; Delay = 30 }
            @{ Count = 2; Delay = 60 }
            @{ Count = 3; Delay = 120 }
            @{ Count = 4; Delay = 240 }
            @{ Count = 5; Delay = 480 }
            @{ Count = 6; Delay = 960 }
            @{ Count = 7; Delay = 1800 }
            @{ Count = 8; Delay = 1800 }
            @{ Count = 20; Delay = 1800 }
        ) {
            # Just before the delay has passed: no upload, and the wake time is the retry time.
            $w = New-TestWatcher
            $w.Failed[$script:State.Hash] = @{ Message = 'x'; At = [DateTime]::UtcNow.AddSeconds(-($Delay - 5)); Count = $Count }
            Get-UploadedPath $w $script:State | Should -BeNullOrEmpty
            Should -Invoke Send-Image -Times 0 -Exactly
            Assert-Wake $w 5

            # Just after: it tries again and the next delay is longer (or the cap).
            $w = New-TestWatcher
            $w.Failed[$script:State.Hash] = @{ Message = 'x'; At = [DateTime]::UtcNow.AddSeconds(-($Delay + 1)); Count = $Count }
            [void](Get-UploadedPath $w $script:State)
            Should -Invoke Send-Image -Times 1 -Exactly
            $w.Failed[$script:State.Hash].Count | Should -Be ($Count + 1)
            Assert-Wake $w ([Math]::Min(1800, 30 * [Math]::Pow(2, $Count)))
        }

        It 'keeps the failures of different images apart' {
            $w = New-TestWatcher
            $other = @{ Hash = 'fedcba9876543210fedcba9876543210'; Png = [byte[]](5..50) }
            [void](Get-UploadedPath $w $script:State)
            [void](Get-UploadedPath $w $other)
            Should -Invoke Send-Image -Times 2 -Exactly
            $w.Failed.Count | Should -Be 2
        }
    }

    It 'succeeds after failures: forgets them, caches the path and moves the wake time to the refresh' {
        $script:Fail = $true
        Mock Send-Image { if ($script:Fail) { throw 'ssh exited with 255: Connection refused' }; return $script:ImagePath }
        $w = New-TestWatcher
        [void](Get-UploadedPath $w $script:State)
        $w.Failed[$script:State.Hash].At = [DateTime]::UtcNow.AddSeconds(-31)
        [void](Get-UploadedPath $w $script:State)
        $w.Failed[$script:State.Hash].Count | Should -Be 2
        $w.Failed[$script:State.Hash].At = [DateTime]::UtcNow.AddSeconds(-61)
        $script:Fail = $false
        Get-UploadedPath $w $script:State | Should -BeExactly $script:ImagePath
        $w.Failed.ContainsKey($script:State.Hash) | Should -BeFalse
        Assert-Wake $w ($script:UploadCacheHours * 3600)
        Get-UploadedPath $w $script:State | Should -BeExactly $script:ImagePath
        Should -Invoke Send-Image -Times 3 -Exactly
    }

    It 'a failure after a cached success does not hide the cached path before it expires' {
        Mock Send-Image { return $script:ImagePath }
        $w = New-TestWatcher
        [void](Get-UploadedPath $w $script:State)
        $w.Failed[$script:State.Hash] = @{ Message = 'old'; At = [DateTime]::UtcNow; Count = 3 }
        Get-UploadedPath $w $script:State | Should -BeExactly $script:ImagePath
        Should -Invoke Send-Image -Times 1 -Exactly
    }
}

Describe 'New-Watcher' {
    It 'starts idle: nothing read, no wake time, a fresh token per watcher, the pin and the proxy flag kept' {
        Mock Get-SshVersion { return [version]'9.6' }
        Mock Get-HostMatcher { return @{ Kind = 'test'; Window = [IntPtr]::Zero; Pids = $null } }
        $pin = @{ HostName = '1.2.3.4'; Port = 22; HostKeyAlias = 'h' }
        $a = New-Watcher -SshPath 'ssh' -Parsed (Split-SshArguments @('h')) -NoProxy -Pin $pin
        $b = New-Watcher -SshPath 'ssh' -Parsed (Split-SshArguments @('h'))
        $a.Token | Should -Not -Be $b.Token
        $a.LastSeq | Should -Be -1
        $a.WakeAt | Should -Be ([DateTime]::MaxValue)
        $a.NoProxy | Should -BeTrue
        $a.Pin.HostName | Should -BeExactly '1.2.3.4'
        $a.SshVersion | Should -Be ([version]'9.6')
        $b.NoProxy | Should -BeFalse
        $b.Pin | Should -BeNullOrEmpty
        $a.Uploaded.Count | Should -Be 0
        $a.Failed.Count | Should -Be 0
    }
}

Describe 'watcher state machine (Invoke-WatcherTick, Restore-Clipboard) against a simulated clipboard' -Skip:$onWindows {
    # Windows is skipped because Initialize-Native there loads the real SshPasteNative; this
    # block needs the stand-in below. Nothing here touches a real clipboard, window or ssh:
    #   - SshPasteNative is a stand-in whose foreground window and clipboard sequence number
    #     are fields the tests set;
    #   - the clipboard is $script:Entry plus that sequence number; Read-ClipboardImage and
    #     Set-SshPasteClipboard are mocked to read and write it, and every write bumps the
    #     sequence number, as Windows does;
    #   - Send-Image is mocked (it counts uploads and can fail or run code "during" the upload);
    #   - Get-UploadedPath, Invoke-WatcherTick, Restore-Clipboard, Test-HostForeground and
    #     New-Watcher are the real ones.
    # Windows: 1001 and 3003 are two terminal windows, 2002 and 5005 are other apps.
    BeforeAll {
        if (-not ('SshPasteNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class SshPasteNative {
    public static long Foreground;
    public static uint Sequence;
    public static Dictionary<long, long> RootOwner = new Dictionary<long, long>();
    public static Dictionary<long, uint> ProcessOf = new Dictionary<long, uint>();
    public static IntPtr GetForegroundWindow() { return new IntPtr(Foreground); }
    public static uint GetClipboardSequenceNumber() { return Sequence; }
    public static IntPtr GetAncestor(IntPtr hWnd, uint flags) {
        long owner;
        if (RootOwner.TryGetValue(hWnd.ToInt64(), out owner)) return new IntPtr(owner);
        return hWnd;
    }
    public static uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId) {
        uint pid;
        processId = ProcessOf.TryGetValue(hWnd.ToInt64(), out pid) ? pid : 0;
        return 1;
    }
}
'@
        }
        if ($null -eq ([SshPasteNative].GetField('Foreground'))) { throw 'SshPasteNative is the real type here; these tests need the stand-in' }

        $script:TerminalA = 1001
        $script:Other = 2002
        $script:TerminalB = 3003
        $script:OtherToo = 5005

        function New-FakePng {
            param([int]$Seed)
            $bytes = New-Object byte[] 64
            for ($i = 0; $i -lt 64; $i++) { $bytes[$i] = [byte](($i * 7 + $Seed * 31) % 251) }
            return , $bytes
        }

        function Reset-World {
            [SshPasteNative]::Foreground = 0
            [SshPasteNative]::Sequence = 1
            [SshPasteNative]::RootOwner.Clear()
            [SshPasteNative]::ProcessOf.Clear()
            $script:Entry = $null          # what is on the clipboard: Png, Text, HasFiles, Owner, Token (Owner $null: not written by ssh-paste)
            $script:Writes = New-Object System.Collections.ArrayList
            $script:Uploads = New-Object System.Collections.ArrayList
            $script:Reads = 0
            $script:FailNext = 0           # how many of the next uploads fail
            $script:DuringUpload = $null   # runs inside Send-Image: something happens while we upload
            $script:AfterRead = $null      # runs after Read-ClipboardImage took its snapshot
            $script:BeforeWrite = $null    # runs inside Set-SshPasteClipboard, before the clipboard is written
            $script:ReadFails = 0
            $script:Prefix = @{}           # ssh path -> directory the "server" answers with
            $script:NextWindow = $script:TerminalA
        }

        function Set-Focus { param([long]$Window) [SshPasteNative]::Foreground = $Window }

        function Copy-FromApp {
            # Another program puts an image (and optionally text or files) on the clipboard.
            param([byte[]]$Png, [string]$Text, [switch]$Files)
            $script:Entry = @{ Png = $Png; Text = $Text; HasFiles = [bool]$Files; Owner = $null; Token = $null }
            [SshPasteNative]::Sequence++
        }

        function Copy-TextFromApp {
            param([string]$Text)
            $script:Entry = @{ Png = $null; Text = $Text; HasFiles = $false; Owner = $null; Token = $null }
            [SshPasteNative]::Sequence++
        }

        function New-FakeWatcher {
            # The real New-Watcher, for a terminal window and a "server" (the ssh path names it).
            param([long]$Window, [string]$SshPath = 'ssh-a', [string]$Directory)
            $script:NextWindow = $Window
            if ($Directory) { $script:Prefix[$SshPath] = $Directory }
            return (New-Watcher -SshPath $SshPath -Parsed (Split-SshArguments @('alice@h')))
        }

        function Invoke-Ticks {
            param([Parameter(Mandatory)]$Watcher, [int]$Count = 1)
            for ($i = 0; $i -lt $Count; $i++) { Invoke-WatcherTick $Watcher }
        }

        function Move-Clock {
            # Advance the clock by shifting every time the watcher has stored into the past.
            param($Watcher, [double]$Seconds)
            foreach ($k in @($Watcher.Failed.Keys)) { $Watcher.Failed[$k].At = $Watcher.Failed[$k].At.AddSeconds(-$Seconds) }
            foreach ($k in @($Watcher.Uploaded.Keys)) { $Watcher.Uploaded[$k].At = $Watcher.Uploaded[$k].At.AddSeconds(-$Seconds) }
            if ($Watcher.WakeAt -ne [DateTime]::MaxValue) { $Watcher.WakeAt = $Watcher.WakeAt.AddSeconds(-$Seconds) }
        }

        function Get-PathFor {
            param([byte[]]$Png, [string]$Directory = '/tmp')
            return ($Directory + '/ssh-paste-' + (Get-ImageHash $Png) + '.png')
        }
    }

    BeforeEach {
        Reset-World
        Mock Get-SshVersion { return [version]'9.6' }
        Mock Get-HostMatcher { return @{ Kind = 'test terminal'; Window = [IntPtr]([long]$script:NextWindow); Pids = $null } }
        Mock Read-ClipboardImage {
            if ($script:ReadFails -gt 0) { $script:ReadFails--; throw 'the clipboard is busy' }
            $script:Reads++
            $e = $script:Entry
            $state = @{ Seq = [long][SshPasteNative]::Sequence; Png = $null; Hash = $null; HasText = $false; HasFiles = $false; Owner = $null; Token = $null; Text = $null }
            if ($null -ne $e) {
                $state.HasText = (-not [string]::IsNullOrEmpty($e.Text))
                $state.HasFiles = [bool]$e.HasFiles
                if ($null -ne $e.Png) {
                    $state.Png = $e.Png
                    $state.Hash = Get-ImageHash $e.Png
                    if ($null -ne $e.Owner) {
                        $state.Owner = [long]$e.Owner
                        $state.Token = [long]$e.Token
                        if ($state.HasText) { $state.Text = $e.Text }
                    }
                }
            }
            if ($null -ne $script:AfterRead) { & $script:AfterRead }
            return $state
        }
        Mock Set-SshPasteClipboard {
            # Like PendingClipboard.Write: refuses when the clipboard moved past -Basis.
            # Promise is 'open' for a promised text, then 'resolved' or 'failed'.
            param([byte[]]$Png, [string]$Text, [long]$Owner, [long]$Token, [switch]$Promise, [long]$Basis)
            if ($null -ne $script:BeforeWrite) { & $script:BeforeWrite }
            if ($Basis -ne [long][SshPasteNative]::Sequence) { throw 'could not write the clipboard: the clipboard changed since it was read' }
            $state = $null
            if ($Promise) { $state = 'open' }
            $script:Entry = @{ Png = $Png; Text = $Text; HasFiles = $false; Owner = $Owner; Token = $Token; Promise = $state }
            [SshPasteNative]::Sequence++
            [void]$script:Writes.Add(@{ Text = $Text; Owner = $Owner; Token = $Token })
        }
        # One promise for the whole fake clipboard: a session completes the promise of the
        # entry on the clipboard, which in these tests is always its own.
        Mock Complete-ClipboardPromise {
            param([string]$Text)
            if ($null -ne $script:Entry -and $script:Entry['Promise'] -eq 'open') {
                if ([string]::IsNullOrEmpty($Text)) { $script:Entry.Promise = 'failed' } else { $script:Entry.Promise = 'resolved' }
            }
        }
        Mock Test-ClipboardAnswers {
            param([string]$Text)
            $e = $script:Entry
            return ($null -ne $e -and $e.Text -ceq $Text -and $e['Promise'] -ne 'failed')
        }
        Mock Send-Image {
            param($SshPath, $Arguments, $Png, $Hash, $TimeoutSeconds)
            [void]$script:Uploads.Add(@{ Hash = $Hash; SshPath = $SshPath; Arguments = $Arguments })
            if ($null -ne $script:DuringUpload) { & $script:DuringUpload }
            if ($script:FailNext -gt 0) { $script:FailNext--; throw 'ssh exited with 255: Permission denied (publickey).' }
            $directory = '/tmp'
            if ($script:Prefix.ContainsKey($SshPath)) { $directory = $script:Prefix[$SshPath] }
            return ($directory + '/ssh-paste-' + $Hash + '.png')
        }
    }

    Context 'one watcher, one terminal window' {
        It 'does not upload a screenshot copied while another app is in front, until the terminal comes to the front' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:Other
            Copy-FromApp $png
            Invoke-Ticks $w 10
            $script:Uploads.Count | Should -Be 0
            $script:Writes.Count | Should -Be 0
            $script:Entry.Text | Should -BeNullOrEmpty
            $script:Entry.Owner | Should -BeNullOrEmpty -Because 'the image is still the app''s own entry'

            Set-Focus $script:TerminalA
            Invoke-Ticks $w 1
            $script:Uploads.Count | Should -Be 1
            $script:Writes.Count | Should -Be 1
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            $script:Entry.Png | Should -Be $png
        }

        It 'uploads and writes once, however many ticks follow' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $w 20
            $script:Uploads.Count | Should -Be 1
            $script:Writes.Count | Should -Be 1
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            $script:Entry.Owner | Should -Be $script:TerminalA
            $script:Entry.Token | Should -Be $w.Token
        }

        It 'puts the image back without the path when another app comes to the front, and re-adds the path on return without uploading again' {
            $png = New-FakePng 1
            $path = Get-PathFor $png
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $w 3

            Set-Focus $script:Other
            Invoke-Ticks $w 5
            $script:Entry.Text | Should -BeNullOrEmpty
            $script:Entry.Png | Should -Be $png
            $script:Entry.Owner | Should -Be 0 -Because 'a plain image, written by ssh-paste, for no window'
            $script:Entry.Token | Should -Be $w.Token
            $script:Writes.Count | Should -Be 2

            Set-Focus $script:TerminalA
            Invoke-Ticks $w 5
            $script:Entry.Text | Should -BeExactly $path
            $script:Writes.Count | Should -Be 3
            $script:Uploads.Count | Should -Be 1

            # And once more round, still one upload.
            Set-Focus $script:OtherToo
            Invoke-Ticks $w 2
            Set-Focus $script:TerminalA
            Invoke-Ticks $w 2
            $script:Entry.Text | Should -BeExactly $path
            $script:Uploads.Count | Should -Be 1
        }

        It 'uploads a new screenshot that replaces the old one, and pastes its own path' {
            $first = New-FakePng 1
            $second = New-FakePng 2
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $first
            Invoke-Ticks $w 3
            Copy-FromApp $second
            Invoke-Ticks $w 3
            $script:Uploads.Count | Should -Be 2
            $script:Entry.Text | Should -BeExactly (Get-PathFor $second)
            $script:Entry.Png | Should -Be $second
        }

        It 'has the remote path on the clipboard while the upload runs, so an early Ctrl+V pastes it' {
            $png = New-FakePng 4
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            $script:SeenDuringUpload = 'not called'
            $script:DuringUpload = { $script:SeenDuringUpload = $script:Entry.Text }
            Invoke-Ticks $w 1
            $script:DuringUpload = $null
            $script:SeenDuringUpload | Should -BeExactly (Get-PathFor $png)
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            $script:Writes.Count | Should -Be 1 -Because 'the real path equals the expected one, so there is no second write'
        }

        It 'does not overwrite a copy that happens during the upload' {
            $first = New-FakePng 1
            $second = New-FakePng 2
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $first
            $script:DuringUpload = { Copy-FromApp $second }
            Invoke-Ticks $w 1
            $script:Uploads.Count | Should -Be 1
            $script:Writes.Count | Should -Be 1 -Because 'the expected path goes on the clipboard before the upload starts'
            $script:Entry.Png | Should -Be $second
            $script:Entry.Text | Should -BeNullOrEmpty
            $script:Entry.Owner | Should -BeNullOrEmpty

            # The new image is then handled as a new image, with its own path.
            $script:DuringUpload = $null
            Invoke-Ticks $w 3
            $script:Uploads.Count | Should -Be 2
            $script:Writes.Count | Should -Be 2
            $script:Entry.Text | Should -BeExactly (Get-PathFor $second)
        }

        It 'does not overwrite text the user copies during the upload' {
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp (New-FakePng 1)
            $script:DuringUpload = { Copy-TextFromApp 'meeting at 3' }
            Invoke-Ticks $w 1
            Invoke-Ticks $w 5
            $script:Writes.Count | Should -Be 1 -Because 'only the write before the upload; the text copied during it stays'
            $script:Entry.Text | Should -BeExactly 'meeting at 3'
            $script:Entry.Png | Should -BeNullOrEmpty
            $script:Uploads.Count | Should -Be 1
        }

        It 'puts the path back to a plain image when another app comes to the front during the upload, and writes it again after coming back without a second upload' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            $script:DuringUpload = { Set-Focus $script:Other }
            Invoke-Ticks $w 1
            $script:Writes.Count | Should -Be 1 -Because 'the expected path went on the clipboard before the upload'

            $script:DuringUpload = $null
            Invoke-Ticks $w 3
            $script:Writes.Count | Should -Be 2 -Because 'another app is in front, so the plain image goes back'
            $script:Entry.Text | Should -BeNullOrEmpty
            Set-Focus $script:TerminalA
            Invoke-Ticks $w 3
            $script:Writes.Count | Should -Be 3
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            $script:Uploads.Count | Should -Be 1
        }

        It 'leaves an image that an app copied together with text or files alone, in front or not' -ForEach @(
            @{ Name = 'text'; Text = 'a caption'; Files = $false }
            @{ Name = 'files'; Text = $null; Files = $true }
            @{ Name = 'text and files'; Text = 'report.png'; Files = $true }
        ) {
            $w = New-FakeWatcher $script:TerminalA
            $png = New-FakePng 3
            if ($Files) { Copy-FromApp $png -Text $Text -Files } else { Copy-FromApp $png -Text $Text }
            $before = $script:Entry
            $seq = [SshPasteNative]::Sequence
            foreach ($window in @($script:Other, $script:TerminalA, $script:Other, $script:TerminalA)) {
                Set-Focus $window
                Invoke-Ticks $w 4
            }
            $script:Uploads.Count | Should -Be 0 -Because "an image with $Name from an app is not a screenshot"
            $script:Writes.Count | Should -Be 0
            [object]::ReferenceEquals($script:Entry, $before) | Should -BeTrue
            [SshPasteNative]::Sequence | Should -Be $seq
        }

        It 'ignores a clipboard that holds only text, and one that is empty' {
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Invoke-Ticks $w 3
            Copy-TextFromApp 'just text'
            Invoke-Ticks $w 3
            $script:Uploads.Count | Should -Be 0
            $script:Writes.Count | Should -Be 0
            $script:Entry.Text | Should -BeExactly 'just text'
        }

        It 'does nothing while no window is in front (the lock screen, a switch in progress)' {
            $w = New-FakeWatcher $script:TerminalA
            Copy-FromApp (New-FakePng 1)
            Set-Focus 0
            Invoke-Ticks $w 3
            $script:Reads | Should -Be 0
            $script:Uploads.Count | Should -Be 0
            $script:Writes.Count | Should -Be 0
        }

        It 'does not read the clipboard again while nothing changes, and reads again when the sequence number or the window changes' {
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp (New-FakePng 1)
            Invoke-Ticks $w 3          # read, upload, write; read the write back
            $reads = $script:Reads
            Invoke-Ticks $w 25
            $script:Reads | Should -Be $reads
            Copy-FromApp (New-FakePng 2)
            Invoke-Ticks $w 1
            $script:Reads | Should -Be ($reads + 1)
        }

        It 'retries a busy clipboard on the next tick' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            $script:ReadFails = 2
            { Invoke-WatcherTick $w } | Should -Throw '*clipboard is busy*'
            { Invoke-WatcherTick $w } | Should -Throw '*clipboard is busy*'
            Invoke-Ticks $w 2
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
        }

        It 'counts a window that the terminal owns (a popup, a tab drag) as the terminal' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            [SshPasteNative]::RootOwner[4004] = $script:TerminalA
            Set-Focus 4004
            Copy-FromApp $png
            Invoke-Ticks $w 3
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            Set-Focus $script:TerminalA
            Invoke-Ticks $w 3
            $script:Writes.Count | Should -Be 1 -Because 'the path is already there; moving between the terminal''s own windows changes nothing'
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
        }

        It 'uploads again when the cached upload is old enough to be cleaned up on the server, and leaves the clipboard as it is' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $w 3
            $script:Uploads.Count | Should -Be 1
            Invoke-Ticks $w 5
            $script:Uploads.Count | Should -Be 1
            Move-Clock $w (($script:UploadCacheHours * 3600) + 60)
            Invoke-Ticks $w 3
            $script:Uploads.Count | Should -Be 2 -Because 'the server may have pruned the first copy'
            $script:Writes.Count | Should -Be 1 -Because 'the path on the clipboard is still right'
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            Invoke-Ticks $w 5
            $script:Uploads.Count | Should -Be 2
        }
    }

    Context 'a failing upload' {
        It 'beeps once (not testable here), takes its path back off the clipboard, is quiet while it waits, and retries by itself after the backoff' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            $script:FailNext = 2

            Invoke-Ticks $w 1
            $script:Uploads.Count | Should -Be 1
            $w.Failed.Count | Should -Be 1
            $w.Failed[(Get-ImageHash $png)].Count | Should -Be 1
            $script:Writes.Count | Should -Be 2 -Because 'the expected path went on before the upload and came off when it failed'
            $script:Entry.Text | Should -BeNullOrEmpty

            # Nothing changes on the clipboard or in the window: no retry before the backoff (30 s).
            Invoke-Ticks $w 30
            $script:Uploads.Count | Should -Be 1
            Move-Clock $w 20
            Invoke-Ticks $w 5
            $script:Uploads.Count | Should -Be 1

            # 30 s have passed: the same tick loop tries again, still nothing else changed. It fails again.
            Move-Clock $w 11
            Invoke-Ticks $w 1
            $script:Uploads.Count | Should -Be 2
            $w.Failed[(Get-ImageHash $png)].Count | Should -Be 2
            $script:Writes.Count | Should -Be 2 -Because 'a retry after a failure uploads first and writes only on success'

            # The second wait is 60 s, not 30.
            Move-Clock $w 31
            Invoke-Ticks $w 5
            $script:Uploads.Count | Should -Be 2
            Move-Clock $w 30
            Invoke-Ticks $w 1
            $script:Uploads.Count | Should -Be 3
            $w.Failed.Count | Should -Be 0
            $script:Writes.Count | Should -Be 3
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            Invoke-Ticks $w 10
            $script:Uploads.Count | Should -Be 3
        }

        It 'does not retry while another app is in front, and retries when the terminal returns after the backoff' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            $script:FailNext = 1
            Invoke-Ticks $w 1
            Set-Focus $script:Other
            Move-Clock $w 100
            Invoke-Ticks $w 5
            $script:Uploads.Count | Should -Be 1
            Set-Focus $script:TerminalA
            Invoke-Ticks $w 2
            $script:Uploads.Count | Should -Be 2
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
        }

        It 'a window change before the backoff is over does not retry early' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            $script:FailNext = 1
            Invoke-Ticks $w 1
            Set-Focus $script:Other
            Invoke-Ticks $w 1
            Set-Focus $script:TerminalA
            Invoke-Ticks $w 3
            $script:Uploads.Count | Should -Be 1
            $script:Entry.Text | Should -BeNullOrEmpty
        }

        It 'a different screenshot is not held back by the backoff of the one that failed' {
            $first = New-FakePng 1
            $second = New-FakePng 2
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $first
            $script:FailNext = 1
            Invoke-Ticks $w 1
            Copy-FromApp $second
            Invoke-Ticks $w 2
            $script:Uploads.Count | Should -Be 2
            $script:Entry.Text | Should -BeExactly (Get-PathFor $second)
        }

        It 'puts the failure into the summary shown when the session ends' {
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp (New-FakePng 1)
            $script:FailNext = 1
            Invoke-Ticks $w 1
            Get-FailureSummary $w | Should -Match '1 screenshot upload\(s\) failed: alice@h did not accept a key for uploads'
        }
    }

    Context 'two watchers in two different terminal windows' {
        It 'does not ping-pong: writes stay bounded over many ticks while the focus moves, and each window gets its own path' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalB 'ssh-b' '/srv-b'
            Copy-FromApp $png
            $pathA = Get-PathFor $png '/srv-a'
            $pathB = Get-PathFor $png '/srv-b'
            $order = @($script:TerminalA, $script:Other, $script:TerminalB, $script:Other, $script:TerminalB, $script:TerminalA,
                $script:OtherToo, $script:TerminalA, $script:TerminalB, $script:OtherToo, $script:Other, $script:TerminalB)
            $changes = 0
            $previous = 0
            for ($round = 0; $round -lt 4; $round++) {
                foreach ($window in $order) {
                    Set-Focus $window
                    if ($window -ne $previous) { $changes++ }
                    $previous = $window
                    # Both orders, many ticks: the result must not depend on who ticks first.
                    for ($t = 0; $t -lt 6; $t++) {
                        if (($t + $round) % 2 -eq 0) { Invoke-WatcherTick $a; Invoke-WatcherTick $b } else { Invoke-WatcherTick $b; Invoke-WatcherTick $a }
                    }
                    # Settled: what is on the clipboard is what the window in front needs.
                    if ($window -eq $script:TerminalA) {
                        $script:Entry.Text | Should -BeExactly $pathA
                        $script:Entry.Token | Should -Be $a.Token
                    } elseif ($window -eq $script:TerminalB) {
                        $script:Entry.Text | Should -BeExactly $pathB
                        $script:Entry.Token | Should -Be $b.Token
                    } else {
                        $script:Entry.Text | Should -BeNullOrEmpty
                    }
                    $script:Entry.Png | Should -Be $png
                }
            }
            $script:Uploads.Count | Should -Be 2 -Because 'one upload per watcher for this image'
            $script:Writes.Count | Should -BeLessOrEqual (2 * $changes) -Because 'a focus change costs at most one restore and one new path'
            $writes = $script:Writes.Count
            Invoke-Ticks $a 20
            Invoke-Ticks $b 20
            $script:Writes.Count | Should -Be $writes -Because 'with the focus still, the watchers go quiet'
        }

        It 'lets the window in front win and does not touch its entry from the other window' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalB 'ssh-b' '/srv-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $a 2
            Invoke-Ticks $b 10
            $script:Writes.Count | Should -Be 2 -Because 'the expected /tmp path first, then the path this server returned'
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png '/srv-a')
            $script:Uploads.Count | Should -Be 1 -Because 'the watcher of the other window has no reason to upload'
        }

        It 'after the first window leaves, the second window''s watcher takes over from the plain image' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalB 'ssh-b' '/srv-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $a 2
            Set-Focus $script:TerminalB
            Invoke-Ticks $b 1
            Invoke-Ticks $a 1
            Invoke-Ticks $b 3
            Invoke-Ticks $a 3
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png '/srv-b')
            $script:Entry.Token | Should -Be $b.Token
        }
    }

    Context 'two watchers in the same terminal window (two tabs)' {
        It 'never overwrite each other''s entry, and both upload' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalA 'ssh-b' '/srv-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            for ($t = 0; $t -lt 10; $t++) {
                if ($t % 2 -eq 0) { Invoke-WatcherTick $a; Invoke-WatcherTick $b } else { Invoke-WatcherTick $b; Invoke-WatcherTick $a }
            }
            $script:Uploads.Count | Should -Be 2
            ($script:Uploads | ForEach-Object { $_.SshPath } | Sort-Object) | Should -Be @('ssh-a', 'ssh-b')
            $script:Writes.Count | Should -Be 2 -Because 'the expected /tmp path first, then the path this server returned'
            $script:Entry.Token | Should -Be $a.Token -Because 'the first one to write keeps the entry'
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png '/srv-a')
        }

        It 'keeps the first entry when the other watcher ticks first on later rounds too' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalA 'ssh-b' '/srv-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $b 1
            Invoke-Ticks $a 1
            Invoke-Ticks $b 2
            Invoke-Ticks $a 2
            $script:Entry.Token | Should -Be $b.Token
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png '/srv-b')
            $script:Writes.Count | Should -Be 2 -Because 'the expected /tmp path first, then the path this server returned'
        }

        It 'restores the plain image once when the window loses the focus, and writes a path once when it returns' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalA 'ssh-b' '/srv-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $a 2
            Invoke-Ticks $b 2
            $writes = $script:Writes.Count

            Set-Focus $script:Other
            Invoke-Ticks $a 2
            Invoke-Ticks $b 2
            $script:Writes.Count | Should -Be ($writes + 1)
            $script:Entry.Text | Should -BeNullOrEmpty

            Set-Focus $script:TerminalA
            Invoke-Ticks $b 2
            Invoke-Ticks $a 2
            $script:Writes.Count | Should -Be ($writes + 2)
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png '/srv-b')
            $script:Uploads.Count | Should -Be 2
        }

        It 'a watcher with a working server still serves the window when the other one''s upload fails' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalA 'ssh-b' '/srv-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            $script:FailNext = 1
            Invoke-Ticks $a 1       # fails
            Invoke-Ticks $b 2       # works
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png '/srv-b')
            $script:Entry.Token | Should -Be $b.Token
            Invoke-Ticks $a 5
            $script:Entry.Token | Should -Be $b.Token
        }
    }

    Context 'the counterexamples of the model check (verify/watcher)' {
        It 'leaves a copy made while it writes alone, and tries again on the next tick (NoLostCopy)' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            # The user copies text after the tick read the clipboard, before the write lands.
            $script:BeforeWrite = { $script:BeforeWrite = $null; Copy-TextFromApp 'copied meanwhile' }
            Invoke-WatcherStep $w
            $script:Entry.Text | Should -BeExactly 'copied meanwhile'
            $script:Entry.Png | Should -BeNullOrEmpty
            Invoke-Ticks $w 5
            $script:Entry.Text | Should -BeExactly 'copied meanwhile' -Because 'text the user copied is never replaced'
            $script:Writes.Count | Should -Be 0
        }

        It 'writes the path again when a failed promise was left on the clipboard and the retry succeeds (ReadyPathPastes)' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            # The upload fails while the user is in another window, so the failed promise stays.
            $script:FailNext = 1
            $script:DuringUpload = { Set-Focus $script:Other }
            Invoke-Ticks $w 1
            $script:Entry.Promise | Should -Be 'failed'
            # The user is back before the next tick, and the retry is due.
            $script:DuringUpload = $null
            Set-Focus $script:TerminalA
            Move-Clock $w 31
            Invoke-Ticks $w 1
            $script:Uploads.Count | Should -Be 2
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
            $script:Entry.Promise | Should -Not -Be 'failed' -Because 'Ctrl+V must get the path, not nothing'
        }

        It 'does not rely on the entry of a session in another window, even when the path has the same name (NoLocalPathDuringUpload)' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a'
            $b = New-FakeWatcher $script:TerminalB 'ssh-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $a 1
            $script:Entry.Token | Should -Be $a.Token
            Set-Focus $script:TerminalB
            Invoke-Ticks $b 1
            $script:Entry.Token | Should -Be $b.Token -Because 'a paste in this window must ask this session, which uploads to this server'
            $script:Entry.Owner | Should -Be $script:TerminalB
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png)
        }
    }

    Context 'Restore-Clipboard (on exit)' {
        It 'puts the plain image back when the clipboard still holds this session''s path' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $w 3
            $script:Entry.Text | Should -Not -BeNullOrEmpty
            Restore-Clipboard $w
            $script:Entry.Text | Should -BeNullOrEmpty
            $script:Entry.Png | Should -Be $png
            $script:Entry.Owner | Should -Be 0
            $script:Entry.Token | Should -Be $w.Token
        }

        It 'leaves another session''s entry alone' {
            $png = New-FakePng 1
            $a = New-FakeWatcher $script:TerminalA 'ssh-a' '/srv-a'
            $b = New-FakeWatcher $script:TerminalA 'ssh-b' '/srv-b'
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $a 3
            $writes = $script:Writes.Count
            Restore-Clipboard $b
            $script:Writes.Count | Should -Be $writes
            $script:Entry.Text | Should -BeExactly (Get-PathFor $png '/srv-a')
            $script:Entry.Token | Should -Be $a.Token
            Restore-Clipboard $a
            $script:Entry.Text | Should -BeNullOrEmpty
        }

        It 'leaves an image from an app alone, with or without text' -ForEach @(
            @{ Text = $null }
            @{ Text = 'caption' }
        ) {
            $w = New-FakeWatcher $script:TerminalA
            Copy-FromApp (New-FakePng 1) -Text $Text
            $before = $script:Entry
            Restore-Clipboard $w
            $script:Writes.Count | Should -Be 0
            [object]::ReferenceEquals($script:Entry, $before) | Should -BeTrue
        }

        It 'leaves a plain image of its own, and text, and an empty clipboard alone' {
            $png = New-FakePng 1
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $w 3
            Set-Focus $script:Other
            Invoke-Ticks $w 2
            $writes = $script:Writes.Count
            Restore-Clipboard $w
            Copy-TextFromApp 'hello'
            Restore-Clipboard $w
            $script:Entry = $null
            Restore-Clipboard $w
            $script:Writes.Count | Should -Be $writes
        }

        It 'does not write when the clipboard changes between its read and its write' {
            $png = New-FakePng 1
            $other = New-FakePng 2
            $w = New-FakeWatcher $script:TerminalA
            Set-Focus $script:TerminalA
            Copy-FromApp $png
            Invoke-Ticks $w 3
            $writes = $script:Writes.Count
            $script:AfterRead = { Copy-FromApp $other }
            Restore-Clipboard $w
            $script:Writes.Count | Should -Be $writes
            $script:Entry.Png | Should -Be $other
            $script:Entry.Owner | Should -BeNullOrEmpty
        }

        It 'does not throw when the clipboard is busy' {
            $w = New-FakeWatcher $script:TerminalA
            $script:ReadFails = 1
            { Restore-Clipboard $w } | Should -Not -Throw
        }
    }

    Context 'Test-HostForeground' {
        It 'matches the terminal window, a window that terminal owns, and no other; never a null window' {
            $m = @{ Kind = 'Windows Terminal'; Window = [IntPtr]1001; Pids = $null }
            [SshPasteNative]::RootOwner[1500] = 1001
            Test-HostForeground $m ([IntPtr]1001) | Should -BeTrue
            Test-HostForeground $m ([IntPtr]1500) | Should -BeTrue
            Test-HostForeground $m ([IntPtr]2002) | Should -BeFalse
            Test-HostForeground $m ([IntPtr]::Zero) | Should -BeFalse
        }

        It 'matches by process when the terminal has no window of its own to compare' {
            $pids = New-Object 'System.Collections.Generic.HashSet[int]'
            [void]$pids.Add(4242)
            $m = @{ Kind = 'terminal process'; Window = [IntPtr]::Zero; Pids = $pids }
            [SshPasteNative]::ProcessOf[7007] = 4242
            [SshPasteNative]::ProcessOf[8008] = 99
            Test-HostForeground $m ([IntPtr]7007) | Should -BeTrue
            Test-HostForeground $m ([IntPtr]8008) | Should -BeFalse
            Test-HostForeground $m ([IntPtr]9009) | Should -BeFalse
        }
    }
}

Describe 'Invoke-Proxy (the --proxy relay, in a child process against a local TCP server)' {
    BeforeAll {
        function Start-RelayServer {
            # Accepts one connection, reads until the client half-closes, then either answers
            # and closes ('reply') or keeps the connection open ('hold').
            param([string]$Mode)
            $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
            $listener.Start()
            $ps = [powershell]::Create()
            [void]$ps.AddScript({
                    param($Listener, $Mode)
                    $client = $Listener.AcceptTcpClient()
                    $stream = $client.GetStream()
                    $received = New-Object System.IO.MemoryStream
                    $buffer = New-Object byte[] 4096
                    while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $received.Write($buffer, 0, $n) }
                    if ($Mode -eq 'reply') {
                        $reply = [System.Text.Encoding]::ASCII.GetBytes('world')
                        $stream.Write($reply, 0, $reply.Length)
                        $stream.Flush()
                        $client.Close()
                    } else {
                        Start-Sleep -Seconds 120
                    }
                    return , $received.ToArray()
                }).AddArgument($listener).AddArgument($Mode)
            $handle = $ps.BeginInvoke()
            return @{ Listener = $listener; Port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port; Ps = $ps; Handle = $handle }
        }

        function Stop-RelayServer {
            param($Server)
            try { $Server.Ps.Stop() } catch { }
            try { $Server.Listener.Stop() } catch { }
            $Server.Ps.Dispose()
        }

        $script:Harness = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-proxy-harness-' + [guid]::NewGuid().ToString('N') + '.ps1')
        # Runs Invoke-Proxy as the ProxyCommand of an interactive "ssh alice@host", with the
        # watcher and the Windows pieces replaced by stand-ins that record what they were given.
        [System.IO.File]::WriteAllText($script:Harness, @'
param([string]$CorePath, [string]$TargetHost, [string]$Port, [string]$Out, [string]$Mode)
. $CorePath
function Get-ParentSshArguments { return @{ Path = 'the-parent-ssh'; Args = @('alice@host') } }
function Get-EffectiveSshConfig {
    param($SshPath, $Arguments)
    if ($Mode -eq 'alias') { return @{ hostkeyalias = 'my-alias' } }
    return $null
}
function Initialize-Native { }
function New-Watcher {
    param($SshPath, $Parsed, [switch]$NoProxy, $Pin)
    $record = @{ SshPath = $SshPath; Destination = $Parsed.Destination; NoProxy = [bool]$NoProxy; HostName = $Pin.HostName; Port = $Pin.Port; HostKeyAlias = $Pin.HostKeyAlias }
    [System.IO.File]::WriteAllText($Out, (ConvertTo-Json -Compress -InputObject $record))
    return $null
}
exit (Invoke-Proxy $TargetHost $Port 'alias-for-doctor')
'@)
        function Invoke-Harness {
            param([string]$TargetHost, $Server, [string]$Mode = '')
            $out = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-proxy-pin-' + [guid]::NewGuid().ToString('N') + '.json')
            $argv = @('-NoLogo', '-NoProfile')
            if ($script:OnWindows) { $argv += @('-ExecutionPolicy', 'Bypass') }
            $argv += @('-File', $script:Harness, $script:CorePath, $TargetHost, [string]$Server.Port, $out, $Mode)
            $r = Invoke-Process -FilePath (Get-ThisPowerShell) -Arguments $argv
            $pin = $null
            if (Test-Path -LiteralPath $out) { $pin = ConvertFrom-Json ([System.IO.File]::ReadAllText($out)); Remove-Item -LiteralPath $out -Force }
            return [pscustomobject]@{ Run = $r; Watcher = $pin }
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Harness -Force -ErrorAction SilentlyContinue
    }

    It 'relays bytes both ways, closes when the server does, and exits 0 with only the server''s bytes on stdout' {
        $server = Start-RelayServer 'reply'
        try {
            $r = Invoke-Process -FilePath (Get-ThisPowerShell) -Arguments @('-NoLogo', '-NoProfile', '-File', $script:CorePath, '--proxy', '127.0.0.1', [string]$server.Port, 'x') -InputBytes ([System.Text.Encoding]::ASCII.GetBytes('hello'))
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $r.Stdout | Should -BeExactly 'world'
            $server.Handle.AsyncWaitHandle.WaitOne(10000) | Should -BeTrue
            [System.Text.Encoding]::ASCII.GetString($server.Ps.EndInvoke($server.Handle)[0]) | Should -BeExactly 'hello'
        } finally { Stop-RelayServer $server }
    }

    It 'uploads go to the address the relay reached, with the host key alias the session used (name and port)' {
        $server = Start-RelayServer 'reply'
        try {
            $h = Invoke-Harness 'localhost' $server
            $h.Run.ExitCode | Should -Be 0 -Because $h.Run.Stderr
            $h.Watcher | Should -Not -BeNullOrEmpty -Because 'the session is interactive, so a watcher is made'
            $h.Watcher.HostName | Should -BeExactly '127.0.0.1' -Because 'the numeric address of the connection, not the name that was resolved'
            $h.Watcher.Port | Should -Be $server.Port
            $h.Watcher.HostKeyAlias | Should -BeExactly ('[localhost]:' + $server.Port)
            $h.Watcher.NoProxy | Should -BeTrue
            $h.Watcher.SshPath | Should -BeExactly 'the-parent-ssh'
            $h.Watcher.Destination | Should -BeExactly 'alice@host'
        } finally { Stop-RelayServer $server }
    }

    It 'takes the HostKeyAlias from the effective ssh configuration when there is one' {
        $server = Start-RelayServer 'reply'
        try {
            $h = Invoke-Harness '127.0.0.1' $server -Mode 'alias'
            $h.Run.ExitCode | Should -Be 0 -Because $h.Run.Stderr
            $h.Watcher.HostKeyAlias | Should -BeExactly 'my-alias'
            $h.Watcher.HostName | Should -BeExactly '127.0.0.1'
        } finally { Stop-RelayServer $server }
    }

    It 'returns 1 and says so on stderr when the server does not close within 30 s of the half-close' {
        $server = Start-RelayServer 'hold'
        try {
            $started = [DateTime]::UtcNow
            $r = Invoke-Process -FilePath (Get-ThisPowerShell) -Arguments @('-NoLogo', '-NoProfile', '-File', $script:CorePath, '--proxy', '127.0.0.1', [string]$server.Port, 'x') -TimeoutSeconds 90
            $elapsed = ([DateTime]::UtcNow - $started).TotalSeconds
            $r.ExitCode | Should -Be 1
            $r.Stderr | Should -Match 'did not close the connection within 30 seconds'
            $r.Stdout | Should -BeExactly ''
            $elapsed | Should -BeGreaterThan 29
            $elapsed | Should -BeLessThan 60
        } finally { Stop-RelayServer $server }
    }
}

Describe 'Invoke-Doctor (clipboard line)' {
    BeforeEach {
        Mock Initialize-Native { }
        Mock Get-SshPath { return 'ssh' }
        Mock Invoke-NativeCapture { return @{ ExitCode = 0; Out = ''; Err = 'OpenSSH_9.6p1, OpenSSL 3.0' } }
        Mock Get-HostMatcher { return @{ Kind = 'Windows Terminal'; Window = [IntPtr]::Zero; Pids = $null } }
    }

    It 'reports the image size when the clipboard holds an image' {
        Mock Read-ClipboardImage { return @{ Seq = 5; Png = [byte[]](1..40); Hash = 'x'; HasText = $false; HasFiles = $false; Owner = $null; Token = $null; Text = $null } }
        $out = (@(Invoke-Doctor @() 6>&1) | Out-String)
        $out | Should -Match 'clipboard: image, 40 bytes'
    }

    # Read-ClipboardImage now always returns a state, with Png $null when there is no image; the
    # doctor still tests the state itself for $null (line 1198), so with no image it reads
    # $state.Png.Length under strict mode, throws, and --doctor prints FAIL and exits 1.
    # Patch: if ($null -eq $state.Png) { Report $true 'clipboard: readable (no image right now)' } else { ... }
    It 'says there is no image when the clipboard holds none' {
        Mock Read-ClipboardImage { return @{ Seq = 5; Png = $null; Hash = $null; HasText = $true; HasFiles = $false; Owner = $null; Token = $null; Text = $null } }
        $out = (@(Invoke-Doctor @() 6>&1) | Out-String)
        $out | Should -Match 'clipboard: readable \(no image right now\)'
        $out | Should -Not -Match 'clipboard: image'
    }

    It 'fails the clipboard check when the clipboard is busy' {
        Mock Read-ClipboardImage { throw 'the clipboard is busy' }
        $out = (@(Invoke-Doctor @() 6>&1) | Out-String)
        $out | Should -Match 'FAIL'
        $out | Should -Match 'clipboard: the clipboard is busy'
    }
}

Describe 'command line' {
    It '--version prints the version and exits 0' {
        $r = Invoke-SshPaste @('--version')
        $r.ExitCode | Should -Be 0
        $r.Stdout.Trim() | Should -BeExactly $script:Version
    }

    It '--help and no arguments print the usage and exit 0' {
        foreach ($a in @(@('--help'), @('-h'), @())) {
            $r = Invoke-SshPaste $a
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -Match '--enable \[OPTIONS\] HOST'
            $r.Stdout | Should -Match '--keep TIME'
            $r.Stdout | Should -Match '--dir DIR'
            $r.Stdout | Should -Match '--disable'
            $r.Stdout | Should -Match '--doctor'
            $r.Stdout | Should -Match '--uninstall'
        }
    }

    It '--proxy without enough arguments exits 2 and says what it needs on stderr, nothing on stdout' {
        $r = Invoke-SshPaste @('--proxy', 'host')
        $r.ExitCode | Should -Be 2
        $r.Stderr | Should -Match 'needs %h %p %n'
        $r.Stdout | Should -BeExactly ''
    }

    It '--proxy to a closed port fails with a clear message on stderr and nothing on stdout' {
        $r = Invoke-SshPaste @('--proxy', '127.0.0.1', '1', 'x')
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match 'ssh-paste: cannot connect to 127\.0\.0\.1 port 1'
        $r.Stdout | Should -BeExactly ''
    }

    It '--enable without a host explains the usage' {
        $r = Invoke-SshPaste @('--enable')
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match 'usage: ssh-paste --enable \[--keep TIME\] \[--dir DIR\] HOST'
    }
}

Describe 'wrapper mode' {
    BeforeAll {
        # Wrapper mode runs "ssh" with the arguments it was given. Point it at PowerShell
        # itself so the exit code and the argument hand-over can be checked anywhere.
        $script:OldSsh = $env:SSH_PASTE_SSH
        $env:SSH_PASTE_SSH = Get-ThisPowerShell
    }
    AfterAll {
        if ($null -eq $script:OldSsh) { Remove-Item Env:\SSH_PASTE_SSH -ErrorAction SilentlyContinue } else { $env:SSH_PASTE_SSH = $script:OldSsh }
    }

    It 'returns the exit code of the program it runs' {
        (Invoke-SshPaste @('-NoProfile', '-Command', 'exit 7')).ExitCode | Should -Be 7
        (Invoke-SshPaste @('-NoProfile', '-Command', 'exit 0')).ExitCode | Should -Be 0
    }

    It 'hands every argument over unchanged' {
        $script = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-wrap-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($script, '[Console]::Out.Write((ConvertTo-Json -Compress -InputObject @($args)))')
        try {
            $items = @('plain', 'with space', 'say "hi"', 'C:\Program Files\x\', 'a\"b')
            $r = Invoke-SshPaste (@('-NoProfile', '-File', $script) + $items)
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $r.Stdout | Should -BeExactly (Format-ArgList $items)
        } finally {
            Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-ReleaseChecksum' {
    BeforeAll {
        function Get-TestHash {
            param([byte[]]$Bytes)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
        }
        $script:Bytes = [System.Text.Encoding]::ASCII.GetBytes("Write-Host 'install'`n")
        $script:Hash = Get-TestHash $script:Bytes
        $script:OtherHash = Get-TestHash ([System.Text.Encoding]::ASCII.GetBytes('something else'))
    }

    It 'accepts the line of the file with the right hash' {
        Test-ReleaseChecksum ($script:Hash + '  install.ps1') 'install.ps1' $script:Bytes | Should -BeTrue
    }

    It 'accepts the line in the middle of the others, as sha256sum writes them' {
        $sums = ($script:OtherHash + '  ssh-paste.ps1'), ($script:Hash + '  install.ps1'), ($script:OtherHash + '  ssh-paste.cmd') -join "`n"
        Test-ReleaseChecksum ($sums + "`n") 'install.ps1' $script:Bytes | Should -BeTrue
    }

    It 'refuses a wrong hash' {
        Test-ReleaseChecksum ($script:OtherHash + '  install.ps1') 'install.ps1' $script:Bytes | Should -BeFalse
    }

    It 'refuses bytes that changed by one byte' {
        $changed = [byte[]]$script:Bytes.Clone()
        $changed[0] = $changed[0] -bxor 1
        Test-ReleaseChecksum ($script:Hash + '  install.ps1') 'install.ps1' $changed | Should -BeFalse
    }

    It 'refuses when only another file name has the hash' {
        $sums = ($script:Hash + '  ssh-paste.ps1'), ($script:OtherHash + '  install.ps1') -join "`n"
        Test-ReleaseChecksum $sums 'install.ps1' $script:Bytes | Should -BeFalse
    }

    It 'refuses when the file is not listed' {
        Test-ReleaseChecksum ($script:Hash + '  ssh-paste.cmd') 'install.ps1' $script:Bytes | Should -BeFalse
        Test-ReleaseChecksum '' 'install.ps1' $script:Bytes | Should -BeFalse
    }

    It 'does not take a longer or differently cased name for the file' {
        Test-ReleaseChecksum ($script:Hash + '  install.ps1.bak') 'install.ps1' $script:Bytes | Should -BeFalse
        Test-ReleaseChecksum ($script:Hash + '  my-install.ps1') 'install.ps1' $script:Bytes | Should -BeFalse
        Test-ReleaseChecksum ($script:Hash + '  Install.ps1') 'install.ps1' $script:Bytes | Should -BeFalse
    }

    It 'accepts the binary marker "*" before the name' {
        Test-ReleaseChecksum ($script:Hash + ' *install.ps1') 'install.ps1' $script:Bytes | Should -BeTrue
        Test-ReleaseChecksum ($script:OtherHash + ' *install.ps1') 'install.ps1' $script:Bytes | Should -BeFalse
    }

    It 'accepts CRLF line endings' {
        $sums = (($script:OtherHash + '  ssh-paste.ps1'), ($script:Hash + '  install.ps1')) -join "`r`n"
        Test-ReleaseChecksum ($sums + "`r`n") 'install.ps1' $script:Bytes | Should -BeTrue
        Test-ReleaseChecksum $sums 'install.ps1' $script:Bytes | Should -BeTrue
    }

    It 'accepts an upper case hash' {
        Test-ReleaseChecksum ($script:Hash.ToUpperInvariant() + '  install.ps1') 'install.ps1' $script:Bytes | Should -BeTrue
    }

    It 'refuses a hash of the wrong length' {
        Test-ReleaseChecksum ($script:Hash.Substring(0, 63) + '  install.ps1') 'install.ps1' $script:Bytes | Should -BeFalse
        Test-ReleaseChecksum ($script:Hash + '0  install.ps1') 'install.ps1' $script:Bytes | Should -BeFalse
    }

    It 'goes by the first line that names the file' {
        $sums = ($script:OtherHash + '  install.ps1'), ($script:Hash + '  install.ps1') -join "`n"
        Test-ReleaseChecksum $sums 'install.ps1' $script:Bytes | Should -BeFalse
    }
}

Describe 'New-ChildStartInfo (the one way to start a program)' {
    It 'leaves out every variable with the Win32-OpenSSH private prefix, set before or after start' {
        $name = $script:InheritedSshPrefix + 'POSIX_FD_STATE'
        $later = $script:InheritedSshPrefix + 'SOMETHING_NEW'
        try {
            Set-Item -LiteralPath ('Env:' + $name) -Value 'fd table'
            Set-Item -LiteralPath ('Env:' + $later) -Value 'x'
            $psi = New-ChildStartInfo -FilePath 'ssh' -Arguments @('-V') -Redirect
            @($psi.EnvironmentVariables.Keys | Where-Object { ([string]$_).StartsWith($script:InheritedSshPrefix, [StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 0
            $psi.EnvironmentVariables.ContainsKey('PATH') | Should -BeTrue -Because 'only the private variables go'
        } finally {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ('Env:' + $later) -ErrorAction SilentlyContinue
        }
    }
    It 'redirects the three streams and hides the window only with -Redirect' {
        $psi = New-ChildStartInfo -FilePath 'ssh' -Arguments @('-V') -Redirect
        @($psi.RedirectStandardInput, $psi.RedirectStandardOutput, $psi.RedirectStandardError, $psi.CreateNoWindow) | Should -Be @($true, $true, $true, $true)
        $plain = New-ChildStartInfo -FilePath 'ssh' -Arguments @('host')
        @($plain.RedirectStandardInput, $plain.RedirectStandardOutput, $plain.UseShellExecute) | Should -Be @($false, $false, $false)
    }
}

Describe 'Invoke-Update (ssh-paste --update)' {
    BeforeEach {
        $script:Installer = [System.Text.Encoding]::ASCII.GetBytes("Write-Host 'installer'`r`n")
        $script:Sums = (Get-Sha256Hex $script:Installer) + '  install.ps1' + "`n" + ('0' * 64) + '  ssh-paste.ps1' + "`n"
        $script:Fetched = New-Object System.Collections.ArrayList
        Mock Write-Info { }
        Mock Invoke-WebDownload {
            [void]$script:Fetched.Add($Url)
            if ($Url -like '*/install.ps1') { return , $script:Installer }
            if ($Url -like '*/SHA256SUMS') { return , ([System.Text.Encoding]::ASCII.GetBytes($script:Sums)) }
            throw "unexpected url $Url"
        }
        Mock Start-Installer { $script:RanInstaller = [System.IO.File]::ReadAllBytes($Path); return 0 }
        $script:RanInstaller = $null
    }

    It 'takes no options, so a typo never does something else' {
        { Invoke-Update @('--check') } | Should -Throw '*--update takes no options: --check*'
        $script:Fetched.Count | Should -Be 0
    }

    It 'downloads install.ps1 and SHA256SUMS of the latest release and runs the installer when they match' {
        Invoke-Update @() | Should -Be 0
        @($script:Fetched) | Should -Be @(
            'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1',
            'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/SHA256SUMS')
        $script:RanInstaller | Should -Be $script:Installer
    }

    It 'returns the exit code of the installer' {
        Mock Start-Installer { return 7 }
        Invoke-Update @() | Should -Be 7
    }

    It 'refuses an installer that does not match SHA256SUMS and runs nothing' {
        $script:Sums = ('f' * 64) + '  install.ps1'
        { Invoke-Update @() } | Should -Throw '*install.ps1 does not match SHA256SUMS; nothing was changed*'
        Should -Invoke Start-Installer -Times 0 -Exactly
    }

    It 'refuses when SHA256SUMS does not list install.ps1' {
        $script:Sums = (Get-Sha256Hex $script:Installer) + '  other.ps1'
        { Invoke-Update @() } | Should -Throw '*does not match*'
        Should -Invoke Start-Installer -Times 0 -Exactly
    }

    It 'uses SSH_PASTE_UPDATE_URL instead of GitHub when it is set' {
        $env:SSH_PASTE_UPDATE_URL = 'http://127.0.0.1:9/rel/'
        try {
            Invoke-Update @() | Should -Be 0
            $script:Fetched[0] | Should -BeExactly 'http://127.0.0.1:9/rel/install.ps1'
        } finally { Remove-Item Env:SSH_PASTE_UPDATE_URL }
    }

    It 'leaves no temporary folder behind' {
        $before = @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'ssh-paste-update-*' -ErrorAction SilentlyContinue).Count
        Invoke-Update @() | Should -Be 0
        @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'ssh-paste-update-*' -ErrorAction SilentlyContinue).Count | Should -Be $before
    }
}

Describe 'Start-Installer' {
    BeforeAll {
        $script:SavedSystemRoot = $env:SystemRoot
        if (-not $env:SystemRoot) { $env:SystemRoot = 'C:\Windows' }   # Linux has none
    }
    AfterAll { $env:SystemRoot = $script:SavedSystemRoot }
    It 'starts the installer without SSH_PASTE_UNINSTALL and SSH_PASTE_REF, so an update never uninstalls or switches refs' {
        $script:Seen = $null
        Mock New-ChildStartInfo { $script:Seen = $RemoveVariables; throw 'stop here' }
        { Start-Installer 'x.ps1' } | Should -Throw 'stop here'
        $script:Seen | Should -Contain 'SSH_PASTE_UNINSTALL'
        $script:Seen | Should -Contain 'SSH_PASTE_REF'
    }

    It 'returns only the child exit code, even when the child prints output' -Skip:(-not $IsLinux -and -not $IsMacOS) {
        # On Linux the same mechanics run with /bin/sh standing in for powershell.exe.
        $script:Shell = '/bin/sh'
        Mock Join-Path { $script:Shell } -ParameterFilter { $ChildPath -like '*powershell.exe' }
        $script:Script = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-installer-' + [guid]::NewGuid().ToString('N') + '.sh')
        [System.IO.File]::WriteAllText($script:Script, "echo some output`nexit 3`n")
        try {
            Mock New-ChildStartInfo {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = '/bin/sh'
                $psi.ArgumentList.Add($script:Script)
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                return $psi
            }
            $result = @(Start-Installer $script:Script)
            $result.Count | Should -Be 1
            $result[0] | Should -Be 3
        } finally { Remove-Item -LiteralPath $script:Script -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-ChildStartInfo -RemoveVariables' {
    It 'removes the named variables from the child environment only' {
        $env:SSH_PASTE_UNINSTALL = '1'
        try {
            $psi = New-ChildStartInfo -FilePath 'x' -Arguments @() -RemoveVariables @('SSH_PASTE_UNINSTALL')
            $psi.EnvironmentVariables.ContainsKey('SSH_PASTE_UNINSTALL') | Should -BeFalse
            $env:SSH_PASTE_UNINSTALL | Should -Be '1' -Because 'our own environment is left alone'
        } finally { Remove-Item Env:SSH_PASTE_UNINSTALL -ErrorAction SilentlyContinue }
    }
}

Describe 'release scripts (.github/scripts)' -Tag 'Unix' -Skip:$onWindows {
    BeforeAll {
        $script:ScriptsDir = Join-Path $script:RepoRoot '.github/scripts'
        $script:Bash = (Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $script:Git = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $script:Root = Join-Path $script:SandboxRoot ('release-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:Root)

        # The stand-in gh. A release is a folder $GH_STUB_DIR/releases/<tag> with a file "draft"
        # while it is a draft and a folder "assets". Every call is appended to $GH_STUB_DIR/calls.
        # GH_STUB_FAIL="release list" makes that gh command fail; GH_STUB_CORRUPT=1 changes a
        # downloaded file.
        $script:StubBin = Join-Path $script:Root 'bin'
        [void][System.IO.Directory]::CreateDirectory($script:StubBin)
        $stub = @'
#!/usr/bin/env bash
set -u
d=$GH_STUB_DIR
echo "$*" >> "$d/calls"
if [ "${GH_STUB_FAIL:-}" = "$1 $2" ]; then echo "gh: HTTP 503" >&2; exit 1; fi
case "$1 $2" in
  "release list")
    for r in "$d"/releases/*/; do
      [ -d "$r" ] || continue
      t=$(basename "$r")
      if [ -e "$r/draft" ]; then echo "$t true"; else echo "$t false"; fi
    done ;;
  "release create")
    t=$3; shift 3
    mkdir -p "$d/releases/$t/assets"
    while [ $# -gt 0 ]; do
      case "$1" in
        --draft) touch "$d/releases/$t/draft" ;;
        --title|--notes-file) shift ;;
        --*) ;;
        *) cp "$1" "$d/releases/$t/assets/" ;;
      esac
      shift
    done ;;
  "release delete") rm -rf "$d/releases/$3" ;;
  "release download")
    t=$3; shift 3; dir=.
    while [ $# -gt 0 ]; do if [ "$1" = --dir ]; then dir=$2; shift; fi; shift; done
    cp "$d/releases/$t/assets/"* "$dir/"
    if [ -n "${GH_STUB_CORRUPT:-}" ]; then echo tamper >> "$dir/ssh-paste.cmd"; fi ;;
  "release edit")
    t=$3; shift 3
    for a in "$@"; do
      case "$a" in
        --draft=false) rm -f "$d/releases/$t/draft" ;;
        --latest) echo "$t" > "$d/latest" ;;
      esac
    done ;;
  "api repos/"*) cat "$d/latest" ;;
  "attestation verify") exit 0 ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 2 ;;
esac
'@
        [System.IO.File]::WriteAllText((Join-Path $script:StubBin 'gh'), ($stub -replace "`r`n", "`n"))
        Invoke-Process -FilePath 'chmod' -Arguments @('+x', (Join-Path $script:StubBin 'gh')) | Out-Null

        function Invoke-GitIn {
            param([string]$Dir, [string[]]$Arguments)
            $r = Invoke-Process -FilePath $script:Git -Arguments (@('-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false') + $Arguments) -WorkingDirectory $Dir
            if ($r.ExitCode -ne 0) { throw ('git ' + ($Arguments -join ' ') + ' failed: ' + $r.Stderr) }
            return $r.Stdout.Trim()
        }
        # Runs a release script with the stand-in gh first on PATH and the given environment.
        function Invoke-Script {
            param([string]$Script, [string[]]$Arguments, [string]$Work, [hashtable]$Environment)
            $names = @($Environment.Keys) + @('PATH')
            $saved = @{}
            foreach ($n in $names) { $saved[$n] = [System.Environment]::GetEnvironmentVariable($n) }
            try {
                foreach ($n in $Environment.Keys) { [System.Environment]::SetEnvironmentVariable($n, $Environment[$n]) }
                $env:PATH = $script:StubBin + [System.IO.Path]::PathSeparator + $saved['PATH']
                return (Invoke-Process -FilePath $script:Bash -Arguments (@((Join-Path $script:ScriptsDir $Script)) + $Arguments) -WorkingDirectory $Work)
            } finally {
                foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, $saved[$n]) }
            }
        }
        # A folder that is the stand-in's GitHub. Set-Release adds a release to it.
        function New-Stub {
            $d = Join-Path $script:Root ('stub-' + [guid]::NewGuid().ToString('N'))
            [void][System.IO.Directory]::CreateDirectory((Join-Path $d 'releases'))
            return $d
        }
        function Set-Release {
            param([string]$Stub, [string]$Tag, [switch]$Draft, [string]$AssetsFrom)
            $r = Join-Path (Join-Path $Stub 'releases') $Tag
            [void][System.IO.Directory]::CreateDirectory((Join-Path $r 'assets'))
            if ($Draft) { [System.IO.File]::WriteAllText((Join-Path $r 'draft'), '') }
            if ($AssetsFrom) { foreach ($f in @(Get-ChildItem -LiteralPath $AssetsFrom -File)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $r 'assets') } }
            else { [System.IO.File]::WriteAllText((Join-Path (Join-Path $r 'assets') 'stale'), 'old') }
        }
        function Get-StubCalls {
            param([string]$Stub)
            $f = Join-Path $Stub 'calls'
            if (Test-Path -LiteralPath $f) { return @([System.IO.File]::ReadAllLines($f)) }
            return @()
        }
        # A work clone with a bare "origin". Returns the clone's path.
        function New-ScratchRepo {
            $base = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
            [void][System.IO.Directory]::CreateDirectory($base)
            $origin = Join-Path $base 'origin.git'
            Invoke-GitIn $base @('init', '-q', '--bare', '-b', 'main', $origin) | Out-Null
            $work = Join-Path $base 'work'
            Invoke-GitIn $base @('clone', '-q', $origin, $work) | Out-Null
            [void][System.IO.Directory]::CreateDirectory((Join-Path $work 'src'))
            [System.IO.File]::WriteAllText((Join-Path $work 'src/ssh-paste.ps1'), "one`n")
            [System.IO.File]::WriteAllText((Join-Path $work 'install.ps1'), "installer`n")
            [System.IO.File]::WriteAllText((Join-Path $work 'install.sh'), "mac installer`n")
            [System.IO.File]::WriteAllText((Join-Path $work 'README.md'), "readme`n")
            Invoke-GitIn $work @('add', '-A') | Out-Null
            Invoke-GitIn $work @('commit', '-q', '-m', 'install: first version') | Out-Null
            Invoke-GitIn $work @('push', '-q', 'origin', 'HEAD:main') | Out-Null
            return $work
        }
        function Add-Commit {
            param([string]$Work, [string]$File, [string]$Subject)
            [System.IO.File]::AppendAllText((Join-Path $Work $File), "line $Subject`n")
            Invoke-GitIn $Work @('commit', '-q', '-am', $Subject) | Out-Null
            Invoke-GitIn $Work @('push', '-q', 'origin', 'HEAD:main') | Out-Null
            return (Invoke-GitIn $Work @('rev-parse', 'HEAD'))
        }
        # Runs plan-release.sh for the commit. Returns the tag it chose (empty for none), its reason and its exit code.
        function Invoke-Plan {
            param([string]$Work, [string]$Sha, [string]$Stub, [hashtable]$Extra = @{})
            $out = Join-Path $Work '../plan-output.txt'
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out }
            $environment = @{ SHA = $Sha; GITHUB_OUTPUT = $out; GITHUB_REPOSITORY = 'x/y'; GH_STUB_DIR = $Stub }
            foreach ($k in $Extra.Keys) { $environment[$k] = $Extra[$k] }
            $r = Invoke-Script 'plan-release.sh' @() $Work $environment
            $tag = ''
            $reason = ''
            if (Test-Path -LiteralPath $out) {
                $lines = @([System.IO.File]::ReadAllLines($out))
                $tag = ($lines | Where-Object { $_ -like 'tag=*' } | Select-Object -First 1).Substring(4)
                $reason = ($lines | Where-Object { $_ -like 'reason=*' }) -join ' '
            }
            return @{ Tag = $tag; Reason = $reason; Exit = $r.ExitCode; Stderr = $r.Stderr }
        }
        # Plans, and fails the test unless the script succeeded.
        function Get-Plan {
            param([string]$Work, [string]$Sha, [string]$Stub)
            $p = Invoke-Plan $Work $Sha $Stub
            $p.Exit | Should -Be 0 -Because $p.Stderr
            return $p
        }
        function Get-RemoteTags {
            param([string]$Work)
            $t = Invoke-GitIn $Work @('ls-remote', '--tags', '--refs', 'origin')
            return @($t -split "`n" | Where-Object { $_ } | ForEach-Object { ($_ -split 'refs/tags/')[1] })
        }
        # The seven release files of a version in a new folder, SHA256SUMS included.
        # -JsVersion gives ssh-paste.js (the macOS client) another version than the script.
        function New-Dist {
            param([string]$Version, [string]$JsVersion)
            if (-not $JsVersion) { $JsVersion = $Version }
            $d = Join-Path $script:Root ('dist-' + [guid]::NewGuid().ToString('N'))
            [void][System.IO.Directory]::CreateDirectory($d)
            # The version line comes early and the file is larger than a pipe buffer (64 KB),
            # like the real script: a check that stops reading early (grep -q) breaks its pipe.
            [System.IO.File]::WriteAllText((Join-Path $d 'ssh-paste.ps1'), ("`$script:Version = '$Version'`n" + ("# body line`n" * 12000)))
            [System.IO.File]::WriteAllText((Join-Path $d 'ssh-paste.cmd'), "cmd`n")
            [System.IO.File]::WriteAllText((Join-Path $d 'install.ps1'), "installer`n")
            [System.IO.File]::WriteAllText((Join-Path $d 'ssh-paste.js'), ("// macOS client`nvar VERSION = '$JsVersion';`n" + ("// body line`n" * 12000)))
            [System.IO.File]::WriteAllText((Join-Path $d 'ssh-paste-mac'), "#!/bin/zsh`n")
            [System.IO.File]::WriteAllText((Join-Path $d 'install.sh'), "#!/bin/sh`n")
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $sums = foreach ($n in @('ssh-paste.ps1', 'ssh-paste.cmd', 'install.ps1', 'ssh-paste.js', 'ssh-paste-mac', 'install.sh')) {
                '{0}  {1}' -f (([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes((Join-Path $d $n)))) -replace '-', '').ToLowerInvariant()), $n
            }
            [System.IO.File]::WriteAllText((Join-Path $d 'SHA256SUMS'), (($sums -join "`n") + "`n"))
            $sha.Dispose()
            return $d
        }
    }

    AfterAll {
        if ($script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'has bash and git, which the tests below need' {
        $script:Bash | Should -Not -BeNullOrEmpty
        $script:Git | Should -Not -BeNullOrEmpty
    }

    It 'parses every script with bash -n' {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.sh')) {
            $r = Invoke-Process -FilePath $script:Bash -Arguments @('-n', $f.FullName)
            $r.ExitCode | Should -Be 0 -Because ($f.Name + ': ' + $r.Stderr)
        }
    }

    Context 'stamp-version.sh' {
        It 'changes the version line of the real script and nothing else' {
            $out = Join-Path $script:Root 'stamped.ps1'
            $r = Invoke-Process -FilePath $script:Bash -Arguments @((Join-Path $script:ScriptsDir 'stamp-version.sh'), $script:CorePath, $out, '0.1.7')
            $r.ExitCode | Should -Be 0 -Because ($r.Stdout + $r.Stderr)
            $a = @([System.IO.File]::ReadAllText($script:CorePath) -split "`n")
            $b = @([System.IO.File]::ReadAllText($out) -split "`n")
            $b.Count | Should -Be $a.Count
            $diff = @(0..($a.Count - 1) | Where-Object { $a[$_] -cne $b[$_] })
            $diff.Count | Should -Be 1
            ($b[$diff[0]] -replace "`r$", '') | Should -BeExactly '$script:Version = ''0.1.7'''
            # The line ending of the line stays what it was (CRLF in a Windows checkout).
            $a[$diff[0]].EndsWith("`r") | Should -Be $b[$diff[0]].EndsWith("`r")
        }

        It 'changes the version line of the macOS client and nothing else' {
            $js = Join-Path $script:RepoRoot 'src/ssh-paste.js'
            $out = Join-Path $script:Root 'stamped.js'
            $r = Invoke-Process -FilePath $script:Bash -Arguments @((Join-Path $script:ScriptsDir 'stamp-version.sh'), $js, $out, '0.1.7')
            $r.ExitCode | Should -Be 0 -Because ($r.Stdout + $r.Stderr)
            $a = @([System.IO.File]::ReadAllText($js) -split "`n")
            $b = @([System.IO.File]::ReadAllText($out) -split "`n")
            $b.Count | Should -Be $a.Count
            $diff = @(0..($a.Count - 1) | Where-Object { $a[$_] -cne $b[$_] })
            $diff.Count | Should -Be 1
            $b[$diff[0]] | Should -BeExactly "var VERSION = '0.1.7';"
        }

        It 'refuses a source without the exact line, and a version that is not v0.1.N' {
            $odd = Join-Path $script:Root 'odd.ps1'
            [System.IO.File]::WriteAllText($odd, "`$script:Version = '0.0.0-dev' # a comment`n")
            $o = Join-Path $script:Root 'o.out'
            $stamp = Join-Path $script:ScriptsDir 'stamp-version.sh'
            (Invoke-Process -FilePath $script:Bash -Arguments @($stamp, $odd, $o, '0.1.7')).ExitCode | Should -Not -Be 0
            foreach ($bad in @('0.1.7; rm', 'v0.1.7', '0.1.07', '0.2.0', '0.1.7-rc.1')) {
                (Invoke-Process -FilePath $script:Bash -Arguments @($stamp, $script:CorePath, $o, $bad)).ExitCode | Should -Not -Be 0 -Because $bad
            }
        }
    }

    Context 'homebrew-formula.sh and scoop-manifest.sh' {
        BeforeAll {
            $script:Rel = Join-Path $script:Root 'download/v0.1.7'
            [void][System.IO.Directory]::CreateDirectory($script:Rel)
            $script:Sums = Join-Path $script:Rel 'SHA256SUMS'
            $script:Hex = @{}
            $lines = foreach ($f in @('ssh-paste.ps1', 'ssh-paste.cmd', 'ssh-paste.js', 'ssh-paste-mac')) {
                # Stand-in sums: the SHA-256 of each name, unique and well-formed.
                $h = ([System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.Text.Encoding]::ASCII.GetBytes($f))) -replace '-', '').ToLowerInvariant()
                $script:Hex[$f] = $h
                $h + '  ' + $f
            }
            [System.IO.File]::WriteAllText($script:Sums, (($lines -join "`n") + "`n"))
            $script:Base = 'https://github.com/xuing/ssh-please-paste-picture/releases/download/v0.1.7'
        }

        It 'writes a Scoop manifest with the release URLs, their sums, the shim and the uninstall hook' {
            $r = Invoke-Process -FilePath $script:Bash -Arguments @((Join-Path $script:ScriptsDir 'scoop-manifest.sh'), '0.1.7', $script:Base, $script:Sums)
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $m = $r.Stdout | ConvertFrom-Json
            $m.version | Should -BeExactly '0.1.7'
            @($m.url) | Should -Be @(($script:Base + '/ssh-paste.ps1'), ($script:Base + '/ssh-paste.cmd'))
            @($m.hash) | Should -Be @($script:Hex['ssh-paste.ps1'], $script:Hex['ssh-paste.cmd'])
            $m.bin | Should -BeExactly 'ssh-paste.cmd'
            (@($m.uninstaller.script) -join "`n") | Should -Match ([regex]::Escape("if (`$cmd -eq 'uninstall')"))
            (@($m.uninstaller.script) -join "`n") | Should -Match ([regex]::Escape('& "$dir\ssh-paste.cmd" --disable'))
            @($m.autoupdate.url)[0] | Should -BeExactly 'https://github.com/xuing/ssh-please-paste-picture/releases/download/v$version/ssh-paste.ps1'
            $m.autoupdate.hash.url | Should -BeExactly '$baseurl/SHA256SUMS'
        }

        It 'writes a Homebrew formula with the release URLs and their sums, and no version line' {
            $r = Invoke-Process -FilePath $script:Bash -Arguments @((Join-Path $script:ScriptsDir 'homebrew-formula.sh'), '0.1.7', $script:Base, $script:Sums)
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $r.Stdout | Should -Match ([regex]::Escape('url "' + $script:Base + '/ssh-paste.js"'))
            $r.Stdout | Should -Match ([regex]::Escape('sha256 "' + $script:Hex['ssh-paste.js'] + '"'))
            $r.Stdout | Should -Match ([regex]::Escape('sha256 "' + $script:Hex['ssh-paste-mac'] + '"'))
            $r.Stdout | Should -Not -Match '(?m)^\s*version "'
        }

        It 'refuses a bad version, a URL that does not end in the version folder or could end a string, and a missing sum' {
            foreach ($name in @('scoop-manifest.sh', 'homebrew-formula.sh')) {
                $path = Join-Path $script:ScriptsDir $name
                foreach ($bad in @(@('0.1.7"', $script:Base), @('0.1.8', $script:Base), @('0.1.7', ($script:Base -replace 'v0\.1\.7$', 'x"/v0.1.7')), @('0.1.7', 'http://example.com/v0.1.7'))) {
                    (Invoke-Process -FilePath $script:Bash -Arguments @($path, $bad[0], $bad[1], $script:Sums)).ExitCode | Should -Not -Be 0 -Because ($name + ' ' + ($bad -join ' '))
                }
                $partial = Join-Path $script:Root 'partial-sums'
                [System.IO.File]::WriteAllText($partial, ($script:Hex['ssh-paste.cmd'] + '  ssh-paste.cmd' + "`n"))
                (Invoke-Process -FilePath $script:Bash -Arguments @($path, '0.1.7', $script:Base, $partial)).ExitCode | Should -Not -Be 0 -Because ($name + ' without all sums')
            }
        }
    }

    Context 'plan-release.sh' {
        It 'releases v0.1.0 when nothing is published, and tags exactly the commit it was given' {
            $work = New-ScratchRepo
            $stub = New-Stub
            $sha = Invoke-GitIn $work @('rev-parse', 'HEAD')
            $p = Get-Plan $work $sha $stub
            $p.Tag | Should -BeExactly 'v0.1.0'
            Get-RemoteTags $work | Should -Contain 'v0.1.0'
            Invoke-GitIn $work @('rev-parse', 'v0.1.0^{commit}') | Should -BeExactly $sha
            Invoke-GitIn $work @('cat-file', '-t', 'v0.1.0') | Should -BeExactly 'tag'
        }

        It 'continues with the tag that already points at the commit, so a rerun makes no second tag' {
            $work = New-ScratchRepo
            $stub = New-Stub
            $sha = Invoke-GitIn $work @('rev-parse', 'HEAD')
            (Get-Plan $work $sha $stub).Tag | Should -BeExactly 'v0.1.0'
            # The first run died after pushing the tag and before publishing: no release exists.
            $again = Get-Plan $work $sha $stub
            $again.Tag | Should -BeExactly 'v0.1.0'
            $again.Reason | Should -Match 'already points at'
            # Even when the release was published meanwhile: publishing checks it again.
            Set-Release $stub 'v0.1.0'
            (Get-Plan $work $sha $stub).Tag | Should -BeExactly 'v0.1.0'
            @(Get-RemoteTags $work).Count | Should -Be 1
        }

        It 'does nothing for a commit that is not the newest on main: the newer commit releases it' {
            $work = New-ScratchRepo
            $stub = New-Stub
            $first = Invoke-GitIn $work @('rev-parse', 'HEAD')
            $newer = Add-Commit $work 'src/ssh-paste.ps1' 'upload: a visible change'
            $p = Get-Plan $work $first $stub
            $p.Tag | Should -BeExactly ''
            $p.Reason | Should -Match 'newer commit'
            @(Get-RemoteTags $work).Count | Should -Be 0
            (Get-Plan $work $newer $stub).Tag | Should -BeExactly 'v0.1.0'
        }

        It 'never gives older code a higher version than the unpublished tag that won' {
            $work = New-ScratchRepo
            $stub = New-Stub
            (Get-Plan $work (Invoke-GitIn $work @('rev-parse', 'HEAD')) $stub).Tag | Should -BeExactly 'v0.1.0'
            Set-Release $stub 'v0.1.0'
            $a = Add-Commit $work 'src/ssh-paste.ps1' 'upload: change a'
            (Get-Plan $work $a $stub).Tag | Should -BeExactly 'v0.1.1'
            # v0.1.1 has no release (its run died), and a newer commit arrives.
            $b = Add-Commit $work 'src/ssh-paste.ps1' 'upload: change b'
            $old = Get-Plan $work $a $stub
            $old.Tag | Should -BeExactly ''
            $new = Get-Plan $work $b $stub
            $new.Tag | Should -BeExactly 'v0.1.2'
            Invoke-GitIn $work @('rev-parse', 'v0.1.1^{commit}') | Should -BeExactly $a
            Invoke-GitIn $work @('rev-parse', 'v0.1.2^{commit}') | Should -BeExactly $b
        }

        It 'counts a draft as unpublished: its changes are released with the next commit, even a docs one' {
            $work = New-ScratchRepo
            $stub = New-Stub
            (Get-Plan $work (Invoke-GitIn $work @('rev-parse', 'HEAD')) $stub).Tag | Should -BeExactly 'v0.1.0'
            Set-Release $stub 'v0.1.0'
            $src = Add-Commit $work 'src/ssh-paste.ps1' 'upload: change one'
            (Get-Plan $work $src $stub).Tag | Should -BeExactly 'v0.1.1'
            Set-Release $stub 'v0.1.1' -Draft
            $docs = Add-Commit $work 'README.md' 'docs: change two'
            $p = Get-Plan $work $docs $stub
            $p.Tag | Should -BeExactly 'v0.1.2'
            Invoke-GitIn $work @('rev-parse', 'v0.1.2^{commit}') | Should -BeExactly $docs
        }

        It 'skips a commit that changes only docs, tests or workflows, and releases one that changes src/, install.ps1 or install.sh' {
            $work = New-ScratchRepo
            $stub = New-Stub
            (Get-Plan $work (Invoke-GitIn $work @('rev-parse', 'HEAD')) $stub).Tag | Should -BeExactly 'v0.1.0'
            Set-Release $stub 'v0.1.0'
            [void][System.IO.Directory]::CreateDirectory((Join-Path $work 'tests'))
            [System.IO.File]::WriteAllText((Join-Path $work 'tests/a.ps1'), "t`n")
            Invoke-GitIn $work @('add', '-A') | Out-Null
            Invoke-GitIn $work @('commit', '-q', '-m', 'tests: more') | Out-Null
            $docs = Add-Commit $work 'README.md' 'docs: more'
            $skip = Get-Plan $work $docs $stub
            $skip.Tag | Should -BeExactly ''
            $skip.Reason | Should -Match 'nothing to release'
            $src = Add-Commit $work 'src/ssh-paste.ps1' 'upload: a visible change'
            (Get-Plan $work $src $stub).Tag | Should -BeExactly 'v0.1.1'
            Set-Release $stub 'v0.1.1'
            $docs2 = Add-Commit $work 'README.md' 'docs: again'
            (Get-Plan $work $docs2 $stub).Tag | Should -BeExactly ''
            $inst = Add-Commit $work 'install.ps1' 'install: a visible change'
            (Get-Plan $work $inst $stub).Tag | Should -BeExactly 'v0.1.2'
            Set-Release $stub 'v0.1.2'
            $mac = Add-Commit $work 'install.sh' 'install: a visible change on macOS'
            (Get-Plan $work $mac $stub).Tag | Should -BeExactly 'v0.1.3'
        }

        It 'orders versions as numbers and ignores tags that are not v0.1.N: after v0.1.9 comes v0.1.10' {
            $work = New-ScratchRepo
            $stub = New-Stub
            $first = Invoke-GitIn $work @('rev-parse', 'HEAD')
            # v0.1.08 and v0.1.010 have leading zeros: bash would read 08 as a bad octal number.
            foreach ($t in @('v0.1.2', 'v0.1.9', 'v0.1.08', 'v0.1.010', 'v0.2.0-rc.1', 'v1.0.0')) { Invoke-GitIn $work @('tag', '-a', $t, '-m', $t, $first) | Out-Null }
            Invoke-GitIn $work @('push', '-q', 'origin', '--tags') | Out-Null
            $src = Add-Commit $work 'src/ssh-paste.ps1' 'upload: a visible change'
            Set-Release $stub 'v0.1.08'
            $p = Get-Plan $work $src $stub
            $p.Tag | Should -BeExactly 'v0.1.10'
            Invoke-GitIn $work @('rev-parse', 'v0.1.9^{commit}') | Should -BeExactly $first
        }

        It 'ignores a leading-zero tag that points at the commit, and makes a real version' {
            $work = New-ScratchRepo
            $stub = New-Stub
            $sha = Invoke-GitIn $work @('rev-parse', 'HEAD')
            Invoke-GitIn $work @('tag', '-a', 'v0.1.08', '-m', 'odd', $sha) | Out-Null
            Invoke-GitIn $work @('push', '-q', 'origin', '--tags') | Out-Null
            (Get-Plan $work $sha $stub).Tag | Should -BeExactly 'v0.1.0'
        }

        It 'fails and tags nothing when gh cannot list the releases' {
            $work = New-ScratchRepo
            $stub = New-Stub
            $sha = Invoke-GitIn $work @('rev-parse', 'HEAD')
            $p = Invoke-Plan $work $sha $stub @{ GH_STUB_FAIL = 'release list' }
            $p.Exit | Should -Not -Be 0
            $p.Tag | Should -BeExactly ''
            @(Get-RemoteTags $work).Count | Should -Be 0
        }
    }

    Context 'publish-release.sh' {
        BeforeAll {
            function Invoke-Publish {
                param([string]$Stub, [string]$Tag, [string]$Dist, [hashtable]$Extra = @{})
                $notes = Join-Path $script:Root 'notes.md'
                [System.IO.File]::WriteAllText($notes, "notes`n")
                $environment = @{ GITHUB_REPOSITORY = 'x/y'; GH_STUB_DIR = $Stub; ATTEST_WAIT = '0' }
                foreach ($k in $Extra.Keys) { $environment[$k] = $Extra[$k] }
                return (Invoke-Script 'publish-release.sh' @($Tag, $Dist, $notes) $script:Root $environment)
            }
            function Test-IsDraft { param([string]$Stub, [string]$Tag) return (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $Stub 'releases') $Tag) 'draft')) }
            function Get-Latest { param([string]$Stub) $f = Join-Path $Stub 'latest'; if (Test-Path -LiteralPath $f) { return ([System.IO.File]::ReadAllText($f)).Trim() } return '' }
        }

        It 'creates a draft, checks it, and only then publishes it as Latest' {
            $stub = New-Stub
            $dist = New-Dist '0.1.7'
            $r = Invoke-Publish $stub 'v0.1.7' $dist
            $r.ExitCode | Should -Be 0 -Because ($r.Stdout + $r.Stderr)
            $calls = @(Get-StubCalls $stub)
            $create = @($calls | Where-Object { $_ -like 'release create *' })
            $create.Count | Should -Be 1
            $create[0] | Should -Match '--draft'
            $create[0] | Should -Match '--verify-tag'
            $edit = @($calls | Where-Object { $_ -like 'release edit *' })
            $edit.Count | Should -Be 1
            $edit[0] | Should -Match '--draft=false --latest$'
            $calls.IndexOf($create[0]) | Should -BeLessThan $calls.IndexOf(@($calls | Where-Object { $_ -like 'release download *' })[0])
            $calls.IndexOf(@($calls | Where-Object { $_ -like 'release download *' })[0]) | Should -BeLessThan $calls.IndexOf($edit[0])
            Test-IsDraft $stub 'v0.1.7' | Should -BeFalse
            Get-Latest $stub | Should -BeExactly 'v0.1.7'
            @(Get-ChildItem -LiteralPath (Join-Path $stub 'releases/v0.1.7/assets')).Count | Should -Be 7
        }

        It 'resumes after an earlier run left a draft: the draft is created again and published' {
            $stub = New-Stub
            $dist = New-Dist '0.1.7'
            Set-Release $stub 'v0.1.7' -Draft   # one stale asset, as after an interrupted upload
            $r = Invoke-Publish $stub 'v0.1.7' $dist
            $r.ExitCode | Should -Be 0 -Because ($r.Stdout + $r.Stderr)
            @(Get-StubCalls $stub | Where-Object { $_ -like 'release delete v0.1.7*' }).Count | Should -Be 1
            Test-IsDraft $stub 'v0.1.7' | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Join-Path $stub 'releases/v0.1.7/assets') | ForEach-Object { $_.Name } | Sort-Object) -join ' ' | Should -BeExactly ((@('install.ps1', 'install.sh', 'SHA256SUMS', 'ssh-paste.cmd', 'ssh-paste.js', 'ssh-paste.ps1', 'ssh-paste-mac') | Sort-Object) -join ' ')
        }

        It 'checks an already published release instead of failing on create' {
            $stub = New-Stub
            $dist = New-Dist '0.1.7'
            Set-Release $stub 'v0.1.7' -AssetsFrom $dist
            [System.IO.File]::WriteAllText((Join-Path $stub 'latest'), 'v0.1.7')
            $r = Invoke-Publish $stub 'v0.1.7' $dist
            $r.ExitCode | Should -Be 0 -Because ($r.Stdout + $r.Stderr)
            @(Get-StubCalls $stub | Where-Object { $_ -like 'release create *' -or $_ -like 'release delete *' }).Count | Should -Be 0
        }

        It 'does not give an older version the Latest mark' {
            $stub = New-Stub
            Set-Release $stub 'v0.1.9'
            [System.IO.File]::WriteAllText((Join-Path $stub 'latest'), 'v0.1.9')
            $r = Invoke-Publish $stub 'v0.1.7' (New-Dist '0.1.7')
            $r.ExitCode | Should -Be 0 -Because ($r.Stdout + $r.Stderr)
            @(Get-StubCalls $stub | Where-Object { $_ -like 'release edit v0.1.7*' })[0] | Should -Match '--latest=false'
            Get-Latest $stub | Should -BeExactly 'v0.1.9'
        }

        It 'fails before creating or publishing anything when gh cannot list the releases' {
            $stub = New-Stub
            Set-Release $stub 'v0.1.9'
            $r = Invoke-Publish $stub 'v0.1.7' (New-Dist '0.1.7') @{ GH_STUB_FAIL = 'release list' }
            $r.ExitCode | Should -Not -Be 0
            @(Get-StubCalls $stub | Where-Object { $_ -like 'release create *' -or $_ -like 'release edit *' }).Count | Should -Be 0
            Get-Latest $stub | Should -BeExactly ''
        }

        It 'leaves the draft unpublished when a downloaded file differs from the sums' {
            $stub = New-Stub
            $r = Invoke-Publish $stub 'v0.1.7' (New-Dist '0.1.7') @{ GH_STUB_CORRUPT = '1' }
            $r.ExitCode | Should -Not -Be 0
            Test-IsDraft $stub 'v0.1.7' | Should -BeTrue
            @(Get-StubCalls $stub | Where-Object { $_ -like 'release edit *' }).Count | Should -Be 0
        }

        It 'leaves the draft unpublished when ssh-paste.ps1 does not say the tag version' {
            $stub = New-Stub
            $r = Invoke-Publish $stub 'v0.1.7' (New-Dist '0.1.6')
            $r.ExitCode | Should -Not -Be 0
            ($r.Stdout + $r.Stderr) | Should -Match 'does not say version 0\.1\.7'
            Test-IsDraft $stub 'v0.1.7' | Should -BeTrue
        }

        It 'leaves the draft unpublished when ssh-paste.js (the macOS client) does not say the tag version' {
            $stub = New-Stub
            $r = Invoke-Publish $stub 'v0.1.7' (New-Dist '0.1.7' -JsVersion '0.0.0-dev')
            $r.ExitCode | Should -Not -Be 0
            ($r.Stdout + $r.Stderr) | Should -Match 'ssh-paste\.js on the release does not say version 0\.1\.7'
            Test-IsDraft $stub 'v0.1.7' | Should -BeTrue
        }

        It 'leaves the draft unpublished when an attestation does not verify' {
            $stub = New-Stub
            $r = Invoke-Publish $stub 'v0.1.7' (New-Dist '0.1.7') @{ GH_STUB_FAIL = 'attestation verify' }
            $r.ExitCode | Should -Not -Be 0
            Test-IsDraft $stub 'v0.1.7' | Should -BeTrue
        }

        It 'refuses a tag that is not v0.1.N, leading zeros included' {
            $stub = New-Stub
            foreach ($bad in @('v0.1.08', 'v0.2.0', 'v0.1.7-rc.1', 'main')) {
                (Invoke-Publish $stub $bad (New-Dist '0.1.7')).ExitCode | Should -Not -Be 0 -Because $bad
            }
            @(Get-StubCalls $stub).Count | Should -Be 0
        }
    }

    Context 'release-notes.sh' {
        BeforeAll {
            function Get-Notes {
                param([string]$Work, [string]$Tag, [string[]]$Published = @())
                $stub = New-Stub
                foreach ($t in $Published) { Set-Release $stub $t }
                $r = Invoke-Script 'release-notes.sh' @($Tag) $Work @{ GITHUB_REPOSITORY = 'xuing/ssh-please-paste-picture'; GH_STUB_DIR = $stub }
                $r.ExitCode | Should -Be 0 -Because $r.Stderr
                return $r.Stdout
            }
        }

        It 'lists the commit subjects since the previous release, leaves out docs, ci and tests commits, and ends with the install block' {
            $work = New-ScratchRepo
            Invoke-GitIn $work @('tag', '-a', 'v0.1.9', '-m', 'x') | Out-Null
            Add-Commit $work 'src/ssh-paste.ps1' 'upload: a copied image keeps its extension' | Out-Null
            Add-Commit $work 'README.md' 'docs: reword the intro' | Out-Null
            Add-Commit $work 'README.md' 'ci: faster runs' | Out-Null
            Add-Commit $work 'README.md' 'tests: cover --update' | Out-Null
            Add-Commit $work 'install.ps1' 'install: the installer keeps your PATH order' | Out-Null
            Invoke-GitIn $work @('tag', '-a', 'v0.1.10', '-m', 'x') | Out-Null
            $notes = Get-Notes $work 'v0.1.10' @('v0.1.9')
            $notes | Should -Match 'Since v0\.1\.9'
            $notes | Should -Match '- upload: a copied image keeps its extension \([0-9a-f]{7,}\)'
            $notes | Should -Match '- install: the installer keeps your PATH order \([0-9a-f]{7,}\)'
            $notes | Should -Not -Match 'docs: reword'
            $notes | Should -Not -Match 'ci: faster'
            $notes | Should -Not -Match 'tests: cover'
            $notes | Should -Not -Match 'first version'
            $notes | Should -Match 'compare/v0\.1\.9\.\.\.v0\.1\.10'
            $notes | Should -Match 'releases/download/v0\.1\.10/install\.ps1 \| iex'
            $notes | Should -Match 'ssh-paste --update'
            $notes | Should -Match 'gh attestation verify'
        }

        It 'starts at the previous published release, not at a tag that has no release' {
            $work = New-ScratchRepo
            Invoke-GitIn $work @('tag', '-a', 'v0.1.0', '-m', 'x') | Out-Null
            Add-Commit $work 'src/ssh-paste.ps1' 'upload: in the lost release' | Out-Null
            Invoke-GitIn $work @('tag', '-a', 'v0.1.1', '-m', 'x') | Out-Null
            Add-Commit $work 'src/ssh-paste.ps1' 'upload: in this release' | Out-Null
            Invoke-GitIn $work @('tag', '-a', 'v0.1.2', '-m', 'x') | Out-Null
            $notes = Get-Notes $work 'v0.1.2' @('v0.1.0')
            $notes | Should -Match 'Since v0\.1\.0'
            $notes | Should -Match 'upload: in the lost release'
            $notes | Should -Match 'upload: in this release'
        }

        It 'lists every commit when only docs, ci and tests commits are there' {
            $work = New-ScratchRepo
            Invoke-GitIn $work @('tag', '-a', 'v0.1.0', '-m', 'x') | Out-Null
            Add-Commit $work 'README.md' 'docs: reword the intro' | Out-Null
            Invoke-GitIn $work @('tag', '-a', 'v0.1.1', '-m', 'x') | Out-Null
            Get-Notes $work 'v0.1.1' @('v0.1.0') | Should -Match 'docs: reword the intro'
        }

        It 'starts at the first commit when nothing is published' {
            $work = New-ScratchRepo
            Invoke-GitIn $work @('tag', '-a', 'v0.1.0', '-m', 'x') | Out-Null
            $notes = Get-Notes $work 'v0.1.0'
            $notes | Should -Match 'The first release'
            $notes | Should -Match 'install: first version'
        }

        It 'refuses a tag that is not v0.1.N' {
            $work = New-ScratchRepo
            $stub = New-Stub
            foreach ($bad in @('main; rm -rf', 'v0.1.08', 'v0.2.0', 'v0.1.7-rc.1')) {
                $r = Invoke-Script 'release-notes.sh' @($bad) $work @{ GITHUB_REPOSITORY = 'x/y'; GH_STUB_DIR = $stub }
                $r.ExitCode | Should -Not -Be 0 -Because $bad
            }
        }
    }
}

Describe 'Invoke-Main' {
    It 'prints the usage without arguments and returns 0' {
        $out = @(Invoke-Main @() 6>&1)
        $out[-1] | Should -Be 0
        ($out | Out-String) | Should -Match 'ssh-paste \S+ - paste Windows screenshots'
    }

    It 'returns 2 for --proxy without arguments' {
        $oldError = [Console]::Error
        [Console]::SetError([System.IO.TextWriter]::Null)
        try { $code = Invoke-Main @('--proxy') } finally { [Console]::SetError($oldError) }
        $code | Should -Be 2
    }
}

Describe 'Test-ScoopInstall' {
    It 'is true only for a folder that holds scoop-install.json' {
        $dir = Join-Path $script:SandboxRoot ('scoop-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($dir)
        Test-ScoopInstall $dir | Should -BeFalse
        [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'scoop-install.json'))
        Test-ScoopInstall $dir | Should -BeFalse
        Remove-Item -LiteralPath (Join-Path $dir 'scoop-install.json')
        [System.IO.File]::WriteAllText((Join-Path $dir 'scoop-install.json'), '{}')
        Test-ScoopInstall $dir | Should -BeTrue
        Test-ScoopInstall '' | Should -BeFalse
    }

    It 'also knows install.json, which Scoop wrote before 0.6' {
        $dir = Join-Path $script:SandboxRoot ('scoop-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($dir)
        [System.IO.File]::WriteAllText((Join-Path $dir 'install.json'), '{}')
        Test-ScoopInstall $dir | Should -BeTrue
    }
}

Describe 'Get-ProxyScriptPath' {
    BeforeEach {
        $script:App = Join-Path $script:SandboxRoot ('apps-' + [guid]::NewGuid().ToString('N') + '/ssh-paste')
        $script:VersionDir = Join-Path $script:App '0.1.0'
        [void][System.IO.Directory]::CreateDirectory($script:VersionDir)
        [System.IO.File]::WriteAllText((Join-Path $script:VersionDir 'ssh-paste.ps1'), '#')
        [System.IO.File]::WriteAllText((Join-Path $script:VersionDir 'scoop-install.json'), '{}')
    }

    It 'keeps the path of an install that Scoop did not make' {
        $p = Join-Path $script:SandboxRoot 'Programs/ssh-paste/ssh-paste.ps1'
        Get-ProxyScriptPath $p | Should -BeExactly $p
    }

    It 'gives the current path of a Scoop install, also when called from a version folder' {
        $current = Join-Path $script:App 'current'
        [void][System.IO.Directory]::CreateDirectory($current)
        [System.IO.File]::WriteAllText((Join-Path $current 'ssh-paste.ps1'), '#')
        [System.IO.File]::WriteAllText((Join-Path $current 'scoop-install.json'), '{}')
        $want = Join-Path $current 'ssh-paste.ps1'
        Get-ProxyScriptPath (Join-Path $script:VersionDir 'ssh-paste.ps1') | Should -BeExactly $want
        Get-ProxyScriptPath $want | Should -BeExactly $want
    }

    It 'refuses a Scoop install without the current junction (no_junction)' {
        { Get-ProxyScriptPath (Join-Path $script:VersionDir 'ssh-paste.ps1') } | Should -Throw '*no_junction*wrapper mode*'
    }
}

Describe 'Invoke-Main under Scoop' {
    BeforeEach {
        Mock Invoke-Update { return 0 }
        Mock Invoke-Uninstall { return 0 }
        $script:OldError = [Console]::Error
        $script:Err = New-Object System.IO.StringWriter
        [Console]::SetError($script:Err)
    }
    AfterEach { [Console]::SetError($script:OldError) }

    It 'leaves --update to scoop update' {
        Mock Test-ScoopInstall { return $true }
        Invoke-Main @('--update') | Should -Be 1
        $script:Err.ToString() | Should -Match 'scoop update ssh-paste'
        Should -Invoke Invoke-Update -Times 0 -Exactly
    }

    It 'leaves --uninstall to scoop uninstall' {
        Mock Test-ScoopInstall { return $true }
        Invoke-Main @('--uninstall') | Should -Be 1
        $script:Err.ToString() | Should -Match 'scoop uninstall ssh-paste'
        Should -Invoke Invoke-Uninstall -Times 0 -Exactly
    }

    It 'still updates and uninstalls an install that Scoop did not make' {
        Mock Test-ScoopInstall { return $false }
        Invoke-Main @('--update') | Should -Be 0
        Invoke-Main @('--uninstall') | Should -Be 0
        Should -Invoke Invoke-Update -Times 1 -Exactly
        Should -Invoke Invoke-Uninstall -Times 1 -Exactly
        Should -Invoke Test-ScoopInstall -Times 2 -Exactly
    }
}

Describe 'Native argument quoting against a real child process' {
    It 'delivers every argument unchanged to a child PowerShell' {
        $script = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-args-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($script, '[Console]::Out.Write((ConvertTo-Json -Compress -InputObject @($args)))')
        try {
            $items = @('plain', 'with space', 'say "hi"', 'C:\Program Files\x\', 'a\"b', 'tab' + [char]9 + 'x', '-o', 'ProxyCommand=a "b c" d')
            $argv = @('-NoLogo', '-NoProfile')
            if ($script:OnWindows) { $argv += @('-ExecutionPolicy', 'Bypass') }
            $argv += @('-File', $script)
            $argv += $items
            $r = Invoke-Process -FilePath (Get-ThisPowerShell) -Arguments $argv
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeExactly (Format-ArgList $items)
        } finally {
            Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'server-side script run through real shells' -Tag 'Unix' -Skip:$onWindows {
    BeforeAll {
        $script:Created = New-Object System.Collections.ArrayList
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-work-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:WorkDir)
        # Files that a careless unquoted glob in the script would pick up.
        Set-Content -LiteralPath (Join-Path $script:WorkDir 'ssh-paste-decoy-1') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:WorkDir 'ssh-paste-decoy-2') -Value 'x'

        function New-RandomPng {
            # Not a real PNG: the server script treats the payload as opaque bytes.
            param([int]$Size = 4096)
            $bytes = New-Object byte[] $Size
            (New-Object System.Random).NextBytes($bytes)
            return , $bytes
        }

        function Get-Published {
            param([string]$Hash)
            $path = '/tmp/ssh-paste-' + $Hash + '.png'
            $null = $script:Created.Add($path)
            return $path
        }

        function Invoke-RemoteScript {
            # Runs the exact last argument that ssh would receive, through "<shell> -c".
            # Hash and Size default to the hash and the length of Bytes; pass Size to
            # claim another length, as when an upload is cut short.
            # Keep and Dir are --keep and --dir.
            param([string]$ShellPath = 'sh', [byte[]]$Bytes, [string]$Hash, $Size = $null, [string]$Directory,
                [string]$Keep = '1d', [string]$Dir = '/tmp')
            if (-not $Hash) { $Hash = Get-ImageHash $Bytes }
            if ($null -eq $Size) { $Size = $Bytes.Length }
            $argv = Get-UploadSshArguments -Parsed (Split-SshArguments @('host')) -Hash $Hash -Size $Size -Keep $Keep -Dir $Dir
            $command = $argv[$argv.Count - 1]
            if ($Directory) { $command = $command.Replace('/tmp', $Directory) }
            elseif ($Dir -cne '/tmp') { }
            else {
                $null = Get-Published $Hash
                $null = $script:Created.Add('/tmp/ssh-paste-' + $Hash + '-' + (& id -u).Trim() + '.png')
            }
            return (Invoke-Process -FilePath $ShellPath -Arguments @('-c', $command) -InputBytes $Bytes -WorkingDirectory $script:WorkDir)
        }

        function Get-Mode { param([string]$Path) return ((& stat -c '%a' $Path).Trim()) }
        function Get-Inode { param([string]$Path) return ((& stat -c '%i' $Path).Trim()) }
        function Get-TempNames {
            # The script receives into /tmp/ssh-paste-tmp.XXXXXXXXXX; none may stay behind.
            return @(Get-ChildItem -Path '/tmp' -Filter 'ssh-paste-tmp.*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        }
        function Get-NewTempNames {
            param([string[]]$Before)
            return @(Get-TempNames | Where-Object { $Before -notcontains $_ })
        }
    }

    AfterAll {
        foreach ($p in $script:Created) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'login shell <Shell>' -ForEach $unixShells {
        It 'puts the image into a --dir folder it makes (mode 700), with the class of --keep in the name' {
            $dir = Join-Path $script:WorkDir ('dir-' + [guid]::NewGuid().ToString('N') + '/shots/new')
            $png = New-RandomPng 700
            $hash = Get-ImageHash $png
            $r = Invoke-RemoteScript -ShellPath $ShellPath -Bytes $png -Dir $dir -Keep '7d'
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $path = $dir + '/ssh-paste-k7d-' + $hash + '.png'
            Read-UploadReply $r.Stdout $png.Length $hash 'png' $dir 'k7d-' | Should -BeExactly $path
            Get-Mode $dir | Should -BeExactly '700'
            Get-Mode $path | Should -BeExactly '600'
        }

        It 'uploads, replies with the size and the path, and makes a private file' {
            $png = New-RandomPng 5000
            $hash = Get-ImageHash $png
            $r = Invoke-RemoteScript -ShellPath $ShellPath -Bytes $png
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            Read-UploadReply $r.Stdout $png.Length $hash | Should -BeExactly $path
            Get-Mode $path | Should -BeExactly '600'
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))) | Should -BeExactly (Get-Sha256Hex $png)
        }

        It 'rejects a short upload with "short N" and exit 4' {
            $png = New-RandomPng 900
            $hash = Get-ImageHash $png
            $r = Invoke-RemoteScript -ShellPath $ShellPath -Bytes $png -Size 1000
            $r.ExitCode | Should -Be 4
            $r.Stdout.Trim() | Should -BeExactly 'short 900'
            Test-Path -LiteralPath ('/tmp/ssh-paste-' + $hash + '.png') | Should -BeFalse
        }
    }

    Context 'behaviour of the script' {
        It 'leaves no temporary file behind, after a success or a rejected upload' {
            $before = Get-TempNames
            $png = New-RandomPng 100
            (Invoke-RemoteScript -Bytes $png).ExitCode | Should -Be 0
            (Invoke-RemoteScript -Bytes (New-RandomPng 50) -Size 100).ExitCode | Should -Be 4
            @(Get-NewTempNames $before).Count | Should -Be 0
        }

        It 'reuses an identical complete file instead of rewriting it, and refreshes its time' {
            $png = New-RandomPng 3000
            $hash = Get-ImageHash $png
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            (Invoke-RemoteScript -Bytes $png).ExitCode | Should -Be 0
            $inode = Get-Inode $path
            (New-Object System.IO.FileInfo $path).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-5)
            $before = Get-TempNames
            $again = Invoke-RemoteScript -Bytes $png
            $again.ExitCode | Should -Be 0
            Read-UploadReply $again.Stdout $png.Length $hash | Should -BeExactly $path
            Get-Inode $path | Should -BeExactly $inode
            Get-Mode $path | Should -BeExactly '600'
            ([datetime]::UtcNow - (New-Object System.IO.FileInfo $path).LastWriteTimeUtc).TotalMinutes | Should -BeLessThan 5
            @(Get-NewTempNames $before).Count | Should -Be 0
        }

        It 'repairs a partial leftover: a file of the wrong size is replaced by the full upload' {
            $png = New-RandomPng 800
            $hash = Get-ImageHash $png
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            [System.IO.File]::WriteAllBytes($path, [byte[]](1..10))
            $null = $script:Created.Add($path)
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Read-UploadReply $r.Stdout $png.Length $hash | Should -BeExactly $path
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))) | Should -BeExactly (Get-Sha256Hex $png)
            Get-Mode $path | Should -BeExactly '600'
        }

        It 'replaces an empty leftover file' {
            $png = New-RandomPng 800
            $hash = Get-ImageHash $png
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            [System.IO.File]::WriteAllBytes($path, [byte[]]@())
            $null = $script:Created.Add($path)
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 0
            Read-UploadReply $r.Stdout $png.Length $hash | Should -BeExactly $path
            (Get-Item -LiteralPath $path).Length | Should -Be 800
        }

        It 'rejects a short upload and leaves the existing file untouched' {
            $png = New-RandomPng 600
            $hash = Get-ImageHash $png
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            (Invoke-RemoteScript -Bytes $png).ExitCode | Should -Be 0
            $inode = Get-Inode $path
            $sha = Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))
            (New-Object System.IO.FileInfo $path).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-3)
            $before = Get-TempNames

            $cut = New-Object byte[] 500
            [Array]::Copy($png, $cut, 500)
            $r = Invoke-RemoteScript -Bytes $cut -Hash $hash -Size 600
            $r.ExitCode | Should -Be 4
            $r.Stdout.Trim() | Should -BeExactly 'short 500'
            { Read-UploadReply $r.Stdout 600 $hash } | Should -Throw '*received 500 of 600 bytes*'

            Get-Inode $path | Should -BeExactly $inode
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))) | Should -BeExactly $sha
            ([datetime]::UtcNow - (New-Object System.IO.FileInfo $path).LastWriteTimeUtc).TotalHours | Should -BeGreaterThan 2 -Because 'a rejected upload must not even touch the file'
            @(Get-NewTempNames $before).Count | Should -Be 0
        }

        It 'does not create a file when the upload is short, and rejects one that is too long' {
            $hash = ('e' * 31) + '1'
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            $r = Invoke-RemoteScript -Bytes (New-RandomPng 100) -Hash $hash -Size 200
            $r.ExitCode | Should -Be 4
            Test-Path -LiteralPath $path | Should -BeFalse
            $r = Invoke-RemoteScript -Bytes (New-RandomPng 300) -Hash $hash -Size 200
            $r.ExitCode | Should -Be 4
            $r.Stdout.Trim() | Should -BeExactly 'short 300'
            Test-Path -LiteralPath $path | Should -BeFalse
        }

        It 'fails and leaves nothing when no data arrives' {
            $hash = ('f' * 32)
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            $before = Get-TempNames
            $r = Invoke-RemoteScript -Bytes ([byte[]]@()) -Hash $hash -Size 100
            $r.ExitCode | Should -Be 4
            $r.Stdout.Trim() | Should -BeExactly 'short 0'
            Test-Path -LiteralPath $path | Should -BeFalse
            @(Get-NewTempNames $before).Count | Should -Be 0
        }

        It 'replaces a symbolic link at the target instead of writing through it or reusing it, even when its target has the same size' {
            $png = New-RandomPng 700
            $hash = Get-ImageHash $png
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            $victim = Join-Path $script:WorkDir 'victim.txt'
            [System.IO.File]::WriteAllBytes($victim, (New-Object byte[] 700))
            [void](New-Item -ItemType SymbolicLink -Path $path -Target $victim)
            $null = $script:Created.Add($path)
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 0
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($victim))) | Should -BeExactly (Get-Sha256Hex (New-Object byte[] 700))
            (New-Object System.IO.FileInfo $path).LinkTarget | Should -BeNullOrEmpty
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))) | Should -BeExactly (Get-Sha256Hex $png)
        }

        It 'replaces a dangling symbolic link without creating its target' {
            $png = New-RandomPng 400
            $hash = Get-ImageHash $png
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            $target = Join-Path $script:WorkDir 'does-not-exist'
            [void](New-Item -ItemType SymbolicLink -Path $path -Target $target)
            $null = $script:Created.Add($path)
            (Invoke-RemoteScript -Bytes $png).ExitCode | Should -Be 0
            Test-Path -LiteralPath $target | Should -BeFalse
            (New-Object System.IO.FileInfo $path).LinkTarget | Should -BeNullOrEmpty
            (Get-Item -LiteralPath $path).Length | Should -Be 400
        }

        It 'prunes our own content-named files older than a day and old temp leftovers, and nothing else' {
            $oldMine = '/tmp/ssh-paste-' + ('a' * 31) + '1.png'
            $freshMine = '/tmp/ssh-paste-' + ('a' * 31) + '2.png'
            $oldUserName = '/tmp/ssh-paste-' + ('a' * 31) + '3-' + (& id -u).Trim() + '.png'
            $oldTemp = '/tmp/ssh-paste-tmp.' + 'OLDLEFT012'   # mktemp's 10 characters
            $oldOther = '/tmp/not-ssh-paste-' + [guid]::NewGuid().ToString('N')
            foreach ($p in @($oldMine, $freshMine, $oldUserName, $oldTemp, $oldOther)) { Set-Content -LiteralPath $p -Value 'x'; $null = $script:Created.Add($p) }
            foreach ($p in @($oldMine, $oldUserName, $oldTemp, $oldOther)) { (New-Object System.IO.FileInfo $p).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-3) }
            $r = Invoke-RemoteScript -Bytes (New-RandomPng 300)
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Test-Path -LiteralPath $oldMine | Should -BeFalse
            Test-Path -LiteralPath $oldUserName | Should -BeFalse
            Test-Path -LiteralPath $oldTemp | Should -BeFalse
            Test-Path -LiteralPath $freshMine | Should -BeTrue
            Test-Path -LiteralPath $oldOther | Should -BeTrue
        }

        It 'never prunes a same-user file that merely starts with ssh-paste-, such as /tmp/ssh-paste-notes.png' {
            $keep = @(
                ('/tmp/ssh-paste-notes-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.png'),
                ('/tmp/ssh-paste-' + ('b' * 20) + '.png'),                     # too short to be a content name
                ('/tmp/ssh-paste-' + ('b' * 32) + '.txt'),                     # not .png
                ('/tmp/ssh-paste-tmp-keep-' + [guid]::NewGuid().ToString('N').Substring(0, 8)),
                ('/tmp/ssh-paste-' + ('b' * 32) + '-7-notes.png'),             # a number, but not our uid
                ('/tmp/ssh-paste-' + ('b' * 31) + 'c-' + (& id -u).Trim() + '0.png'),   # not exactly our uid
                ('/tmp/ssh-paste-tmp.' + 'notes.txt1'),                         # 10 characters, but not mktemp's
                ('/tmp/ssh-paste-' + [guid]::NewGuid().ToString('N'))
            )
            foreach ($p in $keep) { Set-Content -LiteralPath $p -Value 'x'; $null = $script:Created.Add($p); (New-Object System.IO.FileInfo $p).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-30) }
            $r = Invoke-RemoteScript -Bytes (New-RandomPng 300)
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            foreach ($p in $keep) { Test-Path -LiteralPath $p | Should -BeTrue -Because "$p is not an ssh-paste upload" }
        }

        It 'replaces a file of the same size but different content, instead of reusing it' {
            $png = New-RandomPng 900
            $hash = Get-ImageHash $png
            $path = '/tmp/ssh-paste-' + $hash + '.png'
            $other = New-RandomPng 900
            [System.IO.File]::WriteAllBytes($path, $other)
            $null = $script:Created.Add($path)
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))) | Should -Not -BeExactly (Get-Sha256Hex $png)
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Read-UploadReply $r.Stdout $png.Length $hash | Should -BeExactly $path
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))) | Should -BeExactly (Get-Sha256Hex $png)
            Get-Mode $path | Should -BeExactly '600'
        }

        It 'falls back to the per-user name when a directory sits at the content name' {
            $png = New-RandomPng 500
            $hash = Get-ImageHash $png
            $main = '/tmp/ssh-paste-' + $hash + '.png'
            $uid = (& id -u).Trim()
            $fallback = '/tmp/ssh-paste-' + $hash + '-' + $uid + '.png'
            [void](New-Item -ItemType Directory -Path $main)
            $null = $script:Created.Add($main)
            $null = $script:Created.Add($fallback)
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Read-UploadReply $r.Stdout $png.Length $hash | Should -BeExactly $fallback
            (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($fallback))) | Should -BeExactly (Get-Sha256Hex $png)
            (Get-Item -LiteralPath $main).PSIsContainer | Should -BeTrue
            @(Get-ChildItem -LiteralPath $main -Force).Count | Should -Be 0
        }

        It 'falls back to the per-user name when a symbolic link to a directory sits at the content name, and writes nothing into that directory' {
            $png = New-RandomPng 500
            $hash = Get-ImageHash $png
            $main = '/tmp/ssh-paste-' + $hash + '.png'
            $uid = (& id -u).Trim()
            $fallback = '/tmp/ssh-paste-' + $hash + '-' + $uid + '.png'
            $targetDir = Join-Path $script:WorkDir 'linked-dir'
            [void](New-Item -ItemType Directory -Path $targetDir)
            [void](New-Item -ItemType SymbolicLink -Path $main -Target $targetDir)
            $null = $script:Created.Add($main)
            $null = $script:Created.Add($fallback)
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Read-UploadReply $r.Stdout $png.Length $hash | Should -BeExactly $fallback
            @(Get-ChildItem -LiteralPath $targetDir -Force).Count | Should -Be 0
            (New-Object System.IO.FileInfo $main).LinkTarget | Should -Not -BeNullOrEmpty
        }

        It 'reuses the per-user file the second time too (same bytes), without leaving a temp file' {
            $png = New-RandomPng 500
            $hash = Get-ImageHash $png
            $main = '/tmp/ssh-paste-' + $hash + '.png'
            $uid = (& id -u).Trim()
            $fallback = '/tmp/ssh-paste-' + $hash + '-' + $uid + '.png'
            [void](New-Item -ItemType Directory -Path $main)
            $null = $script:Created.Add($main)
            $null = $script:Created.Add($fallback)
            (Invoke-RemoteScript -Bytes $png).ExitCode | Should -Be 0
            $inode = Get-Inode $fallback
            $before = Get-TempNames
            $again = Invoke-RemoteScript -Bytes $png
            $again.ExitCode | Should -Be 0
            Read-UploadReply $again.Stdout $png.Length $hash | Should -BeExactly $fallback
            Get-Inode $fallback | Should -BeExactly $inode
            @(Get-NewTempNames $before).Count | Should -Be 0
        }

        It 'fails and leaves no temp file when both names are directories' {
            $png = New-RandomPng 500
            $hash = Get-ImageHash $png
            $uid = (& id -u).Trim()
            $names = @(('/tmp/ssh-paste-' + $hash + '.png'), ('/tmp/ssh-paste-' + $hash + '-' + $uid + '.png'))
            foreach ($n in $names) { [void](New-Item -ItemType Directory -Path $n); $null = $script:Created.Add($n) }
            $before = Get-TempNames
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 1
            @(Get-NewTempNames $before).Count | Should -Be 0
            foreach ($n in $names) { @(Get-ChildItem -LiteralPath $n -Force).Count | Should -Be 0 }
        }

        It 'is not confused by files named ssh-paste-* in the working directory (globbing is off)' {
            # WorkDir has ssh-paste-decoy-1 and -2; an unquoted glob would make find fail.
            $r = Invoke-RemoteScript -Bytes (New-RandomPng 200)
            $r.ExitCode | Should -Be 0
            $r.Stderr | Should -BeExactly ''
            (Test-Path -LiteralPath (Join-Path $script:WorkDir 'ssh-paste-decoy-1')) | Should -BeTrue
        }

        It 'handles a payload of several megabytes' {
            $png = New-RandomPng (6 * 1024 * 1024)
            $hash = Get-ImageHash $png
            $r = Invoke-RemoteScript -Bytes $png
            $r.ExitCode | Should -Be 0
            Read-UploadReply $r.Stdout $png.Length $hash | Should -BeExactly ('/tmp/ssh-paste-' + $hash + '.png')
        }

        It 'fails, writes nothing and leaves nothing when the directory is not writable' {
            if ((& id -u).Trim() -eq '0') { Set-ItResult -Skipped -Because 'root can write anywhere'; return }
            $dir = Join-Path $script:WorkDir 'readonly'
            [void](New-Item -ItemType Directory -Path $dir)
            & chmod 500 $dir
            try {
                $r = Invoke-RemoteScript -Bytes (New-RandomPng 100) -Directory $dir
                $r.ExitCode | Should -Not -Be 0
                @(Get-ChildItem -LiteralPath $dir -Force).Count | Should -Be 0
            } finally { & chmod 700 $dir }
        }
    }

    Context 'folder and keep (--dir, --keep)' {
        BeforeEach {
            $script:Folder = Join-Path $script:WorkDir ('dir-' + [guid]::NewGuid().ToString('N'))
            function New-Image {
                # An upload's file in the folder, AgeMinutes old.
                param([string]$Name, [int]$AgeMinutes)
                $path = Join-Path $script:Folder $Name
                [System.IO.File]::WriteAllText($path, 'x')
                & touch -d ('{0} minutes ago' -f $AgeMinutes) $path
                return $path
            }
        }

        It 'makes a missing folder (mode 700) and answers a path that the client accepts' {
            $png = New-RandomPng 300
            $hash = Get-ImageHash $png
            $dir = Join-Path $script:Folder 'a/b'
            $r = Invoke-RemoteScript -Bytes $png -Dir $dir
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Read-UploadReply $r.Stdout $png.Length $hash 'png' $dir | Should -BeExactly (Join-Path $dir ('ssh-paste-' + $hash + '.png'))
            Get-Mode $dir | Should -BeExactly '700'
        }

        It 'answers nodir (exit 5) when it cannot make the folder, and the client says so' {
            [void](New-Item -ItemType Directory -Path $script:Folder)
            & chmod 500 $script:Folder
            try {
                $png = New-RandomPng 300
                $dir = Join-Path $script:Folder 'sub'
                $r = Invoke-RemoteScript -Bytes $png -Dir $dir
                $r.ExitCode | Should -Be 5
                { Read-UploadReply $r.Stdout $png.Length (Get-ImageHash $png) 'png' $dir } | Should -Throw '*cannot write to the folder*'
            } finally { & chmod 700 $script:Folder }
        }

        It 'deletes only regular files of its own --keep older than it, and nothing else' {
            [void](New-Item -ItemType Directory -Path $script:Folder)
            & chmod 700 $script:Folder
            $mine = 'ssh-paste-k60m-'
            $old = New-Image ($mine + ('a' * 32) + '.png') 120
            $oldUser = New-Image ($mine + ('b' * 32) + '-' + (& id -u).Trim() + '.jpg') 120
            $new = New-Image ($mine + ('c' * 32) + '.png') 10
            $default = New-Image ('ssh-paste-' + ('d' * 32) + '.png') 3000
            $never = New-Image ('ssh-paste-knever-' + ('e' * 32) + '.png') 100000
            $notes = New-Image 'ssh-paste-notes.png' 3000
            $long = New-Image 'ssh-paste-quarterly-presentation-preview-2025.png' 3000
            $target = New-Image 'target.png' 0
            $link = Join-Path $script:Folder ($mine + ('f' * 32) + '.png')
            & ln -s $target $link
            & touch -h -d '500 minutes ago' $link
            $r = Invoke-RemoteScript -Bytes (New-RandomPng 100) -Dir $script:Folder -Keep '60m'
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Test-Path -LiteralPath $old | Should -BeFalse
            Test-Path -LiteralPath $oldUser | Should -BeFalse
            foreach ($kept in @($new, $default, $never, $notes, $long, $target, $link)) { Test-Path -LiteralPath $kept | Should -BeTrue -Because $kept }
        }

        It 'deletes no image with --keep never (0), nor when the minutes are not a number' {
            [void](New-Item -ItemType Directory -Path $script:Folder)
            & chmod 700 $script:Folder
            $old = New-Image ('ssh-paste-knever-' + ('c' * 32) + '.png') 100000
            $r = Invoke-RemoteScript -Bytes (New-RandomPng 100) -Dir $script:Folder -Keep 'never'
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Test-Path -LiteralPath $old | Should -BeTrue
            $old5 = New-Image ('ssh-paste-k10m-' + ('c' * 32) + '.png') 100000
            $png = New-RandomPng 100
            $argv = Get-UploadSshArguments -Parsed (Split-SshArguments @('host')) -Hash (Get-ImageHash $png) -Size $png.Length -Keep '10m' -Dir $script:Folder
            $command = $argv[$argv.Count - 1].Replace(" 10 '", " x '")
            $command | Should -Match " x '" -Because 'the minutes must really be replaced'
            $r = Invoke-Process -FilePath 'sh' -Arguments @('-c', $command) -InputBytes $png -WorkingDirectory $script:WorkDir
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            Test-Path -LiteralPath $old5 | Should -BeTrue
        }

        It 'refuses a folder other than /tmp that others can write or that is a link (notprivate), and writes nothing there' {
            [void](New-Item -ItemType Directory -Path $script:Folder)
            & chmod 777 $script:Folder
            $png = New-RandomPng 100
            $r = Invoke-RemoteScript -Bytes $png -Dir $script:Folder
            $r.ExitCode | Should -Be 6
            $r.Stdout.Trim() | Should -BeExactly 'notprivate'
            @(Get-ChildItem -LiteralPath $script:Folder).Count | Should -Be 0
            & chmod 700 $script:Folder
            $link = $script:Folder + '-link'
            & ln -s $script:Folder $link
            $r = Invoke-RemoteScript -Bytes $png -Dir $link
            $r.ExitCode | Should -Be 6
            Remove-Item -LiteralPath $link -Force
        }

        It 'refuses the folder when ls -ld does not show it as private: <Name>' -ForEach @(
            @{ Name = 'ls fails'; Out = ''; Code = 1; Ok = $false }
            @{ Name = 'an ACL (+)'; Out = 'drwx------+ 2 me me 4096 Nov 24 10:00 dir'; Code = 0; Ok = $false }
            @{ Name = 'group write'; Out = 'drwxrwx--- 2 me me 4096 Nov 24 10:00 dir'; Code = 0; Ok = $false }
            @{ Name = 'other write, sticky'; Out = 'drwx-----wt 2 me me 4096 Nov 24 10:00 dir'; Code = 0; Ok = $false }
            @{ Name = 'an SELinux context (.) is fine'; Out = 'drwx------. 2 me me 4096 Nov 24 10:00 dir'; Code = 0; Ok = $true }
            @{ Name = 'macOS extended attributes (@) are fine'; Out = 'drwxr-xr-x@ 2 me staff 64 Nov 24 10:00 dir'; Code = 0; Ok = $true }
        ) {
            [void](New-Item -ItemType Directory -Path $script:Folder)
            & chmod 700 $script:Folder
            $bin = $script:Folder + '-bin'
            [void](New-Item -ItemType Directory -Path $bin)
            $lsBody = "#!/bin/sh`n"
            if ($Out) { $lsBody += "echo '" + $Out + "'`n" }
            [System.IO.File]::WriteAllText((Join-Path $bin 'ls'), $lsBody + "exit " + $Code + "`n")
            & chmod +x (Join-Path $bin 'ls')
            $png = New-RandomPng 100
            $argv = Get-UploadSshArguments -Parsed (Split-SshArguments @('host')) -Hash (Get-ImageHash $png) -Size $png.Length -Dir $script:Folder
            $command = 'PATH=' + $bin + ':$PATH; export PATH; ' + $argv[$argv.Count - 1]
            $r = Invoke-Process -FilePath 'sh' -Arguments @('-c', $command) -InputBytes $png -WorkingDirectory $script:WorkDir
            Remove-Item -LiteralPath $bin -Recurse -Force
            if ($Ok) {
                $r.ExitCode | Should -Be 0 -Because $r.Stderr
            } else {
                $r.ExitCode | Should -Be 6
                $r.Stdout.Trim() | Should -BeExactly 'notprivate'
                @(Get-ChildItem -LiteralPath $script:Folder).Count | Should -Be 0
            }
        }

    }
}

Describe 'the key setup command ($script:KeyInstallCommand) in real login shells' -Tag 'Unix' -Skip:$onWindows {
    Context 'login shell <Shell>' -ForEach $unixShells {
        It 'adds the key on its own line, without CR, to a private .ssh it makes when missing' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-keys-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $dir)
            try {
                # As ssh runs it: "<login shell> -c COMMAND" in the home folder, the key on stdin
                # with the CRLF that Windows PowerShell's pipe adds.
                $key1 = [System.Text.Encoding]::ASCII.GetBytes("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne me@pc`r`n")
                $r = Invoke-Process -FilePath $ShellPath -Arguments @('-c', $script:KeyInstallCommand) -InputBytes $key1 -WorkingDirectory $dir
                $r.ExitCode | Should -Be 0 -Because $r.Stderr
                $auth = Join-Path $dir '.ssh/authorized_keys'
                ((& stat -c '%a' (Join-Path $dir '.ssh')) | Out-String).Trim() | Should -BeExactly '700'
                ((& stat -c '%a' $auth) | Out-String).Trim() | Should -BeExactly '600'
                # A last line without its newline, as an editor may leave it.
                [System.IO.File]::WriteAllText($auth, ([System.IO.File]::ReadAllText($auth) + 'ssh-rsa AAAAB3Old old@pc'))
                $key2 = [System.Text.Encoding]::ASCII.GetBytes("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo me@pc`r`n")
                $r = Invoke-Process -FilePath $ShellPath -Arguments @('-c', $script:KeyInstallCommand) -InputBytes $key2 -WorkingDirectory $dir
                $r.ExitCode | Should -Be 0 -Because $r.Stderr
                $text = [System.IO.File]::ReadAllText($auth)
                $text.Contains("`r") | Should -BeFalse
                $lines = @($text -split "`n" | Where-Object { $_ })
                Format-ArgList $lines | Should -BeExactly (Format-ArgList @('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne me@pc', 'ssh-rsa AAAAB3Old old@pc', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo me@pc'))
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'works with noclobber set, and drops the NUL bytes of a UTF-16 pipe' {
            # zsh and tcsh refuse >> to a missing file under noclobber; fish has no such option.
            $noclobber = @{ zsh = 'setopt noclobber; '; tcsh = 'set noclobber; '; fish = '' }[$Shell]
            if ($null -eq $noclobber) { $noclobber = 'set -C; ' }
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-keys-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $dir)
            try {
                $key = [System.Text.Encoding]::Unicode.GetBytes("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne me@pc`r`n")
                $r = Invoke-Process -FilePath $ShellPath -Arguments @('-c', ($noclobber + $script:KeyInstallCommand)) -InputBytes $key -WorkingDirectory $dir
                $r.ExitCode | Should -Be 0 -Because $r.Stderr
                $text = [System.IO.File]::ReadAllText((Join-Path $dir '.ssh/authorized_keys'))
                @($text -split "`n" | Where-Object { $_ }) | Should -BeExactly @('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne me@pc')
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'the key setup command through the PowerShell pipe that README shows' -Tag 'Windows' -Skip:(-not $onWindows) {
    It 'gets the key from Get-Content | (a native program) intact, without CR' {
        # Git for Windows' sh stands in for the server's login shell; ssh passes stdin on unchanged.
        $sh = Join-Path $env:ProgramFiles 'Git\bin\sh.exe'
        if (-not (Test-Path -LiteralPath $sh)) { Set-ItResult -Skipped -Because 'Git for Windows is not installed'; return }
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-keys-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $dir)
        $pub = Join-Path $dir 'id_ed25519.pub'
        [System.IO.File]::WriteAllText($pub, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne me@pc`n")   # as ssh-keygen writes it
        Push-Location $dir
        try {
            Get-Content $pub | & $sh -c $script:KeyInstallCommand
            $LASTEXITCODE | Should -Be 0
            $text = [System.IO.File]::ReadAllText((Join-Path $dir '.ssh\authorized_keys'))
            $text.Contains("`r") | Should -BeFalse
            @($text -split "`n" | Where-Object { $_ }) | Should -BeExactly @('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne me@pc')
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-SshVersion and Send-Image with a stand-in for ssh' -Tag 'Unix' -Skip:$onWindows {
    BeforeAll {
        $script:FakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('fake-ssh-for-ssh-paste-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:FakeDir)
        $script:Cleanup = New-Object System.Collections.ArrayList
        function New-FakeSsh {
            param([string]$Name, [string]$Body)
            $path = Join-Path $script:FakeDir $Name
            [System.IO.File]::WriteAllText($path, "#!/bin/sh`n" + ($Body -replace "`r", "") + "`n")   # checkouts may be CRLF
            & chmod +x $path
            return $path
        }
        function Get-FakeArguments {
            param([byte[]]$Png, [string]$Hash)
            return (Get-UploadSshArguments -Parsed (Split-SshArguments @('-p', '22', 'host')) -Hash $Hash -Size $Png.Length)
        }
        $script:Runs = New-FakeSsh 'ssh-runs' 'for last; do :; done
exec sh -c "$last"'
    }
    AfterAll {
        foreach ($p in $script:Cleanup) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:FakeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Get-SshVersion reads the version from <Name>' -ForEach @(
        @{ Name = 'OpenSSH on Linux'; Text = 'OpenSSH_9.6p1 Ubuntu-3ubuntu13, OpenSSL 3.0.13 30 Jan 2024'; Expected = '9.6' }
        @{ Name = 'OpenSSH for Windows'; Text = 'OpenSSH_for_Windows_8.6p1, LibreSSL 3.4.3'; Expected = '8.6' }
        @{ Name = 'a two-digit minor version'; Text = 'OpenSSH_8.10p1, OpenSSL 3.0.2'; Expected = '8.10' }
        @{ Name = 'a two-digit major version'; Text = 'OpenSSH_10.0p2 Debian-7, OpenSSL 3.5.1'; Expected = '10.0' }
    ) {
        $ssh = New-FakeSsh 'ssh-version' ("echo '$Text' >&2")
        $v = Get-SshVersion $ssh
        $v | Should -BeOfType ([version])
        $v | Should -Be ([version]$Expected)
    }

    It 'Get-SshVersion is $null when the output is not a version or the program is missing' {
        Get-SshVersion (New-FakeSsh 'ssh-garbage' 'echo hello') | Should -BeNullOrEmpty
        Get-SshVersion (Join-Path $script:FakeDir 'no-such-ssh') | Should -BeNullOrEmpty
    }

    It 'Send-Image sends the bytes, runs the script and returns the published path' {
        $png = New-Object byte[] 5000
        (New-Object System.Random).NextBytes($png)
        $hash = Get-ImageHash $png
        $path = '/tmp/ssh-paste-' + $hash + '.png'
        $null = $script:Cleanup.Add($path)
        $got = Send-Image -SshPath $script:Runs -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash
        $got | Should -BeExactly $path
        (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($path))) | Should -BeExactly (Get-Sha256Hex $png)
    }

    It 'Send-Image reports the message and the exit code when ssh fails' {
        $ssh = New-FakeSsh 'ssh-denied' 'cat > /dev/null; echo "alice@host: Permission denied (publickey)." >&2; exit 255'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash } | Should -Throw '*ssh exited with 255: alice@host: Permission denied (publickey).*'
    }

    It 'Send-Image does not hang when ssh dies before it reads the image' {
        $ssh = New-FakeSsh 'ssh-dies' 'echo "Connection closed" >&2; exit 255'
        $png = New-Object byte[] (6 * 1024 * 1024)
        $hash = Get-ImageHash $png
        $started = [DateTime]::UtcNow
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash -TimeoutSeconds 30 } | Should -Throw '*ssh exited with 255*'
        ([DateTime]::UtcNow - $started).TotalSeconds | Should -BeLessThan 25
    }

    It 'Send-Image kills ssh and says so when it does not finish in time' {
        $ssh = New-FakeSsh 'ssh-hangs' 'exec sleep 30'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        $started = [DateTime]::UtcNow
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash -TimeoutSeconds 2 } | Should -Throw '*did not finish in 2 seconds*'
        ([DateTime]::UtcNow - $started).TotalSeconds | Should -BeLessThan 20
    }

    It 'Send-Image fails when the server says the upload was short' {
        $ssh = New-FakeSsh 'ssh-short' 'cat > /dev/null; echo "short 5"'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash } | Should -Throw '*received 5 of 50 bytes*'
    }

    It 'Send-Image fails when the server names a path that is not this image' {
        $ssh = New-FakeSsh 'ssh-other' 'for last; do :; done
set -- $last
while [ $# -gt 4 ]; do shift; done
n=$1
cat > /dev/null
echo "$n /tmp/ssh-paste-other.png"'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash } | Should -Throw '*unexpected path*'
    }

    It 'Send-Image fails when the reply is noise' {
        $ssh = New-FakeSsh 'ssh-noise' 'cat > /dev/null; echo "Welcome back"'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash } | Should -Throw '*unexpected reply*Welcome back*'
    }

    It 'Send-Image reports the server''s own last line when ssh fails and says nothing on stderr' {
        # The upload script answers "short 120" and exits 4; ssh passes the exit code on.
        $ssh = New-FakeSsh 'ssh-server-says-short' 'cat > /dev/null; echo "banner line"; echo "short 120"; exit 4'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash } | Should -Throw '*ssh exited with 4: short 120'
    }

    It 'Send-Image prefers what ssh says on stderr over the server''s stdout' {
        $ssh = New-FakeSsh 'ssh-both' 'cat > /dev/null; echo "short 120"; echo "Connection reset by peer" >&2; exit 4'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash } | Should -Throw '*ssh exited with 4: Connection reset by peer'
    }

    It 'Send-Image still gives a message when ssh fails with no output at all' {
        $ssh = New-FakeSsh 'ssh-mute' 'cat > /dev/null; exit 9'
        $png = [byte[]](1..50)
        $hash = Get-ImageHash $png
        { Send-Image -SshPath $ssh -Arguments (Get-FakeArguments $png $hash) -Png $png -Hash $hash } | Should -Throw '*ssh exited with 9: no error message'
    }

    It 'Get-EffectiveSshConfig runs "ssh -G" with the session''s arguments and reads the map' {
        $ssh = New-FakeSsh 'ssh-G' 'if [ "$1" = "-G" ]; then
echo "requesttty force"
echo "sessiontype default"
echo "remotecommand top"
echo "requesttty no"
echo "argv $*"
exit 0
fi
exit 5'
        $m = Get-EffectiveSshConfig $ssh @('-p', '2222', 'alice@h')
        $m['requesttty'] | Should -BeExactly 'force'
        $m['sessiontype'] | Should -BeExactly 'default'
        $m['remotecommand'] | Should -BeExactly 'top'
        $m['argv'] | Should -BeExactly '-G -p 2222 alice@h'
    }

    It 'Get-EffectiveSshConfig is $null when ssh -G fails or ssh is missing' {
        Get-EffectiveSshConfig (New-FakeSsh 'ssh-G-fails' 'echo "user x"; exit 255') @('h') | Should -BeNullOrEmpty
        Get-EffectiveSshConfig (Join-Path $script:FakeDir 'no-such-ssh') @('h') | Should -BeNullOrEmpty
    }

    It 'Get-EffectiveSshConfig feeds Test-InteractiveSsh: a config that sets RequestTTY no keeps the watcher off' {
        $ssh = New-FakeSsh 'ssh-G-notty' 'echo "requesttty false"; echo "sessiontype default"; echo "stdinnull no"'
        $parsed = Split-SshArguments @('host')
        Test-InteractiveSsh $parsed (Get-EffectiveSshConfig $ssh @('host')) | Should -BeFalse
        $ssh2 = New-FakeSsh 'ssh-G-tty' 'echo "requesttty auto"; echo "sessiontype default"; echo "stdinnull no"'
        Test-InteractiveSsh $parsed (Get-EffectiveSshConfig $ssh2 @('host')) | Should -BeTrue
    }
}

Describe 'Windows integration' -Tag 'Windows' -Skip:(-not $onWindows) {
    BeforeAll {
        $script:ClipboardAllowed = ([bool]$env:CI -or [bool]$env:SSH_PASTE_TEST_CLIPBOARD)
        $script:NativeReady = $false
        $script:NativeProblem = $null
        try { Initialize-Native; $script:NativeReady = $true } catch { $script:NativeProblem = $_.Exception.Message }
    }

    It 'Initialize-Native loads the clipboard and window APIs' {
        if (-not $script:NativeReady) { Set-ItResult -Skipped -Because $script:NativeProblem; return }
        ('SshPasteNative' -as [type]) | Should -Not -BeNullOrEmpty
        [SshPasteNative]::GetClipboardSequenceNumber() | Should -BeOfType ([uint32])
    }

    It 'Initialize-Native is safe to call twice' {
        if (-not $script:NativeReady) { Set-ItResult -Skipped -Because $script:NativeProblem; return }
        { Initialize-Native } | Should -Not -Throw
    }

    It 'Get-HostMatcher and GetForegroundWindow work without throwing' {
        if (-not $script:NativeReady) { Set-ItResult -Skipped -Because $script:NativeProblem; return }
        { [void][SshPasteNative]::GetForegroundWindow() } | Should -Not -Throw
        $m = Get-HostMatcher
        $m.Kind | Should -Not -BeNullOrEmpty
    }

    It 'ConvertFrom-Dib turns a bitmap from the clipboard into a PNG' {
        if (-not $script:NativeReady) { Set-ItResult -Skipped -Because $script:NativeProblem; return }
        $bitmap = New-Object System.Drawing.Bitmap -ArgumentList 8, 4, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $bitmap.SetPixel(3, 2, [System.Drawing.Color]::FromArgb(10, 200, 30))
            $ms = New-Object System.IO.MemoryStream
            $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp)
            $file = $ms.ToArray()
        } finally { $bitmap.Dispose() }
        $dib = New-Object byte[] ($file.Length - 14)
        [Array]::Copy($file, 14, $dib, 0, $dib.Length)   # a BMP file is a 14-byte header plus the DIB
        $png = ConvertFrom-Dib $dib
        $png | Should -Not -BeNullOrEmpty
        (Get-TrimmedPng $png).Length | Should -Be $png.Length
        $stream = New-Object System.IO.MemoryStream -ArgumentList (, $png)
        $image = [System.Drawing.Image]::FromStream($stream)
        try {
            $image.Width | Should -Be 8
            $image.Height | Should -Be 4
            $image.GetPixel(3, 2).G | Should -Be 200
        } finally { $image.Dispose(); $stream.Dispose() }
    }

    Context 'clipboard round trip' {
        BeforeAll {
            function Get-DataBytes {
                # What DataObject.GetData returns for the formats written as streams.
                param($Data)
                if ($Data -is [byte[]]) { return , $Data }
                if ($Data -is [System.IO.MemoryStream]) { return , $Data.ToArray() }
                return $null
            }
            $script:SkipReason = $null
            if (-not $script:NativeReady) { $script:SkipReason = $script:NativeProblem }
            elseif (-not $script:ClipboardAllowed) { $script:SkipReason = 'the test overwrites the clipboard; set SSH_PASTE_TEST_CLIPBOARD=1 to allow it (always on in CI)' }
            if ($null -eq $script:SkipReason) {
                # The core writes through PendingClipboard; the tests read back with WinForms.
                Add-Type -AssemblyName System.Windows.Forms
                $bitmap = New-Object System.Drawing.Bitmap -ArgumentList 24, 16
                try {
                    for ($x = 0; $x -lt 24; $x++) { $bitmap.SetPixel($x, $x % 16, [System.Drawing.Color]::FromArgb(200, $x * 10, 30)) }
                    $ms = New-Object System.IO.MemoryStream
                    $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                    $script:Png = $ms.ToArray()
                } finally { $bitmap.Dispose() }
                try {
                    Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/ssh-paste-probe.png' -Owner 4242
                    [void][System.Windows.Forms.Clipboard]::GetDataObject()
                } catch {
                    $script:SkipReason = 'the clipboard is not available here: ' + $_.Exception.Message
                }
            }
        }
        AfterAll {
            if ($script:NativeReady -and $script:ClipboardAllowed) { try { [System.Windows.Forms.Clipboard]::Clear() } catch { } }
        }

        It 'reads back the PNG bytes, the owner, the session token and the text that were written' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/ssh-paste-0123.png' -Owner 987654321 -Token 5550123456789
            $state = Read-ClipboardImage
            $state | Should -Not -BeNullOrEmpty
            ($state.Png -join ',') | Should -BeExactly ($script:Png -join ',')
            $state.Hash | Should -BeExactly (Get-ImageHash $script:Png)
            $state.HasText | Should -BeTrue
            $state.Owner | Should -Be 987654321
            $state.Token | Should -Be 5550123456789
            [System.Windows.Forms.Clipboard]::GetText() | Should -BeExactly '/tmp/ssh-paste-0123.png'
        }

        It 'writes a plain image with an owner of 0 when there is no text' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text $null -Owner 0 -Token 77
            $state = Read-ClipboardImage
            $state | Should -Not -BeNullOrEmpty
            $state.HasText | Should -BeFalse
            $state.Owner | Should -Be 0
            $state.Token | Should -Be 77
            [System.Windows.Forms.Clipboard]::ContainsText() | Should -BeFalse
            ($state.Png -join ',') | Should -BeExactly ($script:Png -join ',')
        }

        It 'refuses to write over a copy made after the clipboard was read, and the copy stays' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            $read = [long][SshPasteNative]::GetClipboardSequenceNumber()
            [System.Windows.Forms.Clipboard]::SetText('copied after the read')
            { Set-SshPasteClipboard -Basis $read -Png $script:Png -Text '/tmp/x.png' -Owner 1 -Token 2 } | Should -Throw '*changed since it was read*'
            [System.Windows.Forms.Clipboard]::GetText() | Should -BeExactly 'copied after the read'
        }

        It 'also offers the image as a bitmap for other apps' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/x.png' -Owner 1
            $image = [System.Windows.Forms.Clipboard]::GetImage()
            $image | Should -Not -BeNullOrEmpty
            try { $image.Width | Should -Be 24; $image.Height | Should -Be 16 } finally { $image.Dispose() }
        }

        It 'marks the rewrite so Windows keeps it out of clipboard history and cloud sync' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/x.png' -Owner 1
            $data = [System.Windows.Forms.Clipboard]::GetDataObject()
            $formats = @($data.GetFormats($false))
            foreach ($f in @('ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard', $script:MarkerFormat)) {
                $formats | Should -Contain $f
            }
            $expected = @{ ExcludeClipboardContentFromMonitorProcessing = 1; CanIncludeInClipboardHistory = 0; CanUploadToCloudClipboard = 0 }
            foreach ($k in $expected.Keys) {
                $raw = Get-DataBytes ($data.GetData($k))
                [BitConverter]::ToInt32($raw, 0) | Should -Be $expected[$k] -Because $k
            }
        }

        It 'writes a marker: the owner window, the session token, then the text in UTF-16' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/x.png' -Owner 111 -Token 222
            $raw = Get-DataBytes ([System.Windows.Forms.Clipboard]::GetDataObject().GetData($script:MarkerFormat))
            [BitConverter]::ToInt64($raw, 0) | Should -Be 111
            [BitConverter]::ToInt64($raw, 8) | Should -Be 222
            [System.Text.Encoding]::Unicode.GetString($raw, 16, $raw.Length - 16).Split([char]0)[0] | Should -BeExactly '/tmp/x.png'
        }

        Context 'a promised text (delayed rendering)' {
            BeforeAll {
                function Get-FrontWindow { return [SshPasteNative]::GetForegroundWindow().ToInt64() }
                function Start-TextReader {
                    # Reads CF_UNICODETEXT on another thread, the way a paste does, and
                    # reports how long the read waited.
                    $ps = [powershell]::Create()
                    [void]$ps.AddScript({
                            $watch = [System.Diagnostics.Stopwatch]::StartNew()
                            $bytes = ([SshPasteNative]::ReadFormats([uint32[]]@(13), 65536))[0]
                            $text = $null
                            if ($null -ne $bytes) { $text = [System.Text.Encoding]::Unicode.GetString($bytes).Split([char]0)[0] }
                            [pscustomobject]@{ Text = $text; Ms = $watch.ElapsedMilliseconds }
                        })
                    return @{ Shell = $ps; Handle = $ps.BeginInvoke() }
                }
                function Wait-TextReader {
                    param($Reader)
                    try { return @($Reader.Shell.EndInvoke($Reader.Handle))[0] } finally { $Reader.Shell.Dispose() }
                }
            }

            It 'makes a paste wait until the path is given, then pastes the path' {
                if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/ssh-paste-promised.png' -Owner (Get-FrontWindow) -Token 6 -Promise
                $reader = Start-TextReader
                Start-Sleep -Milliseconds 900
                $reader.Handle.IsCompleted | Should -BeFalse -Because 'the paste waits while the upload runs'
                Complete-ClipboardPromise '/tmp/ssh-paste-promised.png'
                $result = Wait-TextReader $reader
                $result.Text | Should -BeExactly '/tmp/ssh-paste-promised.png'
                $result.Ms | Should -BeGreaterOrEqual 800
            }

            It 'gives a waiting paste nothing when the upload fails' {
                if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/ssh-paste-failed.png' -Owner (Get-FrontWindow) -Token 6 -Promise
                $reader = Start-TextReader
                Start-Sleep -Milliseconds 500
                $reader.Handle.IsCompleted | Should -BeFalse -Because 'the paste waits until the upload ends, here in failure'
                Complete-ClipboardPromise $null
                (Wait-TextReader $reader).Text | Should -BeNullOrEmpty
            }

            It 'keeps the image and the marker readable at once while the text is promised' {
                if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/ssh-paste-open.png' -Owner (Get-FrontWindow) -Token 6 -Promise
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $state = Read-ClipboardImage
                $watch.ElapsedMilliseconds | Should -BeLessThan 2000 -Because 'reading our own entry never asks for the promised text'
                ($state.Png -join ',') | Should -BeExactly ($script:Png -join ',')
                $state.HasText | Should -BeTrue
                $state.Text | Should -BeExactly '/tmp/ssh-paste-open.png' -Because 'the text comes from the marker'
                Complete-ClipboardPromise $null
            }

            It 'gives a paste in another window nothing, at once' {
                if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/ssh-paste-elsewhere.png' -Owner ((Get-FrontWindow) + 4) -Token 6 -Promise
                $result = Wait-TextReader (Start-TextReader)
                $result.Text | Should -BeNullOrEmpty -Because 'the path is on this session''s server, not the server of the window that pastes'
                $result.Ms | Should -BeLessThan 5000 -Because 'it does not wait for the upload'
                Complete-ClipboardPromise $null
            }

            It 'answers whether a paste still gets the text: yes while promised or resolved, no once failed' {
                if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/a.png' -Owner (Get-FrontWindow) -Token 6 -Promise
                Test-ClipboardAnswers '/tmp/a.png' | Should -BeTrue -Because 'the upload still runs'
                Test-ClipboardAnswers '/tmp/b.png' | Should -BeFalse -Because 'the entry carries another text'
                Complete-ClipboardPromise '/tmp/a.png'
                Test-ClipboardAnswers '/tmp/a.png' | Should -BeTrue
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/a.png' -Owner (Get-FrontWindow) -Token 6 -Promise
                Complete-ClipboardPromise $null
                Test-ClipboardAnswers '/tmp/a.png' | Should -BeFalse -Because 'a paste of a failed promise gets nothing'
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/a.png' -Owner 1 -Token 6
                Test-ClipboardAnswers '/tmp/a.png' | Should -BeTrue -Because 'the text was written at once'
                [System.Windows.Forms.Clipboard]::SetText('copied by the user')
                Test-ClipboardAnswers '/tmp/a.png' | Should -BeFalse -Because 'the entry is no longer ours'
            }

            It 'keeps the image on the clipboard after the clipboard window closes' {
                if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
                Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/ssh-paste-closing.png' -Owner (Get-FrontWindow) -Token 6 -Promise
                Close-Clipboard
                try {
                    $state = Read-ClipboardImage
                    ($state.Png -join ',') | Should -BeExactly ($script:Png -join ',')
                } finally { Initialize-Native }
            }
        }

        It 'reads an image that only came as a bitmap (no PNG format, no marker)' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            $stream = New-Object System.IO.MemoryStream -ArgumentList (, $script:Png)
            $image = [System.Drawing.Image]::FromStream($stream)
            try { [System.Windows.Forms.Clipboard]::SetImage($image) } finally { $image.Dispose(); $stream.Dispose() }
            $state = Read-ClipboardImage
            $state | Should -Not -BeNullOrEmpty
            $state.Owner | Should -BeNullOrEmpty
            $state.HasText | Should -BeFalse
            (Get-TrimmedPng $state.Png).Length | Should -Be $state.Png.Length
            $check = New-Object System.IO.MemoryStream -ArgumentList (, $state.Png)
            $back = [System.Drawing.Image]::FromStream($check)
            try { $back.Width | Should -Be 24; $back.Height | Should -Be 16 } finally { $back.Dispose(); $check.Dispose() }
        }

        It 'does not read a format that is larger than the limit' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text $null -Owner 0
            $raw = [SshPasteNative]::ReadFormats([uint32[]]@($script:FormatPng, $script:FormatMarker, 0), 32)
            $raw[0] | Should -BeNullOrEmpty
            $raw[1] | Should -Not -BeNullOrEmpty
            $raw[2] | Should -BeNullOrEmpty
        }

        It 'Read-ClipboardImage still returns a state when the clipboard has no image: no Png, but the text flag and the sequence number' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            [System.Windows.Forms.Clipboard]::SetText('just text')
            $state = Read-ClipboardImage
            $state | Should -Not -BeNullOrEmpty
            $state.Png | Should -BeNullOrEmpty
            $state.Hash | Should -BeNullOrEmpty
            $state.Owner | Should -BeNullOrEmpty
            $state.HasText | Should -BeTrue
            $state.HasFiles | Should -BeFalse
            $state.Seq | Should -Be ([SshPasteNative]::GetClipboardSequenceNumber())
        }

        It 'Read-ClipboardImage reports the sequence number of what it read, and it moves when the clipboard changes' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text $null -Owner 0 -Token 5
            $first = Read-ClipboardImage
            $first.Seq | Should -Be ([SshPasteNative]::GetClipboardSequenceNumber())
            Set-SshPasteClipboard -Basis ([SshPasteNative]::GetClipboardSequenceNumber()) -Png $script:Png -Text '/tmp/x.png' -Owner 9 -Token 5
            $second = Read-ClipboardImage
            $second.Seq | Should -Not -Be $first.Seq
            $second.Text | Should -BeExactly '/tmp/x.png'
            $second.Owner | Should -Be 9
        }

        It 'Read-ClipboardImage does not return the text of an image that came from another program' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            $stream = New-Object System.IO.MemoryStream -ArgumentList (, $script:Png)
            $image = [System.Drawing.Image]::FromStream($stream)
            try {
                $data = New-Object System.Windows.Forms.DataObject
                $data.SetImage($image)
                $data.SetText('caption from an app')
                [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 50)
            } finally { $image.Dispose(); $stream.Dispose() }
            $state = Read-ClipboardImage
            $state.Png | Should -Not -BeNullOrEmpty
            $state.HasText | Should -BeTrue
            $state.Owner | Should -BeNullOrEmpty
            $state.Text | Should -BeNullOrEmpty
        }
    }

    Context 'command-line parsing agrees with the operating system' {
        BeforeAll {
            $csharp = @'
using System;
using System.Runtime.InteropServices;
public static class SshPasteTestArgv {
    [DllImport("shell32.dll", SetLastError = true)]
    static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string line, out int count);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr mem);
    public static string[] Split(string line) {
        int n;
        IntPtr p = CommandLineToArgvW(line, out n);
        if (p == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            string[] result = new string[n];
            for (int i = 0; i < n; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * IntPtr.Size));
            return result;
        } finally { LocalFree(p); }
    }
}
'@
            if (-not ('SshPasteTestArgv' -as [type])) { Add-Type -TypeDefinition $csharp }
        }

        It 'CommandLineToArgvW decodes what Join-NativeArguments encodes' {
            $rng = New-Object System.Random 99
            $alphabet = @('a', 'b', ' ', '"', '\', '\', "`t", '-')
            $bad = @()
            for ($n = 0; $n -lt 500; $n++) {
                $items = @()
                for ($k = 0; $k -lt $rng.Next(1, 5); $k++) {
                    $sb = New-Object System.Text.StringBuilder
                    for ($c = 0; $c -lt $rng.Next(0, 9); $c++) { [void]$sb.Append($alphabet[$rng.Next(0, $alphabet.Count)]) }
                    $items += $sb.ToString()
                }
                $line = 'prog.exe ' + (Join-NativeArguments $items)
                $os = @([SshPasteTestArgv]::Split($line) | Select-Object -Skip 1)
                if ((Format-ArgList $os) -cne (Format-ArgList $items)) { $bad += $line }
            }
            $bad.Count | Should -Be 0 -Because ('first mismatch: ' + ($bad | Select-Object -First 1))
        }

        It 'Split-CommandLine gives what CommandLineToArgvW gives: <Line>' -ForEach @(
            @{ Line = 'C:\Windows\System32\OpenSSH\ssh.exe -V' }
            @{ Line = '"C:\Program Files\OpenSSH\ssh.exe" -o "a b" host' }
            @{ Line = 'ssh.exe a\\b "c\\" d\"e f' }
            @{ Line = 'ssh.exe  -p   22' }
            @{ Line = 'ssh.exe "a b"c d' }
            @{ Line = 'ssh.exe -o ProxyCommand="powershell.exe -File \"C:\x y\a.ps1\" --proxy %h %p %n" host' }
        ) {
            Format-ArgList (Split-CommandLine $Line) | Should -BeExactly (Format-ArgList ([SshPasteTestArgv]::Split($Line)))
        }
    }
}

Describe 'end to end against a real ssh server' -Tag 'E2E' -Skip:(-not $e2eHost) {
    BeforeAll {
        $script:E2EHost = $env:SSH_PASTE_E2E_HOST
        $script:E2ESsh = $env:SSH_PASTE_SSH
        if (-not $script:E2ESsh) { $script:E2ESsh = (Get-Command ssh -CommandType Application | Select-Object -First 1).Source }
        # Options that every connection in these tests gets, in front of the host.
        $script:E2EVersion = Get-SshVersion $script:E2ESsh
        $script:E2EOptions = @()
        if ($env:SSH_PASTE_E2E_CONFIG) { $script:E2EOptions += @('-F', $env:SSH_PASTE_E2E_CONFIG) }
        if ($env:SSH_PASTE_E2E_KEY) { $script:E2EOptions += @('-i', $env:SSH_PASTE_E2E_KEY) }
        $script:E2ETemp = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-e2e-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:E2ETemp)
        $script:RemoteCleanup = New-Object System.Collections.ArrayList

        function Get-E2EParsed {
            param([string[]]$Extra = @())
            return (Split-SshArguments (@($script:E2EOptions) + @($Extra) + @($script:E2EHost)))
        }

        function New-E2EImage {
            $bytes = New-Object byte[] 20000
            (New-Object System.Random).NextBytes($bytes)
            return , $bytes
        }

        function Send-E2EImage {
            param([byte[]]$Png, $Parsed)
            $hash = Get-ImageHash $Png
            $null = $script:RemoteCleanup.Add('/tmp/ssh-paste-' + $hash + '.png')
            $argv = Get-UploadSshArguments -Parsed $Parsed -Hash $hash -Size $Png.Length -SshVersion $script:E2EVersion
            return (Send-Image -SshPath $script:E2ESsh -Arguments $argv -Png $Png -Hash $hash)
        }

        function Invoke-E2ERemote {
            # A plain, quiet command on the server through ssh.
            param([string]$Command, [string[]]$Extra = @())
            $argv = @('-T', '-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR') + @($script:E2EOptions) + @($Extra) + @('--', $script:E2EHost, $Command)
            return (Invoke-Process -FilePath $script:E2ESsh -Arguments $argv)
        }

        function Get-ProxyOption {
            # Windows: the very line --enable writes. Elsewhere (Linux CI): the same shape with this pwsh.
            if ($script:OnWindows) { return @('-o', ('ProxyCommand=' + (Get-ProxyCommandLine $script:CorePath)), '-o', 'ProxyUseFdpass=no') }
            $value = 'ProxyCommand="' + (Get-ThisPowerShell) + '" -NoLogo -NoProfile -File "' + $script:CorePath + '" --proxy %h %p %n'
            return @('-o', $value, '-o', 'ProxyUseFdpass=no')
        }

        function Invoke-E2EBytes {
            # Runs ssh with raw bytes on stdin and returns raw bytes from stdout. (Start-Process
            # -RedirectStandardInput feeds a file as text, which changes bytes that are not valid UTF-8.)
            param([string[]]$Argv, [byte[]]$InputBytes, [int]$TimeoutSeconds = 120)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:E2ESsh
            Set-ProcessArguments $psi $Argv
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            try {
                [void]$process.Start()
                $received = New-Object System.IO.MemoryStream
                $copy = $process.StandardOutput.BaseStream.CopyToAsync($received)
                $err = $process.StandardError.ReadToEndAsync()
                try {
                    if ($null -ne $InputBytes -and $InputBytes.Length -gt 0) { $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length); $process.StandardInput.BaseStream.Flush() }
                } catch { }
                try { $process.StandardInput.Close() } catch { }
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch { }; throw "ssh did not finish in $TimeoutSeconds seconds" }
                $process.WaitForExit()
                [void]$copy.Wait(10000)
                return [pscustomobject]@{ ExitCode = $process.ExitCode; Bytes = $received.ToArray(); Stderr = $err.Result }
            } finally { $process.Dispose() }
        }
    }

    AfterAll {
        if ($script:RemoteCleanup.Count -gt 0) {
            $list = ($script:RemoteCleanup | ForEach-Object { "'" + $_ + "'" }) -join ' '
            [void](Invoke-E2ERemote ('rm -f ' + $list))
        }
        Remove-Item -LiteralPath $script:E2ETemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'asks the server for its home folder for --dir ~/..., and uploads there (made mode 700) with --keep never' {
        $serverHome = (Invoke-E2ERemote 'echo $HOME').Stdout.Trim()
        $serverHome | Should -Match '^/'
        $name = 'ssh-paste-e2e-' + [guid]::NewGuid().ToString('N')
        try {
            $png = New-E2EImage
            $hash = Get-ImageHash $png
            $dir = ConvertTo-AbsoluteDirectory ('~/' + $name) (Get-ServerHome $script:E2ESsh (Get-E2EParsed) $script:E2EVersion)
            $dir | Should -BeExactly ($serverHome + '/' + $name)
            $argv = Get-UploadSshArguments -Parsed (Get-E2EParsed) -Hash $hash -Size $png.Length -SshVersion $script:E2EVersion -Keep 'never' -Dir $dir
            $path = Send-Image -SshPath $script:E2ESsh -Arguments $argv -Png $png -Hash $hash -Dir $dir -Class 'knever-'
            $path | Should -BeExactly ($serverHome + '/' + $name + '/ssh-paste-knever-' + $hash + '.png')
            (Invoke-E2ERemote ('stat -c %a ' + $serverHome + '/' + $name)).Stdout.Trim() | Should -BeExactly '700'
        } finally {
            [void](Invoke-E2ERemote ('rm -rf ' + $serverHome + '/' + $name))
        }
    }

    It 'checks the login as an upload would (Test-ServerLogin), and reads a refused one' {
        $ok = Test-ServerLogin $script:E2ESsh (Get-E2EParsed) $script:E2EVersion
        $ok.Error | Should -BeNullOrEmpty
        $ok.Home | Should -BeExactly ((Invoke-E2ERemote 'echo $HOME').Stdout.Trim())
        # A user the server has no key for (-l wins over User in the config): it refuses, as
        # for someone who never set a key up.
        $bad = Test-ServerLogin $script:E2ESsh (Get-E2EParsed @('-l', 'ssh-paste-no-such-user')) $script:E2EVersion
        $bad.Home | Should -BeNullOrEmpty
        $bad.Error | Should -Match 'Permission denied \('
        Get-LoginReport 'e2e' $bad.Error | Should -BeLike 'e2e did not accept a key for uploads*ssh-paste --doctor e2e shows how'
    }

    It 'the server accepts the key without a prompt' {
        $r = Invoke-E2ERemote 'echo ready'
        $r.ExitCode | Should -Be 0 -Because $r.Stderr
        $r.Stdout.Trim() | Should -BeExactly 'ready'
    }

    It 'knows the version of the ssh it tests with' {
        $script:E2EVersion | Should -BeOfType ([version])
    }

    It 'uploads a PNG (ArgumentList path)' {
        $png = New-E2EImage
        $path = Send-E2EImage $png (Get-E2EParsed)
        $path | Should -BeExactly ('/tmp/ssh-paste-' + (Get-ImageHash $png) + '.png')
        $sum = Invoke-E2ERemote ("sha256sum < '" + $path + "'")
        $sum.Stdout | Should -Match (Get-Sha256Hex $png)
    }

    It 'uploads a PNG (single Arguments string, the Windows PowerShell 5.1 path)' {
        Mock Set-ProcessArguments { param([System.Diagnostics.ProcessStartInfo]$StartInfo, [string[]]$Arguments) $StartInfo.Arguments = Join-NativeArguments $Arguments }
        $png = New-E2EImage
        $path = Send-E2EImage $png (Get-E2EParsed)
        $path | Should -BeExactly ('/tmp/ssh-paste-' + (Get-ImageHash $png) + '.png')
        Should -Invoke Set-ProcessArguments -Times 1 -Exactly
        $size = Invoke-E2ERemote ("wc -c < '" + $path + "'")
        [int]$size.Stdout.Trim() | Should -Be $png.Length
    }

    It 'creates the file with mode 600' {
        $png = New-E2EImage
        $path = Send-E2EImage $png (Get-E2EParsed)
        $mode = Invoke-E2ERemote ("stat -c %a '" + $path + "'")
        $mode.Stdout.Trim() | Should -BeExactly '600'
    }

    It 'reuses the file when the same image is uploaded again' {
        $png = New-E2EImage
        $first = Send-E2EImage $png (Get-E2EParsed)
        $inode1 = (Invoke-E2ERemote ("stat -c %i '" + $first + "'")).Stdout.Trim()
        $second = Send-E2EImage $png (Get-E2EParsed)
        $second | Should -BeExactly $first
        (Invoke-E2ERemote ("stat -c %i '" + $first + "'")).Stdout.Trim() | Should -BeExactly $inode1
    }

    It 'does not write through a symbolic link planted at the target' {
        $png = New-E2EImage
        $path = '/tmp/ssh-paste-' + (Get-ImageHash $png) + '.png'
        $null = $script:RemoteCleanup.Add($path)
        $victim = '/tmp/ssh-paste-e2e-victim-' + [guid]::NewGuid().ToString('N')
        $null = $script:RemoteCleanup.Add($victim)
        (Invoke-E2ERemote ("printf precious > '" + $victim + "'; ln -sf '" + $victim + "' '" + $path + "'")).ExitCode | Should -Be 0
        Send-E2EImage $png (Get-E2EParsed) | Should -BeExactly $path
        (Invoke-E2ERemote ("cat '" + $victim + "'")).Stdout | Should -BeExactly 'precious'
        (Invoke-E2ERemote ("test -h '" + $path + "'")).ExitCode | Should -Not -Be 0
    }

    It 'repairs a partial file left at the target by an earlier, interrupted upload' {
        $png = New-E2EImage
        $path = '/tmp/ssh-paste-' + (Get-ImageHash $png) + '.png'
        $null = $script:RemoteCleanup.Add($path)
        (Invoke-E2ERemote ("printf partial > '" + $path + "'")).ExitCode | Should -Be 0
        Send-E2EImage $png (Get-E2EParsed) | Should -BeExactly $path
        $size = Invoke-E2ERemote ("wc -c < '" + $path + "'")
        [int]$size.Stdout.Trim() | Should -Be $png.Length
    }

    It 'rejects an upload that is shorter than the size it announced, and says how much arrived' {
        $png = New-E2EImage
        $hash = Get-ImageHash $png
        $null = $script:RemoteCleanup.Add('/tmp/ssh-paste-' + $hash + '.png')
        $argv = Get-UploadSshArguments -Parsed (Get-E2EParsed) -Hash $hash -Size ($png.Length + 10) -SshVersion $script:E2EVersion
        # The server answers "short N" and exits 4, so ssh exits 4 as well.
        { Send-Image -SshPath $script:E2ESsh -Arguments $argv -Png $png -Hash $hash } | Should -Throw '*ssh exited with 4*'
        (Invoke-E2ERemote ("test -e '/tmp/ssh-paste-" + $hash + ".png'")).ExitCode | Should -Not -Be 0
    }

    It 'uploads when the user''s options come after the destination' {
        $png = New-E2EImage
        $parsed = Split-SshArguments (@($script:E2EOptions) + @($script:E2EHost, '-o', 'ServerAliveInterval=5', '-v', '-A'))
        @($parsed.Options | Where-Object { $_.After }).Count | Should -BeGreaterThan 0
        Send-E2EImage $png $parsed | Should -Be ('/tmp/ssh-paste-' + (Get-ImageHash $png) + '.png')
    }

    It 'keeps working with the options of a real session (-i, -p, -o) and ignores forwarding and tty options' {
        $png = New-E2EImage
        $parsed = Get-E2EParsed -Extra @('-v', '-A', '-t', '-L', '59999:127.0.0.1:1', '-o', 'ServerAliveInterval=5')
        Send-E2EImage $png $parsed | Should -Be ('/tmp/ssh-paste-' + (Get-ImageHash $png) + '.png')
    }

    It 'fails with a clear error when authentication fails' {
        $png = New-E2EImage
        $parsed = Get-E2EParsed -Extra @('-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=publickey', '-o', 'IdentityAgent=none')
        $message = $null
        try { [void](Send-E2EImage $png $parsed) } catch { $message = $_.Exception.Message }
        $message | Should -Match 'ssh exited with 255'
        $message | Should -Match '(?i)permission denied|no more authentication methods|publickey'
    }

    It 'fails with a clear error when the server cannot be reached' {
        $png = New-E2EImage
        $parsed = Split-SshArguments @('-p', '1', '-o', 'ConnectTimeout=3', '127.0.0.1')
        { Send-E2EImage $png $parsed } | Should -Throw '*ssh exited with 255*'
    }

    It 'a bad reply from the server is an error, not a success' {
        $png = New-E2EImage
        $hash = Get-ImageHash $png
        $argv = Get-UploadSshArguments -Parsed (Get-E2EParsed) -Hash $hash -Size $png.Length -SshVersion $script:E2EVersion
        # The server publishes the right name; Send-Image is told to expect another image's name.
        { Send-Image -SshPath $script:E2ESsh -Arguments $argv -Png $png -Hash ('f' * 32) } | Should -Throw '*unexpected path*'
        $null = $script:RemoteCleanup.Add('/tmp/ssh-paste-' + $hash + '.png')
    }

    Context '--proxy mode relays a full ssh session' {
        It 'runs a command through ssh-paste and gets its output' {
            $r = Invoke-E2ERemote 'echo through-the-proxy' -Extra (Get-ProxyOption)
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $r.Stdout.Trim() | Should -BeExactly 'through-the-proxy'
        }

        It 'really goes through ssh-paste (ssh -v shows the proxy command)' {
            $argv = @('-T', '-v', '-o', 'BatchMode=yes') + @($script:E2EOptions) + (Get-ProxyOption) + @('--', $script:E2EHost, 'true')
            $r = Invoke-Process -FilePath $script:E2ESsh -Arguments $argv
            $r.ExitCode | Should -Be 0 -Because $r.Stderr
            $r.Stderr | Should -Match 'Executing proxy command'
            $r.Stderr | Should -Match '--proxy'
        }

        It 'returns the exit code of the remote command' {
            (Invoke-E2ERemote 'exit 7' -Extra (Get-ProxyOption)).ExitCode | Should -Be 7
        }

        It 'carries a multi-megabyte binary file both ways with identical SHA-256' {
            $size = 12MB
            $bytes = New-Object byte[] $size
            (New-Object System.Random 1234).NextBytes($bytes)
            $expected = Get-Sha256Hex $bytes
            $remote = '/tmp/ssh-paste-e2e-bin-' + [guid]::NewGuid().ToString('N')
            $null = $script:RemoteCleanup.Add($remote)
            $base = @('-T', '-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR') + @($script:E2EOptions) + (Get-ProxyOption) + @('--', $script:E2EHost)

            $up = Invoke-E2EBytes -Argv ($base + @("cat > '" + $remote + "'")) -InputBytes $bytes
            $up.ExitCode | Should -Be 0 -Because $up.Stderr

            $sum = Invoke-E2ERemote ("sha256sum < '" + $remote + "'")
            $sum.Stdout | Should -Match $expected

            $down = Invoke-E2EBytes -Argv ($base + @("cat '" + $remote + "'"))
            $down.ExitCode | Should -Be 0 -Because $down.Stderr
            $down.Bytes.Length | Should -Be $size
            Get-Sha256Hex $down.Bytes | Should -BeExactly $expected
        }

        It 'stays usable for scp-style non-interactive use (no tty, no watcher)' {
            $r = Invoke-E2ERemote 'printf "a\nb\n" | wc -l' -Extra (Get-ProxyOption)
            $r.ExitCode | Should -Be 0
            $r.Stdout.Trim() | Should -BeExactly '2'
        }

        It 'reports a closed port through ssh as a failed connection, not a hang' {
            $argv = @('-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=no', '-o', ('UserKnownHostsFile=' + (Join-Path $script:E2ETemp 'kh')), '-p', '1') + (Get-ProxyOption) + @('--', '127.0.0.1', 'true')
            $r = Invoke-Process -FilePath $script:E2ESsh -Arguments $argv -TimeoutSeconds 30
            $r.ExitCode | Should -Not -Be 0
            $r.Stderr | Should -Match 'cannot connect|Connection'
        }
    }
}

# Guards that read the repository itself, so a rule is checked where the tests already run.
Describe 'repository guards' {
    BeforeAll {
        function Get-RepoFiles {
            param([string]$Filter)
            return @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Filter $Filter |
                    Where-Object { $_.FullName -notmatch '[\\/](\.git|TestResults)[\\/]' })
        }
    }

    It 'keeps the version in the repository at 0.0.0-dev; a release stamps its own' {
        # The release copy of the script gets the real version from .github/scripts/stamp-version.sh.
        $script:Version | Should -BeExactly '0.0.0-dev'
        $lines = @(([System.IO.File]::ReadAllText($script:CorePath) -split "`r?`n") | Where-Object { $_ -cmatch '^\$script:Version\b' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly '$script:Version = ''0.0.0-dev'''
    }

    It 'stamps the version line of the script exactly as it is written there' {
        $stamp = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github/scripts/stamp-version.sh'))
        # from="\$script:Version = '0.0.0-dev'" in bash is the line $script:Version = '0.0.0-dev'.
        $stamp | Should -Match ([regex]::Escape('from="\$script:Version = ''0.0.0-dev''"')) -Because 'stamp-version.sh must look for the line that is in src/ssh-paste.ps1'
        $stamp | Should -Match ([regex]::Escape('to="\$script:Version = ''$version''"'))
        $publish = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github/workflows/publish.yml'))
        $publish | Should -Match ([regex]::Escape('stamp-version.sh src/ssh-paste.ps1 out/dist/ssh-paste.ps1 "${TAG#v}"')) -Because 'publish.yml must stamp the script it attaches to the release'
        $publish | Should -Match ([regex]::Escape('cp src/ssh-paste.cmd install.ps1 out/dist/')) -Because 'the script itself is not copied unstamped'
    }

    It 'has one default ref line in install.ps1 that the release bakes the tag into' {
        $installer = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'install.ps1'))
        @([regex]::Matches($installer, '(?m)^ *\$DefaultRef = ''main''\r?$')).Count | Should -Be 1
        $publish = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github/workflows/publish.yml'))
        $publish | Should -Match ([regex]::Escape('s/^\( *[$]DefaultRef = \)''main''/\1''$TAG''/'))
    }

    It 'releases in one lock: publish.yml has the group release, bash for every step, and is called after CI ok' {
        $publish = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github/workflows/publish.yml'))
        $publish | Should -Match '(?m)^concurrency:\r?\n  group: release\r?\n  cancel-in-progress: false'
        $publish | Should -Match '(?m)^defaults:\r?\n  run:\r?\n    shell: bash'
        $publish | Should -Not -Match '(?m)^\s+shell: (?!bash)'
        $ci = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github/workflows/ci.yml'))
        $ci | Should -Match '(?m)^  release:\r?\n(.*\r?\n)*?    needs: ci-ok\r?\n    if: github\.ref == ''refs/heads/main'' && \(github\.event_name == ''push'' \|\| github\.event_name == ''workflow_dispatch''\)\r?\n    uses: \./\.github/workflows/publish\.yml'
        # A scheduled or manual run must not replace a pending push run (it may be the one that releases).
        $ci | Should -Match 'group: ci-\$\{\{ github\.event_name \}\}-\$\{\{ github\.ref \}\}'
    }

    It 'has one release series and no way to release by a hand-pushed tag' {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot '.github/workflows') -File)) {
            [System.IO.File]::ReadAllText($f.FullName) | Should -Not -Match '(?m)^\s+tags:' -Because ($f.Name + ' must not start on a pushed tag')
        }
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot '.github/scripts') -File -Filter '*.sh')) {
            [System.IO.File]::ReadAllText($f.FullName) | Should -Not -Match 'run_number|--prerelease|-rc' -Because $f.Name
        }
    }

    It 'has no CHANGELOG.md: a commit subject is the release note' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'CHANGELOG.md') | Should -BeFalse
        $mentions = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File |
                Where-Object { $_.FullName -notmatch '[\\/](\.git|TestResults)[\\/]' -and $_.Name -ne 'ssh-paste.Tests.ps1' } |
                Where-Object { [System.IO.File]::ReadAllText($_.FullName) -cmatch 'CHANGELOG' } | ForEach-Object { $_.Name })
        $mentions | Should -BeNullOrEmpty -Because 'nothing may point at a file that does not exist'
    }

    It 'parses every PowerShell file' {
        $problems = @()
        foreach ($file in @(Get-RepoFiles '*.ps1') + @(Get-RepoFiles '*.psd1')) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            foreach ($e in $errors) { $problems += ('{0}:{1}: {2}' -f $file.Name, $e.Extent.StartLineNumber, $e.Message) }
        }
        $problems | Should -BeNullOrEmpty
    }

    It 'keeps shell scripts free of carriage returns' {
        $files = @(Get-RepoFiles '*.sh')
        $files.Count | Should -BeGreaterThan 0
        $crlf = @($files | Where-Object { [System.IO.File]::ReadAllBytes($_.FullName) -contains 13 } | ForEach-Object { $_.Name })
        $crlf | Should -BeNullOrEmpty -Because 'sh fails on CRLF line endings'
    }

    It 'lists every command of the help text in both READMEs' {
        $commands = @([regex]::Matches((Get-Usage), '(?<![\w-])--[a-z][a-z-]*') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $commands.Count | Should -BeGreaterThan 3
        foreach ($readme in @('README.md', 'README.zh-CN.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $readme))
            $missing = @($commands | Where-Object { -not $text.Contains($_) })
            $missing | Should -BeNullOrEmpty -Because "$readme must mention every command that --help shows"
        }
    }
}
