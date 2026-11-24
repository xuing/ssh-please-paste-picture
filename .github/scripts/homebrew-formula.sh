#!/usr/bin/env bash
# Writes the Homebrew formula of a release to stdout. The formula installs the macOS client
# from that release's own files, ssh-paste.js and the launcher ssh-paste-mac, each checked
# against the release's SHA256SUMS (the sums install.sh checks too).
#
#   homebrew-formula.sh VERSION BASE_URL SHA256SUMS
#
# VERSION is 0.1.N and BASE_URL ends in /v0.1.N: .../releases/download/v0.1.N for a release,
# which publish.yml commits to the tap, or a file:// folder for tests/mac/footprint.sh. Homebrew
# reads the version from that URL, so the formula has no version line (brew audit calls one
# redundant).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage='usage: homebrew-formula.sh VERSION BASE_URL SHA256SUMS'
version=${1:?$usage}
base=${2:?$usage}
sums=${3:?$usage}
check_package_args "$version" "$base"
js=$(release_sha256 ssh-paste.js "$sums")
mac=$(release_sha256 ssh-paste-mac "$sums")

cat <<EOF
# Written by .github/scripts/homebrew-formula.sh in xuing/ssh-please-paste-picture for
# each release. Changes made here are replaced by the next release.
class SshPaste < Formula
  desc "Paste screenshots into programs that run over SSH"
  homepage "https://github.com/xuing/ssh-please-paste-picture"
  url "$base/ssh-paste.js"
  sha256 "$js"
  license "MIT"

  depends_on :macos

  resource "launcher" do
    url "$base/ssh-paste-mac"
    sha256 "$mac"
  end

  deny_network_access!

  def install
    libexec.install "ssh-paste.js"
    resource("launcher").stage do
      (libexec/"bin").install "ssh-paste-mac" => "ssh-paste"
    end
    chmod 0755, libexec/"bin/ssh-paste"
    bin.install_symlink libexec/"bin/ssh-paste"
  end

  def caveats
    <<~EOS
      Turn it on for a host:  ssh-paste --enable HOST
      Before brew uninstall ssh-paste, run: ssh-paste --uninstall
      It takes ssh-paste out of ~/.ssh/config, where ssh would otherwise
      keep calling the removed command for those hosts.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/ssh-paste --version").strip
    # --enable writes the opt path, which brew upgrade keeps, into ~/.ssh/config. ssh -G reads
    # no ssh config of the user's, so the test does not depend on it.
    ENV["HOME"] = testpath
    (testpath/"ssh").write <<~SH
      #!/bin/sh
      exec /usr/bin/ssh -F /dev/null "\$@"
    SH
    chmod 0755, testpath/"ssh"
    ENV["SSH_PASTE_SSH"] = (testpath/"ssh").to_s
    system bin/"ssh-paste", "--enable", "127.0.0.1"
    assert_match "ProxyCommand '#{opt_libexec}/bin/ssh-paste' --proxy", (testpath/".ssh/config").read
    system bin/"ssh-paste", "--disable"
    refute_path_exists testpath/".ssh/config"
  end
end
EOF
