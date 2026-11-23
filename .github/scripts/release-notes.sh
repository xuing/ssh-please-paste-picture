#!/usr/bin/env bash
# Writes the release notes of a tag to stdout: the subject of every commit since the previous
# release, then the install block. Used by .github/workflows/publish.yml.
#
#   release-notes.sh v0.1.N      run in a clone that has the full history and all tags
#
# Environment: GITHUB_REPOSITORY (owner/name) and GH_TOKEN, to ask GitHub which releases are
# published. The previous release is the highest published v0.1.N below the tag among the
# tags that the tagged commit contains. Commits whose subject starts with "docs:", "ci:" or
# "tests:" are left out when other commits remain: a commit subject is the release note, so
# it names what a user now sees.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tag=${1:?usage: release-notes.sh v0.1.N}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
[[ "$tag" =~ $TAG_RE ]] || { echo "bad tag: $tag" >&2; exit 1; }

below=$(git tag --list 'v0.1.*' --merged "$tag^{commit}" | valid_tags | awk -v t="$tag" '$0 == t { exit } { print }')
published=$(published_tags)
prev=$(printf '%s\n' "$below" | { grep -Fx -f <(printf '%s\n' "$published") || true; } | tail -n 1)

if [ -n "$prev" ]; then range="$prev..$tag"; else range="$tag"; fi
all=$(git log --no-merges --format='- %s (%h)' "$range")
shown=$(printf '%s\n' "$all" | { grep -Ev '^- (docs|ci|tests)(\([^)]*\))?: ' || true; })
[ -n "$shown" ] || shown=$all

printf '### Changes\n\n'
if [ -n "$prev" ]; then
  printf 'Since %s:\n\n' "$prev"
else
  printf 'The first release.\n\n'
fi
printf '%s\n\n' "${shown:-- No commits.}"
if [ -n "$prev" ]; then
  printf 'All commits: https://github.com/%s/compare/%s...%s\n\n' "$repo" "$prev" "$tag"
fi
printf '### Install\n\n'
printf 'Windows, in PowerShell:\n\n'
printf '```powershell\n'
printf 'irm https://github.com/%s/releases/download/%s/install.ps1 | iex\n' "$repo" "$tag"
printf '```\n\n'
printf 'macOS, in Terminal:\n\n'
printf '```sh\n'
printf 'curl -fsSL https://github.com/%s/releases/download/%s/install.sh | sh\n' "$repo" "$tag"
printf '```\n\n'
printf 'To update an installed ssh-paste: `ssh-paste --update`.\n\n'
printf '`SHA256SUMS` lists the SHA-256 of `install.ps1`, `ssh-paste.ps1` and `ssh-paste.cmd` (Windows), and of `install.sh`, `ssh-paste-mac` and `ssh-paste.js` (macOS).\n'
printf 'Each file also has a build provenance attestation: `gh attestation verify <file> -R %s`.\n' "$repo"
