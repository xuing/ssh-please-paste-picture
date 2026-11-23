#!/usr/bin/env bash
# Decides whether the tested commit is released, and if so makes sure it has its version
# tag. Called by .github/workflows/publish.yml inside its concurrency group "release", so
# no other release is being planned or published at the same time.
# Run it in a clone with full history. The remote "origin" must accept a tag push.
#
# Input (environment):
#   SHA                the commit that CI tested (github.sha), 40 hex digits.
#   GITHUB_REPOSITORY  owner/name; GH_TOKEN lets gh read the releases.
#   GITHUB_OUTPUT      where "tag=" and "reason=" go (stdout when unset).
#
# Output: tag=v0.1.N when the commit is to be published, tag= (empty) when there is
# nothing to do.
#
# The rules:
#   1. Only the newest commit of main releases. When origin/main is not SHA, a newer push
#      exists and its own run releases it (and everything before it).
#   2. A v0.1.N tag that already points at SHA is reused: that is a rerun. A tag is never
#      moved, and one commit never gets two versions.
#   3. Otherwise the commit is released only if src/ or install.ps1 differ from the last
#      published release (the highest v0.1.N whose release is not a draft). With no
#      published release, everything counts as changed.
#   4. The version is one above the highest v0.1.N tag, published or not, so a number is
#      never reused. The first one is v0.1.0. The tag is annotated and pushed without force.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${SHA:?SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
OUT=${GITHUB_OUTPUT:-/dev/stdout}

[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "SHA is not a full commit id: $SHA" >&2; exit 1; }
git cat-file -e "$SHA^{commit}" || { echo "commit $SHA is not in this clone (fetch the full history)" >&2; exit 1; }

finish() {
  # finish <tag> <reason>
  echo "$2"
  { echo "tag=$1"; echo "reason=$2"; } >> "$OUT"
  exit 0
}

main=$(git ls-remote origin refs/heads/main | cut -f1)
[ -n "$main" ] || { echo "origin has no main branch" >&2; exit 1; }
if [ "$main" != "$SHA" ]; then
  finish "" "main is at $main, not at the tested $SHA: the run for the newer commit releases it"
fi

git fetch --quiet --tags origin

existing=$(git tag --points-at "$SHA" | valid_tags | tail -n 1)
if [ -n "$existing" ]; then
  finish "$existing" "$existing already points at $SHA: continuing with it"
fi

last=$(published_tags | tail -n 1)
if [ -n "$last" ]; then
  changed=$(git diff --name-only "refs/tags/$last^{commit}" "$SHA" -- src install.ps1)
  if [ -z "$changed" ]; then
    finish "" "src/ and install.ps1 are the same as in $last: nothing to release"
  fi
  echo "changed since $last:"; echo "$changed"
fi

highest=$(git tag --list 'v0.1.*' | valid_tags | tail -n 1)
if [ -n "$highest" ]; then
  next="v0.1.$(( 10#${highest#v0.1.} + 1 ))"
else
  next="v0.1.0"
fi

git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  tag -a "$next" -m "ssh-paste ${next#v}" "$SHA"
git push origin "refs/tags/$next"
finish "$next" "tagged $SHA as $next (last release: ${last:-none})"
