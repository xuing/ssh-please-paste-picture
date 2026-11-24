#!/usr/bin/env bash
# Makes a package file in a checkout of the tap or the bucket the one SCRIPT writes for the
# Latest release, and pushes it when it changed.
#
#   sync-package.sh SCRIPT FILE TARGET
#
#   homebrew-formula.sh Formula/ssh-paste.rb  in a checkout of xuing/homebrew-tap
#   scoop-manifest.sh   bucket/ssh-paste.json in a checkout of xuing/scoop-bucket
#
# Environment: SHA (the tested commit), GITHUB_REPOSITORY, GH_TOKEN, GITHUB_OUTPUT. It writes
# the outputs version (of the Latest release) and synced=true once TARGET has the file for that
# release. When main has moved past SHA it does nothing and leaves synced unset: the run of the
# newer commit syncs. SHA256SUMS of the release is checked against its attestation first.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage='usage: sync-package.sh SCRIPT FILE TARGET'
script=${1:?$usage}
file=${2:?$usage}
target=${3:?$usage}
scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=${GITHUB_OUTPUT:-/dev/null}

latest=$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" -q .tag_name)
[[ "$latest" =~ $TAG_RE ]] || { echo "::error::the Latest release is $latest" >&2; exit 1; }
echo "version=${latest#v}" >> "$out"
head=$(gh api "repos/$GITHUB_REPOSITORY/commits/main" -q .sha)
if [ "$head" != "$SHA" ]; then echo "main is at $head now; its own run syncs"; exit 0; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh release download "$latest" -p SHA256SUMS -D "$work"
gh attestation verify "$work/SHA256SUMS" --repo "$GITHUB_REPOSITORY" \
  --signer-workflow "$GITHUB_REPOSITORY/.github/workflows/publish.yml"
mkdir -p "$target/$(dirname "$file")"
bash "$scripts/$script" "${latest#v}" "https://github.com/$GITHUB_REPOSITORY/releases/download/$latest" "$work/SHA256SUMS" > "$target/$file"
cat "$target/$file"

cd "$target"
git add "$file"
if git diff --cached --quiet; then
  echo "it already has this file for $latest"
else
  git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -q -m "ssh-paste ${latest#v}" -m "Written by $GITHUB_REPOSITORY@$SHA"
  git push origin HEAD
fi
echo "synced=true" >> "$out"
