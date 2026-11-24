#!/bin/bash
# End-to-end test of the macOS client against a real ssh server, like
# tests/e2e-linux.sh: a throwaway sshd as the current user on 127.0.0.1, the client
# installed with install.sh, `ssh-paste --enable`, and real sessions in Terminal.app
# windows (ssh mode with plain `ssh`, then wrapper mode). A real screenshot goes on
# the pasteboard; pbpaste must return the remote path, and that file must hold the
# same bytes. The server is this Mac, so its /tmp is ours to check.
#
#   bash tests/mac/e2e.sh        (CI only: it edits ~/.ssh/config and the shell
#                                 profiles, and restores them at the end)
set -u
# shellcheck source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

if [ "${CI:-}" != true ]; then
    echo 'e2e.sh edits ~/.ssh/config and your shell profiles; it runs in CI (CI=true).'
    exit 2
fi

tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/ssh-paste-e2e.XXXXXXXX")
usertmp=$(getconf DARWIN_USER_TEMP_DIR)
rm -f "${usertmp%/}/ssh-paste-debug.log"
me=$(id -un)
cmd=$HOME/.local/share/ssh-paste/bin/ssh-paste
sshd_pid=
had_ssh=no
if [ -e "$HOME/.ssh" ]; then had_ssh=yes; cp -a "$HOME/.ssh" "$work/ssh-backup"; fi
# shellcheck disable=SC2317,SC2329 # runs from the EXIT trap
cleanup() {
    pkill -f 'ssh-paste-e2e' 2> /dev/null
    [ -n "$sshd_pid" ] && kill "$sshd_pid" 2> /dev/null
    sh "$repo/install.sh" --uninstall > /dev/null 2>&1
    rm -rf "$HOME/.ssh"
    if [ "$had_ssh" = yes ]; then cp -a "$work/ssh-backup" "$HOME/.ssh"; fi
    rm -rf "$work"
}
trap cleanup EXIT

debuglog() { for d in "$work" "${usertmp%/}"; do if [ -f "$d/ssh-paste-debug.log" ]; then echo "$d/ssh-paste-debug.log"; return; fi; done; echo /dev/null; }
# shellcheck disable=SC2317,SC2329 # called through wait_for
watchers() { n=$(grep -c 'watching com.apple.Terminal' "$(debuglog)" 2> /dev/null); echo "${n:-0}"; }
# shellcheck disable=SC2317,SC2329 # called through wait_for
more_watchers() { [ "$(watchers)" -gt "$1" ]; }
# shellcheck disable=SC2317,SC2329 # called through wait_for
no_process() { ! pgrep -f "$1" > /dev/null; }

section 'a throwaway sshd on 127.0.0.1'
port=$(perl -MIO::Socket::INET -e 'my $x = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0) or die; print $x->sockport')
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
LogLevel VERBOSE
EOF
/usr/sbin/sshd -t -f "$work/sshd_config" || { fail 'sshd -t'; finish; }
/usr/sbin/sshd -D -e -f "$work/sshd_config" -E "$work/sshd.log" &
sshd_pid=$!
echo "[127.0.0.1]:$port $(cut -d ' ' -f 1,2 "$work/host_key.pub")" > "$work/known_hosts"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
cat >> "$HOME/.ssh/config" << EOF
Host ssh-paste-e2e
    HostName 127.0.0.1
    Port $port
    User $me
    IdentityFile $work/client_key
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile $work/known_hosts
    StrictHostKeyChecking yes
EOF
if wait_for 20 ssh -o BatchMode=yes -o ConnectTimeout=2 ssh-paste-e2e true; then pass "key login to 127.0.0.1:$port"; else fail 'cannot log in'; cat "$work/sshd.log"; finish; fi

section 'install, --enable and --doctor'
sh "$repo/install.sh" > "$work/install.out" 2>&1 || { fail 'install.sh'; cat "$work/install.out"; }
check "$("$cmd" --version)" 0.0.0-dev 'ssh-paste --version'
"$cmd" --enable ssh-paste-e2e > "$work/enable.out" 2>&1 || { fail '--enable'; cat "$work/enable.out"; }
if grep -qxF 'ssh-paste-e2e: uploads log in without a password' "$work/enable.out"; then pass '--enable checked that uploads log in'; else fail "--enable output: $(cat "$work/enable.out")"; fi
if command -v ssh-copy-id > /dev/null; then pass "ssh-copy-id is there, as the README says: $(command -v ssh-copy-id)"; else fail 'no ssh-copy-id on this macOS, which the README tells users to run'; fi
if head -n 1 "$HOME/.ssh/config" | grep -qF '# >>> ssh-paste'; then pass 'the block is at the top of ~/.ssh/config'; else fail "no block: $(cat "$HOME/.ssh/config")"; fi
if grep -qF "    ProxyCommand '$HOME/.local/share/ssh-paste/bin/ssh-paste' --proxy '%h' %p '%n'" "$HOME/.ssh/config"; then pass 'the ProxyCommand runs the installed command'; else fail "ProxyCommand: $(grep ProxyCommand "$HOME/.ssh/config")"; fi
# On macOS /tmp is a symbolic link to /private/tmp: the upload's prune must still
# find our old image there, and leave a name it did not make.
if [ -h /tmp ]; then pass '/tmp is a symbolic link here'; else fail '/tmp is not a link, so the link case is not tested'; fi
rnd=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
old=/tmp/ssh-paste-$rnd.png
near=/tmp/ssh-paste-$rnd-7-notes.png
: > "$old"; : > "$near"
touch -t "$(date -v-3d +%Y%m%d%H%M)" "$old" "$near"
"$cmd" --doctor ssh-paste-e2e > "$work/doctor.out" 2>&1
if grep -q '^  ok    upload to ssh-paste-e2e: /tmp/ssh-paste-[0-9a-f]\{32\}\.png' "$work/doctor.out"; then pass '--doctor uploads'; else fail "--doctor: $(cat "$work/doctor.out")"; fi
if [ -e "$old" ]; then fail "the upload did not prune $old (3 days old) through the /tmp link"; else pass 'the upload pruned our 3-day-old image in /tmp (a link on macOS)'; fi
if [ -e "$near" ]; then pass 'it kept a name it did not make'; else fail "it deleted $near"; fi
rm -f "$old" "$near"
if grep -q 'ssh mode: enabled' "$work/doctor.out"; then pass '--doctor sees ssh mode'; else fail '--doctor does not see ssh mode'; fi
check "$(ssh -o BatchMode=yes ssh-paste-e2e echo relayed)" relayed 'a command through the ssh mode relay'

section '--enable --dir ~/...: the home folder on the server, asked once'
# shellcheck disable=SC2088 # the ~ is for the server, so it stays unexpanded
"$cmd" --enable --dir '~/ssh-paste-e2e-dir' ssh-paste-e2e > "$work/enable2.out" 2>&1 || { fail '--enable --dir ~/...'; cat "$work/enable2.out"; }
if grep -qF -- "--dir '$HOME/ssh-paste-e2e-dir'" "$HOME/.ssh/config"; then pass "~ became the server's home folder: $HOME"; else fail "ssh config: $(grep ProxyCommand "$HOME/.ssh/config")"; fi
"$cmd" --enable --dir /tmp ssh-paste-e2e > /dev/null 2>&1 || fail '--enable --dir /tmp'
if grep -qF -- '--dir' "$HOME/.ssh/config"; then fail "--dir /tmp was written: $(grep ProxyCommand "$HOME/.ssh/config")"; else pass 'back to /tmp, the default, which is not written'; fi
# With debug on, the relay's watcher logs its decision, so this fails both when a
# watcher starts and when the decision is never made.
before=$(watchers)
userlog=${usertmp%/}/ssh-paste-debug.log
declined() { n=$(grep -c 'no watcher: not an interactive session' "$userlog" 2> /dev/null); echo "${n:-0}"; }
was=$(declined)
# The remote command lasts a few seconds so ssh still runs when the watcher reads
# its arguments with ps (a command that ends at once leaves nothing to read).
TMPDIR=$usertmp SSH_PASTE_DEBUG=1 ssh -o BatchMode=yes ssh-paste-e2e sleep 3
TMPDIR=$usertmp SSH_PASTE_DEBUG=1 ssh -o BatchMode=yes -T ssh-paste-e2e sleep 3 < /dev/null
sleep 2
check "$(declined)" "$((was + 2))" 'the relay decided twice: not interactive'
[ "$(declined)" = "$((was + 2))" ] || { echo "        $userlog:"; tail -n 20 "$userlog" 2> /dev/null; }
check "$(watchers)" "$before" 'no watcher for a command without -t, nor for -T'

section 'ssh mode: plain ssh in Terminal.app'
before=$(watchers)
terminal_run sshmode "export SSH_PASTE_DEBUG=1
exec ssh ssh-paste-e2e"
if wait_for 40 more_watchers "$before"; then pass 'the relay started a watcher for Terminal.app'; else fail 'no watcher'; cat "$(debuglog)"; fi
grep 'watching' "$(debuglog)" | tail -n 1
screencapture -c -x
pb save-png "$work/clip1.png"
want=/tmp/ssh-paste-$(sha16 "$work/clip1.png").png
wait_for 20 entry_is "$want" || fail "no entry: $(pb dump)"
paste_timed "$work/p1"
check "$(cat "$work/p1")" "$want" "pbpaste gets the remote path ($(cat "$work/p1.ms") ms)"
if cmp -s "$work/clip1.png" "$want"; then pass 'the file on the server has the screenshot bytes'; else fail "$want is missing or differs"; fi
check "$(stat -f %Lp "$want" 2> /dev/null)" 600 'the file is private (600)'
pkill -f '^ssh ssh-paste-e2e$'
if wait_for 20 no_process 'ssh-paste.js --watch-proxy'; then pass 'the watcher stopped with the session'; else fail 'the watcher still runs'; fi
check "$(pbpaste)" '' 'after the session, pbpaste gets no path: the plain image is back'
case $(pb dump) in *'"public.png"'*'"owner":0'*) pass 'the image is still on the pasteboard' ;; *) fail "pasteboard: $(pb dump)" ;; esac

section 'ssh mode with ControlPersist: the watcher stops when the ssh in the terminal ends'
# The master that ControlPersist leaves in the background keeps the relay (nc)
# running after the session; the watcher must end with the ssh the user ran.
cp=/tmp/ssh-paste-cm-%C
before=$(watchers)
terminal_run cpersist "export SSH_PASTE_DEBUG=1
exec ssh -t -o ControlMaster=auto -o 'ControlPath=$cp' -o ControlPersist=120 ssh-paste-e2e sleep 8"
if wait_for 40 more_watchers "$before"; then pass 'the relay started a watcher'; else fail 'no watcher'; tail -n 20 "$(debuglog)"; fi
if wait_for 30 no_process 'ssh-paste.js --watch-proxy'; then pass 'the watcher stopped when the session ended'; else fail 'the watcher still runs after the session'; fi
if ssh -o "ControlPath=$cp" -O check ssh-paste-e2e 2> /dev/null; then pass 'while the ControlPersist master still runs'; else fail 'no master left, so ControlPersist was not tested'; fi
ssh -o "ControlPath=$cp" -O exit ssh-paste-e2e 2> /dev/null || true

section 'wrapper mode: ssh-paste with ProxyCommand=none'
before=$(watchers)
terminal_run wrapper "export SSH_PASTE_DEBUG=1
exec '$cmd' -o ProxyCommand=none ssh-paste-e2e"
if wait_for 40 more_watchers "$before"; then pass 'wrapper mode started a watcher'; else fail 'no watcher'; fi
screencapture -c -x -R 0,0,320,200
pb save-png "$work/clip2.png"
want=/tmp/ssh-paste-$(sha16 "$work/clip2.png").png
wait_for 20 entry_is "$want" || fail "no entry: $(pb dump)"
paste_timed "$work/p2"
check "$(cat "$work/p2")" "$want" 'pbpaste gets the remote path'
if cmp -s "$work/clip2.png" "$want"; then pass 'the file on the server has the screenshot bytes'; else fail "$want is missing or differs"; fi
# Anchored: the watcher's own command line ends with the ssh command line too.
pkill -f '^/usr/bin/ssh -o ProxyCommand=none ssh-paste-e2e$'
if wait_for 20 no_process 'ssh-paste.js --watch-wrapper'; then pass 'the watcher stopped'; else fail 'the watcher still runs'; fi
check "$(pbpaste)" '' 'the plain image is back'

section '--disable and --uninstall'
"$cmd" --disable ssh-paste-e2e > /dev/null
if grep -qF '# >>> ssh-paste' "$HOME/.ssh/config"; then fail 'the block is still there'; else pass '--disable removed the block'; fi
if grep -q '^Host ssh-paste-e2e$' "$HOME/.ssh/config"; then pass 'the host entry of the user stays'; else fail 'the host entry is gone'; fi
"$cmd" --uninstall > "$work/uninstall.out" 2>&1 || fail '--uninstall'
if [ -e "$HOME/.local/share/ssh-paste" ]; then fail 'the install folder is still there'; else pass '--uninstall removed the install folder'; fi

finish
