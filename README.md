# ssh-please-paste-picture

[![CI](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml/badge.svg)](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/xuing/ssh-please-paste-picture)](https://github.com/xuing/ssh-please-paste-picture/releases/latest)
[![License: MIT](https://img.shields.io/github/license/xuing/ssh-please-paste-picture)](LICENSE)

English | [简体中文](README.zh-CN.md)

Paste a screenshot into remote Claude Code over SSH with Ctrl+V in Windows Terminal, or Cmd+V in Terminal on macOS. One script on your computer (`ssh-paste`); nothing on the server.

How it works, what it never does, and how it compares: [docs/how-it-works.md](docs/how-it-works.md).

## Quick start

**1. Install** on Windows, in PowerShell (not cmd), without administrator rights:

```powershell
irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

It works in this window at once; open a new tab for others. Or with [Scoop](https://scoop.sh):

```powershell
scoop bucket add xuing https://github.com/xuing/scoop-bucket
scoop install xuing/ssh-paste
```

On macOS, with [Homebrew](https://brew.sh):

```sh
brew install xuing/tap/ssh-paste
```

Without Homebrew (then open a new tab, or run the `export PATH=...` line it prints):

```sh
curl -fsSL https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.sh | sh
```

<details>
<summary>More install options</summary>

Main branch (Windows):

```powershell
irm https://raw.githubusercontent.com/xuing/ssh-please-paste-picture/main/install.ps1 | iex
```

If antivirus flags `irm ... | iex`, see [Verify the download](#verify-the-download).

Another tag, branch or commit (`SSH_PASTE_REF`, `-Ref` or `--ref <tag|branch|commit>`):

```powershell
$env:SSH_PASTE_REF = 'v0.1.0'; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

A clone installs its `src` folder: `powershell -ExecutionPolicy Bypass -File install.ps1` or `sh install.sh` (`-Help`, `--help`). As administrator, install.ps1 installs for the elevated account.

</details>

**2. Enable a host:**

```powershell
ssh-paste --enable myhost
```

**3. Connect with `ssh myhost` and paste:**

1. Copy a screenshot (Win+Shift+S; Cmd+Ctrl+Shift+4 on macOS) or image files (`png`, `jpg`, `jpeg`, `gif`, `webp`, `bmp`).
2. Switch to the SSH window; `ssh-paste` uploads the image to `/tmp/ssh-paste-<hash>.png`.
3. Press Ctrl+V (Cmd+V on macOS) to paste that path into Claude Code.

Other programs still paste the image. Nothing runs when no session is connected.

## Use

### ssh mode (recommended)

`--enable` writes a block at the top of `~/.ssh/config` (`%USERPROFILE%\.ssh\config`). Give Host aliases or host names, without `user@` or options (`ssh-paste --enable host1 host2`). Hosts that already use `ProxyJump` or `ProxyCommand` are refused; use wrapper mode for them.

```powershell
ssh-paste --disable myhost   # one host
ssh-paste --disable          # all hosts: removes the whole block
```

<details>
<summary>The block in ~/.ssh/config</summary>

```
# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>
Host myhost
    ProxyCommand C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Users\you\AppData\Local\Programs\ssh-paste\ssh-paste.ps1" --proxy %h %p %n
    ProxyUseFdpass no
Host *
# <<< ssh-paste <<<
```

`ssh-paste` relays the SSH bytes unchanged and watches for interactive sessions (`Host *` ends the block). Uploads use your `ssh.exe` options, the relay's IP address and the session's host key; `-J` works only in wrapper mode. See [SECURITY.md](SECURITY.md).

</details>

### wrapper mode (no config)

```powershell
ssh-paste myhost
ssh-paste -p 2222 -J bastion me@myhost
ssh-paste -t myhost claude
```

Runs `ssh` with all your options, `-J` included. A remote command without `-t` (`ssh-paste myhost ls`) runs as plain `ssh`.

### All commands

```
ssh-paste --enable [OPTIONS] HOST...    make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)
ssh-paste --disable [HOST...]           undo --enable (all hosts if none given)
ssh-paste [OPTIONS] [ssh options] HOST  wrapper mode: ssh with screenshot paste, no config
ssh-paste --doctor [HOST]               check this computer and test an upload to HOST
ssh-paste --update                      install the latest release
ssh-paste --uninstall                   remove ssh-paste and everything it changed
ssh-paste --version | --help

OPTIONS (images on the server; per host for --enable):
  --keep TIME   delete them when older than TIME: 30m, 2h, 7d (default 1d), or never
  --dir DIR     keep them in DIR: /tmp (default), any /path, or ~/path (quote the ~)
```

### Where images go on the server, and for how long

By default an image goes to `/tmp`, and each upload deletes your images there that are older than a day. Choose both per host:

```sh
ssh-paste --enable --keep 7d --dir '~/screenshots' myhost   # keep a week, in your home folder
ssh-paste --enable --keep never myhost                      # never delete
ssh-paste --keep 2h myhost                                  # wrapper mode, this session only
```

`--keep` takes a time of at least 10 minutes (`30m`, `2h`, `7d`) or `never`; `--dir` takes `/path` or `~/path` (quote the `~`, so that your shell leaves it for the server). `~` is the home folder on the server: `--enable` asks the server for it once and writes the full path into your ssh config (wrapper mode asks when the session starts). If ssh-paste cannot log in to ask, give the full path instead. A folder other than `/tmp` is made (mode 700) when missing and must be yours alone: owned by you, not a link, not writable by group or others, no ACL (when the server cannot tell, it refuses the folder). Only the folder itself is checked, so choose one under folders that only you and root can change, such as your home folder. Running `--enable` again for a host changes only the options you give. An upload deletes only images of its own `--keep` that are older than it; the name says which (`ssh-paste-k7d-<hash>.png`, no mark for the default), so images that one host keeps longer are never deleted by another. Deletion happens during an upload, so images stay at least that long.


### Update and remove

| Installed with | Update | Remove |
|---|---|---|
| `install.ps1` or `install.sh` | `ssh-paste --update`, or run the installer again | `ssh-paste --uninstall` |
| Scoop | `scoop update ssh-paste` | `scoop uninstall ssh-paste` |
| Homebrew | `brew upgrade ssh-paste` | `ssh-paste --uninstall`, then `brew uninstall ssh-paste` |

Under Scoop and Homebrew, `--update` and `--uninstall` print the package manager's command, and `--enable` writes a path that updates keep (`apps\ssh-paste\current`, or Homebrew's `opt` path). `scoop uninstall` runs `--disable` itself; with Homebrew run `ssh-paste --uninstall` first, or ssh keeps calling the removed command. With Scoop's `no_junction` setting, `--enable` refuses: use wrapper mode.

Uploaded images stay in the server's `/tmp` (or your `--dir` folder). To delete yours from `/tmp`:

```powershell
ssh myhost "rm -f /tmp/ssh-paste-*"
```

<details>
<summary>If ssh-paste does not run, or manual removal</summary>

Windows, through the installer (after the first line, run `Remove-Item Env:SSH_PASTE_UNINSTALL` before installing again):

```powershell
$env:SSH_PASTE_UNINSTALL = 1; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
& ([scriptblock]::Create((irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1))) -Uninstall
```

From a clone: `powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall`.

macOS: `sh ~/.local/share/ssh-paste/install.sh --uninstall`, or `curl -fsSL https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.sh | sh -s -- --uninstall`. `SSH_PASTE_UNINSTALL=1` works like `--uninstall`; unset it before installing again.

By hand: delete the `# >>> ssh-paste` block in `~/.ssh/config`. Windows: remove `%LOCALAPPDATA%\Programs\ssh-paste` from your `Path` (Start > `"Edit environment variables for your account"`), then `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\ssh-paste"`. macOS: delete the `# >>> ssh-paste PATH` block in your profiles and `~/.local/share/ssh-paste`.

</details>

## Requirements

- **Windows 10 or 11** with the built-in PowerShell 5.1 (works alongside 7), and Windows Terminal (recommended) or the classic console.
- **OpenSSH client** (`ssh.exe`/`ssh`); the installers check for it. On Windows add `"OpenSSH Client"` in **Settings > System > Optional features** (or as administrator: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`).
- **Key login without a prompt:** uploads run `ssh` with `BatchMode=yes`, so password-only logins fail. Use a key without a passphrase, or `ssh-agent`:

  ```powershell
  # once, in PowerShell as Administrator: start the agent now and at every boot
  Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service
  # then, as yourself: add your key (asks the passphrase once)
  ssh-add
  ```

- **Server:** `sh`, `cat`, `wc`, `find`, `cmp`, `mv`, `mktemp` and a writable `/tmp` (`bash`, `zsh`, `fish`, `tcsh` login shell).

## macOS

The same commands, with Cmd+V. A zsh launcher (`ssh-paste-mac`) and a JavaScript file (`ssh-paste.js`) run by `osascript`; it needs nothing beyond macOS (`ssh`, `nc`, `curl`, `shasum`). See [What it changes on your computer](#what-it-changes-on-your-computer).

- **ssh mode:** the `ProxyCommand` is `'~/.local/share/ssh-paste/bin/ssh-paste' --proxy '%h' %p '%n'` with your home folder spelled out (`'/opt/homebrew/opt/ssh-paste/libexec/bin/ssh-paste'` from Homebrew, kept by `brew upgrade`); it relays with `nc`. Options are read from `ps`, so a value with a space (`-i "/path/with space"`) needs wrapper mode. Uploads go to the relay's host name; image bytes wait in a mode-700 folder in `$TMPDIR`. The watcher ignores `SIGHUP` so it can restore the plain image when the terminal closes.
- **Pasteboard entry:** the image, the path (a Cmd+V during the upload waits for it), `com.github.xuing.ssh-paste.owner`, and `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType`, which clipboard managers that follow nspasteboard.org skip. Finder copies become the first image plus the remote paths, and stay files for other apps.
- **Terminal:** found through the process tree, else `__CFBundleIdentifier` or `TERM_PROGRAM`. If `ssh-paste --doctor` cannot tell, set `SSH_PASTE_TERMINAL` to its bundle id (`com.googlecode.iterm2`).
- **Tested** in CI with Terminal.app on macOS 15 and 26. **Not tested:** a Mac used by a person, other terminals (iTerm2, Ghostty, WezTerm), and pasteboard privacy prompts, which a Mac with that setting may show.

## Known limitations

- **Focus is per window, not per tab.** While a session runs, every tab in its window pastes the path, and another SSH tab there may set it first. Use separate windows.
- **In ssh mode on Windows, the path may stay on the clipboard after exit**, because `ssh` ends the `ProxyCommand`; your next copy clears it.
- **Images copied with HTML lose the HTML:** Chrome's **Copy image** keeps only the image and the path.
- **ssh mode on Windows adds PowerShell startup time** to every connection to an enabled host (`scp`, `sftp` and `git` too).

## Troubleshooting

1. Run `ssh-paste --doctor myhost` (without `myhost` for local checks only); `FAIL` lines name the problem.
2. In ssh mode, `SSH_PASTE_DEBUG=1` turns on logging. On Windows the relay writes `ssh-paste debug:` lines to stderr (address, stdin/stdout, which side closed):

   ```powershell
   $env:SSH_PASTE_DEBUG = 1; ssh myhost
   Remove-Item Env:SSH_PASTE_DEBUG
   ```

   On macOS, `SSH_PASTE_DEBUG=1 ssh myhost` logs the watcher's decisions to `$TMPDIR/ssh-paste-debug.log`.
3. Run `ssh -v myhost`; a hang at `expecting SSH2_MSG_KEX_ECDH_REPLY` means the relay stopped forwarding.
4. File a [bug report](https://github.com/xuing/ssh-please-paste-picture/issues/new?template=bug_report.yml) with the output.

## Details

- **Other terminals:** the classic console works; WezTerm and Alacritty are best effort (`ssh-paste --doctor` prints `terminal: ...`).
- **Other CLIs:** Codex CLI, Gemini CLI and aider get the PNG path too; whether they attach it depends on the program (Claude Code does).
- **Another `ssh`:** set `SSH_PASTE_SSH` to its full path for wrapper mode, `--enable` and `--doctor` (Windows ssh mode uploads use the `ssh.exe` that started the relay).

<details>
<summary>Session filtering, uploads, retries, clipboard</summary>

- **Session filtering:** only interactive sessions watch the clipboard (from the arguments and `ssh -G`); `scp`, `sftp`, `git` and VS Code Remote-SSH pass through. Skips `-T`, `-N`, `-W`, `-f`, `-n`, `-s`, `-G`, `-V`, `-O`, `-Q`, non-`-t` commands (`ssh myhost ls`, `git`, `RemoteCommand`), `RequestTTY no`, `SessionType` not `default`, `StdinNull yes`; wrapper mode on an enabled host runs `ssh` directly.
- **Uploads:** up to 64 MB, when the session window comes to the front (polled every 250 ms), not on paste. A paste during the upload waits up to 30 seconds. Each image uploads once per session, again after 6 hours (or half of `--keep`, if shorter). A failure plays the Windows error sound once, retries every 30 seconds while in front (up to 30 minutes), and is summarized at exit. Missing or blocked APIs print `ssh-paste: screenshot paste is off: <reason>`; `ssh` still runs.
- **Clipboard:** entries with both an image and text or files (Excel, Word, Explorer) are skipped. Original screenshots stay in Win+V history; only the rewrites are excluded.

</details>

## Security

### Verify the download

Each release has `SHA256SUMS` and GitHub build attestations for `install.ps1`, `ssh-paste.ps1`, `ssh-paste.cmd`, `install.sh`, `ssh-paste-mac`, `ssh-paste.js`, `SHA256SUMS` (installs from `main` have neither). Release installs check their files against `SHA256SUMS`, and so do Scoop and Homebrew.

<details>
<summary>Check install.ps1 before running it</summary>

SHA-256 (`True` means it matches):

```powershell
$base = 'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download'
Invoke-WebRequest -UseBasicParsing -Uri "$base/install.ps1" -OutFile install.ps1
Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile SHA256SUMS
$want = (Select-String -Path SHA256SUMS -Pattern ' install\.ps1$').Line.Split(' ')[0]
(Get-FileHash install.ps1 -Algorithm SHA256).Hash -eq $want
```

Attestation, with the [GitHub CLI](https://cli.github.com/):

```powershell
gh attestation verify install.ps1 -R xuing/ssh-please-paste-picture
```

Then run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` (the bypass applies to that process only).

</details>

### What it changes on your computer

| Step | Change | Undone by |
|---|---|---|
| `install.ps1` | `%LOCALAPPDATA%\Programs\ssh-paste` (`ssh-paste.ps1`, `ssh-paste.cmd`; creates `Programs` if missing) and an entry in `HKCU\Environment\Path` | `--uninstall`, which also deletes an empty `Programs` or `Path` |
| Scoop | its app folder and shim | `scoop uninstall ssh-paste` |
| `install.sh` | `~/.local/share/ssh-paste` (`bin/ssh-paste`, `ssh-paste.js`, `install.sh`) and a marked `PATH` block atop `~/.zprofile` (and `~/.bash_profile`, `~/.bash_login` or `~/.profile` for bash) | `--uninstall`, which also deletes an empty `~/.local/share` and `~/.local`, and profiles it created |
| Homebrew | its keg and `$(brew --prefix)/bin/ssh-paste` | `brew uninstall ssh-paste` |
| `--enable` | a block atop `~/.ssh/config` (`%USERPROFILE%\.ssh\config`; creates the file and `.ssh` if missing) | `--disable` or `--uninstall`, which also deletes the config and `.ssh` if `ssh-paste` created them and they are empty |
| Windows clipboard | image, path, `SshPaste.Owner`, `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory=0`, `CanUploadToCloudClipboard=0` | the plain image comes back when you switch away or exit ([Known limitations](#known-limitations)); markers stay until your next copy |

No administrator rights, services, tasks, launch agents, login items, daemons, PowerShell profiles, or settings files (`--keep` and `--dir` live in the `--enable` block); Windows install and uninstall briefly set a user variable so new windows see the new `Path`. No passwords, keys or telemetry; downloads come only from `github.com` and `raw.githubusercontent.com`. On the server it writes only `ssh-paste-*` files in `/tmp` or your `--dir` folder.

### Files on the server

`/tmp/ssh-paste-<hash>.png` (first 128 bits of the PNG's SHA-256, hex), or the same name in the `--dir` folder, mode 600, with `k<keep>-` before the hash for a `--keep` other than the default; `ssh-paste-<hash>-<uid>.png` if another user owns that name. An identical file is reused. Each upload deletes your own such files of its `--keep` older than it (a day by default). Nothing runs between uploads or after uninstall; the OS clears `/tmp` (often at reboot).

<details>
<summary>Antivirus and policy limits</summary>

- It stops under Group Policy (`AllSigned` or `Restricted`) and in Constrained Language mode (AppLocker or App Control); `ssh-paste --doctor` reports it.
- The C# that `Add-Type` compiles at run time may trigger scanners; the plain-text script is in `%LOCALAPPDATA%\Programs\ssh-paste`.
- Defender false positives: <https://www.microsoft.com/en-us/wdsi/filesubmission>.

</details>

Report security issues privately, as [SECURITY.md](SECURITY.md) describes.

## Alternatives

| Tool | Needs | Paste |
|---|---|---|
| ssh-please-paste-picture | one script, active only in a session; nothing on the server | Ctrl+V / Cmd+V, uploads on window switch |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) (`/rc`) | Claude Code with Pro, Max, Ultra, Team or Enterprise (not an API key); browser or Claude app | attach in the browser or app |
| [clipaste](https://github.com/hqhq1025/clipaste) | Rust daemon; xclip / wl-paste shim, `clipaste-paste` and curl on the server; `RemoteForward` | Ctrl+V |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | Go hotkey process (Windows experimental) | Alt+Shift+V (scp) |
| [img2ssh](https://github.com/bulletsrip/img2ssh) | Go daemon at login; uploads every copied image | Ctrl+V |
| [claude-ssh-image-paste](https://github.com/devonjones/claude-ssh-image-paste) | AutoHotkey v2, intercepts Ctrl+V | Ctrl+V, uploads on paste |

<details>
<summary>Development</summary>

Files are ASCII and run on PowerShell 5.1 and 7. Open an issue before a pull request. The macOS client's logic: `node --test tests/mac/unit.test.js`; the rest of `tests/mac` runs in macOS CI. See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/RELEASING.md](docs/RELEASING.md). Before each commit:

```powershell
pwsh ./check.ps1
```

</details>

## License

[MIT](LICENSE)
