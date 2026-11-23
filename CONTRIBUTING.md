# Contributing

ssh-paste is one PowerShell script for Windows and one JavaScript for
Automation script for macOS, with one maintainer. Bug reports help the most.
Small pull requests are welcome after an issue.

## Report a bug or ask for a feature

Use the issue forms:

- [Bug report](https://github.com/xuing/ssh-please-paste-picture/issues/new?template=bug_report.yml).
  The form asks for `ssh-paste --doctor HOST` output. In ssh mode, it also asks
  for the output with `SSH_PASTE_DEBUG=1`.
- [Feature request](https://github.com/xuing/ssh-please-paste-picture/issues/new?template=feature_request.yml).

Report a security problem privately, as [SECURITY.md](SECURITY.md) describes.
Do not open a public issue for it.

## Pull requests

Follow these rules for a pull request:

- Open an issue first, and agree on the change there. A typo fix needs no issue.
- Make one change per pull request: one fix or one feature.
- Add a test with a fix. The test must fail without the fix and pass with it.
- Keep `src/ssh-paste.ps1` and `install.ps1` ASCII-only. Both must run on
  Windows PowerShell 5.1 and PowerShell 7. The macOS files (`src/ssh-paste.js`,
  `src/ssh-paste-mac`, `install.sh`) are ASCII-only too.
- A change to what both clients decide (the watcher, the upload, the ssh
  arguments) goes into both clients, with a case in `tests/cases.json` where a
  table fits.
- If you change what a user sees, update `README.md` and `README.zh-CN.md`
  with the same sections. There is no changelog: the subject of your commit
  is the release note (see below).

## Checks a pull request must pass

Run the checks from the repository root. In PowerShell 7, run `./check.ps1`. In
Windows PowerShell, run this command:

```powershell
powershell -ExecutionPolicy Bypass -File .\check.ps1
```

`check.ps1` runs the lint checks in `tests/lint.ps1` and the Pester unit tests
(Pester 5.5 or newer: `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser`).
Add `-E2E` to run the end-to-end tests against a throwaway `sshd` on Linux.
Add `-Footprint` on Windows to check that install, enable, disable, and
uninstall leave nothing behind. `check.ps1` also runs the node tests of the
macOS client when node is installed; the macOS tests that need a Mac
(`tests/mac/*.sh`) run in CI. The footprint test edits your real user
profile and restores it. A change to the clipboard watcher also needs
`bash verify/watcher/check.sh` (Java 11 or later), which model-checks it.

[docs/code-standards.md](docs/code-standards.md) lists the numbered acceptance
checks. In the pull request description, name the checks you ran and their
results. CI runs the same checks on Windows PowerShell 5.1, PowerShell 7 on
Windows, and PowerShell 7 on Linux.

## Commit messages

Write the subject as `area: user-visible effect`. The subject says what a user
sees after the change, not what you fixed. It is the release note: every green
commit that changes `src/` or `install.ps1` is released, and the release notes
are the subjects of its commits. Use one of these areas: `proxy`,
`watcher`, `upload`, `enable`, `install`, `docs`, `ci`, `release`, or `tests`.

In the body, say why the change is needed. Then add a `Verified:` line for each
command you ran with its result, and a `Not run:` line for each check you
skipped with the reason. An example:

```
install: install and uninstall under pwsh leave no ssh_paste_* values in HKCU\Environment

Send-EnvironmentChange cleared its dummy variable with $null. PowerShell 7
passes $null to .NET as an empty string, which .NET keeps, so every install
under pwsh left an ssh_paste_<guid> value. Delete the value in the registry
instead.

Verified: ./check.ps1, lint clean, Pester all passed
Verified: tests/footprint.ps1 -Force on Windows 11 under pwsh 7.5, no values left
Not run: -E2E, the change does not touch the relay or uploads
```

## Review of outside pull requests

Before anyone runs a pull request from outside the project, a reviewer reads
the whole diff. Any one of these stops the review until the maintainer has read
it:

- It changes anything under `.github/`, including the release workflows
  (`ci.yml`, `publish.yml`) and `.github/scripts/`.
- It changes a download URL in `install.ps1` or `install.sh`.
- It adds a network address, a host name, or a URL that `ssh-paste` or the
  installer contacts.
- It sends clipboard contents, files, or keys anywhere they did not go before.
- It changes what `--enable` writes to `~/.ssh/config`, what the installer
  writes to the registry, or what `install.sh` writes to the shell profiles.
- It adds an encoded or minified blob, a binary, new C# code for `Add-Type`, or
  code built from a string at run time, such as `Invoke-Expression` or
  `[scriptblock]::Create`.

The review names the line that stopped it. Nobody runs the pull request on a
computer with real SSH keys until the maintainer clears it.

## Credit

Contributors get credit in the commit:

- A commit that uses a reporter's patch, test, or root cause carries a
  `Co-authored-by: <name> <id>+<login>@users.noreply.github.com` trailer. Get
  the id with `gh api users/<login> --jq .id`.
- A commit that fixes a reported bug without using the reporter's code names the
  issue and the reporter in the body, such as `Reported in #12 by <login>.`
