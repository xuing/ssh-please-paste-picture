#!/usr/bin/env bash
# Model-checks verify/watcher/ClipboardWatcher.tla, the TLA+ model of the clipboard
# watcher in src/ssh-paste.ps1, with TLC. How to read the results and keep the model
# in step with the code: .claude/skills/verify-clipboard-watcher/SKILL.md.
#
#   verify/watcher/check.sh             every property on every layout, on the code and
#                                       on the code with the candidate fixes (2-3 minutes)
#   verify/watcher/check.sh --mutants   also the broken variants: each must break its
#                                       property, which shows the checks can still fail
#   verify/watcher/check.sh --keep DIR  keep the TLC output (configs, traces) in DIR
#
# Needs Java 11 or later (JAVA, or java on PATH) and, on the first run, the network:
# tla2tools.jar of a fixed release is downloaded once, checked against its SHA-256 and
# kept in SSH_PASTE_TLA_CACHE (default: ${XDG_CACHE_HOME:-~/.cache}/ssh-paste-tla). Set TLA2TOOLS
# to use a jar you already have; it must have the same checksum.
#
# Exit code 0: every result is what the table below expects. 1: a result differs (an
# unexpected counterexample, or a known finding that no longer shows). 2: a run failed.
set -euo pipefail

TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_VERSION}/tla2tools.jar"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mutants=0
keep=''
while [ $# -gt 0 ]; do
    case "$1" in
        --mutants) mutants=1 ;;
        --keep) keep=${2:?--keep needs a directory}; shift ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- The runs ----------------------------------------------------------------------
# layout|user steps|images|variants|INVARIANT or PROPERTY|names|expected
#   hold:    TLC must find no counterexample
#   finding: a finding in the code at the sync commit (see the skill); TLC must still
#            find it. When a fix makes it hold, move it to "hold" in the same commit.
#   break:   a broken variant of the code; TLC must find a counterexample
# Layouts, images, variants and the reasons for the budgets: see the skill.
ONE='one|6|{"i1", "i2"}'
WINDOWS='windows|4|{"i2"}'
TABS='tabs|3|{"i2"}'
FIXES='{"fix_seq_in_write", "fix_shown_live", "fix_render_in_owner_window"}'
ALL='PastedPathExists PastedPathOnThisHost NoLocalPathDuringUpload ReadyPathPastes NoLostCopy BoundedWrites'
runs=(
    "$ONE|{}|INVARIANT|PastedPathExists NoLocalPathDuringUpload BoundedWrites|hold"
    'one|5|{"i1", "i2"}|{}|PROPERTY|PasteAnswered|hold'
    "$WINDOWS|{}|INVARIANT|PastedPathExists BoundedWrites|hold"
    'windows|3|{"i2"}|{}|PROPERTY|PasteAnswered|hold'
    "$TABS|{}|INVARIANT|PastedPathExists PastedPathOnThisHost ReadyPathPastes BoundedWrites|hold"
    "$ONE|{}|INVARIANT|NoLostCopy|finding"
    "$ONE|{}|INVARIANT|PastedPathOnThisHost|finding"
    "$ONE|{}|INVARIANT|ReadyPathPastes|finding"
    "$WINDOWS|{}|INVARIANT|NoLocalPathDuringUpload|finding"
    "$TABS|{}|INVARIANT|NoLocalPathDuringUpload|finding"
    # The code with the three candidate fixes: every invariant holds. While a property
    # is a known finding in the code, these runs are what catch a new break of it.
    "$ONE|$FIXES|INVARIANT|$ALL|hold"
    "$WINDOWS|$FIXES|INVARIANT|$ALL|hold"
    "$TABS|$FIXES|INVARIANT|$ALL|hold"
)
mutant_runs=(
    "$ONE|{\"write_path_before_upload\"}|INVARIANT|PastedPathExists|break"
    "$ONE|{\"resolve_on_failure\"}|INVARIANT|PastedPathExists|break"
    "$ONE|{\"upload_before_write\"}|INVARIANT|NoLocalPathDuringUpload|break"
    "$ONE|{\"fix_shown_live\", \"promise_before_empty\"}|INVARIANT|ReadyPathPastes|break"
    'one|4|{"i1", "i2"}|{"complete_only_on_success"}|PROPERTY|PasteAnswered|break'
    "$WINDOWS|{\"strip_any_owner\"}|INVARIANT|BoundedWrites|break"
)
if [ "$mutants" = 1 ]; then runs+=("${mutant_runs[@]}"); fi

# --- Tools -------------------------------------------------------------------------
sha256_of() {
    if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

java=${JAVA:-java}
if ! command -v "$java" > /dev/null; then
    echo "Java 11 or later is needed: install a JDK, or set JAVA to a java binary." >&2
    exit 2
fi
java_major=$("$java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1)
if [ -z "$java_major" ] || [ "$java_major" -lt 11 ]; then
    echo "TLC needs Java 11 or later; $java is version ${java_major:-unknown}." >&2
    exit 2
fi

jar=${TLA2TOOLS:-}
if [ -z "$jar" ]; then
    cache=${SSH_PASTE_TLA_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ssh-paste-tla}
    jar="$cache/tla2tools-$TLA_VERSION.jar"
    if [ ! -f "$jar" ] || [ "$(sha256_of "$jar")" != "$TLA_SHA256" ]; then
        mkdir -p "$cache"
        echo "Downloading tla2tools.jar $TLA_VERSION into $cache"
        curl --fail --silent --show-error --location --retry 3 --output "$jar.part" "$TLA_URL"
        mv "$jar.part" "$jar"
    fi
fi
if [ "$(sha256_of "$jar")" != "$TLA_SHA256" ]; then
    echo "$jar does not have the SHA-256 of tla2tools $TLA_VERSION ($TLA_SHA256)." >&2
    exit 2
fi

if [ -n "$keep" ]; then
    work=$keep
    mkdir -p "$work"
else
    work=$(mktemp -d "${TMPDIR:-/tmp}/watcher-tlc.XXXXXX")
fi
cp "$here/ClipboardWatcher.tla" "$work/"

# --- Run ---------------------------------------------------------------------------
surprises=0
errors=0
n=0
start=$(date +%s)
printf '%-8s %-8s %-28s %s\n' layout expected variants properties
for run in "${runs[@]}"; do
    IFS='|' read -r layout steps images mutant kind names expect <<< "$run"
    n=$((n + 1))
    name=$(printf '%02d-%s' "$n" "$layout")
    {
        echo 'SPECIFICATION Spec'
        echo 'CONSTANTS'
        echo "    Layout = \"$layout\""
        echo "    Steps = $steps"
        echo "    Images = $images"
        echo "    Mutants = $mutant"
        for p in $names; do echo "$kind $p"; done
    } > "$work/$name.cfg"
    set +e
    (cd "$work" && "$java" -XX:+UseParallelGC -Djava.io.tmpdir="$work" -cp "$jar" tlc2.TLC \
        -workers auto -cleanup -metadir "$work/states-$name" -config "$name.cfg" \
        ClipboardWatcher.tla) > "$work/$name.out" 2>&1
    set -e
    out="$work/$name.out"
    if grep -q '^Model checking completed. No error has been found' "$out"; then
        got=hold
    elif grep -qE '^Error: (Invariant [A-Za-z]+ is violated|Temporal properties were violated)' "$out"; then
        got=break
    else
        got=error
    fi
    states=$(grep -oE '[0-9]+ distinct states found' "$out" | tail -n 1 | cut -d' ' -f1 || true)
    which=$(grep -oE '^Error: Invariant [A-Za-z]+' "$out" | head -n 1 | cut -d' ' -f3 || true)
    detail="$got (${states:-?} states)"
    if [ "$got" = break ]; then detail="$got: ${which:-$names} (${states:-?} states)"; fi
    verdict=ok
    case "$expect:$got" in
        hold:hold|finding:break|break:break) ;;
        *:error) verdict=ERROR; errors=$((errors + 1)) ;;
        finding:hold) verdict='FINDING GONE'; surprises=$((surprises + 1)) ;;
        *) verdict=UNEXPECTED; surprises=$((surprises + 1)) ;;
    esac
    shown_mutant=$(printf '%s' "$mutant" | tr -d '{}"' | sed 's/, /+/g')
    printf '%-8s %-8s %-28s %s\n' "$layout" "$expect" "${shown_mutant:-(code)}" "$names"
    printf '         -> %s  [%s]\n' "$detail" "$verdict"
    if [ "$verdict" != ok ]; then echo "    TLC output: $out"; fi
done

echo "$n runs in $(( $(date +%s) - start )) s"
if [ "$errors" -gt 0 ] || [ "$surprises" -gt 0 ] || [ -n "$keep" ]; then echo "TLC output: $work"; fi
if [ "$errors" -gt 0 ]; then
    echo "$errors run(s) failed to complete: read the TLC output above (a model error?)." >&2
    exit 2
fi
if [ "$surprises" -gt 0 ]; then
    echo "$surprises result(s) differ from the table in $0." >&2
    echo 'Read each trace with /statechart; see the skill verify-clipboard-watcher.' >&2
    exit 1
fi
if [ -z "$keep" ]; then rm -rf "$work"; fi
echo 'All results are as expected.'
