# ssh-please-paste-picture

[![CI](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml/badge.svg)](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/xuing/ssh-please-paste-picture)](https://github.com/xuing/ssh-please-paste-picture/releases/latest)
[![License: MIT](https://img.shields.io/github/license/xuing/ssh-please-paste-picture)](LICENSE)

English | [简体中文](README.zh-CN.md)

Press Ctrl+V in Windows Terminal, or Cmd+V in Terminal on macOS, to paste a screenshot into remote Claude Code over SSH.
One script on your computer (`ssh-paste`). Nothing is installed on the server.

## Quick start

**1. Install** in PowerShell, not cmd (no administrator rights needed):

```powershell
irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

Works in that window right away; open a new tab for others. Re-run to upgrade.

**On macOS**, in Terminal (uses only what macOS ships; see [macOS](#macos)), then open a new tab:

```sh
curl -fsSL https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.sh | sh
```

<details>
<summary>More install options (main branch, download first, specific version, policy limits)</summary>

Newest commit on main:

```powershell
irm https://raw.githubusercontent.com/xuing/ssh-please-paste-picture/main/install.ps1 | iex
```

If antivirus flags `irm ... | iex`, download and verify `install.ps1` first (see Security).

**Pick a version.** Set `SSH_PASTE_REF` or pass `-Ref` for another tag, branch, or commit from `raw.githubusercontent.com`:

```powershell
$env:SSH_PASTE_REF = 'v0.1.0'; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

From a repository clone, `powershell -ExecutionPolicy Bypass -File install.ps1` installs its `src` folder. Stops under Group Policy (`AllSigned` or `Restricted`) or Constrained Language mode (AppLocker or App Control); running as administrator installs for the elevated account.

</details>

**2. Enable a host once:**

```powershell
ssh-paste --enable myhost
```

**3. Connect and paste** with `ssh myhost`:

1. Copy a screenshot (Win+Shift+S; Cmd+Ctrl+Shift+4 on macOS) or image files (png, jpg, jpeg, gif, webp, bmp).
2. Switch to your SSH terminal window.
3. `ssh-paste` uploads to `/tmp/ssh-paste-<hash>.png`.
4. Press Ctrl+V (Cmd+V on macOS) to paste the path into Claude Code.

Other apps still paste the image. `ssh-paste` runs only while the session is open.

## Use

### ssh mode (recommended)

`ssh-paste --enable myhost` puts a managed block at the top of `%USERPROFILE%\.ssh\config` so plain `ssh myhost` pastes screenshots. Use a `Host` alias or plain host name without `user@` or options (multiple: `ssh-paste --enable host1 host2`). `--enable` refuses hosts that already use `ProxyJump` or `ProxyCommand`; use wrapper mode instead.

```powershell
ssh-paste --disable myhost   # one host
ssh-paste --disable          # all hosts: removes the whole block
```

<details>
<summary>Generated ~/.ssh/config block and how ssh mode works</summary>

```
# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>
Host myhost
    ProxyCommand C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Users\you\AppData\Local\Programs\ssh-paste\ssh-paste.ps1" --proxy %h %p %n
    ProxyUseFdpass no
Host *
# <<< ssh-paste <<<
```

`ssh` runs `ssh-paste` as `ProxyCommand` to relay SSH bytes unchanged and watch interactive sessions (`Host *` ends the block). Reads `ssh.exe` options, uploads to the relay's IP address, and checks the host key under the session's name (`-J` works in wrapper mode, dropped in ssh mode). See [SECURITY.md](SECURITY.md).

</details>

### wrapper mode (no config)

Run `ssh-paste` instead of `ssh`:

```powershell
ssh-paste myhost
ssh-paste -p 2222 -J bastion me@myhost
ssh-paste -t myhost claude
```

Runs `ssh.exe` with the same arguments and watches the clipboard. All `ssh` options and jump hosts work; remote commands without `-t` (`ssh-paste myhost ls`) run as plain `ssh`.

### All commands

```
ssh-paste --enable HOST [HOST...]   make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)
ssh-paste --disable [HOST...]       undo --enable (all hosts if none given)
ssh-paste [ssh options] HOST        wrapper mode: ssh with screenshot paste, no config
ssh-paste --doctor [HOST]           check this computer and test an upload to HOST
ssh-paste --update                  install the latest release
ssh-paste --uninstall               remove ssh-paste and everything it changed
ssh-paste --version | --help
```

## macOS

The same commands work on macOS, with one difference in what you press: Cmd+V. `ssh-paste` there is a zsh launcher and one JavaScript file run by `osascript`, so it needs nothing beyond macOS itself (zsh, `osascript`, `ssh`, `nc`, `curl`, `shasum`). In ssh mode the `ProxyCommand` is `'~/.local/share/ssh-paste/bin/ssh-paste' --proxy '%h' %p '%n'` (with your home folder spelled out), which relays the connection with `nc`.

- **Install** puts `bin/ssh-paste`, `ssh-paste.js` and `install.sh` in `~/.local/share/ssh-paste` and a marked `PATH` block at the top of `~/.zprofile` (and of `~/.bash_profile`, `~/.bash_login` or `~/.profile`, whichever bash reads, when your login shell is bash). No launch agents or login items. `ssh-paste --uninstall`, or `curl -fsSL .../install.sh | sh -s -- --uninstall`, removes exactly that, the `--enable` block, and empty `~/.local/share` and `~/.local`. Options: `--ref <tag|branch|commit>` (or `SSH_PASTE_REF`), `--uninstall` (or `SSH_PASTE_UNINSTALL=1`).
- **The pasteboard entry** holds the image, the path (promised: a Cmd+V during the upload waits for it), a private `com.github.xuing.ssh-paste.owner` type, and `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType`, which clipboard managers that follow nspasteboard.org skip. Image files copied in Finder are offered as the first image plus the remote paths, and come back as files when another app is in front.
- **Differences from Windows.** You open a new tab after installing. The terminal is found through the process tree, else `__CFBundleIdentifier` or `TERM_PROGRAM`; set `SSH_PASTE_TERMINAL` to its bundle id (`com.googlecode.iterm2`) when `ssh-paste --doctor` says it cannot tell. Focus is per window, as on Windows. In ssh mode the plain image comes back when the session ends, and uploads connect to the host name the relay used (not its IP address), checking the host key under the session's name. In ssh mode the session's `ssh` options are read from `ps`, so an option value with a space in it (`-i "/path/with space"`) makes the session look non-interactive: use wrapper mode for it.
- **Tested** in CI with Terminal.app on macOS 15 and 26 (GitHub runners): paste during an upload, a failed upload, a paste in another app, Finder copies, ssh mode and wrapper mode against a real `sshd`, and install and uninstall leaving the home folder as it was. **Not tested:** a Mac used by a person, iTerm2, Ghostty, WezTerm and other terminals, and macOS pasteboard privacy prompts (`osascript` reading the pasteboard did not ask on the test machines; a Mac with pasteboard privacy turned on may ask).
- **Debugging:** `SSH_PASTE_DEBUG=1 ssh myhost` logs the watcher's decisions to `$TMPDIR/ssh-paste-debug.log`.

## Requirements

- **Windows 10 or 11.** Built-in Windows PowerShell 5.1 (works alongside PowerShell 7).
- **Windows Terminal** (recommended) or classic console.
- **OpenSSH client (`ssh.exe`).** Required by the installer; add `"OpenSSH Client"` under **Settings > System > Optional features** if missing.
- **Key login without a prompt.** Uploads use non-interactive `ssh` (`BatchMode=yes`), so password-only logins fail. Use a key without a passphrase or `ssh-agent`:

  ```powershell
  # once, in PowerShell as Administrator: start the agent now and at every boot
  Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service
  # then, as yourself: add your key (asks the passphrase once)
  ssh-add
  ```

- **Server tools.** `sh`, `cat`, `wc`, `find`, `cmp`, `mv`, `mktemp`, writable `/tmp` (`bash`, `zsh`, `fish`, or `tcsh` login shell).

## Known limitations

- **Focus is per Windows Terminal window, not per tab.** Every tab in that window (including local tabs) pastes the path while a session runs; another SSH tab also uploads, and whichever session writes first sets the path. Use separate windows.
- **In ssh mode, the clipboard may keep the path after exit.** `ssh` terminates `ProxyCommand` on close, so `ssh-paste` may not restore the plain image; your next copy clears it.
- **Images copied with HTML lose the HTML.** Chrome's **Copy image** keeps only image and path after `ssh-paste` rewrites it.
- **ssh mode adds PowerShell startup time to every connection to an enabled host** (including `scp`, `sftp`, and `git`).

## Troubleshooting

1. Run `ssh-paste --doctor myhost` (omit `myhost` for local checks); `FAIL` lines name the problem.
2. In ssh mode, set `SSH_PASTE_DEBUG=1` for `ssh-paste debug:` stderr logs (address, stdin/stdout, close side):

   ```powershell
   $env:SSH_PASTE_DEBUG = 1; ssh myhost
   Remove-Item Env:SSH_PASTE_DEBUG
   ```

3. Run `ssh -v myhost` (hang at `expecting SSH2_MSG_KEX_ECDH_REPLY` means the relay stopped forwarding).
4. File a [bug report](https://github.com/xuing/ssh-please-paste-picture/issues/new?template=bug_report.yml) with the output.

## Security

### Verify the download

Releases include `SHA256SUMS` and a GitHub build attestation for `install.ps1`, `ssh-paste.ps1`, and `ssh-paste.cmd`, and for the macOS `install.sh`, `ssh-paste-mac`, and `ssh-paste.js` (`main` has neither). The macOS installer checks the files it downloads against `SHA256SUMS`.

<details>
<summary>Verify install.ps1 before running</summary>

Check SHA-256 (`True` matches):

```powershell
$base = 'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download'
Invoke-WebRequest -UseBasicParsing -Uri "$base/install.ps1" -OutFile install.ps1
Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile SHA256SUMS
$want = (Select-String -Path SHA256SUMS -Pattern ' install\.ps1$').Line.Split(' ')[0]
(Get-FileHash install.ps1 -Algorithm SHA256).Hash -eq $want
```

[GitHub CLI](https://cli.github.com/) attestation:

```powershell
gh attestation verify install.ps1 -R xuing/ssh-please-paste-picture
```

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` (`-ExecutionPolicy Bypass` affects only that process).

</details>

### What it changes on your computer

| Step | Change | Reverted by |
|---|---|---|
| Install | `%LOCALAPPDATA%\Programs\ssh-paste` (`ssh-paste.ps1`, `ssh-paste.cmd`; creates `%LOCALAPPDATA%\Programs` if missing) | `--uninstall` deletes folder (and `%LOCALAPPDATA%\Programs` if empty) |
| Install | User PATH entry (`HKCU\Environment\Path`) | `--uninstall` removes entry (and `Path` if empty) |
| `--enable` | Top block in `%USERPROFILE%\.ssh\config` (creates file and `.ssh` if missing) | `--disable` or `--uninstall` remove block; deletes config if `ssh-paste` created it and empty (and `.ssh` if empty) |
| Session | Rewrites image entry: image, path text, private `SshPaste.Owner` format, `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory=0`, `CanUploadToCloudClipboard=0` (out of Win+V history and cloud clipboard) | App switch or exit restores image without path text (see [Known limitations](#known-limitations) for ssh mode); `SshPaste.Owner` and three flags remain until next copy |

No services, scheduled tasks, startup entries, profile edits, or settings files. Install and uninstall set and clear a temporary user variable so Windows refreshes `PATH` in new windows. Server: only `/tmp/ssh-paste-*.png`.

### Files on the server

- `/tmp/ssh-paste-<hash>.png` (first 128 bits of PNG SHA-256 in hex), mode 600; `/tmp/ssh-paste-<hash>-<uid>.png` if owned by another user.
- Identical existing files are reused and their age reset.
- Cleanup runs only on a later upload by the same user on the same server, deleting their `ssh-paste-<hash>.png` and temp files older than a day.
- Nothing runs between uploads or after uninstall; OS clears `/tmp` on schedule (often at reboot).

### Antivirus and policies

- Runtime C# via `Add-Type` (clipboard and window APIs) may trigger scanners; plain-text script lives in `%LOCALAPPDATA%\Programs\ssh-paste`.
- Microsoft Defender false positives: <https://www.microsoft.com/en-us/wdsi/filesubmission>.
- AppLocker or App Control Constrained Language mode blocks clipboard access (`ssh-paste --doctor` reports it).
- Security issues: report privately per [SECURITY.md](SECURITY.md).

## Uninstall

```powershell
ssh-paste --uninstall
```

Removes `--enable` block, `PATH` entry, and install folder. Does not touch servers (images stay until `/tmp` clears); delete yours with:

```powershell
ssh myhost "rm -f /tmp/ssh-paste-*"
```

<details>
<summary>If ssh-paste does not run, or manual removal</summary>

Via installer (run `Remove-Item Env:SSH_PASTE_UNINSTALL` after the first line before reinstalling in that window):

```powershell
$env:SSH_PASTE_UNINSTALL = 1; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
& ([scriptblock]::Create((irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1))) -Uninstall
```

Manual removal:

1. Delete `# >>> ssh-paste` through `# <<< ssh-paste <<<` in `%USERPROFILE%\.ssh\config`.
2. Start > `"Edit environment variables for your account"` > `Path` > **Edit** > remove `%LOCALAPPDATA%\Programs\ssh-paste`.
3. `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\ssh-paste"`.

</details>

## Details

- **Other terminals.** Classic console works; WezTerm and Alacritty are best effort (`ssh-paste --doctor` prints `terminal: ...`).
- **Other CLI programs.** Pastes a server PNG path for Codex CLI, Gemini CLI, and aider too; attachment depends on the program (Claude Code supports it).
- **Another `ssh.exe`.** Set `SSH_PASTE_SSH` to its full path for wrapper mode, `--enable`, and `--doctor` (ssh mode uploads use the `ssh.exe` that started the relay).

<details>
<summary>Session filtering, upload timing, retries, and clipboard internals</summary>

- **Session filtering:** Only interactive sessions watch the clipboard (via arguments and `ssh -G`; `scp`, `sftp`, `git`, and VS Code Remote-SSH pass through). Skips `-T`, `-N`, `-W`, `-f`, `-n`, `-s`, `-G`, `-V`, `-O`, `-Q`, remote commands without `-t` (`ssh myhost ls`, `git`, `RemoteCommand`), `RequestTTY no`, `SessionType` not `default`, `StdinNull yes`. Wrapper mode on ssh-mode hosts runs `ssh` directly.
- **Uploads & retries:** Polls every 250 ms; uploads up to 64 MB when the session window is in front (not on Ctrl+V). Ctrl+V mid-upload waits up to 30 seconds (nothing pasted on failure). Uploads once per image per session (re-uploads after 6 hours). Failures play the Windows error sound once per image, retry when in front, and summarize at exit (`ssh` may terminate `ProxyCommand` first). Missing or blocked APIs print `ssh-paste: screenshot paste is off: <reason>` and run as plain `ssh` or relay.
- **Clipboard:** Skips entries with both an image and text or files (Excel, Word, Explorer). Original screenshots stay in Win+V history; only `ssh-paste` rewrites are excluded.

</details>

## Alternatives

| Tool | On Windows | On the server | Runs in the background | Paste key |
|---|---|---|---|---|
| ssh-please-paste-picture | one PowerShell script | nothing | nothing; only during a session | Ctrl+V |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) (`/rc`) | nothing; claude.ai/code or Claude app | nothing extra | Claude Code session | attach in browser or app |
| [clipaste](https://github.com/hqhq1025/clipaste) | Rust daemon | xclip / wl-paste shim, `clipaste-paste` (need curl); `RemoteForward` in ssh config | local daemon | Ctrl+V |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | Go binary (Windows experimental) | nothing for Windows hotkey (scp); Ctrl+V shim and tunnel experimental on Windows | hotkey process (optional autostart) | Alt+Shift+V |
| [img2ssh](https://github.com/bulletsrip/img2ssh) | Go binary | nothing | Task Scheduler daemon from login; uploads every copied image | Ctrl+V |
| AutoHotkey scripts, e.g. [claude-ssh-image-paste](https://github.com/devonjones/claude-ssh-image-paste) | AutoHotkey v2 and script | nothing | AutoHotkey, intercepts Ctrl+V | Ctrl+V |

Remote Control works only with Claude Code, needs a Pro, Max, Ultra, Team, or Enterprise plan (not an API key), and moves you from the terminal to a browser or the Claude app. AutoHotkey scripts upload on Ctrl+V; `ssh-paste` uploads when you switch to the session window.

## Development

Files must stay ASCII-only and run on Windows PowerShell 5.1 and PowerShell 7. Open an issue before opening a pull request. The macOS client's logic has node tests (`node --test tests/mac/unit.test.js`); the rest of `tests/mac` runs on the macOS CI runners.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the other test suites, pull request checks, and the commit convention, and [docs/RELEASING.md](docs/RELEASING.md) for releases. Run lint checks and unit tests before each commit:

```powershell
pwsh ./check.ps1
```

## License

[MIT](LICENSE)
