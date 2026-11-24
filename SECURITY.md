# Security

## Supported versions

Only the newest release gets security fixes. A fix ships as a new release, and
older releases get no backports. Before the first release, `main` is the only
supported version.

| Version | Supported |
|---|---|
| Newest release | Yes |
| Older releases | No |
| `main` before the first release | Yes |

## Reporting a vulnerability

Report security issues privately. Do not open a public issue, and do not post
details in a discussion or pull request.

1. Open
   [Report a vulnerability](https://github.com/xuing/ssh-please-paste-picture/security/advisories/new)
   under the **Security** tab of the repository.
2. Describe what you did and what happened.
3. Include the `ssh-paste --version` output, your Windows or macOS version, and
   the `ssh -V` output.

If the **Report a vulnerability** button is missing, private reporting is
turned off. Open a public issue that asks for a private contact and contains
no details of the problem.

The maintainer replies in the private advisory. With your consent, the advisory
and the fix commit name you as the reporter.

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

Each upload runs a separate `ssh` (`ssh.exe` on Windows) with these options
placed before yours, since `ssh` uses the first value it sees:

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
  name. On macOS the relay is `nc`, so `HostName` is the host name ssh gave the
  relay (`%h`), which the upload resolves again; the host key check is the same.

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

### On macOS

The macOS client works as follows:

- Pasteboard entries written by `ssh-paste` carry
  `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType`,
  which clipboard managers that follow nspasteboard.org leave out of their
  history, and the private `com.github.xuing.ssh-paste.owner` type with the
  window number, a random per-session token, the text and the copied file
  paths. The path text is promised: macOS asks `ssh-paste` for it when
  something pastes, and only a paste while the window the entry was written for
  is in front gets it.
- The image bytes an upload sends are written to a folder in `$TMPDIR` that
  only you can read (mode 700), because the upload's `ssh` reads them from a
  file. The folder is deleted when `ssh-paste` exits.
- To detect interactive sessions, `ssh-paste` runs `ssh -G` with your
  arguments. In ssh mode it reads the parent `ssh` command line with `ps`.
- In ssh mode, `ssh` runs the `ProxyCommand` through your login shell; it is a
  quoted absolute path to `ssh-paste`. That starts the watcher (an `osascript`
  process that ignores SIGHUP, so that it can put the plain image back when the
  terminal closes) and then becomes `/usr/bin/nc`, which relays the bytes. The
  watcher ends when the relay ends.
- `install.sh` downloads with `curl --proto =https`. A release install checks
  `ssh-paste-mac`, `ssh-paste.js` and `install.sh` against the release's
  `SHA256SUMS`; every install checks that the files are ASCII and that the
  launcher parses (`zsh -n`), then runs `ssh-paste --version`.
  `ssh-paste --update` checks the latest `install.sh` against `SHA256SUMS`
  before it runs it.
- `brew install xuing/tap/ssh-paste` installs the same two files of the
  release, `ssh-paste.js` and `ssh-paste-mac`, and Homebrew checks each
  against the SHA-256 in the formula, which a release job copies from the
  attested `SHA256SUMS` of the release marked Latest. Only that job can change
  the tap: its deploy key can write to `xuing/homebrew-tap` and no other
  repository, and it is a secret of an environment that only `main` can use.
- See [macOS](README.md#macos) for everything the install changes.
- `scoop install xuing/ssh-paste` (Windows) installs `ssh-paste.ps1` and
  `ssh-paste.cmd` of the Latest release, and Scoop checks each against the
  SHA-256 in the manifest, copied from the release's attested `SHA256SUMS` by
  the same release job, with a deploy key that can write to
  `xuing/scoop-bucket` only, held by an environment that only `main` can use.
  `scoop uninstall` runs `ssh-paste --disable` before it deletes the files.

### Nothing stored

`ssh-paste` stores no passwords, keys, tokens, or settings, and sends no
telemetry. It uses your existing `ssh` config, keys, and `ssh-agent`. At
runtime, it connects only to your servers through the relayed session in ssh
mode and `ssh` for uploads. The installer downloads only from `github.com` and
`raw.githubusercontent.com`, and so does `install.sh`.

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
  SHA-256 sums in `SHA256SUMS` and GitHub build attestations. See
  [Verify the download](README.md#verify-the-download).
- See [What it changes on your computer](README.md#what-it-changes-on-your-computer)
  for all local changes.
