---
name: verify-clipboard-watcher
description: "Model-check the clipboard watcher of ssh-paste (Invoke-WatcherTick, Sync-ClipboardText, Restore-Clipboard, Set-SshPasteClipboard and the PendingClipboard promise in src/ssh-paste.ps1) with TLA+ and TLC. Use before committing any change to those functions, to the C# PendingClipboard or SshPasteNative.ReadSnapshot, or to how the watcher decides, writes or promises the remote path; and to answer whether two sessions, a paste and the user can interleave into a wrong paste."
---

# Verify the clipboard watcher

`verify/watcher/ClipboardWatcher.tla` is a TLA+ model of the clipboard watcher in
`src/ssh-paste.ps1`. TLC checks every order in which these can act, within small
bounds: the user (copies, window switches, Ctrl+V), up to two ssh-paste sessions
(each a PowerShell thread that ticks and uploads, plus the PendingClipboard window
thread), the uploads, another program that holds the clipboard, and the Windows
clipboard itself. Unit tests cannot reach these interleavings: the Pester watcher
tests mock `Set-SshPasteClipboard`, and the four Windows tests of the promise run
one paste at a time.

## When to use it

Run it when a change touches any function in the coverage record below, or the
order of steps between them. A change elsewhere in `src/ssh-paste.ps1` (the relay,
`--enable`, the installer, `Send-Image` internals other than what it returns) does
not need it.

To see whether the covered code changed since the model was last confirmed (the
sync commit below), list the changed hunks; each `@@` line names the function or
class around it:

```sh
git diff 34c1759 -- src/ssh-paste.ps1 | grep -E '^@@|^[-+].*(WatcherTick|ClipboardText|Restore-Clipboard|ClipboardPromise|SshPasteClipboard|ClipboardImage|UploadedPath|UploadedItemPath|ExpectedText|UploadFailing|PendingClipboard|Publish|Write\(|RenderText|WM_|Resolve|Fail\(|ReadSnapshot|promise|textReady|EmptyClipboard|OpenClipboard|LastSeq|LastForeground|WakeAt|\$shown|\$otherSession|\$wrote)'
```

Any hunk inside a function or class of the coverage record means: run the check,
and first mirror the change into the model (see "When the code changes on purpose").

## Run

```sh
verify/watcher/check.sh              # the gate: 13 TLC runs, 2-3 minutes
verify/watcher/check.sh --mutants    # also the 6 broken variants: each must still fail
verify/watcher/check.sh --keep DIR   # keep configs and TLC output (traces) in DIR
```

It needs Java 11 or later (`JAVA`, or `java` on PATH). The first run downloads
`tla2tools.jar` 1.7.4 from the TLA+ GitHub release, checks its SHA-256 (pinned in
the script) and caches it in `SSH_PASTE_TLA_CACHE` (default
`~/.cache/ssh-paste-tla`, or under `XDG_CACHE_HOME`). On Windows, run it from Git
Bash or WSL. CI runs `check.sh --mutants` in the job "Model check (clipboard
watcher)"; all 19 runs took 3 minutes on 4 cores.

The script runs a table of TLC runs (layout, budget, variants, properties,
expected result) and exits 1 when any result differs from the table: a property
that should hold breaks, a known finding no longer shows, or a broken variant
passes. Three runs check the code with the three candidate fixes from the
findings below, where every invariant holds: while a property is a known finding
in the code, those runs are what catch a new break of it. Exit 2 means TLC did
not finish (a syntax or model error: read the output).
`verify/watcher/ClipboardWatcher.cfg` is a single config with every invariant on
the one-session layout, for reading with `/statechart` or a manual TLC run.

Read every result with the `/statechart` skill: give it the model and the config
of the run (`--keep DIR` writes each run's `.cfg` there). It shows the shortest
path to each broken rule; when a run passes, it can draw how the watcher moves
between states. The states print as raw variables: write a view for it, as
`/statechart` describes, with labels such as "terminal in front, path promised,
upload running" (from `fg`, `cb.text`, `pc`).

## What is verified

Each property is an INVARIANT or PROPERTY of the same name in the model.

| Property | The promise in one sentence | The harm when it breaks |
| --- | --- | --- |
| PastedPathExists | A pasted remote path names a file that exists on the server of the session whose entry it came from. | The remote program (Claude Code) gets a path to a missing file and keeps it as text, not an image. |
| PastedPathOnThisHost | A path that a running session put on the clipboard, pasted into a terminal window, names a file on the server of a session in that window. | A path for host X lands in a terminal on host Y, or in a local shell. |
| NoLocalPathDuringUpload | While a session uploads a copy it took over in its window, Ctrl+V of that copy there gets the remote path (waiting if it must), never the local Explorer path or nothing. | The user sees `C:\Users\...` or nothing pasted (the bug b1b0085 fixed). |
| ReadyPathPastes | Once a session's promised path exists on its server, Ctrl+V of that entry in the window it was written for gets the path, unless the session is replacing the entry at that moment. | Every Ctrl+V pastes nothing although the upload succeeded. |
| NoLostCopy | A session never erases a copy the user made after the clipboard read that its write was based on. | What the user just copied is silently replaced by the old image. |
| BoundedWrites | Between two things the user does, each session writes the clipboard at most `MaxWritesPerAction` (5) times. | Sessions rewrite each other forever (ping-pong), flooding clipboard listeners. |
| PasteAnswered | A paste that waits for a promised path always gets an answer from the session, without the 30 s `PromiseWaitMilliseconds` limit. | The terminal hangs on Ctrl+V for 30 s and pastes nothing. |

"Took over" in NoLocalPathDuringUpload: the tick ran with the terminal in front,
saw no `$otherSession` and no failing upload, so it either promised the path or
found its expected path already there. A retry after a failure, and a copy that
another tab of the same window handles, are not covered by design.

The bound 5 in BoundedWrites: a write decided just before the user acted can land
after it (1), then the promise and `Sync-ClipboardText` of another name (2), and a
late write of the other session can undo that entry twice, one more promise each
(2). TLC finds no more within these bounds, and 3 with `fix_seq_in_write`. A loop
between sessions exceeds any bound.

## Layouts, bounds and assumptions

| Layout | Sessions | Copies | User actions | States | Time (32 cores) |
| --- | --- | --- | --- | --- | --- |
| `one` | A in window t1; t2 is a terminal without ssh-paste | screenshot i1, Explorer files i2, text | 6 (5 for PasteAnswered) | about 0.85 M | 10 s (liveness 35 s) |
| `windows` | A in t1 (host X), B in t2 (host Y) | i2, text | 4 (3 for PasteAnswered) | about 1.3 M | 20 s |
| `tabs` | A and B are tabs of t1 (hosts X and Y) | i2, text | 3 | about 1 M | 15 s |

A user action is a copy, a window switch, a Ctrl+V, a session ending (wrapper
mode, with `Restore-Clipboard`) or being killed (ssh mode, without), or another
program holding the clipboard longer than `Write`'s 20 tries. Retry timers
(`$W.WakeAt` after a failed upload) fire freely. Uploads end with the plain name,
the per-user name, or a failure.

Assumptions, each a place where a counterexample can be a modeling error:

- The user presses Ctrl+V at least one tick (250 ms) after a copy, a window switch
  or the clipboard becoming free: each session has finished a tick that read the
  clipboard after it, or is inside an upload (`UserWaited`). Without this every
  property breaks trivially in the 250 ms before the next tick.
- Windows: `EmptyClipboard` sends `WM_DESTROYCLIPBOARD` to the previous owner
  before it returns; a delayed format counts for `IsClipboardFormatAvailable`; a
  paste holds the clipboard open while `RenderText` waits; the sequence number
  moves on every write; `SetClipboardData` inside `WM_RENDERFORMAT` may or may
  not move it (both are explored).
- `RenderText` answers at once unless the promise is open and unresolved (no
  `Write` can run while the paste holds the clipboard).
- A session that ends destroys its clipboard window, so a waiting paste gets
  nothing.
- Windows Terminal pastes the text format; with only `CF_HDROP` it pastes the
  local path; with only an image, nothing.

Not modeled: time (the 30 s promise wait, upload timeouts, the 6 h re-upload, the
server's day-old cleanup, the backoff lengths); `Test-HostForeground` (windows are
given); image bytes (`Get-TrimmedPng`, `New-DibBytes`, hashing, `CF_DIB`); image
plus text from apps and non-image file lists (the watcher leaves them alone); more
than one file per copy; `WM_RENDERALLFORMATS` and `Close-Clipboard` (not called by
`src/`); `SendMessageTimeout`'s 10 s timeout; the server script. A pass covers
these bounds and assumptions only.

## Coverage record

Sync commit: **34c1759** (`watcher: a new promise survives the clipboard being
emptied for it`). At this commit the model was confirmed against the code below.

| Model action | Code in `src/ssh-paste.ps1` |
| --- | --- |
| `Tick` | `Invoke-WatcherTick` up to the first write: `GetForegroundWindow`, `GetClipboardSequenceNumber` vs `$W.LastSeq`, `Read-ClipboardImage` (`SshPasteNative.ReadSnapshot`, marker text), `$W.LastForeground` / `$W.WakeAt`, `Get-ExpectedText`, `$otherSession`, `$shown`, `Test-UploadFailing`, the branch for another window in front, and the sequence/foreground check before `Set-SshPasteClipboard` |
| `Send` (inside `Tick`, `Sync`, `Restore`) | `Set-SshPasteClipboard` (`New-DibBytes`, marker) and `PendingClipboard.Publish`: withdraw an open promise, then `SendMessageTimeout(WM_APP_PUBLISH)` |
| `WriteOk` / `WriteFails` | `PendingClipboard.Write` on the window thread: 20 x `OpenClipboard`, `EmptyClipboard` (the old owner's `WM_DESTROYCLIPBOARD` handler withdraws its promise), then the new promise state, `SetClipboardData`, `CloseClipboard`. On failure `Publish` returns 0, `Set-SshPasteClipboard` throws, the loop's catch sets `LastSeq = -1` |
| `GetPath` | `Get-UploadedPath` / `Get-UploadedItemPath`: cached path, backoff `$null`, or start `Send-Image` |
| `UploadEnds` | `Send-Image` returns (`Read-UploadReply`: plain or per-user name) or throws; `$W.Uploaded` / `$W.Failed`; `Complete-ClipboardPromise` (`Resolve` / `Fail`); the `$path -cne $expected -or -not ($wrote -or $shown -or $otherSession)` test |
| `Sync` | `Sync-ClipboardText`, including its own sequence/foreground check |
| `Restore` | `Restore-Clipboard` (wrapper mode, `Invoke-Wrapper`'s `finally`) |
| `UserPastes`, `Render` | Windows Terminal's paste; `WM_RENDERFORMAT` -> `RenderText` |
| `UserCopies`, `UserSwitches`, `OtherApp*`, `Session*`, `RetryTimeComes` | the environment: other apps' copies, focus, another program holding the clipboard, ssh exiting (wrapper or `--proxy`), the retry backoff |

Move the sync commit forward only after you have confirmed that every row still
describes the code at the new commit, and the check gives the expected results.

## When a result differs

1. Read the trace with `/statechart` (or the `.out` file from `--keep`): the
   action names are the rows above; `badPaste` names the paste that broke a rule.
2. Replay it against the code, one action per step, in the code's words. Look
   for the assumption it leans on (the list above). A counterexample that needs
   something Windows or the user cannot do is a modeling error: fix the model,
   say why in the commit, and rerun. Do not weaken a property to make it pass.
3. A real bug is a finding. Report it with the steps in the code's words. If the
   change is meant to fix a known finding, move its run from `finding` to `hold`
   in `check.sh` in the same commit.

## When the code changes on purpose

Mirror the change into the action that the coverage record names, keeping one
action per step that nothing can come between in the code (one clipboard open, or
one stretch of a thread touching nothing shared). A new wait, write or read of the
clipboard is a new action. Then run `check.sh --mutants`: every broken variant
must still break, which shows the property can still fail. If the change removes
the code a variant breaks, replace the variant with one that breaks the new code.
Update the coverage record and the sync commit.

## Findings at the sync commit

The check passes on the code only because these runs are listed as `finding`.
Each is a real behavior of 34c1759 within the assumptions above.

1. **A copy made while the watcher writes is erased** (NoLostCopy, all layouts).
   The user copies a screenshot and switches to the terminal.
   `Invoke-WatcherTick` checks that `GetClipboardSequenceNumber()` still equals
   `$state.Seq`, then calls `Set-SshPasteClipboard`, which runs `New-DibBytes` (a
   PowerShell loop over every row of the image) and `Publish`. The user copies
   text now. The window thread's `Write` calls `EmptyClipboard`, which erases the
   text, and writes the old image with the promised path. The same gap is in the
   branch for another window in front, `Sync-ClipboardText` and
   `Restore-Clipboard`. In two tabs it also lets the later session replace the
   entry the other tab already wrote, against the README ("A session leaves alone
   an entry that another session in the same window already updated"); when that
   session's upload fails, Ctrl+V gets nothing (NoLocalPathDuringUpload, `tabs`).
   Candidate fix, checked as `fix_seq_in_write`: pass the expected sequence number
   in the `Entry` and compare it in `Write` after `OpenClipboard`, before
   `EmptyClipboard`.
2. **A Ctrl+V in another window during the upload pastes this session's path**
   (PastedPathOnThisHost, layout `one`). Session A promises the path and
   starts `Send-Image`. The user switches to terminal t2 and presses Ctrl+V.
   Windows asks A's window; `RenderText` waits for the upload and gives A's path
   (host X) to t2. A cannot put the plain image back: its tick is inside
   `Send-Image`. In two windows, session B also sees A's marker text equal to its
   own `$expected` (the name is the content hash on every server), so `$shown` is
   true and B relies on A's promise. Candidate fixes: `RenderText` gives the path
   only when the window in front at `WM_RENDERFORMAT` is the marker's owner window
   (`fix_render_in_owner_window`), and `$shown` counts only this session's own
   entry (`fix_shown_live`).
3. **A promise that can no longer answer stays, and Ctrl+V pastes nothing**
   (ReadyPathPastes, layout `one`). The shortest path TLC finds: the user copies
   image files and switches to the terminal; the tick promises the path and
   uploads; the user switches to another window; the upload fails,
   `Complete-ClipboardPromise` fails the promise, and `Sync-ClipboardText` leaves
   the path because the window in front changed since the tick began; the user
   comes back before the next tick puts the plain image back. After the backoff
   the retry succeeds, but the tick sees its marker text equal to `$expected`
   (`$shown`) and writes nothing. Every Ctrl+V in the terminal then gets nothing
   from `RenderText` until the user switches away and back or copies again.
   Other paths to the same state: `Publish` withdraws a resolved promise to put
   the plain image back, then `Write` fails because another program holds the
   clipboard; or the upload fails while another program holds the clipboard, so
   `Sync-ClipboardText` cannot read it.
   Candidate fix, checked as `fix_shown_live`: `$shown` and the matching early
   return in `Sync-ClipboardText` count an entry as done only if this session
   wrote it and its PendingClipboard can still give the text.
4. **In two windows, a session relies on the other's promise during its upload**
   (NoLocalPathDuringUpload, layout `windows`). A promises the path in t1; the
   user switches to t2; B finds A's marker text equal to its own `$expected`, so
   `$shown` is true and B uploads without writing. Ctrl+V in t2 asks A's window;
   A's upload fails, so the paste gets nothing while B's upload still runs (and
   had A's succeeded, t2 would get a path on A's host, as in finding 2). Fixed
   in the model by `fix_shown_live` together with `fix_seq_in_write`.

With all three candidate fixes (the last three runs of `check.sh`) every
invariant holds on all three layouts.

## Variants (`Mutants` in the model, `--mutants` in the script)

Broken variants, each a change to the code that a property must catch:

| Variant | The code change | Breaks |
| --- | --- | --- |
| `write_path_before_upload` | `Set-SshPasteClipboard` without `-Promise` before the upload (the code of b1b0085) | PastedPathExists: Ctrl+V during the upload pastes a path that is not on the server yet (what ac31bcd fixed) |
| `resolve_on_failure` | `Complete-ClipboardPromise $expected` whatever the upload returned | PastedPathExists |
| `upload_before_write` | upload first, write the path afterwards (before b1b0085) | NoLocalPathDuringUpload: Ctrl+V during the upload pastes the local Explorer path |
| `promise_before_empty` (with `fix_shown_live`) | `Publish` sets the new promise before `Write`'s `EmptyClipboard` (before 34c1759) | ReadyPathPastes: back in the terminal, the re-promised cached path is withdrawn by our own `EmptyClipboard`; Ctrl+V gets nothing |
| `complete_only_on_success` | `Complete-ClipboardPromise` only when the upload succeeded | PasteAnswered: a paste waits forever (until the 30 s limit) on a failed upload |
| `strip_any_owner` | the branch for another window in front drops `-and $state.Owner -ne $fgKey` | BoundedWrites: two windows' sessions rewrite each other without end |

Candidate fixes (must hold): `fix_seq_in_write`, `fix_shown_live`,
`fix_render_in_owner_window`, described in the findings.
