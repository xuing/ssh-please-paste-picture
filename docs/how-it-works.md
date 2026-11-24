# How ssh-paste works

English | [简体中文](how-it-works.zh-CN.md)

## The problem

Claude Code (or Codex CLI, Gemini CLI, aider) runs on a server you reach over SSH. You take a screenshot on your own computer. The screenshot is on your clipboard, but the program on the server can only read files on the server, and a terminal sends text over SSH, never images. So Ctrl+V gives the program nothing it can use.

## The idea

Put the image on the server first, then paste its path instead of the image.

```
your computer                                  the server
-------------                                  ----------
1. copy a screenshot
2. switch to the ssh window  ── upload ──►     /tmp/ssh-paste-<hash>.png
   ssh-paste puts that path
   on the clipboard, next to the image
3. press Ctrl+V              ── the path ──►   Claude Code opens the file
```

Programs other than the terminal still paste the image: the clipboard holds both, and each program takes what it understands.

## What happens, step by step

1. **It only runs while you are connected.** When an interactive `ssh` session starts, ssh-paste starts watching the clipboard. When the session ends, it stops. `scp`, `sftp` and `git` over SSH never get it: in ssh mode their connections only pass through ssh-paste's relay, which forwards the bytes unchanged.
2. **It waits until you switch to that window.** Only then does it upload the image. That is why Ctrl+V is instant: the upload is usually done before you press it, and a paste during the upload waits for it (up to 30 seconds).
3. **It uploads over a second, separate ssh connection,** with your own keys and settings, to the same server as the session. (On macOS in wrapper mode it opens a channel on the connection you logged in to instead, so a server that asks for a password asks only once.) It sends the image bytes and nothing else. The server needs only `sh` and a few standard tools; nothing is installed there.
4. **The file is named after its content** (a hash of the image), so the same screenshot is uploaded once, and two users with the same image never overwrite each other's files.
5. **When you switch away or disconnect,** the clipboard goes back to the plain image. (In ssh mode on Windows, `ssh` ends the relay at once, so the path can stay until your next copy.)

There are two ways to start it:

- **ssh mode** (`ssh-paste --enable myhost`): a marked block in `~/.ssh/config` makes plain `ssh myhost` start ssh-paste, which passes the connection through unchanged.
- **wrapper mode** (`ssh-paste myhost`): runs `ssh` for you, with no config change.

## What it does not do

- It installs nothing on the server, and runs nothing there between uploads.
- It runs no background service, scheduled task, launch agent or login item on your computer. When no session is connected, nothing of it runs.
- It uploads only images, only to the servers of the sessions in the window in front, and only while they run. Text on your clipboard is never sent.
- It keeps no passwords or keys, and sends no telemetry. Its only settings are the marked block in your ssh config. It downloads only from GitHub, and only when you install or update.
- It needs no administrator rights.

## Kept clean on your computer

- **One small, readable program.** On Windows it is one PowerShell script (about 2,300 lines) and a 9-line launcher; on macOS one JavaScript file run by the built-in `osascript` (about 2,000 lines) and a zsh launcher. Nothing is compiled, so you can read what runs.
- **Built-in tools only.** Windows PowerShell 5.1 and OpenSSH on Windows; zsh, `osascript`, `ssh` and `nc` on macOS.
- **Every change is listed and undone exactly.** The installer adds one folder and one `PATH` entry; `--enable` adds one marked block to your ssh config. `--uninstall` removes exactly those, and leaves the rest of your ssh config and profiles as they were (except that a config file mixing CRLF and LF line endings ends up with CRLF throughout). CI installs, enables, disables and uninstalls on Windows and macOS runners and checks that the profile is the same as before.
- **Your choice of installer:** the one-line script, [Homebrew](https://brew.sh) or [Scoop](https://scoop.sh).

## Kept clean and safe on the server

- One file per image, readable only by you (mode 600), in `/tmp` or a folder you choose with `--dir`.
- A folder other than `/tmp` must be yours alone (owned by you, not a link, not writable by others), or the server refuses it before writing anything.
- Each upload deletes only your own images of its own `--keep` that are older than it (one day unless you choose another time, or `never`); the file name says which `--keep` made it, so a host that keeps images longer is never cut short by another. It never touches files of other users or names it did not make.
- In a shared `/tmp`, other users can at most make an upload fail: ssh-paste never follows their symbolic links, never writes into their files, and checks that the path the server answers is the one it expects.

Details: [SECURITY.md](../SECURITY.md).

## How it is tested

Every change runs these checks on GitHub Actions before it can be released:

- unit tests (about 700 for the Windows script, run on Windows PowerShell 5.1, PowerShell 7 on Windows and on Linux, and about 240 for the macOS logic);
- end-to-end tests against a real `sshd` on Linux and on macOS 15 and 26, and a relay test with the real Windows OpenSSH;
- the install and uninstall footprint checks above, on Windows and macOS, and a real Scoop install, update and uninstall;
- a [TLA+](https://lamport.azurewebsites.net/tla/tla.html) model of the clipboard watcher, which a model checker explores state by state, so that, within the model, a paste never gets a path from another server or a path to a file whose upload has not finished.

Each release carries SHA-256 sums and GitHub build attestations for its files, and after each release CI installs it from the Homebrew tap on a Mac and from the Scoop bucket on Windows.

## Compared with other tools

| Tool | On your computer | On the server | Paste |
|---|---|---|---|
| **ssh-paste** | one script, runs only during a session | nothing | Ctrl+V / Cmd+V; uploads when you switch to the window |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) (`/rc`) | claude.ai/code or the Claude app; Claude Code only, with Pro, Max, Ultra, Team or Enterprise (not an API key) | nothing extra | attach in the browser or app |
| [clipaste](https://github.com/hqhq1025/clipaste) | Rust daemon | xclip / wl-paste shim, `clipaste-paste` and curl; `RemoteForward` | Ctrl+V |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | Go hotkey process (Windows experimental) | nothing for the Windows hotkey (scp) | Alt+Shift+V |
| [img2ssh](https://github.com/bulletsrip/img2ssh) | Go daemon from login; uploads every copied image | nothing | Ctrl+V |
| [claude-ssh-image-paste](https://github.com/devonjones/claude-ssh-image-paste) | AutoHotkey v2, intercepts Ctrl+V | nothing | Ctrl+V; uploads on paste |

Choose ssh-paste if you want to keep using your terminal and plain `ssh`, install nothing on servers, and have nothing running when you are not connected. Its limits are in the README: [Known limitations](../README.md#known-limitations).
