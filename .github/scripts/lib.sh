# Shared by the release scripts (sourced, not run). One place for what a release tag is
# and for asking GitHub which releases exist.

# Plain byte order for sort and ls, whatever the runner's locale is.
export LC_ALL=C

# The only series: v0.1.<n>, with no leading zeros (v0.1.08 is not a version).
TAG_RE='^v0\.1\.(0|[1-9][0-9]*)$'

# gh reads the repository from GH_REPO.
if [ -n "${GITHUB_REPOSITORY:-}" ]; then export GH_REPO=$GITHUB_REPOSITORY; fi

# Stdin lines that are versions, lowest first.
valid_tags() { { grep -E "$TAG_RE" || true; } | sort -V; }

# One line per release on GitHub: "<tag> true" for a draft, "<tag> false" for a published
# one. A failed question fails the caller (callers use it in assignments, so set -e stops):
# "could not ask" must never read as "no releases".
release_states() {
  gh release list -L 1000 --json tagName,isDraft -q '.[] | "\(.tagName) \(.isDraft)"'
}

# The versions that are published (not drafts), lowest first.
published_tags() {
  local states
  states=$(release_states) || return 1
  printf '%s\n' "$states" | awk '$2 == "false" { print $1 }' | valid_tags
}
