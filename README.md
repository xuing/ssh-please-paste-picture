# ssh-please-paste-picture

[![CI](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml/badge.svg)](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml)

English | [简体中文](README.zh-CN.md)

Press Ctrl+V in Windows Terminal to paste a screenshot into remote Claude Code
over SSH.

The name says what it does: "ssh, please paste picture". It installs `ssh-paste`, one PowerShell
script on Windows. Nothing is installed on the server.

## What happens

Windows Terminal pastes only text, and remote programs cannot read your Windows
clipboard. Here is how `ssh-paste` works:

1. Copy a screenshot on Windows with Win+Shift+S or another image app, or copy
   image files (png, jpg, jpeg, gif, webp, bmp) in File Explorer.
2. Switch back to your SSH terminal window.
3. `ssh-paste` uploads the image to `/tmp/ssh-paste-<hash>.png` on the server.
4. Press Ctrl+V to paste that path.
5. Claude Code reads the path and attaches the image.

Other apps still paste the image. `ssh-paste` runs only while the session is
open.

## Install

Run this command in PowerShell, not cmd:

```powershell
irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

You do not need administrator rights. `ssh-paste` works in that window right
away. Open a new tab for other windows. Run the same command again to upgrade.

See [Requirements](#requirements) for Windows and SSH prerequisites, and
[Install options](#install-options) for download-then-run or specific versions.

## Use

### ssh mode (recommended)

Enable a host once:

```powershell
ssh-paste --enable myhost
```

Plain `ssh myhost` now pastes screenshots. Any interactive session to `myhost`,
such as a Windows Terminal profile running `ssh myhost`, works too. Use a
`Host` alias from `%USERPROFILE%\.ssh\config` or a plain host name, without
`user@` or options. Enable multiple hosts with
`ssh-paste --enable host1 host2`.

`--enable` puts this block at the top of `%USERPROFILE%\.ssh\config` and prints
it:

```
# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>
Host myhost
    ProxyCommand C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Users\you\AppData\Local\Programs\ssh-paste\ssh-paste.ps1" --proxy %h %p %n
    ProxyUseFdpass no
Host *
# <<< ssh-paste <<<
```

`--enable` refuses hosts that already use `ProxyJump` or `ProxyCommand`. See
[ssh mode and wrapper mode](#ssh-mode-and-wrapper-mode) for how this block
works.

To disable ssh mode, run one of these commands:

```powershell
ssh-paste --disable myhost   # one host
ssh-paste --disable          # all hosts: removes the whole block
```

`--disable` removes only the lines that `--enable` added. If `ssh-paste`
created `%USERPROFILE%\.ssh\config` and nothing else is in it, `--disable`
deletes the file. If `.ssh` is then empty, `--disable` deletes it too.

### wrapper mode (no config)

Run `ssh-paste` instead of `ssh`:

```powershell
ssh-paste myhost
ssh-paste -p 2222 -J bastion me@myhost
ssh-paste -t myhost claude
```

`ssh-paste` runs `ssh.exe` with the same arguments, prints
`ssh-paste: screenshot paste is on. Copy a screenshot, come back here, press Ctrl+V.`,
and watches the clipboard. All `ssh`
options and jump hosts work. A remote command without `-t`, such as
`ssh-paste myhost ls`, runs as plain `ssh`.

### Check your setup

Run `--doctor` to check PowerShell, clipboard and window APIs, `ssh`, and your
terminal, then upload a small test image to `myhost`:

```powershell
ssh-paste --doctor myhost
```

Omit `myhost` to check only this computer. Example output:

```
ssh-paste 0.1.0
  ok    PowerShell 5.1.26100.2161 (Desktop)
  ok    clipboard and window APIs available
  ok    ssh: C:\Windows\System32\OpenSSH\ssh.exe (OpenSSH_for_Windows_9.5p1, LibreSSL 3.8.2)
  ok    terminal: Windows Terminal
  ok    clipboard: image, 48213 bytes
  ok    upload to myhost: /tmp/ssh-paste-4f1c0a9e7b2d3c5a8b6f0e1d2c3b4a59.png (0.8 s)
  info  ssh mode is off for myhost. Turn it on: ssh-paste --enable myhost   (or use: ssh-paste myhost)
```

### All commands

```
ssh-paste --enable HOST [HOST...]   make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)
ssh-paste --disable [HOST...]       undo --enable (all hosts if none given)
ssh-paste [ssh options] HOST        wrapper mode: ssh with screenshot paste, no config
ssh-paste --doctor [HOST]           check this computer and test an upload to HOST
ssh-paste --uninstall               remove ssh-paste and everything it changed
ssh-paste --version | --help
```

## Requirements

Before installing `ssh-paste`, check these requirements:

- **Windows 10 or 11.** `ssh-paste` runs on the built-in Windows PowerShell
  5.1, even if you also have PowerShell 7.
- **Windows Terminal.** Windows Terminal is recommended, and the classic console
  window works too. See
  [Other terminals and programs](#other-terminals-and-programs) for others.
- **OpenSSH client.** Windows includes `ssh.exe` by default. If missing, add
  `"OpenSSH Client"` under **Settings > System > Optional features**. The
  installer stops without `ssh.exe`.
- **Key login without a prompt.** Uploads use a second, non-interactive `ssh`
  connection with `BatchMode=yes`, which never asks for a password or
  passphrase. Use a key without a passphrase, or load it into `ssh-agent`:

  ```powershell
  # once, in PowerShell as Administrator: start the agent now and at every boot
  Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service
  # then, as yourself: add your key (asks for the passphrase once)
  ssh-add
  ```

  With password-only login, SSH works, but uploads fail.
- **Server tools.** The server needs `sh`, the tools `cat`, `wc`, `find`,
  `cmp`, `mv`, and `mktemp`, and a writable `/tmp`. Every Linux server has
  these. Your login shell can be `bash`, `zsh`, `fish`, or `tcsh`.

## Known limitations

`ssh-paste` has these limits:

- **Focus is per Windows Terminal window, not per tab.** Windows cannot report
  the active tab. While a session runs in a window, every tab in that window
  pastes the path, including local tabs. A second tab connected to another host
  also uploads each image, and whichever session writes first sets the pasted
  path. Use separate windows for different hosts and local work.
- **In ssh mode, the clipboard may keep the path after exit.** Because `ssh`
  terminates `ProxyCommand` on close, `ssh-paste` may not restore the plain
  image. Other apps still paste the image, and your next copy clears the path.
- **Images copied with HTML lose the HTML.** Chrome's **Copy image** puts an
  image and HTML on the clipboard. After `ssh-paste` rewrites it, only the
  image and path remain.
- **ssh mode refuses hosts with `ProxyJump` or `ProxyCommand`.** Use wrapper
  mode, such as `ssh-paste myhost`, instead.
- **Uploads require key login without a prompt or `ssh-agent`.** See
  [Requirements](#requirements).
- **ssh mode adds PowerShell startup time to every connection to an enabled
  host.** This includes `scp`, `sftp`, and `git`.

## What it changes on your computer

`ssh-paste` makes only these local changes:

| Step | Change | Reverted by |
|---|---|---|
| Install | Folder `%LOCALAPPDATA%\Programs\ssh-paste` with `ssh-paste.ps1` and `ssh-paste.cmd` (`%LOCALAPPDATA%\Programs` is created if missing) | `--uninstall` deletes the folder, and `%LOCALAPPDATA%\Programs` if it is then empty |
| Install | One entry in your user PATH (`HKCU\Environment\Path`) | `--uninstall` removes the entry, and the `Path` value if nothing else is left in it |
| `--enable` | The block shown above at the top of `%USERPROFILE%\.ssh\config` (the file and the `.ssh` folder are created if missing) | `--disable` or `--uninstall` remove the block; a config that ssh-paste created and that holds nothing else is deleted, and `.ssh` with it if it is then empty |
| While a session runs | The clipboard entry with your image is rewritten: image, path as text, a private `SshPaste.Owner` format, and the flags `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory=0`, `CanUploadToCloudClipboard=0`, which keep these rewrites out of Win+V history and cloud clipboard | The path text goes away: switching to another app or ending the session puts the image back without the path (but see the ssh mode limitation). That entry keeps the `SshPaste.Owner` format and the three flags until you copy something else |

`ssh-paste` adds no services, scheduled tasks, startup entries, profile edits,
or settings files. Install and uninstall set and clear a temporary user
variable so Windows refreshes `PATH` in new windows. On the server, it creates
only `/tmp/ssh-paste-*.png`.

## Uninstall

Run `--uninstall` to remove the `--enable` block, `PATH` entry, and install
folder:

```powershell
ssh-paste --uninstall
```

If `ssh-paste` does not run, uninstall via the installer:

```powershell
$env:SSH_PASTE_UNINSTALL = 1; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
& ([scriptblock]::Create((irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1))) -Uninstall
```

After the first line, run `Remove-Item Env:SSH_PASTE_UNINSTALL` before
reinstalling in that window.

To remove `ssh-paste` manually:

1. Delete `# >>> ssh-paste` through `# <<< ssh-paste <<<` in
   `%USERPROFILE%\.ssh\config`.
2. Open Start, search for `"Edit environment variables for your account"`,
   select `Path`, click **Edit**, and remove `%LOCALAPPDATA%\Programs\ssh-paste`.
3. Run `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\ssh-paste"`.

Uninstalling does not touch your servers. Existing images stay until the server
clears `/tmp`. See [Files on the server](#files-on-the-server). To delete yours
now, run:

```powershell
ssh myhost "rm -f /tmp/ssh-paste-*"
```

## Details

### Which sessions get the clipboard watcher

Only interactive sessions run the watcher. Other connections to an enabled host
pass through the relay without watching the clipboard:

- `ssh -T`, `-N`, `-W`, `-f`, `-n`, `-s`, `-G`, `-V`, `-O`, and `-Q`
- remote commands without `-t`, such as `ssh myhost ls`, `git`, or
  `RemoteCommand`
- `RequestTTY no`, `SessionType` other than `default`, or `StdinNull yes`

`ssh-paste` reads these settings from arguments and `~/.ssh/config` via
`ssh -G`. As a result, `scp`, `sftp`, `git`, and VS Code Remote-SSH run as
plain relays. In wrapper mode, if a host already uses ssh mode, `ssh-paste`
runs `ssh` directly to avoid uploading twice.

### When it uploads, retries, and errors

`ssh-paste` checks the clipboard every 250 ms. It uploads an image up to 64 MB
when the session window is in front. The upload happens when you switch back to
the window, not on Ctrl+V. On a slow link, wait a moment, or press Ctrl+V again
if nothing pastes.

Each image uploads once per session. Returning to an image after 6 hours
uploads it again so day-old server cleanup never deletes a needed path.

Failed uploads play the Windows error sound once per image. When the window is
in front, `ssh-paste` retries after 30 seconds, then 1, 2, 4 minutes, up to 30
minutes. At exit, `ssh-paste` prints:

```
ssh-paste: 1 screenshot upload(s) failed: ssh exited with 255: me@myhost: Permission denied (publickey).
Run: ssh-paste --doctor myhost
```

In ssh mode, `ssh` may terminate `ProxyCommand` before this summary prints.

If a required API is missing or blocked by policy, `ssh-paste` prints
`ssh-paste: screenshot paste is off: <reason>`. It then runs as plain `ssh` or a
plain relay.

### Files on the server

Files are saved as `/tmp/ssh-paste-<hash>.png`, where `<hash>` is the first 128
bits of the PNG's SHA-256 in hex. The same image gets the same name, and
identical existing files are reused. If another user owns that name, `ssh-paste`
uses `/tmp/ssh-paste-<hash>-<uid>.png`. Files get mode 600.

Cleanup runs only on a later upload by the same user on the same server. It
deletes that user's `ssh-paste-<hash>.png` files and temp files older than a
day. Reusing a file resets its age. Nothing runs between uploads or after
uninstall. The OS clears `/tmp` on its own schedule, often at reboot.

### The clipboard

A Windows clipboard entry holds multiple formats. `ssh-paste` writes both the
image and the remote path as text. Windows Terminal pastes text, while image
editors and chat apps paste the image. Switching to another app restores the
plain image.

`ssh-paste` skips entries with both an image and text or files, such as Excel,
Word, or Explorer, so the terminal pastes normally. Your original screenshot
stays in Win+V history, and only `ssh-paste` rewrites are excluded.

Sessions tag each entry with their target window handle, so the front window
wins and separate windows do not overwrite each other. A session leaves alone
an entry that another session in the same window already updated.

### ssh mode and wrapper mode

In ssh mode, `ssh` starts `ssh-paste` as `ProxyCommand`. `ssh-paste` opens the
TCP connection, relays encrypted SSH bytes unchanged, and watches the clipboard
for interactive sessions. `ssh` fills in `%h %p %n` for host name, port, and
alias. `ProxyUseFdpass no` blocks any `ProxyUseFdpass yes` in your config
because `ssh-paste` relays bytes itself. The block sits first because `ssh`
uses the first matching option, and `Host *` ends it so later rules still apply
to every host. If `.ssh\config` did not exist, `ssh-paste` creates it and adds
`# ssh-paste created this file; it is deleted when the last host is disabled.`
after the first marker.

`ssh-paste` reads the parent `ssh.exe` command line to inspect options. It
uploads to the relay's IP address and checks the host key under the session's
name. In wrapper mode, `ssh-paste` starts `ssh.exe` in the same console. Both
modes keep server and login options such as `-l`, `-p`, `-i`, `-F` and `-o`,
plus hardening options. Wrapper mode also keeps `-J`. ssh mode drops it, because
the upload goes straight to the address the relay reached. See [SECURITY.md](SECURITY.md).

### Install options

**Download, read, then run.** Some antivirus tools flag `irm ... | iex` because
malware uses that pattern. Run these commands instead:

```powershell
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 -OutFile install.ps1
notepad install.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
Remove-Item install.ps1
```

`-ExecutionPolicy Bypass` affects only that process. Each release provides
`SHA256SUMS` for `install.ps1`, `ssh-paste.ps1`, and `ssh-paste.cmd`.

**Pick a version.** Each release's `install.ps1` installs that release, and
`releases/latest` is the newest one. Set `SSH_PASTE_REF` or pass `-Ref` to
install another tag, branch, or commit:

```powershell
$env:SSH_PASTE_REF = 'v0.1.0'; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

Files then download from `raw.githubusercontent.com` at that ref. From a
repository clone, `powershell -ExecutionPolicy Bypass -File install.ps1`
installs its `src` folder.

The installer stops if Group Policy sets execution policy to `AllSigned` or
`Restricted`. It also stops if AppLocker or App Control puts PowerShell in
Constrained Language mode. Run as administrator, it installs for the elevated
account and warns that the elevated account may not be your daily one.

### Other terminals and programs

Here are details on terminals, CLI programs, `ssh.exe`, and security software:

- **Other terminals.** The classic console window works. Other terminals such as
  WezTerm and Alacritty are best effort. Usually, walking up the process tree
  finds the terminal. `ssh-paste --doctor` prints the method as `terminal: ...`.
- **Other CLI programs.** `ssh-paste` pastes a server PNG path, including for
  Codex CLI, Gemini CLI, and aider. Image attachment from a path depends on the
  program. Claude Code supports it.
- **Another `ssh.exe`.** Set `SSH_PASTE_SSH` to its full path. Wrapper mode,
  `--enable`, and `--doctor` use it. In ssh mode, uploads use the `ssh.exe` that
  started the relay.
- **Antivirus and policies.** `ssh-paste` compiles short C# code via `Add-Type`
  at runtime to call Windows clipboard and window APIs, which some scanners
  flag. The plain-text script lives in `%LOCALAPPDATA%\Programs\ssh-paste`.
  Report Microsoft Defender false positives at
  <https://www.microsoft.com/en-us/wdsi/filesubmission>. Under AppLocker or App
  Control, Constrained Language mode blocks clipboard access, and
  `ssh-paste --doctor` reports that limit.
- **Background processes.** Nothing runs in the background. The watcher lives
  inside the SSH session process and exits with it.

## Alternatives

Here is how `ssh-please-paste-picture` compares with similar tools:

| Tool | On Windows | On the server | Runs in the background | Paste key |
|---|---|---|---|---|
| ssh-please-paste-picture | one PowerShell script | nothing | nothing; only during a session | Ctrl+V |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) (`/rc`) | nothing; use claude.ai/code or the Claude app | nothing extra | the Claude Code session | attach images in the browser or app |
| [clipaste](https://github.com/hqhq1025/clipaste) | Rust daemon | xclip / wl-paste shim and `clipaste-paste` (need curl); `RemoteForward` in your ssh config | local daemon | Ctrl+V |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | Go binary; Windows support marked experimental | nothing for the Windows hotkey workflow (uploads with scp); the Ctrl+V shim and tunnel are experimental on Windows | hotkey process (optional autostart) | Alt+Shift+V |
| [img2ssh](https://github.com/bulletsrip/img2ssh) | Go binary | nothing | Task Scheduler daemon from login; uploads every copied image | Ctrl+V |
| AutoHotkey scripts, e.g. [claude-ssh-image-paste](https://github.com/devonjones/claude-ssh-image-paste) | AutoHotkey v2 and a script | nothing | AutoHotkey, intercepts Ctrl+V | Ctrl+V |

Remote Control works only with Claude Code and requires a Pro, Max, Ultra, Team,
or Enterprise plan, not an API key. It also moves you from the terminal to a
browser or the Claude app. AutoHotkey scripts upload only on Ctrl+V, whereas
`ssh-paste` uploads every image you bring to the session window.

## Development

All files must stay ASCII-only and run on Windows PowerShell 5.1 and
PowerShell 7:

```
src/ssh-paste.ps1              the program (all logic is in this file)
src/ssh-paste.cmd              the `ssh-paste` command: runs the .ps1 with Windows PowerShell
install.ps1                    installer and uninstaller
tests/ssh-paste.Tests.ps1      Pester tests (tags: Unix, Windows, E2E)
tests/e2e-linux.sh             starts a throwaway sshd and runs the E2E tests against it
tests/footprint.ps1            Windows: install, enable, disable, uninstall leave no trace
PSScriptAnalyzerSettings.psd1  lint rules
.github/workflows/ci.yml       lint, unit tests (5.1 and 7 on Windows, 7 on Linux), E2E, footprint
.github/workflows/release.yml  on a v* tag: CI, then a release with the files and SHA256SUMS
```

Dot-sourcing `. ./src/ssh-paste.ps1` loads its functions without running
anything for tests.

```powershell
# Unit tests, Pester 5.5 or newer. Tests that need Windows or a Unix shell skip elsewhere.
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path tests/ssh-paste.Tests.ps1 -ExcludeTagFilter E2E -Output Detailed
```

```bash
# End to end on Linux against a throwaway sshd on 127.0.0.1 (needs pwsh, ssh, sshd, python3)
bash tests/e2e-linux.sh
```

```powershell
# Footprint, Windows only. It edits your real profile and restores it; CI runs it.
powershell -ExecutionPolicy Bypass -File tests\footprint.ps1 -Force
```

To release, push a tag `vX.Y.Z` matching `$script:Version` in
`src/ssh-paste.ps1`.

## License

[MIT](LICENSE)
