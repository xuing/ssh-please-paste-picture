#!/bin/bash
# Footprint test of the macOS client: install, enable, disable and uninstall must
# leave the home folder exactly as it was. The macOS counterpart of
# tests/footprint.ps1. It edits the real profile (~/.zprofile, ~/.ssh/config, ...)
# and restores the starting state at the end, so it runs in CI only.
#
#   bash tests/mac/footprint.sh
#
# Each round starts from the same snapshot and must end with an identical one:
#   round 1  install twice, check the command, --enable / --disable, ssh-paste --uninstall
#   round 2  install, --enable, sh install.sh --uninstall
#   round 3  install, --enable, `cat install.sh | sh` with SSH_PASTE_UNINSTALL=1
#   round 4  profiles and an ssh config that exist survive install, --enable and
#            uninstall byte for byte, with bash as the login shell
#   round 5  ssh-paste --update runs a release's install.sh only when it matches its
#            SHA256SUMS, without SSH_PASTE_UNINSTALL and SSH_PASTE_REF
#   round 6  only on runs of xuing/ssh-please-paste-picture: `curl ... | sh` from
#            GitHub at the tested commit (SSH_PASTE_REF), then uninstall the same way
#
# The snapshot: the shell profiles (content hash and mode, or absent), every path
# under ~/.ssh and ~/.local with a content hash, the names at the top of the home
# folder, and anything named ssh-paste* in the per-user temporary folder.
set -u
# shellcheck source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

if [ "${CI:-}" != true ]; then
    echo 'footprint.sh installs and uninstalls ssh-paste in your real profile (then restores it). It runs in CI (CI=true).'
    exit 2
fi

tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/ssh-paste-footprint.XXXXXXXX")
usertmp=$(getconf DARWIN_USER_TEMP_DIR)
cmd=$HOME/.local/share/ssh-paste/bin/ssh-paste
installer=$repo/install.sh
profiles='.zprofile .bash_profile .bash_login .profile .zshrc .bashrc'

mkdir -p "$work/saved"
for p in $profiles .ssh .local; do
    if [ -e "$HOME/$p" ]; then cp -a "$HOME/$p" "$work/saved/"; fi
done
# shellcheck disable=SC2317,SC2329 # runs from the EXIT trap
restore() {
    for p in $profiles .ssh .local; do
        rm -rf "${HOME:?}/$p"
        if [ -e "$work/saved/$p" ]; then cp -a "$work/saved/$p" "$HOME/"; fi
    done
    rm -rf "$work"
}
trap restore EXIT

snapshot() {
    for p in $profiles; do
        if [ -e "$HOME/$p" ]; then echo "$p $(shasum -a 256 < "$HOME/$p" | cut -c 1-16) $(stat -f %Lp "$HOME/$p")"; else echo "$p absent"; fi
    done
    for d in .ssh .local; do
        if [ -e "$HOME/$d" ]; then
            (cd "$HOME" && find "$d" | sort | while IFS= read -r f; do
                if [ -f "$f" ]; then echo "$f $(shasum -a 256 < "$f" | cut -c 1-16) $(stat -f %Lp "$f")"; else echo "$f $(stat -f %Lp "$f")"; fi
            done)
        else
            echo "$d absent"
        fi
    done
    for f in "$HOME"/.[!.]* "$HOME"/*; do
        case ${f##*/} in Library|'.[!.]*'|'*') ;; *) echo "top: ${f##*/}" ;; esac
    done
    find "${usertmp%/}" "${tmp%/}" -maxdepth 1 -name 'ssh-paste*' ! -name 'ssh-paste-footprint.*' 2> /dev/null | sort
}

compare() {
    snapshot > "$work/after"
    if diff -u "$work/before" "$work/after" > "$work/diff"; then pass "$1 leaves the home folder as it was"; else fail "$1 changed the home folder:"; cat "$work/diff"; fi
}

run() {
    # run WHAT CMD...: run CMD, show its output on failure.
    local what=$1; shift
    if "$@" > "$work/out" 2>&1; then pass "$what"; else fail "$what (exit $?)"; sed 's/^/        /' "$work/out"; fi
}

snapshot > "$work/before"
echo 'starting snapshot:'
sed 's/^/    /' "$work/before"

section 'round 1: install twice, --enable / --disable, ssh-paste --uninstall'
run 'install' sh "$installer"
run 'install again' sh "$installer"
if grep -q '^Reinstalled ssh-paste' "$work/out"; then pass 'the second install says Reinstalled'; else fail "second install: $(head -n 1 "$work/out")"; fi
check "$("$cmd" --version)" 0.0.0-dev 'ssh-paste --version'
check "$(zsh -lc 'command -v ssh-paste')" "$cmd" 'a new login shell finds ssh-paste on its PATH'
run '--enable localhost' "$cmd" --enable localhost
run '--disable' "$cmd" --disable
run 'ssh-paste --uninstall' "$cmd" --uninstall
compare 'round 1'

section 'round 2: install, --enable, sh install.sh --uninstall'
run 'install' sh "$installer"
run '--enable localhost' "$cmd" --enable localhost
run 'install.sh --uninstall' sh "$installer" --uninstall
if grep -q 'Deleted .*/.ssh/config\|Removed the ssh-paste block' "$work/out"; then pass 'the uninstaller removed the ssh config block'; else fail 'no ssh config block removed'; fi
compare 'round 2'

section 'round 3: install, --enable, cat install.sh | SSH_PASTE_UNINSTALL=1 sh'
run 'install' sh "$installer"
run '--enable localhost' "$cmd" --enable localhost
run 'SSH_PASTE_UNINSTALL=1 through a pipe' sh -c "cat '$installer' | SSH_PASTE_UNINSTALL=1 sh"
if grep -q 'SSH_PASTE_UNINSTALL=1 is still set' "$work/out"; then pass 'it says that SSH_PASTE_UNINSTALL is still set'; else fail 'no note about SSH_PASTE_UNINSTALL'; fi
compare 'round 3'

section 'round 4: existing profiles and ssh config survive byte for byte (bash login shell)'
mkdir -p "$HOME/.ssh"
# CRLF and no final newline. (No byte order mark: ssh on macOS cannot read a config with one.)
printf 'Host keep\r\n  User me\r\n  HostName 127.0.0.1' > "$HOME/.ssh/config"
printf 'export KEEP=1' > "$HOME/.zprofile"
printf 'one\r\ntwo\r\n' > "$HOME/.profile"
rm -f "$HOME/.bash_profile" "$HOME/.bash_login"
chmod 640 "$HOME/.zprofile"
snapshot > "$work/before4"
cp "$work/before" "$work/before-saved"
cp "$work/before4" "$work/before"
run 'install with SHELL=/bin/bash' env SHELL=/bin/bash sh "$installer"
if grep -qF '# >>> ssh-paste PATH' "$HOME/.profile"; then pass 'bash gets the block in ~/.profile, the file it reads at login'; else fail "$HOME/.profile: $(cat "$HOME/.profile")"; fi
if [ -e "$HOME/.bash_profile" ]; then fail 'a ~/.bash_profile was created, which would hide ~/.profile from bash'; else pass 'no ~/.bash_profile was created'; fi
check "$(stat -f %Lp "$HOME/.zprofile")" 640 'the mode of ~/.zprofile stays'
check "$(bash -lc 'command -v ssh-paste')" "$cmd" 'a bash login shell finds ssh-paste'
run '--enable localhost' "$cmd" --enable localhost
run '--disable' "$cmd" --disable
check "$(od -An -tx1 "$HOME/.ssh/config" | tr -d ' \n')" "$(printf 'Host keep\r\n  User me\r\n  HostName 127.0.0.1' | od -An -tx1 | tr -d ' \n')" '--disable gives the ssh config back byte for byte'
run '--enable localhost again' "$cmd" --enable localhost
run 'install.sh --uninstall' sh "$installer" --uninstall
compare 'round 4'
cp "$work/before-saved" "$work/before"
for p in $profiles .ssh; do
    rm -rf "${HOME:?}/$p"
    if [ -e "$work/saved/$p" ]; then cp -a "$work/saved/$p" "$HOME/"; fi
done
compare 'the restore after round 4'

section 'round 5: ssh-paste --update'
run 'install' sh "$installer"
mkdir -p "$work/release"
cat > "$work/release/install.sh" << EOF
#!/bin/sh
echo "update ran: uninstall=\${SSH_PASTE_UNINSTALL-unset} ref=\${SSH_PASTE_REF-unset}" > '$work/update-ran'
EOF
(cd "$work/release" && shasum -a 256 install.sh > SHA256SUMS)
run '--update from a release folder' env SSH_PASTE_UPDATE_URL="file://$work/release" SSH_PASTE_UNINSTALL=1 SSH_PASTE_REF=v0.1.0 "$cmd" --update
check "$(cat "$work/update-ran" 2> /dev/null)" 'update ran: uninstall=unset ref=unset' 'it ran install.sh without SSH_PASTE_UNINSTALL and SSH_PASTE_REF'
rm -f "$work/update-ran"
echo '# changed' >> "$work/release/install.sh"
if env SSH_PASTE_UPDATE_URL="file://$work/release" "$cmd" --update > "$work/out" 2>&1; then fail 'a changed install.sh was accepted'; else pass 'a changed install.sh is refused'; fi
if grep -q 'does not match SHA256SUMS' "$work/out"; then pass 'and it says why'; else fail "message: $(cat "$work/out")"; fi
if [ -e "$work/update-ran" ]; then fail 'the changed install.sh ran'; else pass 'the changed install.sh did not run'; fi
if "$cmd" --update extra > "$work/out" 2>&1; then fail '--update took an option'; else pass '--update takes no options'; fi
run 'ssh-paste --uninstall' "$cmd" --uninstall
compare 'round 5'

if [ "${GITHUB_REPOSITORY:-}" = xuing/ssh-please-paste-picture ] && [ -n "${GITHUB_SHA:-}" ]; then
    section "round 6: curl ... | sh from GitHub at $GITHUB_SHA"
    url=https://raw.githubusercontent.com/xuing/ssh-please-paste-picture/$GITHUB_SHA/install.sh
    run 'install through curl | sh' sh -c "curl -fsSL '$url' | SSH_PASTE_REF='$GITHUB_SHA' sh"
    check "$("$cmd" --version)" 0.0.0-dev 'the installed command runs'
    run 'uninstall through curl | sh -s -- --uninstall' sh -c "curl -fsSL '$url' | sh -s -- --uninstall"
    compare 'round 6'
fi

finish
