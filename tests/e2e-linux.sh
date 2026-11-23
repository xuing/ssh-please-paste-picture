#!/usr/bin/env bash
# End-to-end tests of ssh-paste against a real ssh server, on Linux (used by CI).
#
# It starts a throwaway sshd as the current user on 127.0.0.1 with a random port and
# runs the Pester tests tagged E2E against it. Everything lives in one temporary
# directory (host key, client key, authorized_keys, ssh config, logs) that is removed
# on exit. ~/.ssh and the system's sshd are not touched.
#
#   tests/e2e-linux.sh
#
# Needs: bash, pwsh (PowerShell 7), ssh, ssh-keygen, sshd (openssh-server), python3.
# On a CI runner a missing openssh-server is installed with sudo apt-get.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

need() {
    command -v "$1" > /dev/null 2>&1 || { echo "e2e-linux: '$1' is required but not installed" >&2; exit 2; }
}
need pwsh
need ssh
need ssh-keygen
need python3

find_sshd() {
    if command -v sshd > /dev/null 2>&1; then command -v sshd; return; fi
    if [ -x /usr/sbin/sshd ]; then echo /usr/sbin/sshd; return; fi
    return 1
}

if ! sshd_bin=$(find_sshd); then
    if [ "${CI:-}" = "true" ] && command -v sudo > /dev/null 2>&1; then
        echo "e2e-linux: installing openssh-server"
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server
        sshd_bin=$(find_sshd)
    else
        echo "e2e-linux: sshd not found; install openssh-server" >&2
        exit 2
    fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/ssh-paste-e2e.XXXXXXXX")
sshd_pid=""
cleanup() {
    status=$?
    if [ -n "$sshd_pid" ]; then kill "$sshd_pid" 2> /dev/null || true; wait "$sshd_pid" 2> /dev/null || true; fi
    if [ "$status" -ne 0 ] && [ -f "$work/sshd.log" ]; then
        echo "---- sshd log ----" >&2
        cat "$work/sshd.log" >&2 || true
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

me=$(id -un)
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

ssh-keygen -q -t ed25519 -N '' -C ssh-paste-e2e -f "$work/client_key"
ssh-keygen -q -t ed25519 -N '' -C ssh-paste-e2e-host -f "$work/host_key"
cp "$work/client_key.pub" "$work/authorized_keys"
chmod 600 "$work/client_key" "$work/host_key" "$work/authorized_keys"

cat > "$work/sshd_config" << EOF
Port $port
ListenAddress 127.0.0.1
HostKey $work/host_key
PidFile $work/sshd.pid
AuthorizedKeysFile $work/authorized_keys
AllowUsers $me
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
LogLevel ERROR
EOF

cat > "$work/ssh_config" << EOF
Host ssh-paste-e2e
    HostName 127.0.0.1
    Port $port
    User $me
    IdentityFile $work/client_key
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile $work/known_hosts
    StrictHostKeyChecking no
    BatchMode yes
EOF

"$sshd_bin" -t -f "$work/sshd_config"
# sshd must be started with an absolute path.
"$sshd_bin" -D -e -f "$work/sshd_config" -E "$work/sshd.log" &
sshd_pid=$!

ready=""
for _ in $(seq 1 50); do
    if ssh -F "$work/ssh_config" -o ConnectTimeout=2 ssh-paste-e2e true 2> /dev/null; then ready=yes; break; fi
    kill -0 "$sshd_pid" 2> /dev/null || { echo "e2e-linux: sshd exited early" >&2; exit 1; }
    sleep 0.2
done
[ -n "$ready" ] || { echo "e2e-linux: could not log in to the throwaway sshd on port $port" >&2; exit 1; }
echo "e2e-linux: sshd on 127.0.0.1:$port as $me"

cat > "$work/run-e2e.ps1" << 'EOF'
$ErrorActionPreference = 'Stop'
$minimum = [version]'5.2.0'
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge $minimum })) {
    Install-Module -Name Pester -MinimumVersion $minimum -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion $minimum
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $env:SSH_PASTE_REPO 'tests/ssh-paste.Tests.ps1'
$config.Run.PassThru = $true
$config.Filter.Tag = @('E2E')
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
# A run that skipped its tests (no host, wrong tag) must not look like a pass.
if ($result.FailedCount -gt 0 -or $result.SkippedCount -gt 0 -or $result.PassedCount -eq 0) {
    Write-Host ('E2E: passed {0}, failed {1}, skipped {2}' -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
    exit 1
}
EOF

export SSH_PASTE_REPO="$repo"
export SSH_PASTE_E2E_HOST=ssh-paste-e2e
export SSH_PASTE_E2E_KEY="$work/client_key"
export SSH_PASTE_E2E_CONFIG="$work/ssh_config"

pwsh -NoLogo -NoProfile -NonInteractive -File "$work/run-e2e.ps1" < /dev/null
