<!-- reviewed-through: 9b3216d (2026-11-24 15:10 +0900) -->
# Lessons from merged work

This file keeps what went wrong in earlier work on ssh-paste and the rule that
would have caught it. Read it before changing code.

Each lesson is a rule in bold, then why, then the evidence: the commit that
fixed it and what broke. "Seen" counts the separate times the mistake was
found, each in a different commit or review, with its date. A lesson seen 3
times moves into [docs/code-standards.md](docs/code-standards.md) and leaves a
short entry under [Moved to the code standards](#moved-to-the-code-standards).

The marker on the first line names the last commit that was reviewed. Before
each release, read every commit after it (`git log --stat 9b3216d..HEAD`, full
messages). For each fix that needed a second try, a change that should not
have shipped, or a check that was too thin, add a lesson or add a sighting to
an existing one. Then move the marker.

On 2026-11-23 the first review read all 7 commits, from dab6eb1 to 26ce38f,
and the review rounds before the first commit. Five commits fixed something
an earlier one shipped. Two Windows bugs reached a commit because only Linux
had run the code: the relay hang (70db0c0) and the registry leak (43c21a2).

On 2026-11-24 the second review read the 32 commits from 22f35a3 to 9b3216d
(the Windows watcher's promise, the TLA+ model, the macOS client, Homebrew,
Scoop, `--keep` and `--dir`) and the CI runs of PR #4. The Windows-only rule
reached three sightings and moved to the code standards.

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

**A diagnostic switch gets one real run, because users turn it on when
something already fails.** A debug flag that breaks the thing it diagnoses
takes away the user's only way to report the bug.
- 56c6999: `SSH_PASTE_DEBUG` (added in ac85169) removed `LogLevel=ERROR`
  from the upload command but left its `-o`. The lone `-o` took the next
  option as its value and ssh refused the command line, so every upload
  failed exactly when a user turned debugging on. ac85169 listed only a parse
  check. The macOS client already dropped the pair, and its test showed the
  Windows copy was wrong; the fix adds a Pester test that fails without it.
- Seen 1x (2026-11-24).

**A rule verified for one client is not verified for its port: port the
counterexamples as tests too.** The TLA+ model checks the Windows watcher
only; the macOS watcher makes the same decisions in other code.
- 9c44801 said that the rules of 6396fae hold on macOS. Codex reviews then
  found two cases its tests did not reach: a paste that waited for the
  upload got the path after the user switched windows (a27b62c; the test now
  brings Calculator forward while the paste waits), and with ControlPersist
  the watcher kept writing paths after logout (94e9171).
- Seen 1x (2026-11-24).

**A failing check is not a flake until its log says so.** Read the debug log
or the artifacts of the failed job before you re-run it; a re-run that passes
only hides a race until it hits a user.
- 9d48684: macOS e2e and jxa failed on main twice (runs 45358589125 and
  45362405133) and passed on the PRs. The first was re-run as a runner flake.
  The watcher's debug log in the second run's artifacts showed the cause: a
  tick read the pasteboard between a writer's clear and its write, kept "empty"
  for that change count, and never looked again. The fix reads an empty
  pasteboard again; its test fails without it.
- 89aef10 had loosened the Finder-copy assertion after the same kind of
  failure instead of finding why.
- Seen 2x (2026-11-24, 2026-11-24).

**A test that covers whatever it finds must fail when something it should
cover is missing.** A loop over the shells, browsers or tools present passes
just as well when none of the interesting ones are there.
- 356b04b: the Pester tests ran the server script through every login shell
  they found. The Linux runner had only sh, bash and dash, so zsh, fish and
  tcsh were never tested, while the README said they work and a commit message
  said CI had run them. The CI job now installs them and fails if one is
  missing; they then passed for the first time.
- Seen 1x (2026-11-24).

**A fixture takes machine facts (uid, home folder, host name) from the
machine that runs it.** A literal that matches the author's computer passes
there and fails on a runner.
- 365340f, in the CI run of PR #4: two Pester fixtures named a per-user file
  `ssh-paste-<hash>-1000.png`. The author's uid is 1000; the GitHub Linux
  runner's is 1001, so once the server script deleted only files with the
  real uid, the tests failed in CI and passed locally. The fix uses `id -u`.
- Seen 1x (2026-11-24).

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

- **Code that only runs on Windows is not done until it ran on Windows with
  the real `ssh`.** Acceptance criterion 6. Seen 3x: 70db0c0 (the relay
  hang), 07a4287 (uploads from ssh mode hung on the session's pipes),
  34c1759 (a new promise withdrawn by our own `EmptyClipboard`; 601 Linux
  tests had passed). Moved 2026-11-24.
