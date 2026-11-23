# Notes for coding agents

ssh-paste lets Windows Terminal users paste a screenshot into a program that runs over SSH.
One PowerShell script, `src/ssh-paste.ps1`, watches the clipboard during an SSH session.
When the terminal is in front, it uploads the image to `/tmp` on the server and puts the remote path on the clipboard.
`install.ps1` installs it per user, and `src/ssh-paste.cmd` is the `ssh-paste` command.

## Hard constraints

- Every `.ps1`, `.psd1`, `.cmd`, `.sh` and `.yml` file is ASCII. Windows PowerShell 5.1 reads a file without a BOM as ANSI, so one non-ASCII byte breaks the script on user machines.
- Code parses and runs on Windows PowerShell 5.1 and on PowerShell 7. Do not use `??`, `?.`, the ternary operator, `&&` or `||` in scripts.
- In `--proxy` mode, stdout is the SSH byte stream. Write messages to `[Console]::Error` only, never with `Write-Host` or `Write-Output`.
- Code that only runs on Windows (clipboard, windows, P/Invoke, the relay under Win32-OpenSSH, the launcher) needs a Windows run before you call it done. Linux tests cannot reach it. If you could not run it, the commit says so under "Not run:".

## Read first

- [LESSONS.md](LESSONS.md) before you change code: what earlier work got wrong and the rule that would have caught it.
- [docs/code-standards.md](docs/code-standards.md) when you write or review a change. Its acceptance checks are the bar.
- [SECURITY.md](SECURITY.md) before you touch `install.ps1`, anything under `.github/` (the release workflows and scripts), a download URL, the upload, or anything that sends data over the network.
- [CONTRIBUTING.md](CONTRIBUTING.md) before you review a PR from outside, and for the commit convention.
- [docs/RELEASING.md](docs/RELEASING.md) before you change how a release is made. Releases are automatic: a green commit on `main` that changes `src/` or `install.ps1` becomes `v0.1.<n>`, and its subject is the release note.

## Where things live

| Path, then section or function | Commit area | What it does |
| --- | --- | --- |
| `src/ssh-paste.ps1`, constants at the top | upload | `$script:RemoteScript` (the `sh` command that runs on the server), the ssh option tables |
| `src/ssh-paste.ps1`, "Pure helpers" | proxy, upload, enable | `Split-SshArguments`, `Test-InteractiveSsh`, `Get-UploadSshArguments`, `Get-TrimmedPng`, `ConvertFrom-DropFiles`, `Read-UploadReply`, `Get-ManagedBlock`, `Set-ManagedBlock`. No Windows API, so tests cover them on any OS. |
| `src/ssh-paste.ps1`, "Windows integration" | watcher, upload | `Initialize-Native` (P/Invoke), `Test-HostForeground`, `Read-ClipboardImage`, `Set-SshPasteClipboard`, `Send-Image` |
| `src/ssh-paste.ps1`, "Clipboard watcher" | watcher | `New-Watcher`, `Invoke-WatcherTick` (one tick every 250 ms), `Sync-ClipboardText`, `Restore-Clipboard` |
| `src/ssh-paste.ps1`, "Commands" | proxy, enable, install | `Invoke-Wrapper`, `Invoke-Proxy` (the ProxyCommand relay), `Update-SshConfig`, `Invoke-Enable`, `Invoke-Disable`, `Invoke-Doctor`, `Invoke-Uninstall`, `Invoke-Main` |
| `install.ps1` | install | `Get-SourceFiles` (download or use the clone's `src`), the user PATH in the registry, `Invoke-Install`, `Invoke-Removal` |
| `src/ssh-paste.cmd` | install | The launcher. `--uninstall` ends the batch context with `(goto)` before the script deletes the file. |
| `tests/ssh-paste.Tests.ps1` | tests | Pester 5, one `Describe` per function. Tags: `Windows`, `Unix`, `E2E`. |
| `tests/e2e-linux.sh` | tests | Starts a throwaway `sshd` on 127.0.0.1 and runs the `E2E` tests against it. |
| `tests/footprint.ps1` | tests | Windows only. Installs, enables, disables and uninstalls on the real profile, then compares snapshots. |
| `tests/lint.ps1`, `check.ps1` | tests, ci | The lint checks, and the one local entry point that runs them with Pester. |
| `verify/watcher/` | watcher | A TLA+ model of the clipboard watcher and `check.sh`, which model-checks it with TLC. Run it for any change to the watcher or `PendingClipboard`: [.claude/skills/verify-clipboard-watcher/SKILL.md](.claude/skills/verify-clipboard-watcher/SKILL.md). |
| `.github/workflows/ci.yml`, `publish.yml`, `.github/scripts/*.sh` | ci, release | CI on 5.1, 7 on Windows and 7 on Linux. `ci.yml` releases a green push to `main` (or a manual run on `main`) through `publish.yml`, which tags, builds, attests and publishes. The scripts pick the version, write the notes and stamp the version. |

## Commands

- `pwsh ./check.ps1` runs the lint checks and the Pester unit tests. Run it before every commit.
- `pwsh ./check.ps1 -E2E` adds `tests/e2e-linux.sh` (Linux, needs `sshd`). `-Footprint` adds `tests/footprint.ps1` (Windows only, edits the real user profile and restores it).
- `Invoke-Pester tests/ssh-paste.Tests.ps1 -ExcludeTagFilter E2E` runs only the unit tests. Run the whole file, not one `Describe`.
- `bash verify/watcher/check.sh` model-checks the clipboard watcher (needs Java 11+, 2-3 minutes). Run it when you change the watcher, the clipboard writes or the promise.
- Pester on Windows PowerShell 5.1 and the footprint rounds run in CI. Read the CI run on your commit for those.

## Docs travel with the code

A change that a user can see updates both `README.md` and `README.zh-CN.md` in the same commit. There is no changelog: the commit subject is the release note, so it says what the user now sees (`area: user-visible effect`). `$script:Version` in `src/ssh-paste.ps1` stays `0.0.0-dev`; a release stamps its own version into the copy it publishes.

## The maintenance loop

Every commit that changes `src/` is released at once, so there is no release day to wait for. Each time you pick the work up, read every commit after the `reviewed-through` marker at the top of LESSONS.md (`git log --stat <marker>..HEAD`, full messages).
For each fix that needed a second try, a change that should not have shipped, or a check that was too thin, add a lesson or add a sighting to an existing one.
A lesson seen 3 times moves into docs/code-standards.md. Then set the marker to the commit you reviewed through.

## Debugging on a user's machine

- `ssh-paste --doctor HOST` checks PowerShell, the clipboard and window APIs, `ssh`, the terminal, and one real upload to HOST.
- `$env:SSH_PASTE_DEBUG = 1` makes the `--proxy` relay report each step on stderr.
- `ssh -v HOST` shows where the connection stops. For example, a hang at `expecting SSH2_MSG_KEX_ECDH_REPLY` means the relay stopped forwarding (70db0c0).
