#!/usr/bin/env bash
# Publishes the release of a tag, draft first, and checks it before anyone can see it.
# Used by .github/workflows/publish.yml, inside its concurrency group "release".
#
#   publish-release.sh v0.1.N DIST NOTES
#     DIST   the folder with the four built files: install.ps1 ssh-paste.cmd ssh-paste.ps1 SHA256SUMS
#     NOTES  the release notes file
#
# Environment: GITHUB_REPOSITORY and GH_TOKEN. ATTEST_WAIT: seconds between attestation
# lookups (default 10).
#
# Every step can be run again after a failure; none is repeated blindly:
#   1. No release for the tag: create it as a draft with the four files (--verify-tag: the
#      tag must exist). A draft of an earlier run is deleted and created again; nobody can
#      see a draft. A published release is only checked.
#   2. Download the files from the release and check them: exactly the four files, the sums
#      match, they are the built files, ssh-paste.ps1 says the tag's version, and the build
#      provenance attestations are valid.
#   3. Publish it (--draft=false). It gets the Latest mark only when no published release has
#      a higher version, and the Latest mark is checked afterwards.
# A gh command that fails stops the script, so a half-known state is never published.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tag=${1:?usage: publish-release.sh v0.1.N DIST NOTES}
dist=${2:?usage: publish-release.sh v0.1.N DIST NOTES}
notes=${3:?usage: publish-release.sh v0.1.N DIST NOTES}
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
[[ "$tag" =~ $TAG_RE ]] || { echo "::error::bad tag: $tag" >&2; exit 1; }
fail() { echo "::error::$*" >&2; exit 1; }

files="SHA256SUMS install.ps1 ssh-paste.cmd ssh-paste.ps1"

state=$(release_states | awk -v t="$tag" '$1 == t { print ($2 == "true" ? "draft" : "published") }')
if [ "$state" = draft ]; then
  echo "deleting the draft of $tag that an earlier run left"
  gh release delete "$tag" --yes
  state=
fi
if [ -z "$state" ]; then
  gh release create "$tag" "$dist/ssh-paste.ps1" "$dist/ssh-paste.cmd" "$dist/install.ps1" "$dist/SHA256SUMS" \
    --draft --verify-tag --title "ssh-paste $tag" --notes-file "$notes"
else
  echo "$tag is already published: checking it"
fi

check=$(mktemp -d)
gh release download "$tag" --dir "$check"
found=$(cd "$check" && ls | sort | tr '\n' ' ')
[ "$found" = "$files " ] || fail "the release must have exactly: $files. It has: $found"
(cd "$check" && sha256sum -c SHA256SUMS)
listed=$(awk '{ print $2 }' "$check/SHA256SUMS" | sort | tr '\n' ' ')
[ "$listed" = "install.ps1 ssh-paste.cmd ssh-paste.ps1 " ] || fail "SHA256SUMS must list install.ps1, ssh-paste.cmd and ssh-paste.ps1 only. It lists: $listed"
for f in $files; do cmp "$check/$f" "$dist/$f" || fail "$f on the release is not the built file"; done
tr -d '\r' < "$check/ssh-paste.ps1" | grep -qxF "\$script:Version = '${tag#v}'" ||
  fail "ssh-paste.ps1 on the release does not say version ${tag#v}"
for f in $files; do
  ok=false
  for attempt in 1 2 3 4 5; do
    if gh attestation verify "$check/$f" --repo "$GITHUB_REPOSITORY" \
        --signer-workflow "$GITHUB_REPOSITORY/.github/workflows/publish.yml"; then
      ok=true; break
    fi
    echo "attempt $attempt for $f failed; waiting"
    sleep "${ATTEST_WAIT:-10}"
  done
  [ "$ok" = true ] || fail "no valid attestation for $f"
done
echo "The files of $tag match SHA256SUMS and the build, and are attested."

others=$(published_tags)
top=$(printf '%s\n%s\n' "$others" "$tag" | valid_tags | tail -n 1)
if [ "$top" = "$tag" ]; then
  gh release edit "$tag" --draft=false --latest
else
  echo "$top is newer: $tag is published without the Latest mark"
  gh release edit "$tag" --draft=false --latest=false
fi

now=$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" -q .tag_name)
[ "$now" = "$top" ] || fail "Latest is $now; it must be $top"
echo "$tag is published; Latest is $now"
