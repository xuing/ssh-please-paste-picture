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

# release_sha256 NAME SHA256SUMS: the one SHA-256 that SHA256SUMS lists for NAME (sha256sum
# format, text or binary mode). The package manifests (homebrew-formula.sh,
# scoop-manifest.sh) take their sums from the release this way.
release_sha256() {
  local s
  s=$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$2")
  [[ "$s" =~ ^[0-9a-f]{64}$ ]] || { echo "::error::no single SHA-256 for $1 in $2" >&2; return 1; }
  printf '%s' "$s"
}

# check_package_args VERSION BASE_URL: both go into a manifest (Ruby or JSON strings), so allow
# nothing that could end one. BASE_URL is the release folder, .../download/v<VERSION>, or a
# local copy for the tests (file:// or http://127.0.0.1:<port>), and ends in /v<VERSION>,
# where Homebrew and Scoop read the version.
check_package_args() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::bad version: $1" >&2; return 1; }
  [[ "$2" =~ ^(https://|file://|http://127\.0\.0\.1:[0-9]+/)[A-Za-z0-9._/:-]+$ ]] || { echo "::error::bad base URL: $2" >&2; return 1; }
  [[ "$2" == */v"$1" ]] || { echo "::error::$2 does not end in /v$1" >&2; return 1; }
}
