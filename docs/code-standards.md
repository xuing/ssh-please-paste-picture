# Code standards

These rules come from what went wrong in earlier work on ssh-paste. The
evidence for each one is in [LESSONS.md](../LESSONS.md). Write a change
against them, and review a change by checking each one. A lesson seen 3
times moves here.

## What a change contains

| Rule | What a reviewer looks at |
| --- | --- |
| A commit has one goal. | Every change in behavior has a reason that belongs to the subject. A fix found on the way, a refactor or a new feature goes in a commit of its own, so a revert takes back one thing. |
| A fix reaches every sibling of the bug. | Grep for the same pattern and fix every match in the same commit. That includes `install.ps1` and `src/ssh-paste.ps1`, which share code such as `Remove-UserPathEntry` and `Send-EnvironmentChange`. 43c21a2 fixed the registry leak in both files. |
| A change re-derives what depends on it. | When a change alters a name, a format, a file layout or the order of steps, find every caller, test, README line and server-side command that assumed the old one, and run it. b1b0085 moved the clipboard write before the upload, so the failure path had to take the path back off the clipboard. |
| A failed read means "unknown", not "empty". | A read or parse that fails is never taken as "no hosts" or "no config". Only a file that does not exist counts as empty, and the code checks for that case by itself. `Update-SshConfig` refuses to write when the file changed since it was read. Keep that behavior, and test with the file missing and with the file unreadable. |
| A change holds on the whole path. | Follow it from the user's command to the end result: the launcher, `Invoke-Main`, the ssh config, the server and the clipboard. One correct function does not make the operation correct. |

## PowerShell

- Keep every script ASCII and keep it parsing on Windows PowerShell 5.1. Do
  not use `??`, `?.`, the ternary operator, `&&` or `||`. CI checks both.
- Scripts run under `Set-StrictMode -Version 2.0` with
  `$ErrorActionPreference = 'Stop'`. Keep both.
- Start programs only through `New-ChildStartInfo`. It removes the private
  variables Win32-OpenSSH passes to a ProxyCommand, which would otherwise
  reach every program we start (07a4287). `tests/lint.ps1 -Check Spawn`
  enforces it.
- A `[string]` parameter turns `$null` into `''`. Test it with
  `[string]::IsNullOrEmpty`, never with `$null -eq`. When you compare a value
  that may be `$null` with a `[string]`, cast both sides with `[string]`.
- PowerShell 7 passes `$null` to a .NET `string` parameter as `''`. Pass
  `[NullString]::Value` when the method must get null, as `File.Replace`
  does in `Update-SshConfig`. Delete an environment variable or a registry
  value with `RegistryKey.DeleteValue`, never by setting it to `$null`.
- Match whole strings with `-cmatch '^...\z'`. `$` also matches before a
  trailing newline, so `"abc`n" -cmatch '^abc$'` is true. Use `-cmatch` and
  `-ceq` unless case must not matter.
- Wrap a result you use as an array in `@()`. One item comes back as a
  scalar, and no items come back as `$null`.
- Return a byte array with `return , $bytes`. A plain `return $bytes`
  unrolls it into an `Object[]`.
- In `--proxy` mode stdout is the SSH byte stream. `Invoke-Proxy` and
  everything it calls write messages with `[Console]::Error.WriteLine`, never
  with `Write-Host`, `Write-Output` or an uncaptured value.
- Text that becomes a shell script or a server command has LF line endings.
  Strip `` `r `` from a multi-line here-string, because `.gitattributes`
  checks out `*.ps1` with CRLF.
- Write full parameter names in `.ps1` and `.cmd` files outside `tests/`.
  CI rejects `-EncodedCommand`, `-WindowStyle` and the short forms `-ep`,
  `-nop`, `-noni`, `-enc` and `-w`, because antivirus tools flag them.
- Windows Terminal pastes the text format when the clipboard holds an image
  and text. With only a file list (`CF_HDROP`) from Explorer, it pastes the
  local Windows path. `Set-SshPasteClipboard` relies on both facts.
- A comment says what the code is for. Name functions, not line numbers.

## Tests

| Rule | What a reviewer looks at |
| --- | --- |
| A fix comes with a test that fails without it. | Put the old code back and run the new test. It must fail on its assertion. A parse error or a skipped test does not count. The commit body names the test and what it failed with. |
| Tests stay out of the real machine. | Tests use a temporary home folder for `.ssh/config` and never touch the real profile, PATH or registry. Only `tests/footprint.ps1` edits the real profile, and it runs in CI or with `-Force`. Clipboard tests run only with `$env:CI` or `SSH_PASTE_TEST_CLIPBOARD=1`. |
| A test never reaches the network. | Uploads go to a stand-in for `ssh`, to a local TCP server, or to the throwaway `sshd` that `tests/e2e-linux.sh` starts on 127.0.0.1. |
| A test waits for a state, never for a time. | Poll for the file, the process exit or the clipboard sequence number, with a deadline long enough for a loaded CI runner. Do not use `Start-Sleep` as the check. |
| A red test on `main` is a bug to fix now. | "It fails on main too" is not a baseline. Fix it, or open an issue that names the cause, in a commit of its own before you build on top of it. |
| Run the whole test file. | Run `tests/ssh-paste.Tests.ps1` in full, not one `Describe`. A change in one function can break a test of another. |
| Tests use real inputs. | Fixtures are real clipboard bytes, real `ssh -G` output and real ssh config files, with their BOMs, CRLF line endings and empty values. |

## Acceptance criteria

A change is committed or merged only when it shows each of these that
applies. The commit body says which ones were run and what they printed.
A check that was not run is listed under "Not run:", never left out.

1. **A test that fails without the change.** Revert the code, run the new
   test, and see it fail on its assertion. Restore the code and see it pass.
2. **`./check.ps1` passes.** It runs the lint checks in `tests/lint.ps1`
   (ASCII, the antivirus patterns, PSScriptAnalyzer, and a parse with the
   PowerShell that runs it) and the whole Pester file. The parse with
   Windows PowerShell 5.1 runs in CI.
3. **Pester passes on Windows PowerShell 5.1 and on PowerShell 7.** CI runs
   both on Windows and PowerShell 7 on Linux. Read the run on your commit.
4. **The end-to-end tests pass** for any change under `src/`:
   `./check.ps1 -E2E` or `bash tests/e2e-linux.sh`, or the CI job.
5. **The footprint test passes** for any change to install, `--enable`,
   `--disable` or uninstall: `tests/footprint.ps1` in CI, on 5.1 and 7.
6. **A real Windows run with the real `ssh`** for a change to the relay,
   the clipboard, the watcher, window detection or process handling. Unit
   tests replace the pipes and the clipboard, so they cannot show what
   Win32-OpenSSH and Windows Terminal do. Say what you ran and what you saw.
7. **The docs match.** A change a user can see updates `README.md` and
   `README.zh-CN.md` in the same commit. The commit subject is the release
   note (see Commits), so it names the effect the user sees.
8. **The record is complete.** The commit body lists what was run with its
   result under "Verified:" and what was not run under "Not run:".

Answer a review finding with a test or a reproduction. An argument alone
does not close a finding. If the check needs a platform you do not have,
the finding stays open and the commit lists it under "Not run:".

## Commits

The subject names the area and what the user now sees:
`area: user-visible effect`. It is the release note: a release lists the subjects
of its commits (commits that start with `docs:`, `ci:` or `tests:` are left out).
The areas are `proxy`, `watcher`, `upload`,
`enable`, `install`, `docs`, `ci`, `release` and `tests`. For example:
`watcher: a Ctrl+V during an upload pastes the remote path`.

The body says why the change was needed. Then it has two lines that a later
review can read:

```
Verified: ./check.ps1 (lint ok, 533 passed, 0 failed), and the new test failed with the old code
Not run: real Windows ssh run (no Windows machine)
```

[CONTRIBUTING.md](../CONTRIBUTING.md) has the full convention. After you
commit, check that `git show --stat HEAD` lists your files and only yours.
Parallel agents each work in their own `git worktree add --detach`.

## Releases

Releases are automatic: [docs/RELEASING.md](RELEASING.md). Every green push to
`main` that changes `src/` or `install.ps1` is tagged and released by the CI run
that tested it, as the next `v0.1.<n>`. Nobody tags by hand for a normal release,
and a tag is never moved or reused. A tag is not a release until the release
on GitHub has every asset and the assets verify against `SHA256SUMS`; the run
checks that, and you check it again before you name the version to anyone.
`$script:Version` stays `0.0.0-dev` in the repository: the release stamps its own.
