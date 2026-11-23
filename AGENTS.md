# Notes for coding agents

ssh-paste lets Windows Terminal and macOS terminal users paste a screenshot into a program that runs over SSH.
One PowerShell script, `src/ssh-paste.ps1`, watches the clipboard during an SSH session on Windows; `src/ssh-paste.js` (JavaScript for Automation, run by `osascript`) does the same on macOS.
When the terminal is in front, it uploads the image to `/tmp` on the server and puts the remote path on the clipboard.
`install.ps1` installs the Windows client per user, and `src/ssh-paste.cmd` is its `ssh-paste` command. `install.sh` installs the macOS client, and `src/ssh-paste-mac` is its `ssh-paste` command.

## Hard constraints

- Every `.ps1`, `.psd1`, `.cmd`, `.sh`, `.yml`, `.js` and `.json` file and `src/ssh-paste-mac` is ASCII. Windows PowerShell 5.1 reads a file without a BOM as ANSI, so one non-ASCII byte breaks the script on user machines.
- Code parses and runs on Windows PowerShell 5.1 and on PowerShell 7. Do not use `??`, `?.`, the ternary operator, `&&` or `||` in scripts.
- In `--proxy` mode, stdout is the SSH byte stream. Write messages to `[Console]::Error` only, never with `Write-Host` or `Write-Output`.
- Code that only runs on Windows (clipboard, windows, P/Invoke, the relay under Win32-OpenSSH, the launcher) needs a Windows run before you call it done. Linux tests cannot reach it. If you could not run it, the commit says so under "Not run:".
- The same holds for the macOS client: the pasteboard, windows, `osascript`, the launcher and `install.sh` need the macOS CI jobs (`tests/mac/*.sh` on macOS 15 and 26). They use Terminal.app on a GitHub runner, so a run on a Mac that a person uses, and other terminals, go under "Not run:".
- The two clients make the same decisions. A change to the watcher, the upload, the server script or the ssh argument rules goes into both `src/ssh-paste.ps1` and `src/ssh-paste.js` in the same commit; `tests/cases.json` holds the test tables both test suites read, and `tests/mac/unit.test.js` fails when the server script, the ssh option tables or the markers differ.

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
| `src/ssh-paste.js`, "Pure helpers" | proxy, upload, enable | The macOS client's twins of the pure helpers above (`splitSshArguments`, `testInteractiveSsh`, `uploadSshArguments`, `readUploadReply`, `getManagedBlock`, `setManagedBlock`), plus `proxyCommandLine`, the pasteboard marker and `doctorPng`. No macOS API; node tests them. |
| `src/ssh-paste.js`, "Clipboard watcher" | watcher | `watcherTick` and its helpers: the decisions of `Invoke-WatcherTick` against a platform object `P`. An upload runs as a child process, so a tick that starts one returns and later ticks finish it (`W.Inflight`). |
| `src/ssh-paste.js`, "macOS integration" | watcher, upload | `macPlatform` (the pasteboard, the window list, uploads through `NSTask`, the promised text through `SshPasteProvider`), `findTerminal`, `runCapture` |
| `src/ssh-paste.js`, "Commands" | proxy, enable, install | `watchProxy`, `watchWrapper`, `enableHosts`, `disableHosts`, `doctor`, `update`, `main` |
| `src/ssh-paste-mac` | proxy, install | The zsh launcher (`ssh-paste` on macOS): `--proxy` starts the watcher and becomes `nc`; wrapper mode starts the watcher, runs ssh, stops it; `--uninstall` runs the installed `install.sh`. |
| `install.sh` | install | The macOS installer (POSIX sh): the files in `~/.local/share/ssh-paste`, the PATH block in the shell profiles, `--uninstall` |
| `tests/ssh-paste.Tests.ps1` | tests | Pester 5, one `Describe` per function. Tags: `Windows`, `Unix`, `E2E`. |
| `tests/e2e-linux.sh` | tests | Starts a throwaway `sshd` on 127.0.0.1 and runs the `E2E` tests against it. |
| `tests/footprint.ps1` | tests | Windows only. Installs, enables, disables and uninstalls on the real profile, then compares snapshots. |
| `tests/cases.json` | tests | Test tables that the Pester tests and the node tests both run. |
| `tests/mac/unit.test.js` | tests | node tests of `src/ssh-paste.js`: the shared tables, ports of the Pester cases, the watcher against a simulated pasteboard, and guards that keep both clients equal. |
| `tests/mac/jxa.sh`, `e2e.sh`, `footprint.sh` | tests | macOS only (CI): the pasteboard and the watcher in Terminal.app with a stand-in ssh; a throwaway `sshd` with ssh mode and wrapper mode; install and uninstall against the real home folder. `pb.js` writes the pasteboard as other apps do. |
| `tests/lint.ps1`, `check.ps1` | tests, ci | The lint checks, and the one local entry point that runs them with Pester. |
| `verify/watcher/` | watcher | A TLA+ model of the clipboard watcher and `check.sh`, which model-checks it with TLC. Run it for any change to the watcher or `PendingClipboard`: [.claude/skills/verify-clipboard-watcher/SKILL.md](.claude/skills/verify-clipboard-watcher/SKILL.md). |
| `.github/workflows/ci.yml`, `publish.yml`, `.github/scripts/*.sh` | ci, release | CI on 5.1, 7 on Windows and 7 on Linux, node on Linux, and macOS 15 and 26. `ci.yml` releases a green push to `main` (or a manual run on `main`) through `publish.yml`, which tags, builds, attests and publishes. The scripts pick the version, write the notes and stamp the version. |

## Commands

- `pwsh ./check.ps1` runs the lint checks and the Pester unit tests. Run it before every commit.
- `pwsh ./check.ps1 -E2E` adds `tests/e2e-linux.sh` (Linux, needs `sshd`). `-Footprint` adds `tests/footprint.ps1` (Windows only, edits the real user profile and restores it).
- `Invoke-Pester tests/ssh-paste.Tests.ps1 -ExcludeTagFilter E2E` runs only the unit tests. Run the whole file, not one `Describe`.
- `bash verify/watcher/check.sh` model-checks the clipboard watcher (needs Java 11+, 2-3 minutes). Run it when you change the watcher, the clipboard writes or the promise. The model follows the Windows code; the macOS watcher makes the same decisions, and its node tests replay the model's counterexamples.
- `node --test tests/mac/unit.test.js` runs the macOS client's unit tests on any OS (`check.ps1` runs it when node is on PATH). `bash tests/mac/jxa.sh` needs a Mac with a GUI session and takes over the pasteboard; `tests/mac/e2e.sh` and `tests/mac/footprint.sh` edit the real home folder and run only in CI.
- Pester on Windows PowerShell 5.1 and the footprint rounds run in CI. Read the CI run on your commit for those.

## Docs travel with the code

A change that a user can see updates both `README.md` and `README.zh-CN.md` in the same commit. There is no changelog: the commit subject is the release note, so it says what the user now sees (`area: user-visible effect`). `$script:Version` in `src/ssh-paste.ps1` stays `0.0.0-dev`; a release stamps its own version into the copy it publishes.

## The maintenance loop

Every commit that changes `src/` is released at once, so there is no release day to wait for. Each time you pick the work up, read every commit after the `reviewed-through` marker at the top of LESSONS.md (`git log --stat <marker>..HEAD`, full messages).
For each fix that needed a second try, a change that should not have shipped, or a check that was too thin, add a lesson or add a sighting to an existing one.
A lesson seen 3 times moves into docs/code-standards.md. Then set the marker to the commit you reviewed through.

## Debugging on a user's machine

- `ssh-paste --doctor HOST` checks PowerShell, the clipboard and window APIs, `ssh`, the terminal, and one real upload to HOST.
- `$env:SSH_PASTE_DEBUG = 1` makes the `--proxy` relay report each step on stderr. On macOS, `SSH_PASTE_DEBUG=1` logs the watcher's decisions to `$TMPDIR/ssh-paste-debug.log`.
- `ssh -v HOST` shows where the connection stops. For example, a hang at `expecting SSH2_MSG_KEX_ECDH_REPLY` means the relay stopped forwarding (70db0c0).
