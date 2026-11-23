#!/usr/bin/env bash
# Writes a copy of ssh-paste.ps1 whose version is the release version.
#
#   stamp-version.sh SRC OUT VERSION      VERSION is 0.1.N, no "v"
#
# In the repository the version line is exactly the one in $from below, so a build that
# does not stamp is plainly a development build. The copy for a release differs from SRC in
# that one line and in nothing else; the script checks that and that the copy still parses.
# tests/ssh-paste.Tests.ps1 ("repository guards") fails when this line and the one in
# src/ssh-paste.ps1 drift apart.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

src=${1:?usage: stamp-version.sh SRC OUT VERSION}
out=${2:?usage: stamp-version.sh SRC OUT VERSION}
version=${3:?usage: stamp-version.sh SRC OUT VERSION}
[[ "v$version" =~ $TAG_RE ]] || { echo "::error::bad version: $version" >&2; exit 1; }

from="\$script:Version = '0.0.0-dev'"
to="\$script:Version = '$version'"

# .gitattributes checks .ps1 out with CRLF, hence tr. The awk program keeps each line's own ending.
count=$(tr -d '\r' < "$src" | grep -cxF "$from" || true)
[ "$count" = 1 ] || { echo "::error::$src must have exactly one line $from (found $count)" >&2; exit 1; }
other=$(tr -d '\r' < "$src" | grep -c '^\$script:Version' || true)
[ "$other" = 1 ] || { echo "::error::$src has $other lines that start with \$script:Version, not 1" >&2; exit 1; }

FROM=$from TO=$to awk '
  { line = $0; cr = ""; if (sub(/\r$/, "", line)) cr = "\r" }
  line == ENVIRON["FROM"] { printf "%s%s\n", ENVIRON["TO"], cr; next }
  { print }' "$src" > "$out"

changed=$(diff <(tr -d '\r' < "$src") <(tr -d '\r' < "$out") | grep -c '^>' || true)
stamped=$(tr -d '\r' < "$out" | grep -cxF "$to" || true)
echo "version line: $from -> $to; lines changed: $changed"
[ "$changed" = 1 ] && [ "$stamped" = 1 ] || { echo "::error::stamping changed $changed lines instead of 1" >&2; exit 1; }
cmp -s <(wc -l < "$src") <(wc -l < "$out") || { echo "::error::the copy has another number of lines" >&2; exit 1; }

if command -v pwsh > /dev/null; then
  OUT=$out pwsh -NoProfile -Command '$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:OUT, [ref]$null, [ref]$e); if ($e) { $e | ForEach-Object { Write-Host $_ }; exit 1 }; Write-Host "the stamped copy parses"'
else
  echo "pwsh not found: the parse check is skipped" >&2
fi
