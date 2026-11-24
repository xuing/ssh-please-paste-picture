#!/usr/bin/env bash
# Writes the Scoop manifest of a release to stdout. It installs the Windows client from that
# release's own files, ssh-paste.ps1 and the launcher ssh-paste.cmd, each checked against the
# release's SHA256SUMS (the sums install.ps1 checks too), and puts ssh-paste on PATH through
# Scoop's shim of ssh-paste.cmd.
#
#   scoop-manifest.sh VERSION BASE_URL SHA256SUMS
#
# VERSION is 0.1.N and BASE_URL ends in /v0.1.N: .../releases/download/v0.1.N for a release,
# which publish.yml commits to the bucket xuing/scoop-bucket, or a local copy for tests/scoop.ps1.
# checkver and autoupdate are Scoop's standard way to find and describe the next release, so
# `checkver` and Scoop's Excavator work on this manifest as on any other.
#
# 4-space indents, as Scoop's own formatjson writes them.
#
# The uninstaller runs `ssh-paste --disable` on `scoop uninstall` only ($cmd is "update" during
# `scoop update`, which also runs it), and only when the ssh config block calls this Scoop
# install (a block written by another install stays). If --disable fails, it stops the
# uninstall, and so does a config it cannot read, so ~/.ssh/config never keeps a ProxyCommand
# to removed files. --enable writes the
# path of apps\ssh-paste\current, which `scoop update` keeps.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage='usage: scoop-manifest.sh VERSION BASE_URL SHA256SUMS'
version=${1:?$usage}
base=${2:?$usage}
sums=${3:?$usage}
check_package_args "$version" "$base"
ps1=$(release_sha256 ssh-paste.ps1 "$sums")
cmd=$(release_sha256 ssh-paste.cmd "$sums")
repo=https://github.com/xuing/ssh-please-paste-picture
# $cmd and $dir are Scoop's: the command (uninstall or update) and this version's folder.
hook=$(cat << 'PS'
if ($cmd -eq 'uninstall') {
    $config = Join-Path $env:USERPROFILE '.ssh\config'
    $paths = @((Join-Path (Split-Path -Parent $dir) 'current\ssh-paste.ps1'), (Join-Path $dir 'ssh-paste.ps1'))
    if ((Test-Path -LiteralPath $config) -and @(Select-String -LiteralPath $config -SimpleMatch -Pattern $paths -ErrorAction Stop).Count -gt 0) {
        & "$dir\ssh-paste.cmd" --disable
        if ($LASTEXITCODE -ne 0) { throw 'ssh-paste --disable failed, so ssh-paste stays installed: fix ~/.ssh/config, then run scoop uninstall ssh-paste again' }
    }
}
PS
)

# shellcheck disable=SC2016 # $cmd, $dir, $version, $baseurl and $sha256 are Scoop's variables
jq -n --indent 4 --arg version "$version" --arg base "$base" --arg ps1 "$ps1" --arg cmd "$cmd" --arg repo "$repo" --arg hook "$hook" '{
  version: $version,
  description: "Paste screenshots into programs that run over SSH",
  homepage: $repo,
  license: "MIT",
  notes: "Turn it on for a host: ssh-paste --enable HOST",
  url: [($base + "/ssh-paste.ps1"), ($base + "/ssh-paste.cmd")],
  hash: [$ps1, $cmd],
  bin: "ssh-paste.cmd",
  uninstaller: { script: ($hook | split("\n")) },
  checkver: { github: $repo },
  autoupdate: {
    url: [($repo + "/releases/download/v$version/ssh-paste.ps1"), ($repo + "/releases/download/v$version/ssh-paste.cmd")],
    hash: { url: "$baseurl/SHA256SUMS", regex: "$sha256\\s+$basename" }
  }
}'
