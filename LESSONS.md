<!-- reviewed-through: 26ce38f (2026-11-23 20:57 +0900) -->
# Lessons from merged work

This file keeps what went wrong in earlier work on ssh-paste and the rule that
would have caught it. Read it before changing code.

Each lesson is a rule in bold, then why, then the evidence: the commit that
fixed it and what broke. "Seen" counts the separate times the mistake was
found, each in a different commit or review, with its date. A lesson seen 3
times moves into [docs/code-standards.md](docs/code-standards.md) and leaves a
short entry under [Moved to the code standards](#moved-to-the-code-standards).

The marker on the first line names the last commit that was reviewed. Before
each release, read every commit after it (`git log --stat 26ce38f..HEAD`, full
messages). For each fix that needed a second try, a change that should not
have shipped, or a check that was too thin, add a lesson or add a sighting to
an existing one. Then move the marker.

On 2026-11-23 the first review read all 7 commits, from dab6eb1 to 26ce38f,
and the review rounds before the first commit. Five commits fixed something
an earlier one shipped. Two Windows bugs reached a commit because only Linux
had run the code: the relay hang (70db0c0) and the registry leak (43c21a2).

## PowerShell

**A `[string]` parameter turns `$null` into `''`, so `$null -eq $param` is
never true.** Test with `[string]::IsNullOrEmpty`, or cast both sides with
`[string]` before you compare.
- 46cbcbc: `Get-SourceFiles` in `install.ps1` declares `[string]$Ref`, and the
  installer passed `$null`. Both `$null -eq $Ref` checks were false. A clone
  downloaded instead of using its own `src`, and the URL had an empty ref
  (`.../ssh-pls-paste-pic//src/ssh-paste.ps1`), which returned 404.
- Before the first commit, `ssh-paste --enable` failed on a computer with no
  `~/.ssh/config`. `Read-TextFile` returns `$null` for a missing file, but
  `Update-SshConfig` compared it with `[string]$OldText`, which was `''`. The
  two differed, so it refused with "changed while ssh-paste was editing it".
  dab6eb1 shipped the fix: `[string]$current -cne [string]$OldText`.
- Seen 2x (2026-11-23, 2026-11-23).

**PowerShell 7 passes `$null` to a .NET `string` parameter as `''`.** Pass
`[NullString]::Value` when the .NET method must get a real null. To remove an
environment variable or a registry value, delete it in the registry.
- 43c21a2: `Send-EnvironmentChange` set a dummy user variable to broadcast
  the PATH change, then cleared it with
  `[Environment]::SetEnvironmentVariable(name, $null, 'User')`. Under `pwsh`
  .NET got `''` and kept the value, so every install and uninstall left an
  `ssh_paste_<guid>` value in `HKCU\Environment`. The fix deletes the value in
  the registry and removes the values older versions left.
- The same coercion as the lesson above, through a different API.
- Seen 1x (2026-11-23).

**A script that this code writes for `sh` has LF line endings, even when the
checkout is CRLF.** `.gitattributes` checks out `*.ps1` with CRLF, so a
multi-line here-string in a `.ps1` file carries `\r` into the text. `sh`
reads the `\r` as part of the command. Strip `` `r `` from any multi-line text
that becomes a shell script or a server command.
- 3adb2bd: the Pester helper that writes stand-in `/bin/sh` scripts failed in
  CI, which checks out CRLF, and passed on Linux. The fix strips `` `r `` from
  the body before it writes the file.
- Seen 1x (2026-11-23).

## Verification

**Code that only runs on Windows is not done until it ran on Windows with the
real `ssh`.** Linux tests and Pester on Windows use .NET pipes and a local TCP
server. Win32-OpenSSH behaves differently, and no unit test reaches it.
- 70db0c0: `ssh HOST` in ssh mode hung at "expecting
  SSH2_MSG_KEX_ECDH_REPLY". Win32-OpenSSH hands its ProxyCommand overlapped
  pipes. A synchronous `ReadFile` on them can report a pending read as done
  with 0 bytes, and `Invoke-Proxy` took that for the end of input and
  stopped forwarding. All tests passed. The maintainer found it by hand on
  Windows. The fix opens stdin and stdout with overlapped I/O when the handle
  needs it, and adds `SSH_PASTE_DEBUG=1` so the relay can report its steps.
- 07a4287: every upload from ssh mode hung on Windows (next lesson). The
  Linux and Pester runs passed; the maintainer's `SSH_PASTE_DEBUG=1` log and a
  0-byte temp file on the server showed it.
- Seen 2x (2026-11-23, 2026-11-23).

**What a parent process hands us is not ours to pass on.** In ssh mode
ssh.exe starts our `--proxy` process, and everything it gives us goes on to
any program we start: environment variables and inheritable handles. Clean it
at the boundary, once, and start programs only through `New-ChildStartInfo`.
- 07a4287: Win32-OpenSSH passes its ProxyCommand an fd table in
  `c28fc6f98a2c44abbbd89d6a3037d0d9_POSIX_FD_STATE`. The upload `ssh.exe` that
  `--proxy` started inherited it and took the interactive session's pipes as
  its own stdin and stdout, so the image never reached the server. The
  Win32-OpenSSH source names this case in a TODO in `w32fd.c`.
- Structural fix: the script drops every variable with that prefix at start,
  `New-ChildStartInfo` drops them again for each child, `--proxy` clears the
  inherit flag on the pipes and the socket, and `tests/lint.ps1 -Check Spawn`
  fails when `src/` builds a `ProcessStartInfo` anywhere else.
- Seen 1x (2026-11-23).

**Answer a review finding with a test or a reproduction, never with an
argument alone.** If the finding needs a platform you do not have, leave it
open and say so under "Not run:". Do not close it.
- The first Codex review, before dab6eb1, gave finding 8: `Invoke-Proxy`
  used synchronous console streams on overlapped pipe handles. The review
  said the exact symptom needed a Windows run. The author's answer, given to
  the second review round, left the code unchanged with an argument and no
  test: "kernel32 ReadFile/WriteFile without OVERLAPPED wait on the file
  handle when the I/O is pending". 70db0c0 then fixed exactly that bug, after
  it hung ssh on a real Windows computer.
- Seen 1x (2026-11-23).

**Run every check that CI runs before you push. If a tool is missing, fetch
it (most linters ship a static binary) instead of leaving the check to CI.**
- 0aa6e89: the model check added in fb836ff listed shellcheck under "Not run:"
  because it was not installed. CI's shellcheck failed on `got=break`
  (SC2209), the job stopped before TLC ran, and the watcher fix 6396fae was
  not released until the next commit. shellcheck 0.10.0 from its GitHub
  release runs from a scratch folder.
- Seen 1x (2026-11-24).

**A test that checks that something did not happen also checks a sign that
the code under test ran.** "No new log line" or "the list matches" passes just
as well when the code never ran or the check reads the wrong field. Revert the
fix once and watch the test fail.
- The macOS client's first Codex review (on the branch that became the macOS
  release) found two tests that could not fail: the ssh-mode test counted
  watcher log lines without turning debug logging on, and the Finder restore
  test matched the file list in our own marker instead of the file URLs other
  apps read. Fixed in a27b62c; the ssh-mode test now also requires the
  "not an interactive session" decision twice, and the ControlPersist test was
  run once with its fix reverted (run 45227788340) to see it fail.
- Seen 1x (2026-11-24).

**Check a platform rule in its documentation before a change relies on it,
and make a missing secret fail loudly.** A rule recalled from memory is a
guess, and GitHub hands a called workflow a secret that was not passed as an
empty string, without an error.
- d99008e: the review fix removed the `workflow_call` secret and the
  caller's pass, on the belief that `environment:` on the job alone gives a
  called workflow its environment secrets. GitHub's reuse-workflows page says
  the caller must still pass it by name. In the v0.1.5 run (45320089524)
  `actions/checkout` fell back to `github.token`, and the push to the tap was
  denied (403). The fix passes the secret, marks it `required: true`, and a
  step fails when it is empty.
- Seen 1x (2026-11-24).

**Keep the install and uninstall footprint test in CI.** It compares the real
user profile before and after a full install, enable, disable and uninstall
cycle. It finds what unit tests cannot see: a leak in state that only Windows
has.
- 43c21a2: the footprint test (`tests/footprint.ps1`, under `pwsh`) found
  the `ssh_paste_<guid>` values left in `HKCU\Environment`. No unit test
  looks at the registry.
- Seen 1x (2026-11-23).

**Test fixtures are as large as the real thing.** A check that passes on a
one-line stand-in can fail on the real 80 KB file.
- The first release (v0.1.0) stopped at its last check: `tr ... | grep -q`
  read the published `ssh-paste.ps1`; `grep -q` stopped at the first match,
  `tr` got a broken pipe, and with `pipefail` the check failed. The test's
  stand-in script was one line, smaller than the 64 KB pipe buffer. The fix
  lets grep read everything; the stand-in is now larger than a pipe buffer,
  and the test fails without the fix.
- Seen 1x (2026-11-23).

## Behavior the user sees

**When the user can act during a slow step, put the end result in place
first if it is known in advance, and take it back if the step fails.**
- b1b0085: the watcher uploaded the image and only then wrote the remote
  path to the clipboard. A Ctrl+V pressed during the upload pasted the local
  Explorer path, or nothing for a screenshot. The remote name is the content
  hash plus the extension, so the fix writes the path as soon as the terminal
  is in front and uploads after. If the upload fails, the path comes off the
  clipboard. If the server returns another name, the watcher writes that one.
- Seen 1x (2026-11-23).

## Moved to the code standards

None yet.
