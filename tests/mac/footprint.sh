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
#   round 7  Homebrew: the formula of .github/scripts/homebrew-formula.sh for these
#            files, from a local tap: brew install and brew test, --enable writes the
#            opt path, --update and --uninstall leave the files to brew, brew uninstall
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
run 'install' env PATH=/usr/bin:/bin:/usr/sbin:/sbin sh "$installer"
# The line it prints for the current terminal comes before "Next:" and works when pasted.
line=$(sed -n '/In this one, first run:$/{n;s/^  //;p;}' "$work/out")
if [ -n "$line" ] && [ "$(grep -n 'first run:$' "$work/out" | cut -d: -f1)" -lt "$(grep -n '^Next:$' "$work/out" | cut -d: -f1)" ]; then
    pass 'the install prints the PATH line before Next:'
else
    fail 'no PATH line before Next:'; sed 's/^/        /' "$work/out"
fi
check "$(env PATH=/usr/bin:/bin zsh -fc "$line; command -v ssh-paste")" "$cmd" 'the printed line puts ssh-paste on this shell'"'"'s PATH'
run 'install again' sh "$installer"
if grep -q '^Reinstalled ssh-paste' "$work/out"; then pass 'the second install says Reinstalled'; else fail "second install: $(head -n 1 "$work/out")"; fi
check "$("$cmd" --version)" 0.0.0-dev 'ssh-paste --version'
check "$(zsh -lc 'command -v ssh-paste')" "$cmd" 'a new login shell finds ssh-paste on its PATH'
run '--enable localhost' "$cmd" --enable localhost
if grep -qF "ProxyCommand '$cmd' --proxy" "$HOME/.ssh/config"; then pass 'the ProxyCommand calls the installed command'; else fail "ssh config: $(cat "$HOME/.ssh/config")"; fi
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

section 'round 7: Homebrew'
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
# brew's own state stays out of the home folder: the trust that `brew install user/tap/formula`
# grants goes to $XDG_CONFIG_HOME/homebrew (else ~/.homebrew), and the gems brew style installs
# are cached in HOMEBREW_BUNDLE_USER_CACHE (else ~/.bundle).
export XDG_CONFIG_HOME=$work/xdg HOMEBREW_BUNDLE_USER_CACHE=$work/bundle-cache
prefix=$(brew --prefix)
bcmd=$prefix/bin/ssh-paste
# The files as a release has them: in a folder named for the version, ssh-paste.js stamped.
rel=$work/brew/v0.1.0
mkdir -p "$rel" "$XDG_CONFIG_HOME"
cp "$repo/src/ssh-paste-mac" "$rel/"
bash "$repo/.github/scripts/stamp-version.sh" "$repo/src/ssh-paste.js" "$rel/ssh-paste.js" 0.1.0 > /dev/null
(cd "$rel" && shasum -a 256 ssh-paste.js ssh-paste-mac > SHA256SUMS)
if bash "$repo/.github/scripts/homebrew-formula.sh" 0.1.0 "file://$rel" "$rel/SHA256SUMS" > "$work/brew/ssh-paste.rb"; then pass 'the formula is written'; else fail 'homebrew-formula.sh failed'; fi
run 'brew tap-new' brew tap-new --no-git ssh-paste/test
cp "$work/brew/ssh-paste.rb" "$(brew --repository ssh-paste/test)/Formula/"
run 'brew install' brew install ssh-paste/test/ssh-paste
run 'brew style' brew style ssh-paste/test/ssh-paste
run 'brew audit --strict' brew audit --strict ssh-paste/test/ssh-paste
check "$("$bcmd" --version)" 0.1.0 "$bcmd --version"
run 'brew test' brew test ssh-paste/test/ssh-paste
run '--enable localhost' "$bcmd" --enable localhost
if grep -qF "ProxyCommand '$prefix/opt/ssh-paste/libexec/bin/ssh-paste' --proxy" "$HOME/.ssh/config"; then pass 'the ProxyCommand calls the opt path, which brew upgrade keeps'; else fail "ssh config: $(cat "$HOME/.ssh/config")"; fi
if "$bcmd" --update > "$work/out" 2>&1; then fail '--update ran under Homebrew'; else pass '--update does not update a Homebrew install'; fi
if grep -qF 'brew upgrade ssh-paste' "$work/out"; then pass 'and it says brew upgrade ssh-paste'; else fail "message: $(cat "$work/out")"; fi
run 'ssh-paste --uninstall' "$bcmd" --uninstall
if grep -qF 'brew uninstall ssh-paste' "$work/out"; then pass 'it says brew uninstall ssh-paste'; else fail "message: $(cat "$work/out")"; fi
if [ -e "$(brew --prefix ssh-paste)/libexec/ssh-paste.js" ]; then pass 'it left the files to brew'; else fail 'it removed files that brew owns'; fi
run 'brew uninstall' brew uninstall ssh-paste/test/ssh-paste
run 'brew untap' brew untap ssh-paste/test
compare 'round 7'

finish
