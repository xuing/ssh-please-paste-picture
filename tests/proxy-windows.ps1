<#
Real Windows OpenSSH against the --proxy relay. Windows only; CI runs it on
windows-latest in both Windows PowerShell 5.1 and PowerShell 7 (job proxy-windows).

Why it exists: ssh.exe starts the ProxyCommand with overlapped pipes. A relay that reads
them as ordinary synchronous streams sees the first bytes and then hangs, and only the
real ssh.exe shows it: every other test uses a stand-in for ssh. The banner alone does not
prove the pipes work, so this test also waits for the packet that follows it.

What it does
  1. Listens on 127.0.0.1 and sends the banner "SSH-2.0-test", like an ssh server.
  2. Runs C:\Windows\System32\OpenSSH\ssh.exe with
       -o ProxyCommand=<the line --enable writes, from Get-ProxyCommandLine>
     for x@127.0.0.1 on that port, with SSH_PASTE_DEBUG=1 so the relay reports its steps.
  3. Passes only when the listener received ssh's banner (SSH-2.0-OpenSSH...) and its whole
     KEXINIT packet, which proves bytes went both ways through the relay. ssh then fails
     in the key exchange, because this server never answers: that is expected.
  4. Fails after -TimeoutSeconds, so a hang costs seconds, not the job's timeout. On any
     failure it prints what was received and what ssh and the relay said on stderr.

  powershell -ExecutionPolicy Bypass -File tests\proxy-windows.ps1 [-TimeoutSeconds 30]
Needs only the OpenSSH client that comes with Windows. It touches no file outside the
temp folder and does not use the clipboard.
#>
param(
    [int]$TimeoutSeconds = 30,
    [string]$Ssh
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($env:OS -ne 'Windows_NT') { Write-Host 'proxy-windows.ps1 runs on Windows only.'; exit 2 }
if (-not $Ssh) { $Ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe' }
if (-not (Test-Path -LiteralPath $Ssh)) { Write-Host ('proxy-windows: ssh.exe not found at ' + $Ssh); exit 2 }

$repo = Split-Path -Parent $PSScriptRoot
$core = Join-Path $repo 'src\ssh-paste.ps1'
# Dot-sourcing defines the functions without running the program, and gives the real
# Get-ProxyCommandLine and the argument quoting that the wrapper itself uses.
. $core

$proxyCommand = Get-ProxyCommandLine $core
Write-Host ('PowerShell {0}; ssh: {1}' -f $PSVersionTable.PSVersion, $Ssh)
Write-Host ('ProxyCommand: ' + $proxyCommand)

$received = New-Object System.IO.MemoryStream
$listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
$client = $null
$process = $null
$failure = $null
$stderrTask = $null
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

function Stop-Tree {
    param($Proc)
    if ($null -eq $Proc) { return }
    try { if (-not $Proc.HasExited) { & taskkill.exe /T /F /PID $Proc.Id 2>&1 | Out-Null } } catch { }
}

function Get-ReceivedState {
    # What has arrived so far: has the banner, has the whole packet after it, and the length.
    param([byte[]]$Bytes)
    $state = @{ Banner = $false; Kexinit = $false; Length = $Bytes.Length }
    $newline = [Array]::IndexOf($Bytes, [byte]10)
    if ($newline -lt 0) { return $state }
    $line = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, $newline)
    $state.Banner = $line.StartsWith('SSH-2.0-OpenSSH')
    $start = $newline + 1
    # Binary packet: uint32 length, byte padding length, byte message type (20 = KEXINIT).
    if ($state.Banner -and $Bytes.Length -ge ($start + 6)) {
        $packetLength = ([int]$Bytes[$start] * 16777216) + ([int]$Bytes[$start + 1] * 65536) + ([int]$Bytes[$start + 2] * 256) + [int]$Bytes[$start + 3]
        $isKexinit = ($Bytes[$start + 5] -eq 20)
        $state.Kexinit = ($isKexinit -and $packetLength -gt 100 -and $Bytes.Length -ge ($start + 4 + $packetLength))
    }
    return $state
}

try {
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Ssh
    Set-ProcessArguments $psi @(
        '-v',
        '-o', ('ProxyCommand=' + $proxyCommand),
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'BatchMode=yes',
        '-p', [string]$port,
        'x@127.0.0.1'
    )
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['SSH_PASTE_DEBUG'] = '1'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    # Drain stdout so ssh can never block on a full pipe; ssh writes nothing there in this test.
    $null = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    # The relay (started by ssh) connects to us.
    while (-not $listener.Pending()) {
        if ([DateTime]::UtcNow -gt $deadline) { $failure = 'the relay never connected to the listener'; break }
        if ($process.HasExited) { $failure = ('ssh exited with code {0} before the relay connected' -f $process.ExitCode); break }
        Start-Sleep -Milliseconds 50
    }

    $state = @{ Banner = $false; Kexinit = $false; Length = 0 }
    if (-not $failure) {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $hello = [System.Text.Encoding]::ASCII.GetBytes("SSH-2.0-test`r`n")
        $stream.Write($hello, 0, $hello.Length)
        $stream.Flush()

        $buffer = New-Object byte[] 8192
        while ($true) {
            while ($stream.DataAvailable) {
                $n = $stream.Read($buffer, 0, $buffer.Length)
                if ($n -le 0) { break }
                $received.Write($buffer, 0, $n)
            }
            $state = Get-ReceivedState $received.ToArray()
            if ($state.Kexinit) { break }
            if ([DateTime]::UtcNow -gt $deadline) {
                if ($state.Banner) {
                    $failure = ('ssh sent its banner but no complete KEXINIT within {0} s: the relay hangs after the first bytes' -f $TimeoutSeconds)
                } else {
                    $failure = ('no ssh banner reached the listener within {0} s' -f $TimeoutSeconds)
                }
                break
            }
            if ($process.HasExited -and -not $stream.DataAvailable) {
                $failure = ('ssh exited with code {0} before sending a complete KEXINIT' -f $process.ExitCode)
                break
            }
            Start-Sleep -Milliseconds 50
        }
    }
} catch {
    $failure = 'the test itself failed: ' + $_.Exception.Message
} finally {
    # Hand the relay a closed connection, then make sure nothing is left running.
    if ($null -ne $client) { try { $client.Close() } catch { } }
    if ($null -ne $process) {
        try { [void]$process.WaitForExit(5000) } catch { }
        Stop-Tree $process
    }
    try { $listener.Stop() } catch { }
}

$bytes = $received.ToArray()
if ($failure) {
    Write-Host ('FAIL  ' + $failure)
} else {
    Write-Host ('ok    the listener received {0} bytes: the ssh banner and a complete KEXINIT packet' -f $bytes.Length)
}
$head = $bytes
if ($head.Length -gt 64) { $head = $bytes[0..63] }
Write-Host ('first bytes received: ' + (($head | ForEach-Object { $_.ToString('x2') }) -join ' '))
if ($null -ne $stderrTask) {
    $text = ''
    try { if ($stderrTask.Wait(5000)) { $text = $stderrTask.Result } } catch { }
    if ($failure -or $env:SSH_PASTE_PROXY_VERBOSE) {
        Write-Host '---- ssh and relay stderr ----'
        Write-Host $text
    } else {
        foreach ($l in ($text -split "`r?`n")) { if ($l -like 'ssh-paste debug:*') { Write-Host $l } }
    }
}
if ($failure) { exit 1 }
