# shellcheck shell=bash
# Shared by the macOS test scripts (sourced, not run): tests/mac/jxa.sh, e2e.sh and
# footprint.sh. They run on a Mac with a logged-in GUI session (the GitHub macOS
# runners have one). Every wait has a deadline, so a hidden dialog fails a test
# instead of hanging the job.

# shellcheck disable=SC2154 # $work is set by the script that sources this file.
repo=$(cd "$(dirname "$0")/../.." && pwd)
# The checks read ssh-paste's English messages, whatever the runner's language.
export SSH_PASTE_LANG=en
pbjs=$repo/tests/mac/pb.js
failures=0

pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
check() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3"; printf '        expected: %s\n        got:      %s\n' "$2" "$1"; fi; }
section() { printf '\n== %s\n' "$*"; }

# ms: milliseconds since the epoch.
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# to SECS cmd...: run cmd, killed after SECS seconds (exit 142).
to() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$s" "$@"; }

# pb ARGS...: the pasteboard helper (tests/mac/pb.js).
pb() { to 60 osascript -l JavaScript "$pbjs" "$@"; }

# wait_for SECS cmd...: run cmd every 0.1 s until it succeeds; false after SECS.
wait_for() {
    local limit=$1; shift
    local deadline=$(( $(ms) + limit * 1000 ))
    while [ "$(ms)" -lt "$deadline" ]; do
        if "$@" > /dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    return 1
}

# entry_is TEXT / entry_like PATTERN: our entry on the pasteboard carries this text.
# A user presses Cmd+V a moment after a copy; a test waits for the watcher's write.
entry_is() { [ "$(pb marker-text)" = "$1" ]; }
# files_are JSON: the pasteboard's file URLs (not our marker) are exactly these paths.
files_are() { [ "$(pb files)" = "$1" ]; }
# shellcheck disable=SC2254 # the pattern is a glob on purpose
entry_like() { case $(pb marker-text) in $1) return 0 ;; esac; return 1; }

# paste OUT: pbpaste into OUT, with its time in ms in OUT.ms (a paste may wait).
paste_timed() {
    local t0
    t0=$(ms)
    to 60 pbpaste > "$1" 2> /dev/null || true
    echo $(( $(ms) - t0 )) > "$1.ms"
}

front_bundle() { lsappinfo info -only bundleid "$(lsappinfo front)" | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p'; }
front_is() { [ "$(front_bundle)" = "$1" ]; }

# activate APP: bring an app to the front without Apple Events (open -a), and wait.
activate() {
    open -a "$1"
    wait_for 20 front_is "$2" || fail "$1 did not come to the front (front: $(front_bundle))"
    sleep 0.5
}

# terminal_run NAME SCRIPT: open a Terminal.app window that runs SCRIPT (a shell
# script body) from a .command file; Terminal comes to the front.
terminal_run() {
    local f=$work/$1.command
    printf '#!/bin/zsh\n%s\n' "$2" > "$f"
    chmod +x "$f"
    open -a Terminal "$f"
    wait_for 30 front_is com.apple.Terminal || fail "Terminal did not come to the front for $1"
}

# sha16 FILE: the first 32 hex digits of the SHA-256 (the remote name of an image).
sha16() { shasum -a 256 "$1" | cut -c 1-32; }

finish() {
    printf '\n'
    if [ "$failures" -eq 0 ]; then echo "$(basename "$0"): all checks passed"; exit 0; fi
    echo "$(basename "$0"): $failures check(s) failed"
    exit 1
}
