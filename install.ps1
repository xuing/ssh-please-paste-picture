<#
ssh-paste installer - https://github.com/xuing/ssh-please-paste-picture

Install or upgrade (no administrator rights needed):

    irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex

From a clone or a downloaded copy of the repository (installs those files):

    powershell -ExecutionPolicy Bypass -File install.ps1

Remove ssh-paste and everything it changed, even when the installed copy is broken:

    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
    & ([scriptblock]::Create((irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1))) -Uninstall

Options
    -Ref <tag|branch|commit>   download src/ of that version instead of the default (env: SSH_PASTE_REF)
                               The default is the release this file was attached to, or main
                               for a copy taken from the repository. A release installs the
                               files attached to it, checked against its SHA256SUMS.
    -Uninstall                 remove instead of install (env: SSH_PASTE_UNINSTALL=1)
    -Help                      show this text
The environment variables are for `irm ... | iex`, which cannot pass parameters.
Without -Ref, a copy of the repository installs its own src folder.

What the install changes (ssh-paste --uninstall reverts exactly this):
    %LOCALAPPDATA%\Programs\ssh-paste\ssh-paste.ps1   the program
    %LOCALAPPDATA%\Programs\ssh-paste\ssh-paste.cmd   the `ssh-paste` command
    one entry in your user PATH (HKCU\Environment\Path)
Nothing else: no admin rights, services, scheduled tasks or profile edits.
Later, `ssh-paste --enable HOST` adds a marked block to %USERPROFILE%\.ssh\config.

Running as administrator works, with a warning: ssh-paste is installed for the
account the elevated window runs as, which may not be the one you use daily.

Everything runs inside the script block below, so `irm | iex` leaves no
functions, variables or preferences behind in your PowerShell session. The
only session change is that $env:Path gains the install folder.
Keep this file ASCII and valid for Windows PowerShell 5.1.
#>

& {
    $ErrorActionPreference = 'Stop'
    $mainArgs = @($args)

    # Must match src/ssh-paste.ps1 ($script:BlockBegin / $script:BlockEnd /
    # $script:BlockCreatedFile); a Pester test compares them. The uninstaller
    # carries its own copy so it works when the installed one is broken.
    $BlockBegin = '# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>'
    $BlockEnd = '# <<< ssh-paste <<<'
    $BlockCreatedFile = '# ssh-paste created this file; it is deleted when the last host is disabled.'
    $DownloadBase = 'https://raw.githubusercontent.com/xuing/ssh-please-paste-picture'
    $ReleaseBase = 'https://github.com/xuing/ssh-please-paste-picture/releases/download'
    $ReleaseTag = '^v0\.1\.(0|[1-9][0-9]*)$'
    # The ref that is installed. .github/workflows/publish.yml replaces main with the
    # release tag in the copy it attaches to a release. When it is a release tag, the
    # files come from that release (version stamped, attested), checked against its
    # SHA256SUMS; otherwise they come from src/ at that ref. Keep the next line as it is.
    $DefaultRef = 'main'
    $ScriptDir = $PSScriptRoot   # empty under iex

    function Write-Line {
        param([string]$Message = '', [string]$Color = 'Gray')
        Write-Host $Message -ForegroundColor $Color
    }

    function Get-Usage {
        return @'
ssh-paste installer

  install.ps1 [-Ref <tag|branch|commit>]   install or upgrade ssh-paste for this user
  install.ps1 -Uninstall                   remove ssh-paste and everything it changed

Under `irm ... | iex` use SSH_PASTE_REF / SSH_PASTE_UNINSTALL=1 instead.
https://github.com/xuing/ssh-please-paste-picture
'@
    }

    function Read-Options {
        param([object[]]$Arguments)
        $options = @{ Uninstall = $false; UninstallFromEnv = $false; Ref = $null; Help = $false }
        if ($env:SSH_PASTE_UNINSTALL -eq '1') { $options.Uninstall = $true; $options.UninstallFromEnv = $true }
        if ($env:SSH_PASTE_REF) { $options.Ref = [string]$env:SSH_PASTE_REF }
        $i = 0
        while ($i -lt $Arguments.Count) {
            $a = [string]$Arguments[$i]
            if ($a -match '^-(Uninstall)$') {
                $options.Uninstall = $true
            } elseif ($a -match '^-(Help|h|\?)$' -or $a -eq '/?') {
                $options.Help = $true
            } elseif ($a -match '^-Ref:(.+)$') {
                $options.Ref = $Matches[1]
            } elseif ($a -match '^-Ref$') {
                $i++
                if ($i -ge $Arguments.Count) { throw '-Ref needs a value: a tag, branch or commit' }
                $options.Ref = [string]$Arguments[$i]
            } else {
                throw ("unknown option: {0}`n{1}" -f $a, (Get-Usage))
            }
            $i++
        }
        if ($null -ne $options.Ref -and ($options.Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -or $options.Ref.Contains('..'))) {
            throw "not a valid tag, branch or commit name: $($options.Ref)"
        }
        return $options
    }

    function Assert-Windows {
        if ($env:OS -ne 'Windows_NT') { throw 'ssh-paste runs on Windows only.' }
        if ($PSVersionTable.PSVersion.Major -lt 5) {
            throw ('Windows PowerShell 5.1 or newer is required; this is {0}.' -f $PSVersionTable.PSVersion)
        }
    }

    function Assert-ScriptsCanRun {
        # -ExecutionPolicy Bypass in ssh-paste.cmd cannot override a Group Policy.
        foreach ($entry in @(Get-ExecutionPolicy -List)) {
            $scope = [string]$entry.Scope
            $policy = [string]$entry.ExecutionPolicy
            if (($scope -eq 'MachinePolicy' -or $scope -eq 'UserPolicy') -and ($policy -eq 'AllSigned' -or $policy -eq 'Restricted')) {
                throw ("A Group Policy ({0}) sets the PowerShell execution policy to {1}, which blocks unsigned scripts such as ssh-paste. Ask your IT department to allow it." -f $scope, $policy)
            }
        }
    }

    function Find-Ssh {
        if ($env:SSH_PASTE_SSH -and (Test-Path -LiteralPath $env:SSH_PASTE_SSH)) { return $env:SSH_PASTE_SSH }
        $cmd = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { return $cmd.Source }
        $inbox = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
        if (Test-Path -LiteralPath $inbox) { return $inbox }
        throw ("ssh.exe was not found. Add the OpenSSH Client, then run this installer again:`n" +
            "  Settings > System > Optional features > View features > OpenSSH Client`n" +
            "  or, in PowerShell as administrator: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0")
    }

    function Test-Elevated {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Get-InstallDirectory {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot find the per-user Programs folder.' }
        return (Join-Path $env:LOCALAPPDATA 'Programs\ssh-paste')
    }

    function Get-ScriptVersion {
        param([string]$Text)
        if ($null -ne $Text -and $Text -match "(?m)^\`$script:Version\s*=\s*'([^']+)'") { return $Matches[1] }
        return $null
    }

    # --- getting and checking the files --------------------------------------

    function Get-WebBytes {
        param([string]$Url)
        $client = New-Object System.Net.WebClient
        try {
            if ($null -ne $client.Proxy) { $client.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
            return , $client.DownloadData($Url)
        } catch {
            throw ('could not download {0}: {1}' -f $Url, $_.Exception.GetBaseException().Message)
        } finally {
            $client.Dispose()
        }
    }

    function Get-Sha256Hex {
        param([byte[]]$Bytes)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    }

    function Assert-ListedSha256 {
        # SHA256SUMS ($Sums, text) must list $Name with the SHA-256 of $Bytes.
        param([string]$Sums, [string]$Name, [byte[]]$Bytes)
        $want = $null
        foreach ($line in ($Sums -split "`r?`n")) {
            if ($line -match '^([0-9a-fA-F]{64}) [ *](\S+)\s*$' -and $Matches[2] -ceq $Name) { $want = $Matches[1].ToLowerInvariant() }
        }
        if ($null -eq $want) { throw "SHA256SUMS does not list $Name" }
        $got = Get-Sha256Hex $Bytes
        if ($got -ne $want) { throw ('{0} does not match SHA256SUMS (expected {1}, got {2}); refusing to install it' -f $Name, $want, $got) }
    }

    function Get-SourceFiles {
        # Returns @{ Ps1 = [byte[]]; Cmd = [byte[]]; From = 'description'; Tag = release tag or $null }.
        param([string]$Ref)
        $local = $null
        if ($ScriptDir) { $local = Join-Path $ScriptDir 'src' }
        # A [string] parameter turns $null into '', so test for empty, not for $null.
        if ([string]::IsNullOrEmpty($Ref) -and $null -ne $local -and (Test-Path -LiteralPath (Join-Path $local 'ssh-paste.ps1'))) {
            # Read the bytes rather than copying, so no Zone.Identifier (Mark of the
            # Web) from a browser download is carried into the install folder.
            return @{
                Ps1 = [System.IO.File]::ReadAllBytes((Join-Path $local 'ssh-paste.ps1'))
                Cmd = [System.IO.File]::ReadAllBytes((Join-Path $local 'ssh-paste.cmd'))
                From = $local
                Tag = $null
            }
        }
        if ([string]::IsNullOrEmpty($Ref)) { $Ref = $DefaultRef }
        $fromRelease = ($Ref -ceq $DefaultRef) -and ($DefaultRef -cmatch $ReleaseTag)
        if ($fromRelease) { $base = '{0}/{1}/' -f $ReleaseBase, $Ref } else { $base = '{0}/{1}/src/' -f $DownloadBase, $Ref }
        $oldProtocol = [System.Net.ServicePointManager]::SecurityProtocol
        try {
            # Windows PowerShell 5.1 may not offer TLS 1.2 by default; add it unless
            # the OS default (SystemDefault, 0) is already in use. Restored below.
            if ([int]$oldProtocol -ne 0 -and ([int]$oldProtocol -band 3072) -eq 0) {
                [System.Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [System.Net.SecurityProtocolType]::Tls12
            }
            $files = @{
                Ps1 = Get-WebBytes ($base + 'ssh-paste.ps1')
                Cmd = Get-WebBytes ($base + 'ssh-paste.cmd')
                From = $base
                Tag = $null
            }
            if ($fromRelease) {
                $sums = [System.Text.Encoding]::UTF8.GetString((Get-WebBytes ($base + 'SHA256SUMS')))
                Assert-ListedSha256 $sums 'ssh-paste.ps1' $files.Ps1
                Assert-ListedSha256 $sums 'ssh-paste.cmd' $files.Cmd
                $files.Tag = $Ref
            }
            return $files
        } finally {
            [System.Net.ServicePointManager]::SecurityProtocol = $oldProtocol
        }
    }

    function Get-CheckedText {
        # The files must be ASCII; .ps1 must parse and look like ssh-paste.
        param([byte[]]$Bytes, [string]$Name)
        if ($null -eq $Bytes -or $Bytes.Length -eq 0) { throw "$Name is empty" }
        $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
        if ($text -match '[^\x00-\x7F]') { throw "$Name is not plain ASCII; refusing to install it" }
        if ($Name -like '*.ps1') {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw ('{0} does not parse: {1}' -f $Name, $errors[0].Message) }
            if ($null -eq (Get-ScriptVersion $text) -or -not $text.Contains($BlockBegin)) { throw "$Name does not look like ssh-paste" }
        } elseif (-not $text.Contains('ssh-paste.ps1')) {
            throw "$Name does not look like the ssh-paste launcher"
        }
        return $text
    }

    function Write-FileAtomic {
        # Write next to the target, then swap it in, so a failure never leaves a
        # half-written program behind.
        param([string]$Path, [byte[]]$Bytes)
        $temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
        try {
            [System.IO.File]::WriteAllBytes($temp, $Bytes)
            if ([System.IO.File]::Exists($Path)) {
                # [NullString]: a plain $null would arrive as "" and Replace would throw.
                [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
            } else {
                [System.IO.File]::Move($temp, $Path)
            }
        } finally {
            if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
        }
    }

    # --- user PATH (registry, never [Environment]::SetEnvironmentVariable) ---

    function Test-PathListHas {
        param([string]$List, [string]$Entry)
        foreach ($p in ($List -split ';')) {
            if ($p.TrimEnd('\') -ieq $Entry.TrimEnd('\')) { return $true }
        }
        return $false
    }

    function Get-PathWithEntry {
        # Exact inverse of Remove-UserPathEntry in ssh-paste.ps1: removing $Entry
        # from the result gives $Raw back, including a trailing ';'.
        param([string]$Raw, [string]$Entry)
        if ([string]::IsNullOrEmpty($Raw)) { return $Entry }
        if ($Raw.EndsWith(';')) { return $Raw + $Entry + ';' }
        return $Raw + ';' + $Entry
    }

    function Get-PathWithoutEntry {
        # The same edit as Remove-UserPathEntry in ssh-paste.ps1.
        param([string]$Raw, [string]$Entry)
        $kept = @($Raw -split ';' | Where-Object { $_.TrimEnd('\') -ine $Entry.TrimEnd('\') })
        return ($kept -join ';')
    }

    function Open-EnvironmentKey {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if ($null -eq $key) { throw 'cannot open HKCU\Environment' }
        return $key
    }

    function Read-UserPath {
        # @{ Exists; Kind; Raw } with %VARIABLES% left unexpanded.
        $key = Open-EnvironmentKey
        try {
            if ($key.GetValueNames() -notcontains 'Path') {
                return @{ Exists = $false; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString; Raw = '' }
            }
            $kind = $key.GetValueKind('Path')
            if ($kind -ne [Microsoft.Win32.RegistryValueKind]::String -and $kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) {
                throw "HKCU\Environment\Path has type $kind, not a string; ssh-paste will not touch it."
            }
            $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return @{ Exists = $true; Kind = $kind; Raw = $raw }
        } finally { $key.Close() }
    }

    function Add-UserPathEntry {
        # Appends $Entry, keeping the value's kind (REG_EXPAND_SZ / REG_SZ) and every
        # other entry byte for byte. A new value is REG_EXPAND_SZ, like Windows' own.
        param([string]$Entry)
        $state = Read-UserPath
        if ($state.Exists -and (Test-PathListHas $state.Raw $Entry)) { return $false }
        $new = Get-PathWithEntry $state.Raw $Entry
        if ($new.Length -ge 32767) { throw 'your user PATH would be longer than Windows allows (32767 characters)' }
        $key = Open-EnvironmentKey
        try { $key.SetValue('Path', $new, $state.Kind) } finally { $key.Close() }
        return $true
    }

    function Remove-UserPathEntry {
        # Same behavior as Remove-UserPathEntry in ssh-paste.ps1, including
        # deleting the value when nothing is left in it.
        param([string]$Entry)
        $key = Open-EnvironmentKey
        try {
            if ($key.GetValueNames() -notcontains 'Path') { return $false }
            $kind = $key.GetValueKind('Path')
            $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $new = Get-PathWithoutEntry $raw $Entry
            if ($new -ceq $raw) { return $false }
            if ($new.Trim(';').Length -eq 0) { $key.DeleteValue('Path') } else { $key.SetValue('Path', $new, $kind) }
            return $true
        } finally { $key.Close() }
    }

    function Send-EnvironmentChange {
        # Setting a variable through .NET broadcasts WM_SETTINGCHANGE, so new Explorer
        # and Windows Terminal windows see the new PATH. The variable is then deleted
        # in the registry: PowerShell 7 passes $null to .NET as an empty string, which
        # .NET keeps instead of deleting. Leftovers from earlier runs are removed too.
        $name = 'ssh_paste_' + [guid]::NewGuid().ToString('N')
        [Environment]::SetEnvironmentVariable($name, '1', 'User')
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if ($null -eq $key) { return }
        try {
            foreach ($value in $key.GetValueNames()) {
                if ($value -cmatch '^ssh_paste_[0-9a-f]{32}\z') { $key.DeleteValue($value, $false) }
            }
        } finally { $key.Close() }
    }

    # --- ssh config -----------------------------------------------------------

    function Remove-ManagedBlockText {
        # Drops every line from $BlockBegin through $BlockEnd (as ssh-paste
        # --disable does) and keeps all other text, line endings included.
        # CreatedFile tells whether the block says ssh-paste made the file.
        param([string]$Text)
        $out = New-Object System.Text.StringBuilder
        $inBlock = $false
        $removed = $false
        $createdFile = $false
        foreach ($piece in [regex]::Split($Text, '(?<=\n)')) {
            if ($piece.Length -eq 0) { continue }
            $line = $piece
            if ($line.EndsWith("`n")) { $line = $line.Substring(0, $line.Length - 1) }
            if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
            if (-not $inBlock -and $line -ceq $BlockBegin) { $inBlock = $true; $removed = $true; continue }
            if ($inBlock) {
                if ($line -ceq $BlockEnd) { $inBlock = $false }
                if ($line -ceq $BlockCreatedFile) { $createdFile = $true }
                continue
            }
            [void]$out.Append($piece)
        }
        if ($inBlock) { throw 'the ssh-paste block in the ssh config has no end marker; remove it by hand' }
        return @{ Text = $out.ToString(); Removed = $removed; CreatedFile = $createdFile }
    }

    function Remove-EmptyDirectory {
        param([string]$Path)
        if ((Test-Path -LiteralPath $Path -PathType Container) -and @(Get-ChildItem -LiteralPath $Path -Force).Count -eq 0) {
            Remove-Item -LiteralPath $Path -Force
            return $true
        }
        return $false
    }

    function Remove-ConfigBlock {
        # Takes our block out of the ssh config, as `ssh-paste --disable` does. The
        # file is deleted (and an empty .ssh folder with it) only when the block
        # says ssh-paste created it and nothing else is left. Returns $true if
        # anything changed. The text is handled as ISO-8859-1 so that every other
        # byte, even in a legacy code page, is written back unchanged.
        param([string]$ConfigPath)
        if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
        $latin1 = [System.Text.Encoding]::GetEncoding('iso-8859-1')
        $bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
        $skip = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $skip = 3 }
        $result = Remove-ManagedBlockText ($latin1.GetString($bytes, $skip, $bytes.Length - $skip))
        if (-not $result.Removed) { return $false }
        if ($result.CreatedFile -and $result.Text.Trim().Length -eq 0) {
            Remove-Item -LiteralPath $ConfigPath -Force
            Write-Line ('Deleted {0} (ssh-paste created it and it held only the ssh-paste block)' -f $ConfigPath) 'Green'
            $folder = Split-Path -Parent $ConfigPath
            if (Remove-EmptyDirectory $folder) { Write-Line ('Deleted the empty folder {0}' -f $folder) 'Green' }
        } else {
            $newBytes = $latin1.GetBytes($result.Text)
            if ($skip -gt 0) { $newBytes = [byte[]](@($bytes[0..($skip - 1)]) + @($newBytes)) }
            Write-FileAtomic $ConfigPath $newBytes
            Write-Line ('Removed the ssh-paste block from {0}' -f $ConfigPath) 'Green'
        }
        return $true
    }

    # --- commands -------------------------------------------------------------

    function Invoke-Install {
        param($Options)
        Assert-ScriptsCanRun
        $ssh = Find-Ssh
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powershell)) { throw "Windows PowerShell was not found at $powershell" }
        if (Test-Elevated) {
            Write-Line ('Note: this window runs as administrator. ssh-paste is installed for {0} only;' -f [Environment]::UserName) 'Yellow'
            Write-Line '      if you work under another account, run the installer from a normal window there.' 'Yellow'
        }
        $dir = Get-InstallDirectory
        [void](Read-UserPath)   # fail on an unusable PATH value before changing anything

        $source = Get-SourceFiles $Options.Ref
        $ps1Text = Get-CheckedText $source.Ps1 'ssh-paste.ps1'
        $cmdText = Get-CheckedText $source.Cmd 'ssh-paste.cmd'
        # cmd.exe needs CRLF; a checkout or raw download may carry LF only.
        $cmdBytes = [System.Text.Encoding]::ASCII.GetBytes(($cmdText -replace "`r?`n", "`r`n"))
        $version = Get-ScriptVersion $ps1Text
        if ($null -ne $source.Tag -and $version -ne $source.Tag.Substring(1)) {
            throw ('release {0} ships ssh-paste.ps1 {1}, not {2}; refusing to install it' -f $source.Tag, $version, $source.Tag.Substring(1))
        }

        $installed = Join-Path $dir 'ssh-paste.ps1'
        $oldVersion = $null
        if (Test-Path -LiteralPath $installed) { $oldVersion = Get-ScriptVersion ([System.IO.File]::ReadAllText($installed)) }

        [void][System.IO.Directory]::CreateDirectory($dir)
        Get-ChildItem -LiteralPath $dir -Filter 'ssh-paste.*.tmp' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-FileAtomic $installed $source.Ps1
        Write-FileAtomic (Join-Path $dir 'ssh-paste.cmd') $cmdBytes

        if ($null -eq $oldVersion) {
            Write-Line ('Installed ssh-paste {0} in {1}' -f $version, $dir) 'Green'
        } elseif ($oldVersion -eq $version) {
            Write-Line ('Reinstalled ssh-paste {0} in {1}' -f $version, $dir) 'Green'
        } else {
            Write-Line ('Upgraded ssh-paste {0} -> {1} in {2}' -f $oldVersion, $version, $dir) 'Green'
        }
        Write-Line ('  from {0}' -f $source.From)
        if ($null -ne $source.Tag) { Write-Line '  checked against the SHA256SUMS of the release' }
        Write-Line '  files: ssh-paste.ps1, ssh-paste.cmd'

        $pathAdded = Add-UserPathEntry $dir
        Send-EnvironmentChange   # also removes values that older versions left behind
        if ($pathAdded) {
            Write-Line '  added the folder to your user PATH (HKCU\Environment\Path)'
        } else {
            Write-Line '  the folder is already on your user PATH'
        }
        if (-not (Test-PathListHas $env:Path $dir)) {
            if ($env:Path) { $env:Path = $env:Path.TrimEnd(';') + ';' + $dir } else { $env:Path = $dir }
        }

        # Run the installed command once, the way users will.
        $cmdPath = Join-Path $dir 'ssh-paste.cmd'
        $output = & {
            $ErrorActionPreference = 'Continue'
            & $cmdPath --version 2>&1 | ForEach-Object { [string]$_ }
        }
        $exit = $LASTEXITCODE
        $reported = (@($output) -join ' ').Trim()
        if ($exit -ne 0 -or $reported -ne $version) {
            Write-Line ''
            Write-Line ('The files are installed, but `ssh-paste --version` failed (exit code {0}):' -f $exit) 'Red'
            Write-Line ('  ' + $reported) 'Red'
            Write-Line 'Security software or a policy may be blocking it. Remove it with: install.ps1 -Uninstall' 'Red'
            return 1
        }
        Write-Line ('  checked: ssh-paste --version prints {0}; ssh is {1}' -f $reported, $ssh)

        Write-Line ''
        Write-Line 'Next:'
        Write-Line '  ssh-paste --enable <host>    then connect as usual: ssh <host>'
        Write-Line '  ssh-paste <host>             or run ssh through ssh-paste, with no config change'
        Write-Line '  ssh-paste --doctor <host>    check this computer and test an upload'
        Write-Line '  ssh-paste --uninstall        remove ssh-paste and everything it changed'
        if ($pathAdded -and -not $ScriptDir) {
            Write-Line 'The ssh-paste command works in this window now; in other windows, open a new tab.'
        } elseif ($pathAdded) {
            Write-Line 'Open a new terminal tab so that it sees the new PATH.'
        }
        return 0
    }

    function Invoke-Removal {
        param($Options)
        $did = $false

        if (Remove-ConfigBlock (Join-Path $env:USERPROFILE '.ssh\config')) { $did = $true }

        $dir = Get-InstallDirectory
        if (Remove-UserPathEntry $dir) {
            Write-Line ('Removed from your PATH: ' + $dir) 'Green'
            $did = $true
        }
        Send-EnvironmentChange   # also removes values that older versions left behind
        if ($env:Path -and (Test-PathListHas $env:Path $dir)) { $env:Path = Get-PathWithoutEntry $env:Path $dir }

        if (Test-Path -LiteralPath $dir) {
            $inside = $dir.TrimEnd('\') + '\'
            if (($PWD.ProviderPath + '\').StartsWith($inside, [StringComparison]::OrdinalIgnoreCase)) { Set-Location -LiteralPath $env:USERPROFILE }
            if (([Environment]::CurrentDirectory + '\').StartsWith($inside, [StringComparison]::OrdinalIgnoreCase)) { [Environment]::CurrentDirectory = $env:USERPROFILE }
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Line ('Deleted ' + $dir) 'Green'
            $did = $true
            $programs = Split-Path -Parent $dir
            if (Remove-EmptyDirectory $programs) { Write-Line ('Deleted the empty folder ' + $programs) 'Green' }
        }

        if ($did) {
            Write-Line 'ssh-paste is uninstalled.'
            Write-Line 'Images already uploaded stay in /tmp on your servers until the server clears /tmp.'
            Write-Line 'To delete them now: ssh HOST "rm -f /tmp/ssh-paste-*"'
        } else {
            Write-Line 'ssh-paste is not installed; nothing to remove.'
        }
        if ($Options.UninstallFromEnv) {
            Write-Line 'SSH_PASTE_UNINSTALL=1 is still set; clear it before installing again: Remove-Item Env:SSH_PASTE_UNINSTALL' 'Yellow'
        }
        return 0
    }

    function Invoke-Installer {
        param([object[]]$Arguments)
        # Checked first, with nothing but Write-Host: under AppLocker or App
        # Control, PowerShell runs in ConstrainedLanguage and ssh-paste cannot work.
        $mode = [string]$ExecutionContext.SessionState.LanguageMode
        if ($mode -ne 'FullLanguage') {
            Write-Host ("ssh-paste cannot run here: PowerShell is in $mode mode, which usually means an AppLocker or App Control policy. Ask your IT department.") -ForegroundColor Red
            return 1
        }
        try {
            Set-StrictMode -Version 2.0
            $options = Read-Options $Arguments
            if ($options.Help) { Write-Line (Get-Usage); return 0 }
            Assert-Windows
            if ($options.Uninstall) { return (Invoke-Removal $options) }
            return (Invoke-Install $options)
        } catch {
            Write-Host ('ssh-paste installer: ' + $_.Exception.Message) -ForegroundColor Red
            return 1
        }
    }

    $code = Invoke-Installer $mainArgs
    if ($ScriptDir) { exit $code }   # run as a file: report the exit code
    if ($code -ne 0) { $global:LASTEXITCODE = $code }   # under iex, exit would close the window
} @args
