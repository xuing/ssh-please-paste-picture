# Security

## Reporting a vulnerability

Report security issues privately on GitHub via
[Report a vulnerability](https://github.com/xuing/ssh-please-paste-picture/security/advisories/new)
under the **Security** tab. Do not open a public issue.

Include what you did, what happened, and `ssh-paste --version` output.

## Security model

### What is uploaded and when

Clipboard uploads follow these rules:

- Only an image already on your Windows clipboard is uploaded, as PNG or
  bitmap up to 64 MB. Text is never uploaded.
- Uploads run only while an interactive SSH session using `ssh-paste` is open
  and its terminal window is in front.
- Each upload starts when you switch to that window, before Ctrl+V. Any
  clipboard image goes to the server even if you never paste it.
- Uploads go only to that session's server. Focus is tracked per window, not
  per tab. Every active session in the front window uploads to its own server,
  so a second tab connected to another host also receives the image.
- Each image uploads once per session, re-uploads after 6 hours if revisited,
  and retries after 30 seconds up to 30 minutes on failure.
- `ssh-paste` ignores clipboard entries mixing an image with text or files,
  such as Excel, Word, or Explorer.

### Files on the server

Server uploads create and manage files in `/tmp` as follows:

- The path is `/tmp/ssh-paste-<hash>.png`, where `<hash>` is the first 128
  bits of the PNG's SHA-256 in hex. If another user owns that name, `ssh-paste`
  uses `/tmp/ssh-paste-<hash>-<uid>.png`.
- The server writes bytes to a private temp file via `mktemp`, `umask 077`, and
  noclobber. If the byte count differs from what `ssh-paste` sent, the server
  deletes the temp file and fails. Otherwise, `mv` renames it to the final name
  with mode 600.
- The server reuses an existing file only if it is a regular file, not a
  symlink, owned by you, and byte-for-byte identical.
- Symlinks at either path are never followed. `mv` replaces the link itself, or
  fails in sticky `/tmp` if another user owns it. Directories are skipped.
  Other server users can at most make an upload fail, never read your images or
  make you write into their files.
- `ssh-paste` pastes the path only if the server reply `<size> <path>` matches
  the sent size and one of those two path forms.
- The file name depends only on the image. Another user with the same image can
  compute the name and see it exists, but cannot read it.
- Each upload deletes your `ssh-paste-<hash>.png` and leftover temp files in
  `/tmp` older than one day. Nothing runs between uploads or after uninstall.
  Files stay until the server clears `/tmp`.

### The upload connection

Each upload runs a separate `ssh.exe` with these options placed before yours,
since `ssh` uses the first value it sees:

- `-T`, `-x`, and `RequestTTY=no` disable terminals and X11 forwarding.
- `BatchMode=yes` disables password, passphrase, and unknown host key prompts.
  Host keys are still checked against `known_hosts`.
- `ForwardAgent=no` and `ClearAllForwardings=yes` disable agent and port
  forwarding.
- `PermitLocalCommand=no` and `RemoteCommand=none` block extra config commands.
- `ControlMaster=no` and `ControlPath=none` disable connection sharing.
- `ConnectTimeout=10`, `ServerAliveInterval=10`, `ServerAliveCountMax=2`, and
  `LogLevel=ERROR` bound timeouts and logs. Uploads time out after 30 seconds.
- OpenSSH 8.7 or newer also sets `StdinNull=no`, `SessionType=default`, and
  `ForkAfterAuthentication=no` to override config.
- In ssh mode, `ssh-paste` also sets `ProxyCommand=none`,
  `HostName=<the IP address the relay connected to>`, `Port=<its port>`,
  `HostKeyAlias=<the name the session used>`, `CheckHostIP=no`, and
  `CanonicalizeHostname=no`. Uploads connect directly to the relay's address
  without restarting `ssh-paste`, and verify the host key under the session's
  name.

From your arguments, `ssh-paste` keeps only server and login options:
`-4 -6 -C -B -F -I -J -P -b -c -i -l -m -o -p`.

It drops `-o` options that would break or redirect uploads: `RequestTTY`,
`RemoteCommand`, `LocalCommand`, `PermitLocalCommand`, `LocalForward`,
`RemoteForward`, `DynamicForward`, `ClearAllForwardings`, `ControlMaster`,
`ControlPath`, `ControlPersist`, `ForwardX11`, `ForwardX11Trusted`,
`ForwardX11Timeout`, `ForwardAgent`, `Tunnel`, `TunnelDevice`, `BatchMode`,
`StdinNull`, `SessionType`, `ForkAfterAuthentication`, `ExitOnForwardFailure`,
`GatewayPorts`, `EscapeChar`, `LogLevel`, `ProxyUseFdpass`,
`EnableEscapeCommandline`, `PermitRemoteOpen`, and `StreamLocalBindUnlink`. In
ssh mode, it also drops `-J`, `ProxyJump`, and `ProxyCommand`.

The remote command is a fixed `sh -c '...'` script taking the 32-digit
lowercase hex hash and byte count. It has no single quote, backslash, or
exclamation mark, so `bash`, `zsh`, `fish`, and `tcsh` pass it to `sh`
unchanged.

### Nothing stored

`ssh-paste` stores no passwords, keys, tokens, or settings, and sends no
telemetry. It uses your existing `ssh` config, keys, and `ssh-agent`. At
runtime, it connects only to your servers through the relayed session in ssh
mode and `ssh` for uploads. The installer downloads only from `github.com` and
`raw.githubusercontent.com`.

### On Windows

Windows integration works as follows:

- Clipboard entries written by `ssh-paste` set
  `ExcludeClipboardContentFromMonitorProcessing`,
  `CanIncludeInClipboardHistory=0`, and `CanUploadToCloudClipboard=0` to stay
  out of Win+V history and cloud clipboard. They also carry the private
  `SshPaste.Owner` format with the window handle and a random per-session
  number.
- To detect interactive sessions, `ssh-paste` runs `ssh -G` with your
  arguments. In ssh mode, it reads the parent `ssh.exe` command line via
  `Win32_Process` in CIM.
- `ProxyCommand` and `ssh-paste` start `powershell.exe` with
  `-ExecutionPolicy Bypass` for that process only, leaving your execution
  policy unchanged.
- The installer checks that downloaded files are ASCII, parse as PowerShell,
  and look like `ssh-paste`, then runs `ssh-paste --version`. Releases publish
  SHA-256 sums in `SHA256SUMS`.
- See [What it changes on your computer](README.md#what-it-changes-on-your-computer)
  for all local changes.
