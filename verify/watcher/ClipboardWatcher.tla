--------------------------- MODULE ClipboardWatcher ---------------------------
(***************************************************************************)
(* A model of the clipboard watcher in src/ssh-paste.ps1.                  *)
(*                                                                         *)
(* PowerShell thread of a session: Invoke-WatcherTick, Get-UploadedPath,   *)
(* Get-UploadedItemPath, Sync-ClipboardText, Restore-Clipboard,            *)
(* Complete-ClipboardPromise, Set-SshPasteClipboard, Read-ClipboardImage.  *)
(* Window thread of a session: PendingClipboard in $script:NativeSource    *)
(* (Publish, Write, RenderText, the WM_RENDERFORMAT and WM_DESTROYCLIPBOARD *)
(* handlers, Resolve, Fail). Around them: the user, a paste in Windows     *)
(* Terminal, the Windows clipboard, the uploads, other programs and a      *)
(* second ssh-paste session.                                               *)
(*                                                                         *)
(* One action is one step that nothing can come between in the code: one  *)
(* clipboard open (ReadSnapshot, Write, a paste, a copy) or a stretch of   *)
(* one thread that touches nothing shared. The skill                       *)
(* .claude/skills/verify-clipboard-watcher/SKILL.md maps each action to its *)
(* code, states the properties, and lists what the model leaves out.        *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Layout,  \* "one":     session A in terminal window t1; t2 has no session
             \* "windows": A in window t1, B in window t2
             \* "tabs":    A and B are two tabs of window t1
    Steps,   \* how many things the user (or another program) may do
    Images,  \* a subset of {"i1", "i2"}: what the user can copy (besides text)
    Mutants  \* {} is the code as it is; the skill lists the variants

None == "none"
Has(m) == m \in Mutants
Terminals == {"t1", "t2"}
\* i1 is a screenshot (PNG); i2 is image files copied in Explorer (CF_HDROP).
Kind(i) == IF i = "i2" THEN "files" ELSE "png"
Watchers == IF Layout = "one" THEN {"A"} ELSE {"A", "B"}
WindowOf(w) == IF w = "A" \/ Layout = "tabs" THEN "t1" ELSE "t2"
Host(w) == IF w = "A" THEN "X" ELSE "Y"
Hosts == {Host(w) : w \in Watchers}

\* Remote paths. The plain name comes from the content hash and is the same
\* string for every server (Get-ExpectedText). The server answers with a
\* per-user name when another user owns the plain one (Read-UploadReply).
Plain(i) == "/tmp/ssh-paste-" \o i
Alt(i, h) == "/tmp/ssh-paste-" \o i \o "-uid@" \o h
Paths == {Plain(i) : i \in Images} \cup {Alt(i, h) : i \in Images, h \in Hosts}

\* PendingClipboard's promise: promiseOpen, textReady set, promisedText.
Closed == [open |-> FALSE, ready |-> FALSE, val |-> None]
Withdrawn == [open |-> FALSE, ready |-> TRUE, val |-> None]

WritePcs == {"writePromise", "writeStrip", "writeSync", "writeRestore"}
Rules == {"PastedPathExists", "PastedPathOnThisHost", "NoLocalPathDuringUpload",
          "ReadyPathPastes"}

VARIABLES
    \* The world
    fg,        \* the foreground window: "t1", "t2" or "app"
    cb,        \* the clipboard entry. by: "user" or the session whose window wrote it
               \* (and owns it); origin: the sequence number of the user's copy it shows
    seq,       \* GetClipboardSequenceNumber
    busy,      \* another program keeps the clipboard open longer than Write's 20 tries
    budget,    \* how many more things the user may do
    paste,     \* a Ctrl+V in a terminal that waits for a promised text
    onServer,  \* host -> remote paths that exist there
    \* Each session's PowerShell thread
    pc,        \* where the thread is
    st,        \* $W.State: the last snapshot from Read-ClipboardImage
    lastSeq,   \* $W.LastSeq (0 stands for -1)
    lastFg,    \* $W.LastForeground
    tfg,       \* $foreground of the running tick
    img,       \* the image the running tick handles
    exp,       \* $expected (Get-ExpectedText)
    wrote,     \* $wrote
    keep,      \* $shown -or $otherSession
    tookOver,  \* the tick in front took the copy over: no $otherSession, no failing upload
    syncText,  \* the $Text that Sync-ClipboardText is about to write
    pub,       \* the entry handed to Publish that the window thread has not written yet
    uploaded,  \* $W.Uploaded: image -> remote path
    failed,    \* $W.Failed: images whose last upload failed
    due,       \* failed images whose retry time has come ($W.WakeAt)
    alive,     \* the session (and with it its clipboard window) runs
    \* Each session's PendingClipboard window thread
    prom,      \* promiseOpen / textReady / promisedText
    \* Bookkeeping for the properties; the code has none of it
    writes,    \* clipboard writes by each session since the user last acted
    lost,      \* a write erased a copy the user made after the writer's snapshot
    fresh,     \* the session started a tick after the user last acted
    broken,    \* rules that a paste broke
    badPaste   \* the paste that broke a rule, for the counterexample

world == <<fg, cb, seq, busy, budget, paste, onServer>>
locals == <<tfg, img, exp, wrote, keep, tookOver, syncText>>
memory == <<st, lastSeq, lastFg, uploaded, failed, due, alive>>
ghost == <<writes, lost, fresh, broken, badPaste>>
vars == <<world, pc, locals, pub, memory, prom, ghost>>

EmptyEntry == [content |-> "empty", by |-> "user", marked |-> FALSE, owner |-> None,
               text |-> "none", val |-> None, origin |-> 0]
NoSnap == [seq |-> 0, content |-> "empty", by |-> "user", marked |-> FALSE,
           owner |-> None, hasText |-> FALSE, val |-> None, origin |-> 0]
NoPaste == [phase |-> "none", win |-> None, img |-> None, origin |-> 0, src |-> None,
            owner |-> None, val |-> None]
NoEntry == [content |-> None, owner |-> None, val |-> None, basis |-> 0, origin |-> 0,
            promise |-> FALSE]
NoBadPaste == [in |-> None, entry |-> None, from |-> None, got |-> None, how |-> None,
               broke |-> {}]

Init ==
    /\ fg = "app"
    /\ cb = EmptyEntry
    /\ seq = 1
    /\ busy = FALSE
    /\ budget = Steps
    /\ paste = NoPaste
    /\ onServer = [h \in Hosts |-> {}]
    /\ pc = [w \in Watchers |-> "idle"]
    /\ tfg = [w \in Watchers |-> None]
    /\ img = [w \in Watchers |-> None]
    /\ exp = [w \in Watchers |-> None]
    /\ wrote = [w \in Watchers |-> FALSE]
    /\ keep = [w \in Watchers |-> FALSE]
    /\ tookOver = [w \in Watchers |-> FALSE]
    /\ syncText = [w \in Watchers |-> None]
    /\ pub = [w \in Watchers |-> NoEntry]
    /\ st = [w \in Watchers |-> NoSnap]
    /\ lastSeq = [w \in Watchers |-> 0]
    /\ lastFg = [w \in Watchers |-> None]
    /\ uploaded = [w \in Watchers |-> [i \in Images |-> None]]
    /\ failed = [w \in Watchers |-> {}]
    /\ due = [w \in Watchers |-> {}]
    /\ alive = [w \in Watchers |-> TRUE]
    /\ prom = [w \in Watchers |-> Closed]
    /\ writes = [w \in Watchers |-> 0]
    /\ lost = FALSE
    /\ fresh = [w \in Watchers |-> FALSE]
    /\ broken = {}
    /\ badPaste = NoBadPaste

-----------------------------------------------------------------------------
(* Helpers *)

\* A paste that waits for a promised text holds the clipboard open.
Blocked == busy \/ paste.phase = "asking"

\* Read-ClipboardImage: one SshPasteNative.ReadSnapshot. The text comes from
\* the marker, so reading never asks for a promised text.
Snap == [seq |-> seq, content |-> cb.content, by |-> cb.by, marked |-> cb.marked,
         owner |-> cb.owner, hasText |-> cb.text # "none",
         val |-> IF cb.marked /\ cb.text # "none" THEN cb.val ELSE None,
         origin |-> cb.origin]

\* Get-ExpectedText
Expected(w, i) == IF uploaded[w][i] # None THEN uploaded[w][i] ELSE Plain(i)

\* EmptyClipboard sends WM_DESTROYCLIPBOARD to the window that owned the old
\* entry; the handler withdraws an open promise.
AfterEmpty ==
    IF cb.by \in Watchers /\ alive[cb.by] /\ prom[cb.by].open
    THEN [prom EXCEPT ![cb.by] = Withdrawn]
    ELSE prom

\* $shown and Sync-ClipboardText (unless shown_any_entry): this session wrote the clipboard
\* entry, and its window can still give the text (it is concrete, or the
\* promise is open and not failed).
CanStillPaste(w, s) ==
    /\ s.by = w
    /\ \/ cb.text = "plain"
       \/ prom[w].open /\ (~prom[w].ready \/ prom[w].val # None)

\* The $W.WakeAt test: a failed upload of the current image is due for a retry.
Wake(w) == st[w].content \in due[w]

\* The user presses Ctrl+V at least one tick (250 ms) after a copy or a
\* window switch: each session has finished a tick that started (and could
\* read the clipboard) after it, or is inside an upload, which can take seconds.
UserWaited ==
    \A w \in Watchers : ~alive[w] \/ (pc[w] = "idle" /\ fresh[w]) \/ pc[w] = "upload"

\* The rules a paste breaks when it gets res. how: "at once" (concrete text,
\* or no text), "rendered" (the owner window answered WM_RENDERFORMAT), or
\* "owner gone" (the session ended while the paste waited). replacing: the
\* owner had handed Publish a new entry that its window had not written yet.
Judge(p, res, how, replacing) ==
    LET isPath == res \in Paths
        uploadingHere ==
            \E w \in Watchers : /\ WindowOf(w) = p.win /\ alive[w] /\ pc[w] = "upload"
                                /\ tookOver[w] /\ st[w].origin = p.origin
    IN {r \in Rules :
          \/ r = "PastedPathExists" /\ isPath
             /\ ~(p.src \in Watchers /\ res \in onServer[Host(p.src)])
          \/ r = "PastedPathOnThisHost" /\ isPath /\ p.src \in Watchers /\ alive[p.src]
             /\ ~\E w \in Watchers : WindowOf(w) = p.win /\ res \in onServer[Host(w)]
          \/ r = "NoLocalPathDuringUpload" /\ res \in {"local", "nothing"}
             /\ how # "owner gone" /\ uploadingHere
          \/ r = "ReadyPathPastes" /\ how = "rendered" /\ res = "nothing"
             /\ p.owner = p.win /\ p.val \in onServer[Host(p.src)] /\ ~replacing}

\* The paste gets res: judge it, then forget it.
Answer(p, res, how, replacing) ==
    LET bad == Judge(p, res, how, replacing)
    IN /\ paste' = NoPaste
       /\ broken' = broken \cup bad
       /\ badPaste' = IF bad = {} THEN badPaste
                      ELSE [in |-> p.win, entry |-> p.img, from |-> p.src, got |-> res,
                            how |-> how, broke |-> bad]

\* The session's process ends and Windows destroys its clipboard window: a
\* paste waiting on that window gets nothing.
Dies(w) ==
    /\ alive' = [alive EXCEPT ![w] = FALSE]
    /\ pc' = [pc EXCEPT ![w] = "dead"]
    /\ IF paste.phase = "asking" /\ paste.src = w
       THEN Answer(paste, "nothing", "owner gone", FALSE)
       ELSE UNCHANGED <<paste, broken, badPaste>>

\* Set-SshPasteClipboard on the PowerShell thread: New-DibBytes, then
\* PendingClipboard.Publish withdraws an older promise of this window and
\* sends WM_APP_PUBLISH. The window thread writes later (WriteOk, WriteFails).
Send(w, next, e) ==
    /\ pub' = [pub EXCEPT ![w] = e]
    /\ pc' = [pc EXCEPT ![w] = next]
    /\ prom' = [prom EXCEPT ![w] =
           IF Has("promise_before_empty")
           THEN [open |-> e.promise, ready |-> FALSE, val |-> None]
           ELSE IF prom[w].open THEN Withdrawn
           ELSE prom[w]]

Entry(content, owner, val, s, promise) ==
    [content |-> content, owner |-> owner, val |-> val, basis |-> s.seq,
     origin |-> s.origin, promise |-> promise]

\* The tick returns: the loop ticks again in 250 ms. Its local variables go.
Finish(w) ==
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ tfg' = [tfg EXCEPT ![w] = None]
    /\ img' = [img EXCEPT ![w] = None]
    /\ exp' = [exp EXCEPT ![w] = None]
    /\ wrote' = [wrote EXCEPT ![w] = FALSE]
    /\ keep' = [keep EXCEPT ![w] = FALSE]
    /\ tookOver' = [tookOver EXCEPT ![w] = FALSE]
    /\ syncText' = [syncText EXCEPT ![w] = None]

\* ... and sets $W.LastSeq = -1: after a write (to read it back), after
\* Sync-ClipboardText, and in the session loop's catch after a throw.
FinishAndReread(w) ==
    /\ Finish(w)
    /\ lastSeq' = [lastSeq EXCEPT ![w] = 0]

\* Complete-ClipboardPromise, then the rest of Invoke-WatcherTick's branch for
\* the terminal in front.
Complete(w, path) ==
    /\ prom' = IF wrote[w] /\ (path # None \/ ~Has("complete_only_on_success"))
               THEN [prom EXCEPT ![w] = [@ EXCEPT
                        !.ready = TRUE,
                        !.val = IF Has("resolve_on_failure") THEN exp[w]
                                ELSE IF path = exp[w] THEN path ELSE None]]
               ELSE prom
    /\ IF path = None \/ path # exp[w] \/ ~(wrote[w] \/ keep[w])
       THEN /\ pc' = [pc EXCEPT ![w] = "sync"]
            /\ syncText' = [syncText EXCEPT ![w] = path]
            /\ UNCHANGED <<tfg, img, exp, wrote, keep, tookOver>>
       ELSE Finish(w)

UserActs ==
    /\ budget > 0
    /\ budget' = budget - 1
    /\ writes' = [w \in Watchers |-> 0]
    /\ fresh' = [w \in Watchers |-> FALSE]

-----------------------------------------------------------------------------
(* The user and other programs *)

\* Copy a screenshot, image files in Explorer, or text. The app opens the
\* clipboard and empties it, which tells the old owner window.
UserCopies(c) ==
    /\ ~Blocked
    /\ UserActs
    /\ prom' = AfterEmpty
    /\ cb' = [content |-> c, by |-> "user", marked |-> FALSE, owner |-> None,
              text |-> IF c = "text" THEN "plain" ELSE "none",
              val |-> IF c = "text" THEN "usertext" ELSE None, origin |-> seq + 1]
    /\ seq' = seq + 1
    /\ UNCHANGED <<fg, busy, paste, onServer, pc, locals, pub, memory, lost, broken, badPaste>>

UserSwitches(x) ==
    /\ x # fg
    /\ UserActs
    /\ fg' = x
    /\ UNCHANGED <<cb, seq, busy, paste, onServer, pc, locals, pub, memory, prom, lost,
                   broken, badPaste>>

\* RenderText of session w's window, once it need not wait: promisedText if
\* the promise is open, else nothing. A path it gives stays on the clipboard
\* as concrete text; SetClipboardData may or may not move the sequence number.
\* win: the window in front when WM_RENDERFORMAT came; only the marker's
\* window gets the path (any window with the variant render_in_any_window).
Rendered(w, win) ==
    IF /\ prom[w].open /\ prom[w].val # None
       /\ ~Has("render_in_any_window") => win = cb.owner
    THEN prom[w].val ELSE "nothing"
KeepRendered(res) ==
    IF res # "nothing"
    THEN cb' = [cb EXCEPT !.text = "plain"] /\ seq' \in {seq, seq + 1}
    ELSE UNCHANGED <<cb, seq>>

\* Ctrl+V in Windows Terminal. It pastes the text format; with no text, the
\* local Windows path of copied files, and nothing for an image. For a
\* promised (delayed) text Windows sends WM_RENDERFORMAT to the owner window
\* and the paste holds the clipboard open until that window answers. The
\* window answers at once (no Write can run while the paste holds the
\* clipboard) unless its promise is open and not yet resolved: then the
\* paste waits (Render).
UserPastes ==
    /\ budget > 0
    /\ budget' = budget - 1
    /\ fg \in Terminals
    /\ paste.phase = "none"
    /\ ~busy
    /\ UserWaited
    /\ LET p == [phase |-> "asking", win |-> fg, img |-> cb.content, origin |-> cb.origin,
                 src |-> cb.by, owner |-> cb.owner, val |-> cb.val]
           w == cb.by
       IN IF cb.text = "delayed" /\ w \in Watchers /\ alive[w]
          THEN IF prom[w].open /\ ~prom[w].ready
               THEN paste' = p /\ UNCHANGED <<cb, seq, broken, badPaste>>
               ELSE Answer(p, Rendered(w, fg), "rendered", pc[w] \in WritePcs)
                    /\ KeepRendered(Rendered(w, fg))
          ELSE /\ Answer(p, CASE cb.text = "plain" -> cb.val
                              [] cb.text = "delayed" -> "nothing"   \* its window is gone
                              [] cb.content \in Images /\ Kind(cb.content) = "files" -> "local"
                              [] OTHER -> "nothing",
                         "at once", FALSE)
               /\ UNCHANGED <<cb, seq>>
    /\ UNCHANGED <<fg, busy, onServer, pc, locals, pub, memory, prom, writes, lost, fresh>>

\* Another program (a clipboard manager, rdpclip) keeps the clipboard open.
OtherAppHoldsClipboard ==
    /\ ~Blocked
    /\ budget > 0
    /\ budget' = budget - 1
    /\ busy' = TRUE
    /\ UNCHANGED <<fg, cb, seq, paste, onServer, pc, locals, pub, memory, prom, ghost>>

\* The sessions get a tick to catch up before the user pastes (UserWaited).
OtherAppClosesClipboard ==
    /\ busy
    /\ busy' = FALSE
    /\ fresh' = [w \in Watchers |-> FALSE]
    /\ UNCHANGED <<fg, cb, seq, budget, paste, onServer, pc, locals, pub, memory, prom, writes,
                   lost, broken, badPaste>>

\* The ssh session ends in wrapper mode: the loop in Invoke-Wrapper stops
\* between ticks and runs Restore-Clipboard.
SessionEnds(w) ==
    /\ alive[w]
    /\ pc[w] = "idle"
    /\ UserActs
    /\ pc' = [pc EXCEPT ![w] = "restore"]
    /\ UNCHANGED <<fg, cb, seq, busy, paste, onServer, locals, pub, memory, prom, lost,
                   broken, badPaste>>

\* In ssh mode ssh terminates the --proxy process at any point: no restore,
\* and its clipboard window is gone, so a waiting paste gets nothing.
SessionKilled(w) ==
    /\ alive[w]
    /\ UserActs
    /\ Dies(w)
    /\ pub' = [pub EXCEPT ![w] = NoEntry]
    /\ UNCHANGED <<fg, cb, seq, busy, onServer, locals, st, lastSeq, lastFg, uploaded, failed,
                   due, prom, lost>>

\* A failed upload's backoff (30 s, then 1 min, ...) runs out.
RetryTimeComes(w, i) ==
    /\ i \in failed[w] \ due[w]
    /\ due' = [due EXCEPT ![w] = @ \cup {i}]
    /\ writes' = [v \in Watchers |-> 0]
    /\ UNCHANGED <<world, pc, locals, pub, st, lastSeq, lastFg, uploaded, failed, alive, prom,
                   lost, fresh, broken, badPaste>>

-----------------------------------------------------------------------------
(* A session's PowerShell thread *)

\* Invoke-WatcherTick up to its first write: read the foreground window and,
\* when the sequence number moved, the clipboard; then decide. The check that
\* sequence number and window are unchanged, just before a write, belongs to
\* this step too: the watcher does nothing in between. What follows the check
\* (New-DibBytes, Publish, then Write on the window thread) are later steps.
Tick(w) ==
    /\ alive[w]
    /\ pc[w] = "idle"
    /\ LET needRead == seq # lastSeq[w]
       IN IF ~needRead /\ fg = lastFg[w] /\ ~Wake(w)
          THEN /\ fresh' = [fresh EXCEPT ![w] = TRUE]
               /\ UNCHANGED <<world, pc, locals, pub, memory, prom, writes, lost, broken,
                              badPaste>>
          ELSE IF needRead /\ Blocked
          THEN \* ReadSnapshot throws "the clipboard is busy"; the loop's catch. This
               \* tick saw nothing, so it does not count for UserWaited.
               /\ lastSeq' = [lastSeq EXCEPT ![w] = 0]
               /\ UNCHANGED <<world, pc, locals, pub, st, lastFg, uploaded, failed, due, alive,
                              prom, writes, lost, fresh, broken, badPaste>>
          ELSE LET s == IF needRead THEN Snap ELSE st[w]
                   i == s.content
                   e == IF i \in Images THEN Expected(w, i) ELSE None
                   otherSession == s.marked /\ s.hasText /\ s.owner = fg /\ s.by # w
                   shown == /\ s.marked /\ s.hasText /\ s.val = e
                            /\ ~Has("shown_any_entry") => CanStillPaste(w, s)
                   failing == i \in Images /\ i \in failed[w]
               IN /\ fresh' = [fresh EXCEPT ![w] = TRUE]
                  /\ st' = [st EXCEPT ![w] = s]
                  /\ lastSeq' = [lastSeq EXCEPT ![w] = s.seq]
                  /\ lastFg' = [lastFg EXCEPT ![w] = fg]
                  /\ UNCHANGED <<world, uploaded, failed, due, alive, writes, lost, broken,
                                 badPaste>>
                  /\ CASE i \notin Images ->
                            Finish(w) /\ UNCHANGED <<pub, prom>>
                       [] WindowOf(w) = fg ->
                            \* The terminal is in front: promise the path, then upload.
                            /\ tfg' = [tfg EXCEPT ![w] = fg]
                            /\ img' = [img EXCEPT ![w] = i]
                            /\ exp' = [exp EXCEPT ![w] = e]
                            /\ keep' = [keep EXCEPT ![w] = shown \/ otherSession]
                            /\ tookOver' = [tookOver EXCEPT ![w] = ~otherSession /\ ~failing]
                            /\ UNCHANGED <<wrote, syncText>>
                            /\ IF ~shown /\ ~otherSession /\ ~failing
                                  /\ ~Has("upload_before_write")
                               THEN Send(w, "writePromise",
                                         Entry(i, fg, e, s, ~Has("write_path_before_upload")))
                               ELSE pc' = [pc EXCEPT ![w] = "getPath"] /\ UNCHANGED <<pub, prom>>
                       [] s.marked /\ s.hasText /\ (s.owner # fg \/ Has("strip_any_owner")) ->
                            \* Another window is in front: put the plain image back.
                            /\ Send(w, "writeStrip", Entry(i, None, None, s, FALSE))
                            /\ UNCHANGED locals
                       [] OTHER ->
                            Finish(w) /\ UNCHANGED <<pub, prom>>

\* Get-UploadedPath when no upload is needed: the cached path, or $null while
\* a failed upload waits for its retry time. Otherwise the upload starts.
GetPath(w) ==
    /\ alive[w]
    /\ pc[w] = "getPath"
    /\ LET i == img[w] IN
       IF uploaded[w][i] # None THEN Complete(w, uploaded[w][i])
       ELSE IF i \in failed[w] /\ i \notin due[w] THEN Complete(w, None)
       ELSE pc' = [pc EXCEPT ![w] = "upload"] /\ UNCHANGED <<locals, prom>>
    /\ UNCHANGED <<world, pub, memory, ghost>>

\* Send-Image returns in Get-UploadedItemPath, then Complete-ClipboardPromise.
UploadEnds(w, r) ==
    /\ alive[w]
    /\ pc[w] = "upload"
    /\ LET i == img[w]
           path == CASE r = "plain" -> Plain(i)
                     [] r = "alt" -> Alt(i, Host(w))
                     [] r = "fail" -> None
       IN /\ IF path # None
             THEN /\ onServer' = [onServer EXCEPT ![Host(w)] = @ \cup {path}]
                  /\ uploaded' = [uploaded EXCEPT ![w][i] = path]
                  /\ failed' = [failed EXCEPT ![w] = @ \ {i}]
             ELSE /\ failed' = [failed EXCEPT ![w] = @ \cup {i}]
                  /\ UNCHANGED <<onServer, uploaded>>
          /\ due' = [due EXCEPT ![w] = @ \ {i}]
          /\ Complete(w, path)
    /\ UNCHANGED <<fg, cb, seq, busy, budget, paste, pub, st, lastSeq, lastFg, alive, ghost>>

\* Sync-ClipboardText: read again; write $Text only if the same image is
\* there, the entry allows it, and sequence number and window are unchanged.
Sync(w) ==
    /\ alive[w]
    /\ pc[w] = "sync"
    /\ IF Blocked
       THEN FinishAndReread(w) /\ UNCHANGED <<pub, prom>>   \* ReadSnapshot throws
       ELSE LET c == Snap
                t == syncText[w]
                skip == \/ c.content # img[w]
                        \/ /\ t # None
                           /\ \/ ~c.marked /\ c.hasText
                              \/ /\ c.marked /\ c.hasText /\ c.val = t
                                 /\ ~Has("shown_any_entry") => CanStillPaste(w, c)
                              \/ c.marked /\ c.hasText /\ c.owner = tfg[w] /\ c.by # w
                        \/ t = None /\ ~(c.marked /\ c.hasText /\ c.by = w)
                        \/ fg # tfg[w]
            IN IF skip
               THEN FinishAndReread(w) /\ UNCHANGED <<pub, prom>>
               ELSE /\ Send(w, "writeSync",
                            Entry(c.content, IF t = None THEN None ELSE tfg[w], t, c, FALSE))
                    /\ UNCHANGED <<locals, lastSeq>>
    /\ UNCHANGED <<world, st, lastFg, uploaded, failed, due, alive, ghost>>

\* Restore-Clipboard on exit; then the process ends, and its window with it.
Restore(w) ==
    /\ pc[w] = "restore"
    /\ LET c == Snap
       IN IF ~Blocked /\ c.content \in Images /\ c.marked /\ c.hasText /\ c.by = w
          THEN Send(w, "writeRestore", Entry(c.content, None, None, c, FALSE))
               /\ UNCHANGED alive
               /\ UNCHANGED <<paste, broken, badPaste>>
          ELSE Dies(w) /\ UNCHANGED <<pub, prom>>
    /\ UNCHANGED <<fg, cb, seq, busy, budget, onServer, locals, st, lastSeq, lastFg, uploaded,
                   failed, due, writes, lost, fresh>>

-----------------------------------------------------------------------------
(* A session's PendingClipboard window thread *)

\* WM_APP_PUBLISH -> Write: OpenClipboard, EmptyClipboard (WM_DESTROYCLIPBOARD
\* to the old owner), set the new promise, SetClipboardData, CloseClipboard.
\* Publish then returns to the PowerShell thread, which goes on.
WriteOk(w) ==
    /\ alive[w]
    /\ pc[w] \in WritePcs
    /\ ~Blocked
    /\ ~Has("write_ignores_seq") => seq = pub[w].basis
    /\ LET e == pub[w]
           p1 == AfterEmpty
       IN /\ cb' = [content |-> e.content, by |-> w, marked |-> TRUE, owner |-> e.owner,
                    text |-> IF e.promise THEN "delayed"
                             ELSE IF e.val = None THEN "none" ELSE "plain",
                    val |-> e.val, origin |-> e.origin]
          /\ lost' = (lost \/ (cb.by = "user" /\ seq # e.basis))
          /\ prom' = IF Has("promise_before_empty") THEN p1
                     ELSE [p1 EXCEPT ![w] = [open |-> e.promise, ready |-> FALSE, val |-> None]]
    /\ seq' = seq + 1
    /\ writes' = [writes EXCEPT ![w] = @ + 1]
    /\ pub' = [pub EXCEPT ![w] = NoEntry]
    /\ CASE pc[w] = "writePromise" ->
              /\ pc' = [pc EXCEPT ![w] = "getPath"]
              /\ wrote' = [wrote EXCEPT ![w] = TRUE]
              /\ lastSeq' = [lastSeq EXCEPT ![w] = 0]
              /\ UNCHANGED <<tfg, img, exp, keep, tookOver, syncText, alive>>
         [] pc[w] \in {"writeStrip", "writeSync"} ->
              FinishAndReread(w) /\ UNCHANGED alive
         [] pc[w] = "writeRestore" ->
              /\ pc' = [pc EXCEPT ![w] = "dead"]   \* no paste waits: Write needed the clipboard
              /\ alive' = [alive EXCEPT ![w] = FALSE]
              /\ UNCHANGED <<locals, lastSeq>>
    /\ UNCHANGED <<fg, busy, budget, paste, onServer, st, lastFg, uploaded, failed, due, fresh,
                   broken, badPaste>>

\* Write gives up: 20 tries of OpenClipboard failed, because another program
\* or a paste that waits on another window holds the clipboard. Publish
\* returns 0 and Set-SshPasteClipboard throws.
WriteFails(w) ==
    /\ alive[w]
    /\ pc[w] \in WritePcs
    /\ \/ busy
       \/ paste.phase = "asking" /\ paste.src # w
       \/ ~Has("write_ignores_seq") /\ ~Blocked /\ seq # pub[w].basis
    /\ pub' = [pub EXCEPT ![w] = NoEntry]
    /\ prom' = IF Has("promise_before_empty")
               THEN [prom EXCEPT ![w].open = FALSE] ELSE prom
    /\ IF pc[w] = "writeRestore"
       THEN Dies(w) /\ UNCHANGED <<locals, lastSeq>>   \* Restore-Clipboard catches it
       ELSE FinishAndReread(w) /\ UNCHANGED <<alive, paste, broken, badPaste>>
    /\ UNCHANGED <<fg, cb, seq, busy, budget, onServer, st, lastFg, uploaded, failed, due,
                   writes, lost, fresh>>

\* RenderText stops waiting: Resolve or Fail set textReady, or the promise
\* was withdrawn (Publish, or WM_DESTROYCLIPBOARD).
Render(w) ==
    /\ paste.phase = "asking"
    /\ paste.src = w
    /\ alive[w]
    /\ ~prom[w].open \/ prom[w].ready
    /\ Answer(paste, Rendered(w, paste.win), "rendered", pc[w] \in WritePcs)
    /\ KeepRendered(Rendered(w, paste.win))
    /\ UNCHANGED <<fg, busy, budget, onServer, pc, locals, pub, memory, prom, writes, lost,
                   fresh>>

-----------------------------------------------------------------------------

WatcherThread(w) ==
    \/ Tick(w) \/ GetPath(w) \/ Sync(w) \/ Restore(w)
    \/ \E r \in {"plain", "alt", "fail"} : UploadEnds(w, r)

WindowThread(w) == WriteOk(w) \/ WriteFails(w) \/ Render(w)

\* Every session has ended: an end state, not a hang.
Done == (\A w \in Watchers : ~alive[w]) /\ UNCHANGED vars

Next ==
    \/ \E c \in Images \cup {"text"} : UserCopies(c)
    \/ \E x \in Terminals \cup {"app"} : UserSwitches(x)
    \/ UserPastes
    \/ OtherAppHoldsClipboard
    \/ OtherAppClosesClipboard
    \/ \E w \in Watchers : SessionEnds(w) \/ SessionKilled(w)
    \/ \E w \in Watchers, i \in Images : RetryTimeComes(w, i)
    \/ \E w \in Watchers : WatcherThread(w) \/ WindowThread(w)
    \/ Done

\* The sessions' threads keep running and every upload ends (Send-Image has a
\* timeout). No program holds the clipboard forever.
Fairness ==
    /\ \A w \in Watchers : WF_vars(WatcherThread(w)) /\ WF_vars(WindowThread(w))
    /\ WF_vars(OtherAppClosesClipboard)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties. The skill states each in plain words with the harm it guards. *)

\* A pasted remote path names a file that exists on the server of the
\* session whose entry it came from.
PastedPathExists == "PastedPathExists" \notin broken

\* A remote path that a running session put on the clipboard, pasted into a
\* terminal window, names a file on the server of a session in that window.
\* (A path left behind by a session that ended is the README's known
\* limitation for ssh mode.)
PastedPathOnThisHost == "PastedPathOnThisHost" \notin broken

\* While a session uploads a copy it took over in its window (it promised the
\* path, or found its expected path already there; not a retry after a
\* failure, and not a copy another session of the window handles), Ctrl+V of
\* that copy there gets the remote path, waiting if it must, never the local
\* Explorer path or nothing.
NoLocalPathDuringUpload == "NoLocalPathDuringUpload" \notin broken

\* Once a session's promised path exists on its server, Ctrl+V of that entry
\* in the window it was written for gets the path, unless the session is
\* replacing the entry at that moment.
ReadyPathPastes == "ReadyPathPastes" \notin broken

\* A session never erases a copy the user made after the clipboard read that
\* its write was based on.
NoLostCopy == ~lost

\* Between two things the user does (or two retry timers), each session
\* writes the clipboard a bounded number of times: sessions never keep
\* rewriting each other's entries. Where 5 comes from: a write decided just
\* before the user acted can land after it (1), then the session's own promise
\* and Sync-ClipboardText of another name (2); a late write of the other
\* session (see NoLostCopy) can undo that entry twice, each costing one more
\* promise (2). Write refuses a write decided before the user acted, so TLC
\* finds no more than 3 within the bounds of check.sh (5 with the variant
\* write_ignores_seq). A loop between sessions exceeds any bound.
MaxWritesPerAction == 3
BoundedWrites == \A w \in Watchers : writes[w] <= MaxWritesPerAction

\* A paste that waits for a promised path gets an answer from the session
\* without the 30-second PromiseWaitMilliseconds limit.
PasteAnswered == paste.phase = "asking" ~> paste.phase = "none"

=============================================================================
