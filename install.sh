#!/bin/sh
# ssh-paste installer for macOS - https://github.com/xuing/ssh-please-paste-picture
#
# Install or upgrade (no administrator rights needed):
#
#     curl -fsSL https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.sh | sh
#
# From a clone or a downloaded copy of the repository (installs its src folder):
#
#     sh install.sh
#
# Remove ssh-paste and everything it changed, even when the installed copy is broken:
#
#     sh install.sh --uninstall
#     curl -fsSL https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.sh | sh -s -- --uninstall
#
# Options
#     --ref <tag|branch|commit>   install that version instead of the default (env: SSH_PASTE_REF)
#                                 The default is the release this file was attached to, or main
#                                 for a copy taken from the repository. A release installs the
#                                 files attached to it, checked against its SHA256SUMS.
#     --uninstall                 remove instead of install (env: SSH_PASTE_UNINSTALL=1)
#     --help                      show this text
# The environment variables are for `curl ... | sh`; `sh -s -- --uninstall` works too.
# Without --ref, a copy of the repository installs its own src folder.
#
# What the install changes (ssh-paste --uninstall reverts exactly this):
#     ~/.local/share/ssh-paste/bin/ssh-paste   the `ssh-paste` command
#     ~/.local/share/ssh-paste/ssh-paste.js    the program
#     ~/.local/share/ssh-paste/install.sh      this installer, which --uninstall runs
#     a marked PATH block at the top of ~/.zprofile, and of the profile bash reads
#     at login (~/.bash_profile, ~/.bash_login or ~/.profile) when your login shell is bash
# Nothing else: no administrator rights, launch agents, login items or daemons.
# Later, `ssh-paste --enable HOST` adds a marked block to ~/.ssh/config.
#
# Keep this file ASCII and POSIX sh (it runs under /bin/sh, which is bash 3.2 on macOS).

set -eu

# The ref that is installed. .github/workflows/publish.yml replaces main with the
# release tag in the copy it attaches to a release. When it is a release tag, the
# files come from that release (version stamped, attested), checked against its
# SHA256SUMS; otherwise they come from src/ at that ref. Keep the next line as it is.
DEFAULT_REF='main'

REPO=xuing/ssh-please-paste-picture
RAW_BASE=https://raw.githubusercontent.com/$REPO
RELEASE_BASE=https://github.com/$REPO/releases/download

# Must match src/ssh-paste.js (BLOCK_BEGIN, BLOCK_END, BLOCK_CREATED_FILE); a test
# compares them. The uninstaller carries its own copy so it works when the
# installed one is broken.
SSH_BEGIN='# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>'
SSH_END='# <<< ssh-paste <<<'
SSH_CREATED='# ssh-paste created this file; it is deleted when the last host is disabled.'
# The PATH block in the shell profiles.
PATH_BEGIN='# >>> ssh-paste PATH (managed by the ssh-paste installer) >>>'
PATH_END='# <<< ssh-paste PATH <<<'
PATH_CREATED='# ssh-paste created this file; it is deleted when ssh-paste is uninstalled.'
# shellcheck disable=SC2016 # $HOME and $PATH are for the profile, not for us.
PATH_LINE='export PATH="$HOME/.local/share/ssh-paste/bin:$PATH"'

say() { printf '%s\n' "$*"; }
die() { printf 'ssh-paste installer: %s\n' "$*" >&2; exit 1; }

usage() {
    say 'ssh-paste installer for macOS'
    say ''
    say '  install.sh [--ref <tag|branch|commit>]   install or upgrade ssh-paste for this user'
    say '  install.sh --uninstall                   remove ssh-paste and everything it changed'
    say ''
    # shellcheck disable=SC2016 # literal backticks
    say 'Under `curl ... | sh` use SSH_PASTE_REF / SSH_PASTE_UNINSTALL=1, or `sh -s -- --uninstall`.'
    say "https://github.com/$REPO"
}

# --- options ---------------------------------------------------------------------

uninstall=no
from_env=no
ref=${SSH_PASTE_REF:-}
if [ "${SSH_PASTE_UNINSTALL:-}" = 1 ]; then uninstall=yes; from_env=yes; fi
while [ $# -gt 0 ]; do
    case $1 in
        --uninstall) uninstall=yes ;;
        --ref)
            [ $# -ge 2 ] || die '--ref needs a value: a tag, branch or commit'
            ref=$2
            shift ;;
        --ref=*) ref=${1#--ref=} ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done
if [ -n "$ref" ]; then
    case $ref in
        *..*|*[!A-Za-z0-9._/-]*) die "not a valid tag, branch or commit name: $ref" ;;
        [A-Za-z0-9]*) ;;
        *) die "not a valid tag, branch or commit name: $ref" ;;
    esac
    [ ${#ref} -le 128 ] || die "not a valid tag, branch or commit name: $ref"
fi

[ "$(uname -s)" = Darwin ] || die 'this installer is for macOS. On Windows, use install.ps1 (see the README).'
home=${HOME:-}
if [ -z "$home" ] || [ ! -d "$home" ]; then die 'HOME is not set to a folder'; fi
dir=$home/.local/share/ssh-paste
work=$(mktemp -d "${TMPDIR:-/tmp}/ssh-paste-install.XXXXXXXX") || die 'cannot create a temporary folder'
trap 'rm -rf "$work"' EXIT

# --- editing text files byte for byte -------------------------------------------

# remove_block FILE BEGIN END CREATED
# Takes the block from the line BEGIN through the line END out of FILE and keeps
# every other byte: line endings, a missing final newline, a UTF-8 byte order
# mark. FILE is deleted when the block has the line CREATED (ssh-paste made the
# file) and nothing but white space is left. Prints removed, deleted or nothing.
# The file is rewritten in place, so a symlinked profile stays a symlink.
remove_block() {
    f=$1
    if [ ! -f "$f" ]; then say nothing; return 0; fi
    cp "$f" "$work/orig"
    if [ -n "$(tail -c 1 "$work/orig")" ]; then nl=0; else nl=1; fi
    status=0
    LC_ALL=C awk -v b="$2" -v e="$3" -v c="$4" -v nl="$nl" '
        { line = $0; sub(/\r$/, "", line)
          if (NR == 1 && substr(line, 1, 3) == "\357\273\277") { bom = substr($0, 1, 3); line = substr(line, 4); $0 = substr($0, 4) }
          if (!inb && line == b) { inb = 1; found = 1; next }
          if (inb) { if (line == e) inb = 0; else if (line == c) created = 1; next }
          out[++n] = $0 }
        END {
          if (inb) exit 3
          if (!found) exit 2
          printf "%s", bom
          for (i = 1; i <= n; i++) { printf "%s", out[i]; if (i < n || nl) printf "\n" }
          if (created) exit 4
          exit 0 }' "$work/orig" > "$work/new" || status=$?
    case $status in
        2) say nothing; return 0 ;;
        3) die "the ssh-paste block in $f has no end marker; remove it by hand" ;;
        0|4) ;;
        *) die "could not read $f" ;;
    esac
    cmp -s "$f" "$work/orig" || die "$f changed while the installer was editing it; run it again"
    if [ "$status" = 4 ] && [ -z "$(LC_ALL=C tr -d ' \t\r\n\357\273\277' < "$work/new")" ]; then
        rm -f "$f"
        say deleted
    else
        cat "$work/new" > "$f"
        say removed
    fi
}

# add_path_block FILE: puts the PATH block at the top of FILE (creating it when
# missing), unless the block is already there. Prints added or present.
add_path_block() {
    f=$1
    if [ -f "$f" ] && grep -qxF "$PATH_BEGIN" "$f"; then say present; return 0; fi
    if [ -e "$f" ] || [ -L "$f" ]; then
        [ -f "$f" ] || die "$f is not a regular file; add $PATH_LINE to your profile by hand"
        cp "$f" "$work/orig"
        { printf '%s\n' "$PATH_BEGIN" "$PATH_LINE" "$PATH_END"; cat "$work/orig"; } > "$work/new"
        cmp -s "$f" "$work/orig" || die "$f changed while the installer was editing it; run it again"
    else
        printf '%s\n' "$PATH_BEGIN" "$PATH_CREATED" "$PATH_LINE" "$PATH_END" > "$work/new"
    fi
    cat "$work/new" > "$f"
    say added
}

# The profiles that get the PATH block: ~/.zprofile (zsh is the macOS default),
# and for a bash login shell the one file bash reads at login.
bash_profile() {
    for p in .bash_profile .bash_login .profile; do
        if [ -e "$home/$p" ]; then say "$home/$p"; return 0; fi
    done
    say "$home/.bash_profile"
}

# --- getting and checking the files ---------------------------------------------

fetch() {
    curl -fsSL --proto '=https' --proto-redir '=https' -o "$2" "$1" || die "could not download $1"
}

check_sum() {
    # check_sum SUMS NAME FILE: SUMS must list NAME with the SHA-256 of FILE.
    want=$(awk -v n="$2" '$2 == n || $2 == "*" n { print tolower($1) }' "$1" | tail -n 1)
    [ -n "$want" ] || die "SHA256SUMS does not list $2"
    got=$(shasum -a 256 "$3" | awk '{ print $1 }')
    [ "$got" = "$want" ] || die "$2 does not match SHA256SUMS (expected $want, got $got); refusing to install it"
}

check_ascii() {
    [ -s "$1" ] || die "$2 is empty"
    if LC_ALL=C grep -q '[^[:print:][:space:]]' "$1"; then die "$2 is not plain ASCII; refusing to install it"; fi
}

script_version() {
    sed -n "s/^var VERSION = '\([^']*\)';\$/\1/p" "$1" | head -n 1
}

get_files() {
    # Puts ssh-paste-mac, ssh-paste.js and install.sh into $work/files; sets
    # from (where they came from) and tag (the release, or empty).
    mkdir -p "$work/files"
    tag=
    case $0 in */install.sh|install.sh) here=$(cd "$(dirname "$0")" && pwd) ;; *) here= ;; esac
    if [ -z "$ref" ] && [ -n "$here" ] && [ -f "$here/src/ssh-paste.js" ] && [ -f "$here/src/ssh-paste-mac" ]; then
        cp "$here/src/ssh-paste-mac" "$here/src/ssh-paste.js" "$here/install.sh" "$work/files/"
        from=$here/src
        return 0
    fi
    [ -n "$ref" ] || ref=$DEFAULT_REF
    if [ "$ref" = "$DEFAULT_REF" ] && printf '%s\n' "$ref" | grep -Eqx 'v0\.1\.(0|[1-9][0-9]*)'; then
        base=$RELEASE_BASE/$ref
        for name in ssh-paste-mac ssh-paste.js install.sh SHA256SUMS; do fetch "$base/$name" "$work/files/$name"; done
        for name in ssh-paste-mac ssh-paste.js install.sh; do check_sum "$work/files/SHA256SUMS" "$name" "$work/files/$name"; done
        rm -f "$work/files/SHA256SUMS"
        tag=$ref
    else
        base=$RAW_BASE/$ref
        fetch "$base/src/ssh-paste-mac" "$work/files/ssh-paste-mac"
        fetch "$base/src/ssh-paste.js" "$work/files/ssh-paste.js"
        fetch "$base/install.sh" "$work/files/install.sh"
    fi
    from=$base
}

check_files() {
    f=$work/files
    check_ascii "$f/ssh-paste-mac" ssh-paste-mac
    check_ascii "$f/ssh-paste.js" ssh-paste.js
    check_ascii "$f/install.sh" install.sh
    if [ "$(head -n 1 "$f/ssh-paste-mac")" != '#!/bin/zsh' ] || ! grep -q 'ssh-paste.js' "$f/ssh-paste-mac"; then
        die 'ssh-paste-mac does not look like the ssh-paste launcher'
    fi
    /bin/zsh -n "$f/ssh-paste-mac" || die 'ssh-paste-mac does not parse'
    grep -qF "$SSH_BEGIN" "$f/ssh-paste.js" || die 'ssh-paste.js does not look like ssh-paste'
    version=$(script_version "$f/ssh-paste.js")
    [ -n "$version" ] || die 'ssh-paste.js has no version'
    if ! grep -q '^DEFAULT_REF=' "$f/install.sh" || ! /bin/sh -n "$f/install.sh"; then die 'install.sh does not look like this installer'; fi
    if [ -n "$tag" ] && [ "$version" != "${tag#v}" ]; then
        die "release $tag ships ssh-paste.js $version, not ${tag#v}; refusing to install it"
    fi
}

put() {
    # put SOURCE DEST MODE: write next to DEST, then rename it into place, so a
    # failure never leaves a half-written program behind.
    cp "$1" "$2.tmp.$$"
    chmod "$3" "$2.tmp.$$"
    mv -f "$2.tmp.$$" "$2"
}

# --- commands ----------------------------------------------------------------------

add_to_profile() {
    r=$(add_path_block "$1") || exit 1
    if [ "$r" = added ]; then
        say "  added $dir/bin to your PATH in $1"
    else
        say "  $1 already puts $dir/bin on your PATH"
    fi
}

do_install() {
    command -v ssh > /dev/null 2>&1 || die 'ssh was not found'
    if [ ! -x /usr/bin/osascript ] || [ ! -x /usr/bin/nc ] || [ ! -x /bin/zsh ]; then die 'this Mac lacks osascript, nc or zsh, which ssh-paste needs'; fi
    get_files
    check_files
    old=
    if [ -f "$dir/ssh-paste.js" ]; then old=$(script_version "$dir/ssh-paste.js"); fi

    mkdir -p "$dir/bin"
    put "$work/files/ssh-paste.js" "$dir/ssh-paste.js" 644
    put "$work/files/install.sh" "$dir/install.sh" 644
    put "$work/files/ssh-paste-mac" "$dir/bin/ssh-paste" 755

    if [ -z "$old" ]; then
        say "Installed ssh-paste $version in $dir"
    elif [ "$old" = "$version" ]; then
        say "Reinstalled ssh-paste $version in $dir"
    else
        say "Upgraded ssh-paste $old -> $version in $dir"
    fi
    say "  from $from"
    if [ -n "$tag" ]; then say '  checked against the SHA256SUMS of the release'; fi
    say '  files: bin/ssh-paste, ssh-paste.js, install.sh'

    add_to_profile "$home/.zprofile"
    case ${SHELL:-} in */bash) add_to_profile "$(bash_profile)" ;; esac

    # Run the installed command once, the way users will.
    reported=$("$dir/bin/ssh-paste" --version 2>&1) || reported="failed: $reported"
    if [ "$reported" != "$version" ]; then
        say ''
        # shellcheck disable=SC2016 # literal backticks
        say 'The files are installed, but `ssh-paste --version` did not work:'
        say "  $reported"
        say 'Remove it with: sh ~/.local/share/ssh-paste/install.sh --uninstall'
        return 1
    fi
    say "  checked: ssh-paste --version prints $reported; ssh is $(command -v ssh)"
    say ''
    say 'Next:'
    say '  ssh-paste --enable <host>    then connect as usual: ssh <host>'
    say '  ssh-paste <host>             or run ssh through ssh-paste, with no config change'
    say '  ssh-paste --doctor <host>    check this Mac and test an upload'
    say '  ssh-paste --uninstall        remove ssh-paste and everything it changed'
    case ":${PATH:-}:" in
        *":$dir/bin:"*) ;;
        *) say "Open a new terminal tab so that it sees the new PATH, or run: export PATH=\"\$HOME/.local/share/ssh-paste/bin:\$PATH\"" ;;
    esac
    return 0
}

do_uninstall() {
    did=no
    r=$(remove_block "$home/.ssh/config" "$SSH_BEGIN" "$SSH_END" "$SSH_CREATED") || exit 1
    case $r in
        removed) did=yes; say "Removed the ssh-paste block from $home/.ssh/config" ;;
        deleted)
            did=yes
            say "Deleted $home/.ssh/config (ssh-paste created it and it held only the ssh-paste block)"
            if rmdir "$home/.ssh" 2> /dev/null; then say "Deleted the empty folder $home/.ssh"; fi ;;
    esac
    for p in .zprofile .bash_profile .bash_login .profile; do
        r=$(remove_block "$home/$p" "$PATH_BEGIN" "$PATH_END" "$PATH_CREATED") || exit 1
        case $r in
            removed) did=yes; say "Removed the ssh-paste PATH block from $home/$p" ;;
            deleted) did=yes; say "Deleted $home/$p (ssh-paste created it for the PATH block)" ;;
        esac
    done
    if [ -e "$dir" ]; then
        rm -rf "$dir"
        did=yes
        say "Deleted $dir"
        for parent in "$home/.local/share" "$home/.local"; do
            if rmdir "$parent" 2> /dev/null; then say "Deleted the empty folder $parent"; fi
        done
    fi
    if [ "$did" = yes ]; then
        say 'ssh-paste is uninstalled.'
        say 'Images already uploaded stay in /tmp on your servers until the server clears /tmp.'
        say 'To delete them now: ssh HOST "rm -f /tmp/ssh-paste-*"'
    else
        say 'ssh-paste is not installed; nothing to remove.'
    fi
    if [ "$from_env" = yes ]; then
        say 'SSH_PASTE_UNINSTALL=1 is still set; clear it before installing again: unset SSH_PASTE_UNINSTALL'
    fi
    return 0
}

if [ "$uninstall" = yes ]; then do_uninstall; else do_install; fi
