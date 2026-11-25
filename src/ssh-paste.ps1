<#
ssh-paste - paste Windows screenshots into programs running over SSH.

  ssh mode      ssh-paste --enable myhost     then use plain `ssh myhost`
  wrapper mode  ssh-paste myhost              same arguments as ssh

While connected, copy a screenshot (Win+Shift+S), return to the terminal and
press Ctrl+V: the image is uploaded to /tmp on the server and its path is pasted.

Runs on the Windows PowerShell 5.1 that ships with Windows, and on PowerShell 7.
Keep this file ASCII. https://github.com/xuing/ssh-please-paste-picture
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Win32-OpenSSH hands a child it spawns (our --proxy process) its file
# descriptor table in these variables. A posix program started further down,
# such as the ssh.exe that uploads, would read them too and take the
# interactive session's pipes as its own stdin and stdout (see the TODO in
# PowerShell/openssh-portable contrib/win32/win32compat/w32fd.c). Drop them, and
# start every child through New-ChildStartInfo, which drops them again.
# Every variable with Win32-OpenSSH's private prefix goes, so later ones do too.
$script:InheritedSshPrefix = 'c28fc6f98a2c44abbbd89d6a3037d0d9_'
foreach ($variable in @(Get-ChildItem -Path Env: | Where-Object { $_.Name.StartsWith($script:InheritedSshPrefix, [StringComparison]::OrdinalIgnoreCase) })) {
    Remove-Item -LiteralPath ('Env:' + $variable.Name) -ErrorAction SilentlyContinue
}

$script:Version = '0.0.0-dev'
$script:MarkerFormat = 'SshPaste.Owner'
$script:Clipboard = $null   # the PendingClipboard that owns our entries (Initialize-Native)
$script:BlockBegin = '# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>'
$script:BlockEnd = '# <<< ssh-paste <<<'
$script:BlockCreatedFile = '# ssh-paste created this file; it is deleted when the last host is disabled.'
$script:MaxImageBytes = 64MB
$script:ImageExtensions = @('png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp')
$script:MaxCopiedFiles = 20
$script:RetryFailedSeconds = 30
# The server half of setting up a key without ssh-copy-id (Windows has none): the public key
# comes on stdin. It runs in the user's login shell (sh, bash, zsh, fish, tcsh), so it uses
# only words they all read alike; touch makes the file first, since >> cannot under noclobber
# in zsh and tcsh; the echo ends a last line that lacks its newline; tr drops the CR that
# PowerShell adds (and NUL, should $OutputEncoding be UTF-16). --doctor prints it; the
# READMEs show it.
$script:KeyInstallCommand = "umask 077; mkdir -p .ssh; touch .ssh/authorized_keys; echo >> .ssh/authorized_keys; tr -d '\r\000' >> .ssh/authorized_keys"
$script:UploadCacheHours = 6
# --keep and --dir (ssh-paste --enable, wrapper mode): how long the server keeps your images,
# and in which folder. The defaults are what ssh-paste always did.
$script:DefaultKeep = '1d'
$script:DefaultDir = '/tmp'

# Runs on the server through `sh -c`, with $1 = content hash (32 hex digits, made
# by us), $2 = byte count, $3 = file extension (png when absent), $4 = minutes to keep
# this class of images (0: keep them; 1440 when absent; anything that is not a number
# keeps them too), $5 = the folder (/tmp when absent) and $6 = the class: empty for
# --keep 1d, else k<keep>- (as in ssh-paste-k7d-<hash>.png), so that each upload
# deletes only images of its own --keep, never those another setting keeps longer.
# The folder is absolute (the client turns ~ into the home folder there when you give
# it). A folder other than /tmp is made (mode 700) when missing and must be
# yours, not a symbolic link, and not writable by group or others (notprivate
# otherwise), so other users cannot reach the files at all; in /tmp, the sticky bit
# and the checks below keep them out. Folder names need no quoting (the client allows
# letters, digits and . _ - / only) and set -f keeps them from globbing. The script
# contains no single quote, double quote, backslash or exclamation mark, so every
# login shell (bash, zsh, fish, tcsh) passes it to sh unchanged. It receives into a
# private temp file in the folder, checks the size, deletes this user's images of the
# class older than $4 minutes and temp leftovers older than a day (regular files with
# exactly the names the script makes), then publishes <folder>/ssh-paste-<class><hash>.<ext>
# (reused when an identical complete copy exists; a per-user name when another user
# owns it).
$script:RemoteScript = 'umask 077; set -fC; n=$2; e=${3:-png}; k=${4:-1440}; d=${5:-/tmp}; c=${6:-}; u=$(id -u); a=[A-Za-z0-9]; h=[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]; ' +
    '[ -d $d ] || mkdir -p $d 2> /dev/null || { echo nodir; exit 5; }; ' +
    'if [ $d = /tmp ]; then :; elif [ -h $d ]; then echo notprivate; exit 6; elif [ -O $d ]; then m=$(ls -ld $d 2> /dev/null); case ${m%% *} in d????-??-? | d????-??-?. | d????-??-?@) ;; *) echo notprivate; exit 6;; esac; else echo notprivate; exit 6; fi; ' +
    't=$(mktemp $d/ssh-paste-tmp.XXXXXXXXXX 2> /dev/null) || { echo nodir; exit 3; }; ' +
    'cat >> $t; s=$(wc -c < $t); if [ $s -eq $n ]; then :; else rm -f $t; echo short $s; exit 4; fi; ' +
    'if [ $k -gt 0 ] 2> /dev/null; then for x in png jpg jpeg gif webp bmp; do for p in ssh-paste-$c$h.$x ssh-paste-$c$h-$u.$x; do ' +
    'find $d/ -maxdepth 1 -type f -user $u -name $p -mmin +$k -exec rm -f {} + 2> /dev/null; done; done; fi; ' +
    'find $d/ -maxdepth 1 -type f -user $u -name ssh-paste-tmp.$a$a$a$a$a$a$a$a$a$a -mmin +1440 -exec rm -f {} + 2> /dev/null; ' +
    'for f in $d/ssh-paste-$c$1.$e $d/ssh-paste-$c$1-$u.$e; do ' +
    'if [ -h $f ]; then :; elif [ -f $f ] && [ -O $f ] && cmp -s $t $f && touch -c $f && [ -f $f ]; then rm -f $t; echo $n $f; exit 0; fi; ' +
    'if [ -d $f ]; then continue; fi; ' +
    'if mv -f $t $f 2> /dev/null && [ -f $f ]; then echo $n $f; exit 0; fi; done; rm -f $t; exit 1'

# ssh(1) getopt string, from ssh.c: letters without and with an argument.
$script:SshFlagsNoArg = '1246ACGKMNTVXYZafgknqstvxy'
$script:SshFlagsWithArg = 'BDEFIJLOPQRSWbceilmopw'
# Options that identify the server and its credentials; kept for the upload connection.
$script:SshKeepNoArg = '46C'
$script:SshKeepWithArg = 'BFIJbcilmopP'
# `-o` settings from the user that would break or redirect the upload connection.
$script:SshDropOptions = @('requesttty', 'remotecommand', 'localcommand', 'permitlocalcommand', 'localforward',
    'remoteforward', 'dynamicforward', 'clearallforwardings', 'controlmaster', 'controlpath', 'controlpersist',
    'forwardx11', 'forwardx11trusted', 'forwardx11timeout', 'forwardagent', 'tunnel', 'tunneldevice', 'batchmode',
    'stdinnull', 'sessiontype', 'forkafterauthentication', 'exitonforwardfailure', 'gatewayports', 'escapechar',
    'loglevel', 'proxyusefdpass', 'enableescapecommandline', 'permitremoteopen', 'streamlocalbindunlink')

# ---------------------------------------------------------------------------
# Messages in the user's language
# ---------------------------------------------------------------------------
# The English text in the code is the key (as in gettext): Get-Text 'Enabled for: {0}' $h
# looks it up in the catalog of the user's language and falls back to the English text.
# The catalogs are src/locale/<name>.json; the line below is generated from them, ASCII
# with \u escapes, by `node tests/locale.js --write`, and a test fails when it is stale.
# >>> locale
$script:LocaleData = '{"zh-CN":{"    Copy a screenshot (Cmd+Ctrl+Shift+4) or image files in Finder, switch to":"    \u622a\u4e00\u5f20\u56fe\uff08Cmd+Ctrl+Shift+4\uff09\uff0c\u6216\u5728 Finder \u91cc\u590d\u5236\u56fe\u7247\u6587\u4ef6\uff0c\u5207\u6362\u5230","    Copy a screenshot (Win+Shift+S), switch to the ssh window, press Ctrl+V:":"    \u622a\u4e00\u5f20\u56fe\uff08Win+Shift+S\uff09\uff0c\u5207\u6362\u5230 ssh \u7a97\u53e3\uff0c\u6309 Ctrl+V\uff1a","    paste the image.":"    \u7c98\u8d34\u7684\u4ecd\u7136\u662f\u56fe\u7247\u3002","    pasted. Other apps still paste the image.":"    \u7c98\u8d34\u7684\u662f\u8def\u5f84\u3002\u5728\u5176\u4ed6\u7a0b\u5e8f\u91cc\u7c98\u8d34\u7684\u4ecd\u7136\u662f\u56fe\u7247\u3002","    ssh myhost                   then connect as usual":"    ssh myhost                   \u7136\u540e\u7167\u5e38\u8fde\u63a5","    ssh-paste --enable myhost    once per host":"    ssh-paste --enable myhost    \u6bcf\u53f0\u4e3b\u673a\u8fd0\u884c\u4e00\u6b21","    the image goes to the server and its path is pasted. Other apps still":"    \u56fe\u7247\u4f1a\u4f20\u5230\u670d\u52a1\u5668\u4e0a\uff0c\u7c98\u8d34\u7684\u662f\u5b83\u7684\u8def\u5f84\u3002\u5728\u5176\u4ed6\u7a0b\u5e8f\u91cc","    the ssh window, press Cmd+V: the image goes to the server and its path is":"    ssh \u7a97\u53e3\uff0c\u6309 Cmd+V\uff1a\u56fe\u7247\u4f1a\u4f20\u5230\u670d\u52a1\u5668\u4e0a\uff0c","  --dir DIR     keep them in DIR: /tmp (default), any /path, or ~/path (quote the ~)":"  --dir DIR     \u56fe\u7247\u653e\u5728 DIR\uff1a/tmp\uff08\u9ed8\u8ba4\uff09\u3001\u4efb\u610f /path\uff0c\u6216 ~/path\uff08~ \u8981\u52a0\u5f15\u53f7\uff09","  --keep TIME   delete them when older than TIME: 30m, 2h, 7d (default 1d), or never":"  --keep TIME   \u8d85\u8fc7 TIME \u5c31\u5220\u9664\uff1a30m\u30012h\u30017d\uff08\u9ed8\u8ba4 1d\uff09\uff0c\u6216 never\uff08\u4e0d\u5220\uff09","  Add the other ssh options this host needs to the ssh line.":"  \u8fd9\u53f0\u4e3b\u673a\u8fd8\u9700\u8981\u7684\u5176\u4ed6 ssh \u9009\u9879\uff0c\u8bf7\u81ea\u5df1\u52a0\u5230 ssh \u90a3\u4e00\u884c\u91cc\u3002","  Add the other ssh options this host needs to the ssh-copy-id line.":"  \u8fd9\u53f0\u4e3b\u673a\u8fd8\u9700\u8981\u7684\u5176\u4ed6 ssh \u9009\u9879\uff0c\u8bf7\u81ea\u5df1\u52a0\u5230 ssh-copy-id \u90a3\u4e00\u884c\u91cc\u3002","  If you log in with ssh -i KEY, or ~/.ssh/config names an IdentityFile for this host,":"  \u5982\u679c\u4f60\u5e73\u65f6\u7528 ssh -i KEY \u767b\u5f55\uff0c\u6216\u8005 ~/.ssh/config \u7ed9\u8fd9\u53f0\u4e3b\u673a\u6307\u5b9a\u4e86 IdentityFile\uff0c","  Or paste there without a key: ssh-paste {0} (wrapper mode) shares the connection you log in to.":"  \u4e5f\u53ef\u4ee5\u4e0d\u914d key\uff1assh-paste {0}\uff08wrapper \u6a21\u5f0f\uff09\u4f1a\u5171\u7528\u4f60\u767b\u5f55\u7684\u90a3\u6761\u8fde\u63a5\u6765\u4e0a\u4f20\u3002","  Set up a key (once; ssh asks your password one last time):":"  \u914d\u7f6e key\uff08\u53ea\u9700\u4e00\u6b21\uff1bssh \u4f1a\u6700\u540e\u4e00\u6b21\u63d0\u793a\u4f60\u8f93\u5165\u5bc6\u7801\uff09\uff1a","  Set up a key (once; ssh-copy-id asks your password one last time):":"  \u914d\u7f6e key\uff08\u53ea\u9700\u4e00\u6b21\uff1bssh-copy-id \u4f1a\u6700\u540e\u4e00\u6b21\u63d0\u793a\u4f60\u8f93\u5165\u5bc6\u7801\uff09\uff1a","  With a passphrase, also run: {0}":"  \u5982\u679c\u7ed9 key \u8bbe\u4e86 passphrase\uff0c\u8fd8\u8981\u8fd0\u884c\uff1a{0}","  info  ssh mode is off for {0}. Turn it on: ssh-paste --enable {0}   (or use: ssh-paste {0})":"  info  {0} \u6ca1\u6709\u5f00\u542f ssh \u6a21\u5f0f\u3002\u5f00\u542f\uff1assh-paste --enable {0}   \uff08\u6216\u8005\u7528\uff1assh-paste {0}\uff09","  ssh-keygen: press Enter at each question (no passphrase: Windows\u0027 ssh-agent is off":"  ssh-keygen\uff1a\u6bcf\u4e2a\u95ee\u9898\u76f4\u63a5\u6309\u56de\u8f66\uff08\u4e0d\u8bbe passphrase\uff1aWindows \u7684 ssh-agent \u9ed8\u8ba4\u5173\u95ed\uff0c","  ssh-keygen: press Enter at each question; if the key file exists already, answer n.":"  ssh-keygen\uff1a\u6bcf\u4e2a\u95ee\u9898\u76f4\u63a5\u6309\u56de\u8f66\uff1b\u5982\u679c\u63d0\u793a key \u6587\u4ef6\u5df2\u7ecf\u5b58\u5728\uff0c\u56de\u7b54 n\u3002","  ssh-paste --disable [HOST...]           undo --enable (all hosts if none given)":"  ssh-paste --disable [HOST...]           \u64a4\u9500 --enable\uff08\u4e0d\u5199\u4e3b\u673a\u5c31\u662f\u5168\u90e8\uff09","  ssh-paste --doctor [HOST]               check this computer and test an upload to HOST":"  ssh-paste --doctor [HOST]               \u68c0\u67e5\u672c\u673a\uff0c\u5e76\u8bd5\u7740\u5f80 HOST \u4e0a\u4f20\u4e00\u6b21","  ssh-paste --enable [OPTIONS] HOST...    make plain \"ssh HOST\" paste screenshots (edits ~/.ssh/config)":"  ssh-paste --enable [OPTIONS] HOST...    \u8ba9\u666e\u901a\u7684 \"ssh HOST\" \u4e5f\u80fd\u7c98\u8d34\u622a\u56fe\uff08\u4f1a\u4fee\u6539 ~/.ssh/config\uff09","  ssh-paste --uninstall                   remove ssh-paste and everything it changed":"  ssh-paste --uninstall                   \u5378\u8f7d ssh-paste\uff0c\u5e76\u64a4\u9500\u5b83\u505a\u8fc7\u7684\u6240\u6709\u6539\u52a8","  ssh-paste --update                      install the latest release":"  ssh-paste --update                      \u5b89\u88c5\u6700\u65b0\u7248\u672c","  ssh-paste [OPTIONS] [ssh options] HOST  wrapper mode: ssh with screenshot paste, no config":"  ssh-paste [OPTIONS] [ssh options] HOST  wrapper \u6a21\u5f0f\uff1a\u5e26\u622a\u56fe\u7c98\u8d34\u7684 ssh\uff0c\u4e0d\u6539\u914d\u7f6e","  unless an administrator turns it on); if the key file exists already, answer n.":"  \u8981\u7ba1\u7406\u5458\u624d\u80fd\u6253\u5f00\uff09\uff1b\u5982\u679c\u63d0\u793a key \u6587\u4ef6\u5df2\u7ecf\u5b58\u5728\uff0c\u56de\u7b54 n\u3002","  use that key instead, and name it with IdentityFile in the Host entry.":"  \u5c31\u6362\u7528\u90a3\u628a key\uff0c\u5e76\u5728 Host \u914d\u7f6e\u91cc\u7528 IdentityFile \u5199\u660e\u3002","--dir is given twice":"--dir \u5199\u4e86\u4e24\u6b21","--dir takes a folder on the server, /... or ~/... (quote ~ so that your shell keeps it), with letters, digits and . _ - / only: {0}":"--dir \u8981\u5199\u670d\u52a1\u5668\u4e0a\u7684\u76ee\u5f55\uff1a/... \u6216 ~/...\uff08~ \u8981\u52a0\u5f15\u53f7\uff0c\u514d\u5f97\u88ab\u4f60\u672c\u673a\u7684 shell \u5c55\u5f00\uff09\uff0c\u53ea\u80fd\u542b\u5b57\u6bcd\u3001\u6570\u5b57\u548c . _ - /\uff1a{0}","--keep is at least 10m: {0}":"--keep \u81f3\u5c11\u662f 10m\uff1a{0}","--keep is at most 3650d: {0}":"--keep \u6700\u591a\u662f 3650d\uff1a{0}","--keep is given twice":"--keep \u5199\u4e86\u4e24\u6b21","--keep takes a time like 30m, 2h or 7d, or never: {0}":"--keep \u8981\u5199 30m\u30012h\u30017d \u8fd9\u6837\u7684\u65f6\u95f4\uff0c\u6216\u8005 never\uff1a{0}","--update takes no options: {0}":"--update \u4e0d\u63a5\u53d7\u9009\u9879\uff1a{0}","Add a host to test an upload: ssh-paste --doctor myhost":"\u52a0\u4e0a\u4e3b\u673a\u540d\uff0c\u53ef\u4ee5\u8bd5\u4e00\u6b21\u4e0a\u4f20\uff1assh-paste --doctor myhost","Add a host to test an upload: {0}":"\u52a0\u4e0a\u4e3b\u673a\u540d\uff0c\u53ef\u4ee5\u8bd5\u4e00\u6b21\u4e0a\u4f20\uff1a{0}","All commands:":"\u5168\u90e8\u547d\u4ee4\uff1a","Already enabled with these settings; nothing changed.":"\u5df2\u7ecf\u7528\u8fd9\u4e9b\u8bbe\u7f6e\u542f\u7528\u8fc7\u4e86\uff0c\u6ca1\u6709\u6539\u52a8\u3002","Changed for: {0}":"\u5df2\u4fee\u6539\uff1a{0}","Deleted {0}":"\u5df2\u5220\u9664 {0}","Disabled for: {0}":"\u5df2\u505c\u7528\uff1a{0}","Downloading the latest release from {0}":"\u6b63\u5728\u4ece {0} \u4e0b\u8f7d\u6700\u65b0\u7248\u672c","Enabled for: {0}":"\u5df2\u542f\u7528\uff1a{0}","Images already uploaded stay in /tmp on your servers until the server clears /tmp.":"\u5df2\u7ecf\u4e0a\u4f20\u7684\u56fe\u7247\u4f1a\u7559\u5728\u670d\u52a1\u5668\u7684 /tmp \u91cc\uff0c\u76f4\u5230\u670d\u52a1\u5668\u6e05\u7406 /tmp\u3002","Now connect as usual: ssh {0}":"\u73b0\u5728\u7167\u5e38\u8fde\u63a5\uff1assh {0}","OPTIONS (images on the server; per host for --enable):":"OPTIONS\uff08\u670d\u52a1\u5668\u4e0a\u7684\u56fe\u7247\uff1b\u914d\u5408 --enable \u65f6\u6309\u4e3b\u673a\u5206\u522b\u8bbe\u7f6e\uff09\uff1a","Or without changing ~/.ssh/config:":"\u6216\u8005\u4e0d\u6539 ~/.ssh/config\uff1a","PowerShell runs in {0} mode here (AppLocker or App Control policy)":"\u8fd9\u53f0\u7535\u8111\u4e0a\u7684 PowerShell \u8fd0\u884c\u5728 {0} \u6a21\u5f0f\uff08AppLocker \u6216 App Control \u7b56\u7565\uff09","Removed from your PATH: {0}":"\u5df2\u4ece PATH \u4e2d\u79fb\u9664\uff1a{0}","Run: ssh-paste --doctor {0}":"\u8bf7\u8fd0\u884c\uff1assh-paste --doctor {0}","SSH_PASTE_LAUNCHER is not set; run this through the ssh-paste command":"\u6ca1\u6709\u8bbe\u7f6e SSH_PASTE_LAUNCHER\uff1b\u8bf7\u901a\u8fc7 ssh-paste \u547d\u4ee4\u6765\u8fd0\u884c","Scoop installed ssh-paste without the apps\\ssh-paste\\current junction (its no_junction setting), so no path to it stays after scoop update. Use wrapper mode instead: ssh-paste HOST":"Scoop \u5b89\u88c5 ssh-paste \u65f6\u6ca1\u6709\u5efa\u7acb apps\\ssh-paste\\current \u94fe\u63a5\uff08\u5b83\u7684 no_junction \u8bbe\u7f6e\uff09\uff0cscoop update \u4e4b\u540e\u5c31\u6ca1\u6709\u56fa\u5b9a\u7684\u8def\u5f84\u53ef\u7528\u3002\u8bf7\u6539\u7528 wrapper \u6a21\u5f0f\uff1assh-paste HOST","Start:":"\u5f00\u59cb\uff1a","Then run again: ssh-paste --enable {0}":"\u7136\u540e\u518d\u8fd0\u884c\u4e00\u6b21\uff1assh-paste --enable {0}","This block is at the top of {0}:":"\u8fd9\u6bb5\u914d\u7f6e\u5728 {0} \u7684\u6700\u524d\u9762\uff1a","To delete them now: {0}":"\u60f3\u73b0\u5728\u5c31\u5220\u6389\uff1a{0}","Uploads use a second, non-interactive ssh connection, so the server must":"\u4e0a\u4f20\u7528\u7684\u662f\u53e6\u4e00\u6761\u4e0d\u80fd\u4ea4\u4e92\u7684 ssh \u8fde\u63a5\uff0c\u6240\u4ee5\u670d\u52a1\u5668\u5fc5\u987b","accept your key without a prompt: a key without a passphrase, or a key loaded":"\u4e0d\u7ecf\u63d0\u793a\u5c31\u63a5\u53d7\u4f60\u7684 key\uff1a\u4e00\u628a\u6ca1\u6709 passphrase \u7684 key\uff0c\u6216\u8005\u5df2\u7ecf\u52a0\u8f7d\u5230","bad --dir: {0}":"--dir \u4e0d\u5bf9\uff1a{0}","bad control socket: {0}":"\u63a7\u5236 socket \u4e0d\u5bf9\uff1a{0}","bad image extension: {0}":"\u56fe\u7247\u6269\u5c55\u540d\u4e0d\u5bf9\uff1a{0}","bad image hash: {0}":"\u56fe\u7247\u54c8\u5e0c\u4e0d\u5bf9\uff1a{0}","cannot ask {0} for its home folder ({1}); give an absolute --dir":"\u6ca1\u6cd5\u95ee {0} \u5b83\u7684\u5bb6\u76ee\u5f55\u5728\u54ea\uff08{1}\uff09\uff1b\u8bf7\u7ed9 --dir \u5199\u5b8c\u6574\u8def\u5f84","cannot connect to {0} port {1}: {2}":"\u8fde\u4e0d\u4e0a {0} \u7684 {1} \u7aef\u53e3\uff1a{2}","cannot find the host {0} (from {1}). Check the name, or add it to ~/.ssh/config, then run --enable again":"\u627e\u4e0d\u5230\u4e3b\u673a {0}\uff08\u6765\u81ea {1}\uff09\u3002\u8bf7\u68c0\u67e5\u540d\u5b57\uff0c\u6216\u8005\u628a\u5b83\u52a0\u8fdb ~/.ssh/config\uff0c\u7136\u540e\u518d\u8fd0\u884c\u4e00\u6b21 --enable","cannot read {0}":"\u8bfb\u4e0d\u4e86 {0}","cannot tell which terminal app runs this session; set SSH_PASTE_TERMINAL to its bundle id":"\u5224\u65ad\u4e0d\u51fa\u8fd9\u4e2a\u4f1a\u8bdd\u8dd1\u5728\u54ea\u4e2a\u7ec8\u7aef\u7a0b\u5e8f\u91cc\uff1b\u8bf7\u628a SSH_PASTE_TERMINAL \u8bbe\u4e3a\u5b83\u7684 bundle id","clipboard and window APIs available":"\u526a\u8d34\u677f\u548c\u7a97\u53e3 API \u53ef\u7528","clipboard: image, {0} bytes":"\u526a\u8d34\u677f\uff1a\u56fe\u7247\uff0c{0} \u5b57\u8282","clipboard: readable (no image right now)":"\u526a\u8d34\u677f\uff1a\u53ef\u4ee5\u8bfb\u53d6\uff08\u73b0\u5728\u6ca1\u6709\u56fe\u7247\uff09","clipboard: {0}":"\u526a\u8d34\u677f\uff1a{0}","clipboard: {0} copied image file(s)":"\u526a\u8d34\u677f\uff1a\u590d\u5236\u4e86 {0} \u4e2a\u56fe\u7247\u6587\u4ef6","could not check the login to {0} now ({1}); ssh-paste --doctor {0} tests it":"\u73b0\u5728\u68c0\u67e5\u4e0d\u4e86\u80fd\u4e0d\u80fd\u767b\u5f55 {0}\uff08{1}\uff09\uff1bssh-paste --doctor {0} \u53ef\u4ee5\u6d4b\u8bd5","could not create a private folder in {0}":"\u6ca1\u6cd5\u5728 {0} \u91cc\u5efa\u79c1\u6709\u76ee\u5f55","could not download {0}: {1}":"\u4e0b\u8f7d {0} \u5931\u8d25\uff1a{1}","could not keep {0}":"\u6ca1\u6cd5\u4fdd\u7559 {0}","could not start {0}: {1}":"\u542f\u52a8 {0} \u5931\u8d25\uff1a{1}","could not write the clipboard":"\u5199\u4e0d\u4e86\u526a\u8d34\u677f","could not write the clipboard: the clipboard changed since it was read":"\u5199\u4e0d\u4e86\u526a\u8d34\u677f\uff1a\u8bfb\u53d6\u4e4b\u540e\u526a\u8d34\u677f\u53c8\u53d8\u4e86","could not write the clipboard: {0}":"\u5199\u4e0d\u4e86\u526a\u8d34\u677f\uff1a{0}","could not write {0}":"\u5199\u4e0d\u4e86 {0}","focus per tab: this tab is {0}":"\u6309\u6807\u7b7e\u9875\u5224\u65ad\u7126\u70b9\uff1a\u672c\u6807\u7b7e\u9875\u662f {0}","focus per window: {0}":"\u6309\u7a97\u53e3\u5224\u65ad\u7126\u70b9\uff1a{0}","images in {0} on the server, kept {1}":"\u56fe\u7247\u653e\u5728\u670d\u52a1\u5668\u7684 {0}\uff0c\u4fdd\u7559 {1}","images in {0} on the server, never deleted":"\u56fe\u7247\u653e\u5728\u670d\u52a1\u5668\u7684 {0}\uff0c\u6c38\u4e0d\u5220\u9664","in ssh-agent (Get-Service ssh-agent; ssh-add). Password-only logins cannot work.":"ssh-agent \u91cc\u7684 key\uff08Get-Service ssh-agent; ssh-add\uff09\u3002\u53ea\u80fd\u7528\u5bc6\u7801\u767b\u5f55\u7684\u670d\u52a1\u5668\u4e0d\u884c\u3002","in ssh-agent (ssh-add --apple-use-keychain). Password-only logins cannot work.":"ssh-agent \u91cc\u7684 key\uff08ssh-add --apple-use-keychain\uff09\u3002\u53ea\u80fd\u7528\u5bc6\u7801\u767b\u5f55\u7684\u670d\u52a1\u5668\u4e0d\u884c\u3002","install.ps1 does not match SHA256SUMS; nothing was changed":"install.ps1 \u548c SHA256SUMS \u5bf9\u4e0d\u4e0a\uff1b\u4ec0\u4e48\u90fd\u6ca1\u6539","install.sh does not match SHA256SUMS; nothing was changed":"install.sh \u548c SHA256SUMS \u5bf9\u4e0d\u4e0a\uff1b\u4ec0\u4e48\u90fd\u6ca1\u6539","macOS {0}, osascript JavaScript":"macOS {0}\uff0cosascript JavaScript","no address":"\u6ca1\u6709\u5730\u5740","nothing changed in ~/.ssh/config:":"~/.ssh/config \u6ca1\u6709\u6539\u52a8\uff1a","pasteboard and window APIs available (change count {0}, front window {1})":"\u526a\u8d34\u677f\u548c\u7a97\u53e3 API \u53ef\u7528\uff08\u53d8\u5316\u8ba1\u6570 {0}\uff0c\u524d\u53f0\u7a97\u53e3 {1}\uff09","pasteboard or window API: {0}":"\u526a\u8d34\u677f\u6216\u7a97\u53e3 API\uff1a{0}","shasum failed: {0}":"shasum \u5931\u8d25\uff1a{0}","size mismatch: sent {0} bytes, server has {1}":"\u5927\u5c0f\u5bf9\u4e0d\u4e0a\uff1a\u53d1\u9001\u4e86 {0} \u5b57\u8282\uff0c\u670d\u52a1\u5668\u4e0a\u662f {1}","ssh -G {0} failed: {1}":"ssh -G {0} \u5931\u8d25\uff1a{1}","ssh could not verify the host key of {0}: run ssh {0} to see why (a new host asks you to accept its key)":"ssh \u6ca1\u6cd5\u9a8c\u8bc1 {0} \u7684 host key\uff1a\u8fd0\u884c ssh {0} \u770b\u770b\u539f\u56e0\uff08\u65b0\u4e3b\u673a\u4f1a\u8bf7\u4f60\u786e\u8ba4\u63a5\u53d7\u5b83\u7684 key\uff09","ssh did not finish in {0} seconds (stdin sent: {1}); ssh said: {2}":"ssh \u5728 {0} \u79d2\u5185\u6ca1\u6709\u7ed3\u675f\uff08\u5df2\u53d1\u9001 stdin\uff1a{1}\uff09\uff1bssh \u8bf4\uff1a{2}","ssh did not finish in {0} seconds; ssh said: {1}":"ssh \u5728 {0} \u79d2\u5185\u6ca1\u6709\u7ed3\u675f\uff1bssh \u8bf4\uff1a{1}","ssh exited with {0}, and the server sent no home folder":"ssh \u9000\u51fa\u7801 {0}\uff0c\u670d\u52a1\u5668\u6ca1\u6709\u8fd4\u56de\u5bb6\u76ee\u5f55","ssh mode: enabled, \"ssh {0}\" pastes screenshots ({1})":"ssh \u6a21\u5f0f\uff1a\u5df2\u542f\u7528\uff0c\"ssh {0}\" \u53ef\u4ee5\u7c98\u8d34\u622a\u56fe\uff08{1}\uff09","ssh option -{0} needs an argument":"ssh \u9009\u9879 -{0} \u9700\u8981\u4e00\u4e2a\u53c2\u6570","ssh-paste is not enabled for any host.":"ssh-paste \u6ca1\u6709\u4e3a\u4efb\u4f55\u4e3b\u673a\u542f\u7528\u3002","ssh-paste is not enabled for: {0}":"ssh-paste \u6ca1\u6709\u4e3a\u8fd9\u4e9b\u4e3b\u673a\u542f\u7528\uff1a{0}","ssh-paste is uninstalled.":"ssh-paste \u5df2\u5378\u8f7d\u3002","ssh-paste was installed with Scoop. Remove it with: scoop uninstall ssh-paste (it also runs ssh-paste --disable)":"ssh-paste \u662f\u7528 Scoop \u5b89\u88c5\u7684\uff0c\u5378\u8f7d\u65f6\u4e5f\u4f1a\u8fd0\u884c ssh-paste --disable\u3002\u5378\u8f7d\u8bf7\u8fd0\u884c\uff1ascoop uninstall ssh-paste","ssh-paste was installed with Scoop. Update it with: scoop update ssh-paste":"ssh-paste \u662f\u7528 Scoop \u5b89\u88c5\u7684\u3002\u5347\u7ea7\u8bf7\u8fd0\u884c\uff1ascoop update ssh-paste","ssh-paste {0} - paste Windows screenshots into programs running over SSH":"ssh-paste {0} - \u628a Windows \u622a\u56fe\u7c98\u8d34\u5230\u901a\u8fc7 SSH \u8fd0\u884c\u7684\u7a0b\u5e8f\u91cc","ssh-paste {0} - paste macOS screenshots into programs running over SSH":"ssh-paste {0} - \u628a macOS \u622a\u56fe\u7c98\u8d34\u5230\u901a\u8fc7 SSH \u8fd0\u884c\u7684\u7a0b\u5e8f\u91cc","ssh-paste: --dir {0} is a folder of this Mac; if you meant the home folder on the server, quote the ~: --dir \u0027{1}\u0027":"ssh-paste\uff1a--dir {0} \u662f\u8fd9\u53f0 Mac \u4e0a\u7684\u76ee\u5f55\uff1b\u5982\u679c\u4f60\u6307\u7684\u662f\u670d\u52a1\u5668\u4e0a\u7684\u5bb6\u76ee\u5f55\uff0c\u8bf7\u7ed9 ~ \u52a0\u5f15\u53f7\uff1a--dir \u0027{1}\u0027","ssh-paste: --proxy needs %h %p %n":"ssh-paste\uff1a--proxy \u9700\u8981 %h %p %n","ssh-paste: connection error: {0}":"ssh-paste\uff1a\u8fde\u63a5\u51fa\u9519\uff1a{0}","ssh-paste: screenshot paste is off: {0}":"ssh-paste\uff1a\u622a\u56fe\u7c98\u8d34\u5df2\u5173\u95ed\uff1a{0}","ssh-paste: screenshot paste is on. Copy a screenshot, come back here, press Cmd+V.":"ssh-paste\uff1a\u622a\u56fe\u7c98\u8d34\u5df2\u5f00\u542f\u3002\u590d\u5236\u4e00\u5f20\u622a\u56fe\uff0c\u56de\u5230\u8fd9\u91cc\uff0c\u6309 Cmd+V\u3002","ssh-paste: screenshot paste is on. Copy a screenshot, come back here, press Ctrl+V.":"ssh-paste\uff1a\u622a\u56fe\u7c98\u8d34\u5df2\u5f00\u542f\u3002\u590d\u5236\u4e00\u5f20\u622a\u56fe\uff0c\u56de\u5230\u8fd9\u91cc\uff0c\u6309 Ctrl+V\u3002","ssh-paste: screenshot paste was off for this session: {0}":"ssh-paste\uff1a\u8fd9\u4e2a\u4f1a\u8bdd\u6ca1\u6709\u622a\u56fe\u7c98\u8d34\uff1a{0}","ssh-paste: ssh mode serves {0}, with its own --keep and --dir; change them with ssh-paste --enable --keep TIME --dir DIR {0}":"ssh-paste\uff1a{0} \u5df2\u7ecf\u7531 ssh \u6a21\u5f0f\u8d1f\u8d23\uff0c\u7528\u7684\u662f\u5b83\u81ea\u5df1\u7684 --keep \u548c --dir\uff1b\u8981\u4fee\u6539\u8bf7\u8fd0\u884c ssh-paste --enable --keep TIME --dir DIR {0}","ssh-paste: the server did not close the connection within 30 seconds":"ssh-paste\uff1a\u670d\u52a1\u5668 30 \u79d2\u5185\u6ca1\u6709\u5173\u95ed\u8fde\u63a5","ssh-paste: unknown command {0}; run ssh-paste --help":"ssh-paste\uff1a\u672a\u77e5\u547d\u4ee4 {0}\uff1b\u8bf7\u8fd0\u884c ssh-paste --help","ssh-paste: {0}":"ssh-paste\uff1a{0}","ssh-paste: {0} screenshot upload(s) failed: {1}":"ssh-paste\uff1a{0} \u6b21\u622a\u56fe\u4e0a\u4f20\u5931\u8d25\uff1a{1}","ssh.exe was not found. Add \"OpenSSH Client\" under Optional features in Windows Settings.":"\u627e\u4e0d\u5230 ssh.exe\u3002\u8bf7\u5728 Windows \u8bbe\u7f6e\u7684\"\u53ef\u9009\u529f\u80fd\"\u91cc\u6dfb\u52a0 \"OpenSSH Client\"\u3002","ssh: {0}":"ssh\uff1a{0}","ssh: {0} ({1})":"ssh\uff1a{0}\uff08{1}\uff09","terminal: {0}":"\u7ec8\u7aef\uff1a{0}","terminal: {0} (from {1}), no window on screen":"\u7ec8\u7aef\uff1a{0}\uff08\u6765\u81ea {1}\uff09\uff0c\u5c4f\u5e55\u4e0a\u6ca1\u6709\u7a97\u53e3","terminal: {0} (from {1}), window {2}":"\u7ec8\u7aef\uff1a{0}\uff08\u6765\u81ea {1}\uff09\uff0c\u7a97\u53e3 {2}","the folder {0} on the server is not yours alone (owned by you, not a link, not writable by group or others); use /tmp or such a folder":"\u670d\u52a1\u5668\u4e0a\u7684\u76ee\u5f55 {0} \u4e0d\u662f\u53ea\u5c5e\u4e8e\u4f60\u7684\uff08\u8981\u5f52\u4f60\u6240\u6709\u3001\u4e0d\u662f\u94fe\u63a5\u3001\u7ec4\u548c\u5176\u4ed6\u4eba\u90fd\u4e0d\u53ef\u5199\uff09\uff1b\u8bf7\u7528 /tmp \u6216\u8005\u6ee1\u8db3\u8fd9\u4e9b\u6761\u4ef6\u7684\u76ee\u5f55","the home folder on the server ({0}) makes {1}, which --dir cannot use; give an absolute --dir":"\u670d\u52a1\u5668\u4e0a\u7684\u5bb6\u76ee\u5f55\uff08{0}\uff09\u62fc\u51fa\u6765\u662f {1}\uff0c--dir \u7528\u4e0d\u4e86\uff1b\u8bf7\u7ed9 --dir \u5199\u5b8c\u6574\u8def\u5f84","the new ssh config text is not plain text":"\u65b0\u7684 ssh \u914d\u7f6e\u5185\u5bb9\u4e0d\u662f\u7eaf\u6587\u672c","the reply from ssh did not arrive in time":"ssh \u7684\u56de\u590d\u6ca1\u6709\u53ca\u65f6\u5230\u8fbe","the server cannot write to the folder {0} (--dir)":"\u670d\u52a1\u5668\u5199\u4e0d\u4e86\u76ee\u5f55 {0}\uff08--dir\uff09","the server received {0} of {1} bytes":"\u670d\u52a1\u5668\u53ea\u6536\u5230 {1} \u5b57\u8282\u4e2d\u7684 {0} \u5b57\u8282","the server sent no reply (is sh available there?)":"\u670d\u52a1\u5668\u6ca1\u6709\u56de\u590d\uff08\u90a3\u91cc\u6709 sh \u5417\uff1f\uff09","the ssh-paste block in the ssh config has no end marker; fix it by hand":"ssh \u914d\u7f6e\u91cc ssh-paste \u90a3\u6bb5\u7f3a\u5c11\u7ed3\u675f\u6807\u8bb0\uff1b\u8bf7\u624b\u52a8\u4fee\u597d","the ssh-paste command path contains a line break":"ssh-paste \u547d\u4ee4\u7684\u8def\u5f84\u91cc\u6709\u6362\u884c","the ssh-paste command path is not absolute: {0}":"ssh-paste \u547d\u4ee4\u7684\u8def\u5f84\u4e0d\u662f\u7edd\u5bf9\u8def\u5f84\uff1a{0}","the terminal app {0} (from {1}) is not running":"\u7ec8\u7aef\u7a0b\u5e8f {0}\uff08\u6765\u81ea {1}\uff09\u6ca1\u6709\u5728\u8fd0\u884c","the terminal app {0} has no window on screen":"\u7ec8\u7aef\u7a0b\u5e8f {0} \u5728\u5c4f\u5e55\u4e0a\u6ca1\u6709\u7a97\u53e3","unexpected path from the server: {0}":"\u670d\u52a1\u5668\u8fd4\u56de\u4e86\u610f\u6599\u4e4b\u5916\u7684\u8def\u5f84\uff1a{0}","unexpected reply from the server: {0}":"\u670d\u52a1\u5668\u8fd4\u56de\u4e86\u610f\u6599\u4e4b\u5916\u7684\u56de\u590d\uff1a{0}","unknown --proxy arguments: {0}":"\u672a\u77e5\u7684 --proxy \u53c2\u6570\uff1a{0}","unknown ssh option -{0}":"\u672a\u77e5\u7684 ssh \u9009\u9879 -{0}","upload to {0}: {1}":"\u4e0a\u4f20\u5230 {0}\uff1a{1}","upload to {0}: {1} ({2:N1} s)":"\u4e0a\u4f20\u5230 {0}\uff1a{1}\uff08{2:N1} \u79d2\uff09","upload to {0}: {1} ({2} s)":"\u4e0a\u4f20\u5230 {0}\uff1a{1}\uff08{2} \u79d2\uff09","usage: ssh-paste --enable [--keep TIME] [--dir DIR] HOST [HOST...]":"\u7528\u6cd5\uff1assh-paste --enable [--keep TIME] [--dir DIR] HOST [HOST...]","usage: ssh-paste [--keep TIME] [--dir DIR] [ssh options] HOST":"\u7528\u6cd5\uff1assh-paste [--keep TIME] [--dir DIR] [ssh options] HOST","use a host name or a Host alias from ~/.ssh/config (no user@, no options): {0}":"\u8bf7\u5199\u4e3b\u673a\u540d\u6216 ~/.ssh/config \u91cc\u7684 Host \u522b\u540d\uff08\u4e0d\u5e26 user@\uff0c\u4e0d\u5e26\u9009\u9879\uff09\uff1a{0}","{0} already uses {1} ({2}); ssh-paste cannot take over its connection. Use wrapper mode instead: ssh-paste {0}":"{0} \u5df2\u7ecf\u7528\u4e86 {1}\uff08{2}\uff09\uff1bssh-paste \u6ca1\u6cd5\u63a5\u7ba1\u5b83\u7684\u8fde\u63a5\u3002\u8bf7\u6539\u7528 wrapper \u6a21\u5f0f\uff1assh-paste {0}","{0} changed while ssh-paste was editing it; run the command again":"ssh-paste \u4fee\u6539 {0} \u65f6\u5b83\u88ab\u522b\u5904\u6539\u52a8\u4e86\uff1b\u8bf7\u518d\u8fd0\u884c\u4e00\u6b21","{0} closed the login after too many keys were tried: name the right key for it with IdentityFile and IdentitiesOnly yes in ~/.ssh/config":"{0} \u56e0\u4e3a\u8bd5\u4e86\u592a\u591a\u628a key \u800c\u65ad\u5f00\u4e86\u767b\u5f55\uff1a\u8bf7\u5728 ~/.ssh/config \u91cc\u7528 IdentityFile \u548c IdentitiesOnly yes \u6307\u5b9a\u6b63\u786e\u7684\u90a3\u628a","{0} did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add":"{0} \u6ca1\u6709\u63a5\u53d7\u4e0a\u4f20\u7528\u7684 key\uff08\u4e0a\u4f20\u6ca1\u6cd5\u8f93\u5bc6\u7801\uff09\uff1a\u8bf7\u914d\u7f6e\u4e00\u628a key\uff0c\u6216\u8005\u7528 ssh-add \u52a0\u8f7d\u4f60\u5df2\u6709\u7684 key","{0} did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add; ssh-paste --doctor {0} shows how":"{0} \u6ca1\u6709\u63a5\u53d7\u4e0a\u4f20\u7528\u7684 key\uff08\u4e0a\u4f20\u6ca1\u6cd5\u8f93\u5bc6\u7801\uff09\uff1a\u8bf7\u914d\u7f6e\u4e00\u628a key\uff0c\u6216\u8005\u7528 ssh-add \u52a0\u8f7d\u4f60\u5df2\u6709\u7684 key\uff1bssh-paste --doctor {0} \u4f1a\u544a\u8bc9\u4f60\u600e\u4e48\u505a","{0} did not finish in {1} seconds":"{0} \u5728 {1} \u79d2\u5185\u6ca1\u6709\u7ed3\u675f","{0} needs a value":"{0} \u9700\u8981\u4e00\u4e2a\u503c","{0} refused a second session on this connection, so uploads cannot share it; with a key, ssh-paste -S none {0} uploads over new connections":"{0} \u62d2\u7edd\u5728\u8fd9\u6761\u8fde\u63a5\u4e0a\u5f00\u7b2c\u4e8c\u4e2a\u4f1a\u8bdd\uff0c\u6240\u4ee5\u4e0a\u4f20\u6ca1\u6cd5\u5171\u7528\u5b83\uff1b\u914d\u597d key \u540e\uff0cssh-paste -S none {0} \u4f1a\u7528\u65b0\u8fde\u63a5\u4e0a\u4f20","{0} refused the login for uploads ({1})":"{0} \u62d2\u7edd\u4e86\u4e0a\u4f20\u7528\u7684\u767b\u5f55\uff08{1}\uff09","{0} wants a password or a one-time code ({1}), which uploads cannot type, so ssh-paste cannot upload to it":"{0} \u8981\u6c42\u8f93\u5165\u5bc6\u7801\u6216\u4e00\u6b21\u6027\u9a8c\u8bc1\u7801\uff08{1}\uff09\uff0c\u4e0a\u4f20\u6ca1\u6cd5\u8f93\u5165\uff0c\u6240\u4ee5 ssh-paste \u4f20\u4e0d\u4e86\u56fe\u7247","{0}: timed out":"{0}\uff1a\u8d85\u65f6","{0}: uploads log in without a password":"{0}\uff1a\u4e0a\u4f20\u53ef\u4ee5\u514d\u5bc6\u767b\u5f55","{0}: {1}":"{0}\uff1a{1}","{0}: {1} is {2} there":"{0}\uff1a{1} \u5728\u90a3\u53f0\u670d\u52a1\u5668\u4e0a\u662f {2}"}}'
# <<< locale
$script:Messages = $null

function ConvertTo-CatalogName {
    # A language tag (zh_CN.UTF-8, zh-Hans-CN, en_US, C) as a catalog name from Available,
    # 'en' for English (C, POSIX, en*), or $null when no catalog has it.
    param([string]$Tag, [string[]]$Available)
    $t = ($Tag -split '[.@]')[0].Replace('_', '-')
    if ($t -ceq 'C' -or $t -ceq 'POSIX' -or $t -match '^en(-|$)') { return 'en' }
    $low = $t.ToLowerInvariant()
    if ($low -match '^zh(-|$)') {
        # Simplified Chinese unless the tag says Traditional or a region that writes it.
        if ($low -match '(^|-)(hant|tw|hk|mo)(-|$)') { return $null }
        $t = 'zh-CN'
    }
    foreach ($a in @($Available)) { if ($a.ToLowerInvariant() -ceq $t.ToLowerInvariant()) { return $a } }
    $lang = ($t -split '-')[0].ToLowerInvariant()
    foreach ($a in @($Available)) { if ((($a -split '-')[0]).ToLowerInvariant() -ceq $lang) { return $a } }
    return $null
}

function Get-UiLanguage {
    # The language for messages, chosen as gettext does: SSH_PASTE_LANG first (ours); else
    # the locale from LC_ALL, LC_MESSAGES or LANG (the first set), where C or POSIX means
    # English; then LANGUAGE, a list, which gettext reads only when the locale is not C; then
    # the locale itself. When no locale variable is set, the system's preferred languages in
    # order (Windows: CurrentUICulture; macOS: NSLocale), skipping those with no catalog.
    # (uiLanguage in src/ssh-paste.js; tests/cases.json uiLanguages.)
    param([hashtable]$Environment, [string[]]$SystemLanguages, [string[]]$Available)
    $own = [string]$Environment['SSH_PASTE_LANG']
    if ($own) {
        $c = ConvertTo-CatalogName $own $Available
        if ($null -ne $c) { return $c }
        return 'en'
    }
    $locale = $null
    foreach ($name in @('LC_ALL', 'LC_MESSAGES', 'LANG')) {
        $value = [string]$Environment[$name]
        if ($value) { $locale = $value; break }
    }
    if ($null -ne $locale) {
        if (($locale -split '[.@]')[0] -cmatch '^(C|POSIX)\z') { return 'en' }
        foreach ($tag in @(([string]$Environment['LANGUAGE']) -split ':' | Where-Object { $_ })) {
            $c = ConvertTo-CatalogName $tag $Available
            if ($null -ne $c) { return $c }
        }
        $c = ConvertTo-CatalogName $locale $Available
        if ($null -ne $c) { return $c }
        return 'en'
    }
    foreach ($tag in @($SystemLanguages)) {
        if ([string]::IsNullOrEmpty($tag)) { continue }
        $c = ConvertTo-CatalogName $tag $Available
        if ($null -ne $c) { return $c }
    }
    return 'en'
}

function Initialize-Language {
    # Picks the catalog once, before any message is written. Choosing a language must never
    # stop the program: in ConstrainedLanguage mode (AppLocker, App Control), on any error, and
    # when the console cannot show the language (Windows PowerShell 5.1 writes stderr in the
    # console code page, so Chinese on code page 437 would become question marks), English.
    $script:Messages = $null
    try {
        if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return }
        Set-UiLanguage
    } catch { $script:Messages = $null }
}

function Set-UiLanguage {
    $data = ConvertFrom-Json $script:LocaleData
    $available = @($data.PSObject.Properties | ForEach-Object { $_.Name })
    $environment = @{}
    foreach ($name in @('SSH_PASTE_LANG', 'LANGUAGE', 'LC_ALL', 'LC_MESSAGES', 'LANG')) { $environment[$name] = [Environment]::GetEnvironmentVariable($name) }
    $language = Get-UiLanguage $environment @([System.Globalization.CultureInfo]::CurrentUICulture.Name) $available
    $script:Messages = $null
    if ($language -ceq 'en') { return }
    $messages = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($p in $data.$language.PSObject.Properties) { $messages[$p.Name] = [string]$p.Value }
    if (-not (Test-ConsoleCanShow (@($messages.Values) -join ''))) { return }
    $script:Messages = $messages
}

function Test-ConsoleCanShow {
    # Whether the console's output encoding keeps every character of Text.
    param([string]$Text)
    $encoding = [Console]::OutputEncoding
    return ($encoding.GetString($encoding.GetBytes($Text)) -ceq $Text)
}

function Get-Text {
    # Template in the user's language, with {0}, {1}... filled from Values; the English
    # template when the catalog has no translation (or no catalog is chosen).
    param([string]$Template, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Values)
    $t = $Template
    if ($null -ne $script:Messages -and $script:Messages.ContainsKey($Template)) { $t = $script:Messages[$Template] }
    if ($null -eq $Values -or $Values.Count -eq 0) { return $t }
    return ($t -f $Values)
}

# ---------------------------------------------------------------------------
# Pure helpers (no Windows APIs; covered by the Pester tests on any platform)
# ---------------------------------------------------------------------------

function ConvertTo-NativeArgument {
    # Quote one argument for the MSVCRT / CommandLineToArgvW parsing rules.
    param([AllowEmptyString()][string]$Argument)
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $Argument.Length) {
        $backslashes = 0
        while ($i -lt $Argument.Length -and $Argument[$i] -eq [char]'\') { $backslashes++; $i++ }
        if ($i -eq $Argument.Length) {
            [void]$sb.Append([char]'\', $backslashes * 2)
            break
        }
        if ($Argument[$i] -eq [char]'"') {
            [void]$sb.Append([char]'\', $backslashes * 2 + 1)
            [void]$sb.Append([char]'"')
        } else {
            [void]$sb.Append([char]'\', $backslashes)
            [void]$sb.Append($Argument[$i])
        }
        $i++
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Join-NativeArguments {
    param([string[]]$Arguments)
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return '' }
    return (($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
}

function Set-ProcessArguments {
    # PowerShell 7 (.NET) has ProcessStartInfo.ArgumentList, which quotes each
    # argument itself; Windows PowerShell 5.1 (.NET Framework) only has the
    # single Arguments string, built with the CommandLineToArgvW rules above.
    param([System.Diagnostics.ProcessStartInfo]$StartInfo, [string[]]$Arguments)
    if ($null -eq $Arguments) { $Arguments = @() }
    if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
        foreach ($a in $Arguments) { $StartInfo.ArgumentList.Add([string]$a) }
    } else {
        $StartInfo.Arguments = Join-NativeArguments $Arguments
    }
}

function Split-SshArguments {
    # Mirrors ssh's own parsing: options may appear before and after the
    # destination; the first non-option after the destination starts the command.
    # Each option remembers which side of the destination it was on, because ssh
    # applies the destination's user@ and :port between the two option passes.
    param([string[]]$Argv)
    $options = New-Object System.Collections.ArrayList
    $destination = $null
    $command = @()
    $i = 0
    if ($null -eq $Argv) { $Argv = @() }
    while ($i -lt $Argv.Count) {
        $token = [string]$Argv[$i]
        if ($token -eq '--') {
            $i++
            if ($null -eq $destination -and $i -lt $Argv.Count) { $destination = [string]$Argv[$i]; $i++ }
            if ($i -lt $Argv.Count) { $command = @($Argv[$i..($Argv.Count - 1)]) }
            break
        }
        if ($token.Length -gt 1 -and $token[0] -eq [char]'-') {
            $after = ($null -ne $destination)
            $j = 1
            while ($j -lt $token.Length) {
                $letter = [string]$token[$j]
                if ($script:SshFlagsNoArg.Contains($letter)) {
                    [void]$options.Add(@{ Flag = $letter; Value = $null; After = $after })
                    $j++
                } elseif ($script:SshFlagsWithArg.Contains($letter)) {
                    if ($j + 1 -lt $token.Length) {
                        $value = $token.Substring($j + 1)
                    } else {
                        $i++
                        if ($i -ge $Argv.Count) { throw (Get-Text 'ssh option -{0} needs an argument' $letter) }
                        $value = [string]$Argv[$i]
                    }
                    [void]$options.Add(@{ Flag = $letter; Value = $value; After = $after })
                    $j = $token.Length
                } else {
                    throw (Get-Text 'unknown ssh option -{0}' $letter)
                }
            }
            $i++
            continue
        }
        if ($null -eq $destination) { $destination = $token; $i++; continue }
        $command = @($Argv[$i..($Argv.Count - 1)])
        break
    }
    return [pscustomobject]@{ Options = @($options); Destination = $destination; Command = @($command) }
}

function Test-InteractiveSsh {
    # Only interactive sessions get the clipboard watcher. scp/sftp/git, VS Code
    # Remote-SSH (-T), port forwards (-N), stdio forwards (-W) stay plain relays.
    # $Effective is the `ssh -G` output for the same arguments, when available:
    # it adds what ~/.ssh/config sets (RequestTTY, SessionType, RemoteCommand).
    param($Parsed, [hashtable]$Effective)
    if ($null -eq $Parsed -or [string]::IsNullOrEmpty($Parsed.Destination)) { return $false }
    $tty = $null
    $hasCommand = ($Parsed.Command.Count -gt 0)
    foreach ($o in $Parsed.Options) {
        if (@('N', 'W', 'f', 's', 'G', 'V', 'O', 'Q', 'n') -ccontains $o.Flag) { return $false }
        if ($o.Flag -ceq 't' -or $o.Flag -ceq 'T') { $tty = $o.Flag }   # the last one wins, as in ssh
        if ($o.Flag -ceq 'o') {
            $key = Get-SshOptionKey $o.Value
            $value = ([string]($o.Value.TrimStart() -split '[=\s]+', 2)[-1]).Trim().ToLowerInvariant()
            if ($key -eq 'sessiontype' -and $value -ne 'default') { return $false }
            if ($key -eq 'stdinnull' -and $value -eq 'yes') { return $false }
            if ($key -eq 'requesttty') {
                if (@('no', 'false') -contains $value) { $tty = 'T' } elseif (@('yes', 'true', 'force') -contains $value) { $tty = 't' }
            }
            if ($key -eq 'remotecommand' -and $value -ne 'none') { $hasCommand = $true }
        }
    }
    if ($null -ne $Effective) {
        if ($Effective.ContainsKey('sessiontype') -and $Effective['sessiontype'] -ne 'default') { return $false }
        if ($Effective.ContainsKey('stdinnull') -and $Effective['stdinnull'] -eq 'yes') { return $false }
        if ($Effective.ContainsKey('requesttty')) {
            $rt = [string]$Effective['requesttty']
            if (@('no', 'false') -contains $rt) { $tty = 'T' } elseif (@('yes', 'true', 'force') -contains $rt) { $tty = 't' }
        }
        if ($Effective.ContainsKey('remotecommand') -and $Effective['remotecommand'] -ne 'none') { $hasCommand = $true }
    }
    if ($tty -ceq 'T') { return $false }
    if ($hasCommand -and $tty -cne 't') { return $false }
    return $true
}

function ConvertFrom-SshG {
    # `ssh -G` prints "key value" lines; keys are lowercase.
    param([string]$Text)
    $map = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^(\S+)\s+(.*)$' -and -not $map.ContainsKey($Matches[1].ToLowerInvariant())) { $map[$Matches[1].ToLowerInvariant()] = $Matches[2] }
    }
    return $map
}

function Get-SshOptionKey {
    param([string]$Value)
    return ([string]($Value.TrimStart() -split '[=\s]', 2)[0]).Trim().ToLowerInvariant()
}

function Get-UploadSshArguments {
    # Arguments for the separate, non-interactive upload connection: those of
    # Get-ServerSshArguments, then the upload command.
    param($Parsed, [string]$Hash, [long]$Size, [switch]$NoProxy, [version]$SshVersion, [hashtable]$Pin, [string]$Ext = 'png',
        [string]$Keep = '1d', [string]$Dir = '/tmp')
    if ($Hash -cnotmatch '^[0-9a-f]{32}\z') { throw "bad image hash: $Hash" }
    if ($script:ImageExtensions -cnotcontains $Ext) { throw "bad image extension: $Ext" }
    $minutes = ConvertTo-KeepMinutes $Keep
    if (-not (Test-ServerDirectory $Dir) -or $Dir.StartsWith('~')) { throw (Get-Text 'bad --dir: {0}' $Dir) }
    $argv = New-Object System.Collections.ArrayList
    foreach ($a in (Get-ServerSshArguments -Parsed $Parsed -NoProxy:$NoProxy -SshVersion $SshVersion -Pin $Pin)) { [void]$argv.Add($a) }
    # The folder in single quotes, as the remote login shell reads the command.
    $command = "sh -c '" + $script:RemoteScript + "' ssh-paste " + $Hash + ' ' + $Size + ' ' + $Ext + ' ' + $minutes + " '" + $Dir + "'"
    $class = Get-KeepClass $Keep
    if ($class.Length -gt 0) { $command += ' ' + $class }
    [void]$argv.Add($command)
    return @($argv)
}

function Get-ServerSshArguments {
    # Arguments for a separate, non-interactive connection to the server of the session
    # (uploads, and the home folder for --dir ~/...), up to the destination and its
    # options; the caller adds the command. Our options come first because ssh uses the
    # first value it sees for each option; the user's options keep their place before or
    # after the destination.
    param($Parsed, [switch]$NoProxy, [version]$SshVersion, [hashtable]$Pin)
    $argv = New-Object System.Collections.ArrayList
    foreach ($a in @('-T', '-x',
            '-o', 'BatchMode=yes', '-o', 'PermitLocalCommand=no', '-o', 'ClearAllForwardings=yes',
            '-o', 'RemoteCommand=none', '-o', 'RequestTTY=no', '-o', 'ForwardAgent=no',
            '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', '-o', 'LogLevel=ERROR')) {
        [void]$argv.Add($a)
    }
    if ($null -ne $SshVersion -and $SshVersion -ge [version]'8.7') {
        # Options that ~/.ssh/config could otherwise set; unknown to older ssh.
        foreach ($a in @('-o', 'StdinNull=no', '-o', 'SessionType=default', '-o', 'ForkAfterAuthentication=no')) { [void]$argv.Add($a) }
    }
    if ($NoProxy) { [void]$argv.Add('-o'); [void]$argv.Add('ProxyCommand=none') }
    if ($null -ne $Pin) {
        # ssh mode: reach the address the session's relay is connected to, and
        # check the host key under the name the session used.
        foreach ($a in @('-o', ('HostName=' + $Pin.HostName), '-o', ('Port=' + $Pin.Port),
                '-o', ('HostKeyAlias=' + $Pin.HostKeyAlias), '-o', 'CheckHostIP=no', '-o', 'CanonicalizeHostname=no')) { [void]$argv.Add($a) }
    }
    $before = New-Object System.Collections.ArrayList
    $after = New-Object System.Collections.ArrayList
    foreach ($o in $Parsed.Options) {
        $target = $before
        if ($o.ContainsKey('After') -and $o.After) { $target = $after }
        if ($null -eq $o.Value) {
            if ($script:SshKeepNoArg.Contains($o.Flag)) { [void]$target.Add('-' + $o.Flag) }
            continue
        }
        if (-not $script:SshKeepWithArg.Contains($o.Flag)) { continue }
        if ($NoProxy -and $o.Flag -ceq 'J') { continue }
        if ($o.Flag -ceq 'o') {
            $key = Get-SshOptionKey $o.Value
            if ($script:SshDropOptions -contains $key) { continue }
            if ($NoProxy -and ($key -eq 'proxycommand' -or $key -eq 'proxyjump')) { continue }
        }
        [void]$target.Add('-' + $o.Flag)
        [void]$target.Add([string]$o.Value)
    }
    foreach ($a in $before) { [void]$argv.Add($a) }
    [void]$argv.Add([string]$Parsed.Destination)
    foreach ($a in $after) { [void]$argv.Add($a) }
    return @($argv)
}

function ConvertTo-AbsoluteDirectory {
    # --dir with ~ made absolute with the home folder on the server; any other --dir as it is.
    param([string]$Dir, [string]$HomeDir)
    if (-not $Dir.StartsWith('~')) { return $Dir }
    $abs = $HomeDir.TrimEnd('/') + $Dir.Substring(1)
    if (-not $abs.StartsWith('/') -or -not (Test-ServerDirectory $abs)) {
        throw (Get-Text 'the home folder on the server ({0}) makes {1}, which --dir cannot use; give an absolute --dir' $HomeDir $abs)
    }
    return $abs
}

function Test-ServerLogin {
    # One connection as an upload makes (no prompt): Home, the home folder on the server, when
    # it logs in; else Error, what ssh said. --enable runs it once for each host it names,
    # with -NoProxy as ssh mode's uploads connect (not through the relay of an older block).
    param([string]$SshPath, $Parsed, [version]$SshVersion, [switch]$NoProxy)
    $argv = @(Get-ServerSshArguments -Parsed $Parsed -NoProxy:$NoProxy -SshVersion $SshVersion) + @('echo $HOME')
    try { $r = Invoke-NativeCapture $SshPath $argv 30 } catch { return @{ Home = $null; Error = $_.Exception.Message } }
    $lines = @(([string]$r.Out) -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    $line = ''
    if ($lines.Count -gt 0) { $line = $lines[$lines.Count - 1].Trim() }
    if ($r.ExitCode -eq 0 -and $line.StartsWith('/')) { return @{ Home = $line; Error = $null } }
    $err = ([string]$r.Err).Trim()
    if ($err) { $err = ('ssh exited with {0}: {1}' -f $r.ExitCode, $err) }
    else { $err = (Get-Text 'ssh exited with {0}, and the server sent no home folder' $r.ExitCode) }
    return @{ Home = $null; Error = $err }
}

function Get-ServerHome {
    # The home folder on the server, for --dir ~/... in wrapper mode.
    param([string]$SshPath, $Parsed, [version]$SshVersion)
    $login = Test-ServerLogin $SshPath $Parsed $SshVersion
    if ($null -eq $login.Home) { throw (Get-HomeError $Parsed.Destination $login.Error) }
    return $login.Home
}

function Get-HomeError {
    param([string]$HostName, [string]$ErrorText)
    return (Get-Text 'cannot ask {0} for its home folder ({1}); give an absolute --dir' $HostName (Get-LoginReport $HostName $ErrorText))
}

function Get-ImageHash {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return (-join ($digest[0..15] | ForEach-Object { $_.ToString('x2') }))
}

function Get-TrimmedPng {
    # Clipboard memory blocks can be longer than the data. Returns the PNG cut
    # after its IEND chunk, or $null when the bytes are not a whole PNG.
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 20) { return $null }
    $signature = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    for ($k = 0; $k -lt 8; $k++) { if ($Bytes[$k] -ne $signature[$k]) { return $null } }
    $pos = 8
    while ($pos + 12 -le $Bytes.Length) {
        $length = ([long]$Bytes[$pos] -shl 24) + ([long]$Bytes[$pos + 1] -shl 16) + ([long]$Bytes[$pos + 2] -shl 8) + [long]$Bytes[$pos + 3]
        $next = $pos + 12 + $length
        if ($next -gt $Bytes.Length) { return $null }
        if ([System.Text.Encoding]::ASCII.GetString($Bytes, $pos + 4, 4) -ceq 'IEND') {
            if ($next -eq $Bytes.Length) { return , $Bytes }
            $out = New-Object byte[] $next
            [Array]::Copy($Bytes, $out, $next)
            return , $out
        }
        $pos = $next
    }
    return $null
}

function ConvertFrom-DropFiles {
    # CF_HDROP bytes (a DROPFILES header, then NUL-separated paths ending with an
    # empty string) -> the list of paths.
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 20) { return @() }
    $offset = [BitConverter]::ToInt32($Bytes, 0)
    if ($offset -lt 20 -or $offset -ge $Bytes.Length) { return @() }
    $encoding = [System.Text.Encoding]::Default
    if ([BitConverter]::ToInt32($Bytes, 16) -ne 0) { $encoding = [System.Text.Encoding]::Unicode }
    $paths = New-Object System.Collections.ArrayList
    foreach ($p in $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset).Split([char]0)) {
        if ($p.Length -eq 0) { break }
        [void]$paths.Add($p)
    }
    return @($paths)
}

function Get-ImageFileExtension {
    # The lowercase extension when the path names an image type we upload, else $null.
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    if ($script:ImageExtensions -contains $ext) { return $ext }
    return $null
}

function Read-UploadReply {
    # The last non-empty line of the reply is "<size> <path>".
    param([string]$Output, [long]$ExpectedSize, [string]$Hash, [string]$Ext = 'png', [string]$Dir = '/tmp', [string]$Class = '')
    $lines = @($Output -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -eq 0) { throw (Get-Text 'the server sent no reply (is sh available there?)') }
    $last = $lines[$lines.Count - 1].Trim()
    if ($last -cmatch '^short (\d+)\z') { throw (Get-Text 'the server received {0} of {1} bytes' $Matches[1] $ExpectedSize) }
    if ($last -ceq 'nodir') { throw (Get-Text 'the server cannot write to the folder {0} (--dir)' $Dir) }
    if ($last -ceq 'notprivate') { throw (Get-Text 'the folder {0} on the server is not yours alone (owned by you, not a link, not writable by group or others); use /tmp or such a folder' $Dir) }
    if ($last -cnotmatch '^(\d+) (/\S+)\z') { throw (Get-Text 'unexpected reply from the server: {0}' $last) }
    $size = [long]$Matches[1]
    $path = $Matches[2]
    if ($size -ne $ExpectedSize) { throw (Get-Text 'size mismatch: sent {0} bytes, server has {1}' $ExpectedSize $size) }
    if ($path -cnotmatch (Get-ReplyPathPattern $Dir $Hash $Ext $Class)) { throw (Get-Text 'unexpected path from the server: {0}' $path) }
    return $path
}

function Get-SshFailure {
    # What an ssh error says, for the advice and for whether trying again can help:
    # Kind auth (Methods: the methods the server still takes, as ssh lists them; KeyLogin:
    # a key would do; Typed: every method needs a person to type), toomany, hostkey,
    # network, or $null when it says none of these. Only ssh's own list of method names
    # counts, not a "Permission denied (...)" from a command on the server.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    # ssh exits 255 for its own errors; another status is the remote command's, whatever it said.
    if ($Text -cmatch '^ssh exited with (\d+):' -and $Matches[1] -cne '255') { return $null }
    if ($Text -cmatch 'Permission denied \(([a-z][a-z0-9@.-]*(,[a-z][a-z0-9@.-]*)*)\)\.') {
        $methods = @($Matches[1] -split ',')
        $typed = @($methods | Where-Object { $_ -cne 'password' -and $_ -cne 'keyboard-interactive' }).Count -eq 0
        return @{ Kind = 'auth'; Methods = $methods; KeyLogin = (@($methods) -ccontains 'publickey'); Typed = $typed }
    }
    if ($Text -cmatch 'Too many authentication failures') { return @{ Kind = 'toomany' } }
    # A shared connection (macOS wrapper mode) whose server allows one session per connection.
    if ($Text -cmatch 'Session open refused by peer|mux_client_request_session: session request failed') { return @{ Kind = 'muxrefused' } }
    if ($Text -cmatch 'Host key verification failed') { return @{ Kind = 'hostkey' } }
    if ($Text -cmatch 'Could not resolve hostname|Connection refused|Connection timed out|No route to host|Network is unreachable|Operation timed out') { return @{ Kind = 'network' } }
    return $null
}

function Test-FailureFinal {
    # Whether trying again in this session cannot help: the server takes only methods that a
    # person types (a password, a one-time code). Anything else may change while the session
    # runs: a key loaded with ssh-add, a renewed Kerberos ticket, a fixed known_hosts.
    param($Failure)
    if ($null -eq $Failure) { return $false }
    return (($Failure.Kind -ceq 'auth' -and $Failure.Typed) -or $Failure.Kind -ceq 'muxrefused')
}

function Get-LoginAdvice {
    # One line on why uploads to HostName cannot log in, or $null when the error says nothing
    # we can advise on. -Here: the key commands follow, so the pointer to --doctor is left out.
    # (loginAdvice in src/ssh-paste.js; tests/cases.json loginReports.)
    param($Failure, [string]$HostName, [switch]$Here)
    if ($null -eq $Failure) { return $null }
    if ($Failure.Kind -ceq 'auth' -and $Failure.KeyLogin) {
        if ($Here) { return (Get-Text '{0} did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add' $HostName) }
        return (Get-Text '{0} did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add; ssh-paste --doctor {0} shows how' $HostName)
    }
    if ($Failure.Kind -ceq 'auth' -and $Failure.Typed) {
        return (Get-Text '{0} wants a password or a one-time code ({1}), which uploads cannot type, so ssh-paste cannot upload to it' $HostName (@($Failure.Methods) -join ','))
    }
    if ($Failure.Kind -ceq 'toomany') {
        return (Get-Text '{0} closed the login after too many keys were tried: name the right key for it with IdentityFile and IdentitiesOnly yes in ~/.ssh/config' $HostName)
    }
    if ($Failure.Kind -ceq 'muxrefused') {
        return (Get-Text '{0} refused a second session on this connection, so uploads cannot share it; with a key, ssh-paste -S none {0} uploads over new connections' $HostName)
    }
    if ($Failure.Kind -ceq 'hostkey') {
        return (Get-Text 'ssh could not verify the host key of {0}: run ssh {0} to see why (a new host asks you to accept its key)' $HostName)
    }
    return $null
}

function Get-LoginReport {
    # The line --enable prints about a host: that uploads log in, or why not. ErrorText is
    # what ssh said when the check failed ($null when it logged in).
    param([string]$HostName, [string]$ErrorText)
    if ([string]::IsNullOrEmpty($ErrorText)) { return (Get-Text '{0}: uploads log in without a password' $HostName) }
    $advice = Get-LoginAdvice (Get-SshFailure $ErrorText) $HostName
    if ($advice) { return $advice }
    $first = @($ErrorText -split "`r?`n" | Where-Object { $_.Trim() })[0]
    return (Get-Text 'could not check the login to {0} now ({1}); ssh-paste --doctor {0} tests it' $HostName ($first.Trim()))
}

function Format-ShellWords {
    # Words as a command line to type again: plain when they hold only safe characters, else
    # in single quotes (an inner ' doubled for PowerShell, '\'' for zsh in formatShellWords).
    param([string[]]$Words)
    return (@(foreach ($w in @($Words)) {
                if ($w -cmatch '^[A-Za-z0-9._@%+=:,/-]+\z') { $w } else { "'" + $w.Replace("'", "''") + "'" }
            }) -join ' ')
}

function Get-EnableRefusal {
    # What --enable says instead of enabling HostName, whose uploads were refused (ssh mode
    # cannot type a password): the reason and, when a key would do, the commands that set one
    # up. $null when the check logged in or could not tell (network, host key, no answer):
    # then the host is enabled. (enableRefusal in src/ssh-paste.js.)
    param([string]$HostName, [string]$ErrorText)
    $f = Get-SshFailure $ErrorText
    if ($null -eq $f -or ($f.Kind -cne 'auth' -and $f.Kind -cne 'toomany')) { return $null }
    $advice = Get-LoginAdvice $f $HostName -Here
    if (-not $advice) { $advice = (Get-Text '{0} refused the login for uploads ({1})' $HostName (@($ErrorText -split "`r?`n" | Where-Object { $_.Trim() })[0].Trim())) }
    $lines = @($advice)
    if ($f.Kind -ceq 'auth' -and $f.KeyLogin) { $lines += @(Get-KeySetupLines $HostName) }
    return , $lines
}

function Get-KeySetupTarget {
    # The host for the key setup commands: [-p PORT] [USER@]HOST from the --doctor arguments,
    # which ssh and ssh-copy-id both read alike; Dropped says other options were left out.
    param($Parsed)
    $user = $null
    $port = $null
    $dropped = $false
    foreach ($o in @($Parsed.Options)) {
        if ($o.Flag -ceq 'l') { if ($null -eq $user) { $user = $o.Value } }
        elseif ($o.Flag -ceq 'p') { if ($null -eq $port) { $port = $o.Value } }
        else { $dropped = $true }
    }
    $target = $Parsed.Destination
    if ($null -ne $user -and -not $target.Contains('@') -and -not $target.StartsWith('ssh://')) { $target = $user + '@' + $target }
    if ($null -ne $port) { $target = '-p ' + $port + ' ' + $target }
    return @{ Target = $target; Dropped = $dropped }
}

function Get-KeySetupLines {
    # The commands that set up a key for HostArgs ([-p PORT] [USER@]HOST). Windows has no
    # ssh-copy-id, and its ssh-agent is off unless an administrator turns it on, so the key
    # needs no passphrase. (keySetupLines in src/ssh-paste.js is the macOS twin.)
    param([string]$HostArgs)
    return @(
        (Get-Text '  Set up a key (once; ssh asks your password one last time):'),
        '    ssh-keygen -t ed25519',
        ('    Get-Content $HOME\.ssh\id_ed25519.pub | ssh ' + $HostArgs + ' "' + $script:KeyInstallCommand + '"'),
        ('    ssh-paste --doctor ' + $HostArgs),
        (Get-Text '  ssh-keygen: press Enter at each question (no passphrase: Windows'' ssh-agent is off'),
        (Get-Text '  unless an administrator turns it on); if the key file exists already, answer n.'),
        (Get-Text '  If you log in with ssh -i KEY, or ~/.ssh/config names an IdentityFile for this host,'),
        (Get-Text '  use that key instead, and name it with IdentityFile in the Host entry.'))
}

function Get-ReplyPathPattern {
    # The paths the server may answer for this image: <folder>/ssh-paste-<class><hash>[-<uid>].<ext>,
    # in exactly the --dir folder.
    param([string]$Dir, [string]$Hash, [string]$Ext, [string]$Class = '')
    return ('^' + [regex]::Escape($Dir) + '/ssh-paste-' + [regex]::Escape($Class) + $Hash + '(-[0-9]+)?\.' + $Ext + '\z')
}

function Get-KeepClass {
    # The part of the file name that says which --keep made it: empty for the default
    # (the names of every earlier release), else k<keep>- such as k7d- or knever-.
    param([string]$Keep)
    if ([string]::IsNullOrEmpty($Keep) -or $Keep -ceq $script:DefaultKeep) { return '' }
    return ('k' + $Keep + '-')
}

function ConvertTo-KeepMinutes {
    # --keep: 30m, 2h, 7d, or never (0: the server keeps every image). From 10 minutes
    # (a path must stay good for a while after the paste; the cache, half of it, then
    # outlasts the longest upload, 5 minutes) to 3650 days.
    param([string]$Keep)
    if ($Keep -ceq 'never') { return 0 }
    if ($Keep -cnotmatch '^([1-9][0-9]{0,6})([mhd])\z') { throw (Get-Text '--keep takes a time like 30m, 2h or 7d, or never: {0}' $Keep) }
    $n = [long]$Matches[1]
    $minutes = $n
    if ($Matches[2] -ceq 'h') { $minutes = $n * 60 } elseif ($Matches[2] -ceq 'd') { $minutes = $n * 1440 }
    if ($minutes -lt 10) { throw (Get-Text '--keep is at least 10m: {0}' $Keep) }
    if ($minutes -gt 5256000) { throw (Get-Text '--keep is at most 3650d: {0}' $Keep) }
    return [int]$minutes
}

function Test-ServerDirectory {
    # --dir: a folder on the server, absolute or under ~ (the home folder there): names of
    # letters, digits and . _ - only, none of them . or .., no // and no / at the end.
    param([string]$Dir)
    if ([string]::IsNullOrEmpty($Dir) -or $Dir.Length -gt 200) { return $false }
    return ($Dir -cmatch '^(~|~?(/(?!\.\.?(/|\z))[A-Za-z0-9._-]+)+)\z')
}

function Read-PasteSettings {
    # The leading --keep TIME and --dir DIR (each at most once) of --enable, wrapper mode and
    # --proxy: Keep and Dir ($null when not given) and the arguments after them.
    param([string[]]$Argv)
    $r = @{ Keep = $null; Dir = $null; Rest = @() }
    $a = @($Argv)
    $i = 0
    while ($i -lt $a.Count -and ($a[$i] -ceq '--keep' -or $a[$i] -ceq '--dir')) {
        $name = $a[$i]
        if ($i + 1 -ge $a.Count) { throw (Get-Text '{0} needs a value' $name) }
        $value = [string]$a[$i + 1]
        if ($name -ceq '--keep') {
            if ($null -ne $r.Keep) { throw (Get-Text '--keep is given twice') }
            [void](ConvertTo-KeepMinutes $value)
            $r.Keep = $value
        } else {
            if ($null -ne $r.Dir) { throw (Get-Text '--dir is given twice') }
            if ($value.Length -gt 1) { $value = $value.TrimEnd('/') }
            if ($value -ceq '') { $value = '/' }
            if (-not (Test-ServerDirectory $value)) {
                throw (Get-Text '--dir takes a folder on the server, /... or ~/... (quote ~ so that your shell keeps it), with letters, digits and . _ - / only: {0}' $value)
            }
            $r.Dir = $value
        }
        $i += 2
    }
    if ($i -lt $a.Count) { $r.Rest = @($a[$i..($a.Count - 1)]) }
    return $r
}

function Get-ProxySettings {
    # --keep and --dir of a ProxyCommand line that --enable wrote (the defaults when absent).
    param([string]$ProxyCommand)
    # Only the words after --proxy count: a path before it may hold anything.
    $s = @{ Keep = $script:DefaultKeep; Dir = $script:DefaultDir }
    $text = [string]$ProxyCommand
    $at = $text.LastIndexOf(' --proxy ')
    if ($at -lt 0) { return $s }
    $tail = $text.Substring($at)
    if ($tail -cmatch " --keep '?([^' ]+)'?") { $s.Keep = $Matches[1] }
    if ($tail -cmatch " --dir '?([^' ]+)'?") { $s.Dir = $Matches[1] }
    return $s
}

function Format-PasteSettings {
    param($Settings)
    if ($Settings.Keep -ceq 'never') { return (Get-Text 'images in {0} on the server, never deleted' $Settings.Dir) }
    return (Get-Text 'images in {0} on the server, kept {1}' $Settings.Dir $Settings.Keep)
}

function Test-HostAlias {
    # A Host alias as written in ~/.ssh/config: no user@, no option-like dash.
    param([string]$Name)
    return ($Name -cmatch '^[A-Za-z0-9_\[][A-Za-z0-9._:\[\]-]*\z')
}

function Get-ProxyCommandLine {
    # --keep and --dir are written only when they are not the defaults, so a block from an
    # older release reads the same. Their values have no space, quote or %.
    param([string]$ScriptPath, [string]$Keep, [string]$Dir)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Win32-OpenSSH runs ProxyCommand without a shell: the text up to the first
    # ".exe " is the program and the rest is passed through. % starts a token.
    $path = $ScriptPath.Replace('%', '%%')
    $exe = $powershell.Replace('%', '%%')
    $line = ('{0} -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" --proxy %h %p %n' -f $exe, $path)
    if (-not [string]::IsNullOrEmpty($Keep) -and $Keep -cne $script:DefaultKeep) { $line += ' --keep ' + $Keep }
    if (-not [string]::IsNullOrEmpty($Dir) -and $Dir -cne $script:DefaultDir) { $line += ' --dir ' + $Dir }
    return $line
}

function Get-ManagedBlock {
    # Our block: its groups (each a Host line with its ProxyCommand; hosts with the same
    # --keep and --dir share one), all their hosts, and the "created the file" flag.
    param([string]$ConfigText)
    $info = @{ Hosts = @(); Groups = @(); ProxyCommand = $null; CreatedFile = $false; Present = $false }
    if ([string]::IsNullOrEmpty($ConfigText)) { return $info }
    $groups = New-Object System.Collections.ArrayList
    $current = $null
    $inBlock = $false
    foreach ($line in ($ConfigText -split "`r?`n")) {
        if ($line -ceq $script:BlockBegin) { $inBlock = $true; $info.Present = $true; continue }
        if ($line -ceq $script:BlockEnd) { $inBlock = $false; continue }
        if (-not $inBlock) { continue }
        if ($line -ceq $script:BlockCreatedFile) { $info.CreatedFile = $true; continue }
        if ($line -match '^Host\s+(.+)$') {
            $hosts = @($Matches[1].Trim() -split '\s+' | Where-Object { $_ -ne '*' })
            $current = $null
            if ($hosts.Count -gt 0) {
                $current = @{ Hosts = $hosts; ProxyCommand = $null }
                [void]$groups.Add($current)
            }
            continue
        }
        if ($line -match '^\s+ProxyCommand\s+(.+)$' -and $null -ne $current -and $null -eq $current.ProxyCommand) { $current.ProxyCommand = $Matches[1].Trim() }
    }
    $info.Groups = @($groups)
    $info.Hosts = @($groups | ForEach-Object { $_.Hosts })
    if ($groups.Count -gt 0) { $info.ProxyCommand = $groups[0].ProxyCommand }
    return $info
}

function Get-SettingsGroups {
    # Hosts (in order) with the same settings share one Host line and ProxyCommand.
    param($Want, [string]$ScriptPath)
    $groups = New-Object System.Collections.ArrayList
    $index = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    foreach ($h in @($Want.psbase.Keys)) {
        $s = $Want[$h]
        $key = $s.Keep + ' ' + $s.Dir
        if (-not $index.ContainsKey($key)) {
            $index[$key] = $groups.Count
            [void]$groups.Add(@{ Hosts = (New-Object System.Collections.ArrayList); ProxyCommand = (Get-ProxyCommandLine $ScriptPath $s.Keep $s.Dir) })
        }
        [void]$groups[$index[$key]].Hosts.Add($h)
    }
    return @($groups)
}

function Set-ManagedBlock {
    # Returns the config text with our block removed and, if a group has hosts, a
    # fresh block put first (ssh uses the first value it finds): one Host line and
    # ProxyCommand per group. The trailing "Host *" keeps any global options that
    # follow in effect for every host. Hosts and ProxyCommand make one group.
    param([string]$ConfigText, [string[]]$Hosts, [string]$ProxyCommand, [switch]$CreatedFile, $Groups)
    if ($null -eq $Groups) { $Groups = @(@{ Hosts = @($Hosts); ProxyCommand = $ProxyCommand }) }
    if ($null -eq $ConfigText) { $ConfigText = '' }
    $newline = "`n"
    if ($ConfigText.Contains("`r`n")) { $newline = "`r`n" }
    $kept = New-Object System.Collections.ArrayList
    $inBlock = $false
    $lines = @()
    if ($ConfigText.Length -gt 0) { $lines = $ConfigText -split "`r?`n" }
    foreach ($line in $lines) {
        if ($line -ceq $script:BlockBegin) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -ceq $script:BlockEnd) { $inBlock = $false }
            continue
        }
        [void]$kept.Add($line)
    }
    if ($inBlock) { throw (Get-Text 'the ssh-paste block in the ssh config has no end marker; fix it by hand') }
    $rest = ($kept -join $newline)
    $used = @(@($Groups) | Where-Object { $null -ne $_ -and @($_.Hosts).Count -gt 0 })
    if ($used.Count -eq 0) { return $rest }
    $blockLines = New-Object System.Collections.ArrayList
    [void]$blockLines.Add($script:BlockBegin)
    if ($CreatedFile) { [void]$blockLines.Add($script:BlockCreatedFile) }
    foreach ($g in $used) {
        [void]$blockLines.Add('Host ' + (@($g.Hosts) -join ' '))
        [void]$blockLines.Add('    ProxyCommand ' + $g.ProxyCommand)
        [void]$blockLines.Add('    ProxyUseFdpass no')
    }
    [void]$blockLines.Add('Host *')
    [void]$blockLines.Add($script:BlockEnd)
    $block = ($blockLines -join $newline)
    if ($rest.Length -eq 0) { return $block + $newline }
    return $block + $newline + $rest
}

function ConvertFrom-Dib {
    # CF_DIB bytes -> a .bmp in memory (adds the 14-byte file header) -> PNG.
    param([byte[]]$Dib)
    if ($null -eq $Dib -or $Dib.Length -lt 40) { return $null }
    $headerSize = [BitConverter]::ToInt32($Dib, 0)
    $bitCount = [BitConverter]::ToInt16($Dib, 14)
    $compression = [BitConverter]::ToInt32($Dib, 16)
    $colorsUsed = [BitConverter]::ToInt32($Dib, 32)
    $masks = 0
    if ($headerSize -eq 40 -and $compression -eq 3) { $masks = 12 }
    if ($headerSize -eq 40 -and $compression -eq 6) { $masks = 16 }
    $colors = $colorsUsed
    if ($colors -eq 0 -and $bitCount -le 8) { $colors = 1 -shl $bitCount }
    $offset = 14 + $headerSize + $masks + 4 * $colors
    $bmp = New-Object byte[] (14 + $Dib.Length)
    $bmp[0] = 0x42; $bmp[1] = 0x4D
    [BitConverter]::GetBytes([int]$bmp.Length).CopyTo($bmp, 2)
    [BitConverter]::GetBytes([int]$offset).CopyTo($bmp, 10)
    [Array]::Copy($Dib, 0, $bmp, 14, $Dib.Length)
    $in = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, $bmp)
    try {
        $image = [System.Drawing.Image]::FromStream($in)
        try {
            $out = New-Object System.IO.MemoryStream
            $image.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
            return , $out.ToArray()
        } finally { $image.Dispose() }
    } finally { $in.Dispose() }
}

# ---------------------------------------------------------------------------
# Windows integration
# ---------------------------------------------------------------------------

$script:NativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class SshPasteNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

    // Clears HANDLE_FLAG_INHERIT, so programs we start do not get a copy of
    // this handle. False when the handle cannot be changed.
    public static bool KeepToSelf(IntPtr handle) {
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;
        return SetHandleInformation(handle, 1, 0);
    }

    public static IntPtr StandardHandle(int which) { return GetStdHandle(which); }
    [StructLayout(LayoutKind.Sequential)] struct IoStatusBlock { public IntPtr Status; public IntPtr Information; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationFile(IntPtr handle, out IoStatusBlock io, out uint info, uint length, int infoClass);

    // True when the handle was opened for overlapped I/O (FileModeInformation has
    // neither FILE_SYNCHRONOUS_IO_ALERT nor _NONALERT). Win32-OpenSSH gives its
    // ProxyCommand such pipes; synchronous ReadFile on them can report a pending
    // read as finished with 0 bytes, which looks like end of input.
    public static bool IsOverlapped(IntPtr handle) {
        IoStatusBlock io; uint mode;
        if (NtQueryInformationFile(handle, out io, out mode, 4, 16) != 0) return false;
        return (mode & 0x30) == 0;
    }

    // stdin (-10) or stdout (-11) as an unbuffered stream that uses overlapped
    // I/O when the handle needs it.
    public static System.IO.Stream OpenStandardStream(int which, bool write, out bool overlapped) {
        IntPtr handle = GetStdHandle(which);
        overlapped = IsOverlapped(handle);
        Microsoft.Win32.SafeHandles.SafeFileHandle safe = new Microsoft.Win32.SafeHandles.SafeFileHandle(handle, false);
        return new System.IO.FileStream(safe, write ? System.IO.FileAccess.Write : System.IO.FileAccess.Read, 1, overlapped);
    }
    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);

    public sealed class Snapshot {
        public uint Sequence;
        public bool HasPng, HasDib, HasText, HasFiles;
        public byte[] Png, Dib, Marker, Text, Drop;
    }

    // One consistent view of the clipboard: availability, the bytes we need and
    // the sequence number, all taken while the clipboard is open.
    public static Snapshot ReadSnapshot(uint pngFormat, uint markerFormat, long maxBytes) {
        if (!OpenClipboard(IntPtr.Zero)) throw new InvalidOperationException("the clipboard is busy");
        try {
            Snapshot s = new Snapshot();
            s.HasPng = IsClipboardFormatAvailable(pngFormat);
            s.HasDib = IsClipboardFormatAvailable(8);
            s.HasText = IsClipboardFormatAvailable(13) || IsClipboardFormatAvailable(1);
            s.HasFiles = IsClipboardFormatAvailable(15);
            if (s.HasPng || s.HasDib || s.HasFiles) {
                if (s.HasFiles) s.Drop = Copy(15, 1 << 20);
                if (s.HasPng) s.Png = Copy(pngFormat, maxBytes);
                if (s.Png == null && s.HasDib) s.Dib = Copy(8, maxBytes);
                s.Marker = Copy(markerFormat, 4096);
            }
            s.Sequence = GetClipboardSequenceNumber();
            return s;
        } finally { CloseClipboard(); }
    }

    static byte[] Copy(uint format, long maxBytes) {
        IntPtr handle = GetClipboardData(format);
        if (handle == IntPtr.Zero) return null;
        long size = (long)GlobalSize(handle).ToUInt64();
        if (size <= 0 || size > maxBytes) return null;
        IntPtr data = GlobalLock(handle);
        if (data == IntPtr.Zero) return null;
        try {
            byte[] bytes = new byte[size];
            Marshal.Copy(data, bytes, 0, (int)size);
            return bytes;
        } finally { GlobalUnlock(handle); }
    }

    // Raw bytes of each requested format, read in one OpenClipboard session.
    // No managed deserialization: other programs' data is only ever copied.
    public static byte[][] ReadFormats(uint[] formats, long maxBytes) {
        byte[][] result = new byte[formats.Length][];
        if (!OpenClipboard(IntPtr.Zero)) throw new InvalidOperationException("the clipboard is busy");
        try {
            for (int i = 0; i < formats.Length; i++) {
                if (formats[i] == 0) continue;
                IntPtr handle = GetClipboardData(formats[i]);
                if (handle == IntPtr.Zero) continue;
                long size = (long)GlobalSize(handle).ToUInt64();
                if (size <= 0 || size > maxBytes) continue;
                IntPtr data = GlobalLock(handle);
                if (data == IntPtr.Zero) continue;
                try {
                    byte[] bytes = new byte[size];
                    Marshal.Copy(data, bytes, 0, (int)size);
                    result[i] = bytes;
                } finally { GlobalUnlock(handle); }
            }
        } finally { CloseClipboard(); }
        return result;
    }
}

// Owns the clipboard entries ssh-paste writes. Image data, file lists, the
// marker and the history flags are put on the clipboard at once. The text (the
// remote path) can be promised instead (Win32 delayed rendering): Windows asks
// for it only when something pastes, and the paste then waits until the upload
// has finished, so a pasted path always names a file that exists.
public sealed class PendingClipboard : IDisposable {
    const int WM_RENDERFORMAT = 0x0305, WM_RENDERALLFORMATS = 0x0306, WM_DESTROYCLIPBOARD = 0x0307;
    const int WM_CLOSE = 0x0010, WM_APP_PUBLISH = 0x8001;
    const uint CF_DIB = 8, CF_UNICODETEXT = 13, CF_HDROP = 15, GMEM_MOVEABLE = 0x0002;
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);

    delegate IntPtr WndProc(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS { public uint style; public WndProc lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public int message; public IntPtr wParam, lParam; public uint time; public int x, y; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClass(ref WNDCLASS c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, int m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

    // One entry to put on the clipboard.
    public sealed class Entry {
        public byte[] Png;          // image entry: the PNG bytes
        public byte[] Dib;          // image entry: the same image as CF_DIB, made by the caller
        public string[] Files;      // file entry: the copied files (CF_HDROP)
        public byte[] Marker;       // ssh-paste's marker: owner window, session, remote path
        public string Text;         // remote path, written at once
        public bool PromiseText;    // write the text later, when a paste asks for it
        public long Basis;          // the clipboard sequence number the caller read; Write refuses when it moved
    }

    readonly Thread thread;
    readonly ManualResetEvent started = new ManualResetEvent(false);
    readonly WndProc proc;
    IntPtr window;
    Entry publishing;
    bool publishResult;
    uint publishSequence;

    // State of the promised text: set by Resolve or Fail from the watcher thread.
    readonly object gate = new object();
    ManualResetEvent textReady = new ManualResetEvent(false);
    string promisedText;
    bool promiseOpen;
    long promiseOwner;      // the terminal window the entry was written for (from the marker)
    string entryText;       // the text of this window's entry
    bool textWritten;       // that text was written at once, not promised

    public int PromiseWaitMilliseconds = 30000;
    public string LastError;
    public uint LastSequence { get { return publishSequence; } }

    public PendingClipboard() {
        proc = WindowProc;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        started.WaitOne(10000);
        if (window == IntPtr.Zero) throw new InvalidOperationException("could not create the clipboard window: " + LastError);
    }

    void Run() {
        try {
            WNDCLASS c = new WNDCLASS();
            c.lpfnWndProc = proc;
            c.hInstance = GetModuleHandle(null);
            c.lpszClassName = "SshPastePendingClipboard" + Guid.NewGuid().ToString("N");
            if (RegisterClass(ref c) == 0) { LastError = "RegisterClass failed"; started.Set(); return; }
            window = CreateWindowEx(0, c.lpszClassName, "ssh-paste", 0, 0, 0, 0, 0, HWND_MESSAGE, IntPtr.Zero, c.hInstance, IntPtr.Zero);
            if (window == IntPtr.Zero) LastError = "CreateWindowEx failed";
        } catch (Exception e) { LastError = e.Message; }
        started.Set();
        if (window == IntPtr.Zero) return;
        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref m); DispatchMessage(ref m); }
    }

    // Puts an entry on the clipboard from the window's thread. Returns the
    // clipboard sequence number after the write, or 0 when it failed.
    public uint Publish(Entry entry) {
        lock (gate) {
            if (promiseOpen) { promisedText = null; textReady.Set(); promiseOpen = false; }   // an older promise can no longer be kept
        }
        publishing = entry;
        publishResult = false;
        IntPtr result;
        IntPtr sent = SendMessageTimeout(window, WM_APP_PUBLISH, IntPtr.Zero, IntPtr.Zero, 0x0002 /* SMTO_ABORTIFHUNG */, 10000, out result);
        if (sent == IntPtr.Zero || !publishResult) return 0;
        return publishSequence;
    }

    // The upload finished: a paste waiting for the text gets this path.
    public void Resolve(string text) { lock (gate) { promisedText = text; textReady.Set(); } }

    // The upload failed: a waiting paste gets nothing.
    public void Fail() { lock (gate) { promisedText = null; textReady.Set(); } }

    public bool IsOwner { get { return GetClipboardOwner() == window && window != IntPtr.Zero; } }

    // True when the clipboard holds this window's entry with this text, and a
    // paste of it gets the text: written at once, or promised and not failed.
    public bool CanAnswer(string text) {
        lock (gate) {
            if (!IsOwner || entryText != text) return false;
            if (textWritten) return true;
            return promiseOpen && !(textReady.WaitOne(0) && promisedText == null);
        }
    }

    IntPtr WindowProc(IntPtr h, int msg, IntPtr w, IntPtr l) {
        switch (msg) {
            case WM_APP_PUBLISH:
                publishResult = Write(publishing);
                return IntPtr.Zero;
            case WM_RENDERFORMAT:
                if ((uint)w.ToInt64() == CF_UNICODETEXT) RenderText(false);
                return IntPtr.Zero;
            case WM_RENDERALLFORMATS:
                if (OpenClipboard(h)) {
                    if (GetClipboardOwner() == h) RenderText(true);
                    CloseClipboard();
                }
                return IntPtr.Zero;
            case WM_DESTROYCLIPBOARD:
                lock (gate) { if (promiseOpen) { promisedText = null; textReady.Set(); promiseOpen = false; } }
                return IntPtr.Zero;
            case WM_CLOSE:
                DestroyWindow(h);
                PostQuitMessage(0);
                return IntPtr.Zero;
        }
        return DefWindowProc(h, msg, w, l);
    }

    // Answers a paste that asks for the promised text. A paste during the upload
    // waits here; when the upload fails or takes too long it gets nothing.
    void RenderText(bool closing) {
        ManualResetEvent ready;
        long owner;
        lock (gate) { if (!promiseOpen) return; ready = textReady; owner = promiseOwner; }
        // Only the terminal window the path was written for gets it: a paste in
        // another window must not get a path on this session's server.
        if (!closing && GetForegroundWindow().ToInt64() != owner) return;
        ready.WaitOne(closing ? 0 : PromiseWaitMilliseconds);
        string text;
        lock (gate) { text = promisedText; }
        if (!string.IsNullOrEmpty(text)) SetData(CF_UNICODETEXT, Encoding.Unicode.GetBytes(text + "\0"));
    }

    bool Write(Entry e) {
        bool opened = false;
        for (int i = 0; i < 20 && !opened; i++) { opened = OpenClipboard(window); if (!opened) Thread.Sleep(25); }
        if (!opened) { LastError = "the clipboard is busy"; return false; }
        try {
            // Write only over what the caller read: a copy the user made since then stays.
            if ((long)GetClipboardSequenceNumber() != e.Basis) { LastError = "the clipboard changed since it was read"; return false; }
            // EmptyClipboard tells the old owner (often this window) that its entry
            // is gone, which withdraws the old promise; only then is the new one set.
            if (!EmptyClipboard()) { LastError = "EmptyClipboard failed"; return false; }
            lock (gate) {
                textReady = new ManualResetEvent(false);
                promisedText = null;
                promiseOpen = e.PromiseText;
                promiseOwner = (e.Marker != null && e.Marker.Length >= 8) ? BitConverter.ToInt64(e.Marker, 0) : 0;
                entryText = e.Text;
                textWritten = !e.PromiseText && !string.IsNullOrEmpty(e.Text);
            }
            if (e.Files != null && e.Files.Length > 0) {
                SetData(CF_HDROP, DropFiles(e.Files));
            } else if (e.Png != null) {
                SetData(RegisterClipboardFormat("PNG"), e.Png);
                if (e.Dib != null) SetData(CF_DIB, e.Dib);
            }
            if (e.Marker != null) SetData(RegisterClipboardFormat("SshPaste.Owner"), e.Marker);
            SetData(RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing"), BitConverter.GetBytes(1));
            SetData(RegisterClipboardFormat("CanIncludeInClipboardHistory"), BitConverter.GetBytes(0));
            SetData(RegisterClipboardFormat("CanUploadToCloudClipboard"), BitConverter.GetBytes(0));
            if (e.PromiseText) SetClipboardData(CF_UNICODETEXT, IntPtr.Zero);
            else if (!string.IsNullOrEmpty(e.Text)) SetData(CF_UNICODETEXT, Encoding.Unicode.GetBytes(e.Text + "\0"));
            return true;
        } finally {
            CloseClipboard();
            publishSequence = GetClipboardSequenceNumber();
        }
    }

    static void SetData(uint format, byte[] bytes) {
        IntPtr h = GlobalAlloc(GMEM_MOVEABLE, new UIntPtr((uint)bytes.Length));
        if (h == IntPtr.Zero) return;
        IntPtr p = GlobalLock(h);
        if (p == IntPtr.Zero) { GlobalFree(h); return; }
        try { Marshal.Copy(bytes, 0, p, bytes.Length); } finally { GlobalUnlock(h); }
        if (SetClipboardData(format, h) == IntPtr.Zero) GlobalFree(h);   // on success the clipboard owns h
    }

    // DROPFILES header (20 bytes), then NUL-separated UTF-16 paths and a final NUL.
    public static byte[] DropFiles(string[] files) {
        byte[] names = Encoding.Unicode.GetBytes(string.Join("\0", files) + "\0\0");
        byte[] all = new byte[20 + names.Length];
        BitConverter.GetBytes(20).CopyTo(all, 0);
        BitConverter.GetBytes(1).CopyTo(all, 16);   // fWide
        names.CopyTo(all, 20);
        return all;
    }

    public void Dispose() {
        if (window != IntPtr.Zero) { PostMessage(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); thread.Join(5000); window = IntPtr.Zero; }
    }
}
'@

function Initialize-Native {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw (Get-Text 'PowerShell runs in {0} mode here (AppLocker or App Control policy)' $ExecutionContext.SessionState.LanguageMode)
    }
    Add-Type -AssemblyName System.Drawing
    if (-not ('SshPasteNative' -as [type])) { Add-Type -TypeDefinition $script:NativeSource }
    $script:FormatPng = [SshPasteNative]::RegisterClipboardFormat('PNG')
    $script:FormatMarker = [SshPasteNative]::RegisterClipboardFormat($script:MarkerFormat)
    if ($null -eq $script:Clipboard) { $script:Clipboard = New-Object PendingClipboard }
}

function Complete-ClipboardPromise {
    # Gives a paste that waits for the promised text the path, or nothing.
    param([string]$Text)
    if ($null -eq $script:Clipboard) { return }
    if ([string]::IsNullOrEmpty($Text)) { $script:Clipboard.Fail() } else { $script:Clipboard.Resolve($Text) }
}

function Test-ClipboardAnswers {
    # True when the clipboard holds this session's entry and a paste of it gets
    # $Text. False when its promise failed or was withdrawn: the entry must be
    # written again.
    param([string]$Text)
    return ($null -ne $script:Clipboard -and $script:Clipboard.CanAnswer($Text))
}

function Close-Clipboard {
    # Ends the clipboard window. A text still promised is then given if ready,
    # or dropped; the image on the clipboard stays.
    if ($null -ne $script:Clipboard) { try { $script:Clipboard.Dispose() } catch { }; $script:Clipboard = $null }
}

function Get-ProcessInfo {
    param([int]$ProcessId)
    return Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
}

function Get-HostMatcher {
    # Which foreground window counts as "this terminal". Windows Terminal owns the
    # console's pseudo window; classic consoles have a visible window of their
    # own; other terminals are matched by process ancestry.
    $console = [SshPasteNative]::GetConsoleWindow()
    if ($console -ne [IntPtr]::Zero) {
        $owner = [SshPasteNative]::GetWindow($console, 4)   # GW_OWNER
        if ($owner -ne [IntPtr]::Zero) { return @{ Kind = 'Windows Terminal'; Window = $owner; Pids = $null } }
        if ([SshPasteNative]::IsWindowVisible($console)) { return @{ Kind = 'console window'; Window = $console; Pids = $null } }
    }
    $skip = @('explorer', 'svchost', 'services', 'wininit', 'winlogon', 'sihost', 'runtimebroker',
        'powershell', 'pwsh', 'cmd', 'conhost', 'openconsole', 'ssh', 'bash', 'sh', 'wsl')
    $pids = New-Object 'System.Collections.Generic.HashSet[int]'
    $current = $PID
    for ($n = 0; $n -lt 16; $n++) {
        $p = Get-ProcessInfo $current
        if ($null -eq $p) { break }
        $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$p.Name).ToLowerInvariant()
        if ($name -eq 'explorer') { break }
        if ($skip -notcontains $name) { [void]$pids.Add([int]$p.ProcessId) }
        $current = [int]$p.ParentProcessId
        if ($current -le 4) { break }
    }
    return @{ Kind = 'terminal process'; Window = [IntPtr]::Zero; Pids = $pids }
}

function Test-HostForeground {
    param($Matcher, [IntPtr]$Foreground)
    if ($Foreground -eq [IntPtr]::Zero) { return $false }
    if ($Matcher.Window -ne [IntPtr]::Zero) {
        if ($Foreground -eq $Matcher.Window) { return $true }
        return ([SshPasteNative]::GetAncestor($Foreground, 3) -eq $Matcher.Window)   # GA_ROOTOWNER
    }
    [uint32]$owner = 0
    [void][SshPasteNative]::GetWindowThreadProcessId($Foreground, [ref]$owner)
    return $Matcher.Pids.Contains([int]$owner)
}

function Read-ClipboardImage {
    # One snapshot of the clipboard. Png is $null when it holds no image. Throws
    # when the clipboard is busy; the caller retries on the next tick.
    $snap = [SshPasteNative]::ReadSnapshot($script:FormatPng, $script:FormatMarker, [long]$script:MaxImageBytes)
    $state = @{ Seq = [long]$snap.Sequence; Png = $null; Hash = $null; HasText = $snap.HasText; HasFiles = $snap.HasFiles
        Owner = $null; Token = $null; Text = $null; Files = $null; Items = $null }
    if ($null -ne $snap.Marker -and $snap.Marker.Length -ge 16) {
        $state.Owner = [BitConverter]::ToInt64($snap.Marker, 0)
        $state.Token = [BitConverter]::ToInt64($snap.Marker, 8)
    }
    if ($null -ne $snap.Marker -and $snap.Marker.Length -gt 16 -and $snap.HasText) {
        # Our entries carry their text in the marker, so we never ask for the
        # text itself: it may be promised and would make us wait on ourselves.
        $state.Text = ([System.Text.Encoding]::Unicode.GetString($snap.Marker, 16, $snap.Marker.Length - 16)).Split([char]0)[0]
    }
    if ($null -ne $snap.Drop) {
        # Image files copied in Explorer: upload the files themselves.
        $items = Read-ImageFiles (ConvertFrom-DropFiles $snap.Drop)
        if ($null -ne $items) {
            $state.Files = @($items | ForEach-Object { $_.Path })
            $state.Items = $items
            $state.Hash = Get-ImageHash ([System.Text.Encoding]::ASCII.GetBytes((@($items | ForEach-Object { $_.Hash }) -join ' ')))
        }
        return $state
    }
    $png = $null
    if ($null -ne $snap.Png) { $png = Get-TrimmedPng $snap.Png }
    $dib = $snap.Dib
    if ($null -eq $png -and $null -eq $dib -and $snap.HasDib) {
        $dib = ([SshPasteNative]::ReadFormats([uint32[]]@(8), [long]$script:MaxImageBytes))[0]
    }
    if ($null -eq $png -and $null -ne $dib) { $png = ConvertFrom-Dib $dib }
    if ($null -eq $png -or $png.Length -eq 0) { return $state }
    $state.Png = $png
    $state.Hash = Get-ImageHash $png
    return $state
}

function Read-ImageFiles {
    # Items to upload when every path is an image file of an accepted type and
    # size; $null otherwise (then the copied files are left to Windows Terminal).
    param([string[]]$Paths)
    if ($null -eq $Paths -or $Paths.Count -eq 0 -or $Paths.Count -gt $script:MaxCopiedFiles) { return $null }
    $items = New-Object System.Collections.ArrayList
    foreach ($path in $Paths) {
        $ext = Get-ImageFileExtension $path
        if ($null -eq $ext) { return $null }
        $info = New-Object System.IO.FileInfo -ArgumentList $path
        if (-not $info.Exists -or $info.Length -eq 0 -or $info.Length -gt $script:MaxImageBytes) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        [void]$items.Add(@{ Path = $path; Bytes = $bytes; Hash = (Get-ImageHash $bytes); Ext = $ext })
    }
    return , @($items)
}

function New-DwordStream {
    param([int]$Value)
    return (New-Object -TypeName System.IO.MemoryStream -ArgumentList (, [BitConverter]::GetBytes($Value)))
}

function New-DibBytes {
    # The PNG as a bottom-up 32-bit device-independent bitmap (CF_DIB), for the
    # apps that paste a bitmap; Windows makes CF_BITMAP and CF_DIBV5 from it.
    param([byte[]]$Png)
    $source = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, $Png)
    try {
        $image = New-Object System.Drawing.Bitmap -ArgumentList $source
        try {
            $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $image.Width, $image.Height
            $bitmap = $image.Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $w = $bitmap.Width; $h = $bitmap.Height; $stride = $w * 4
                $dib = New-Object byte[] (40 + $stride * $h)
                [BitConverter]::GetBytes([int]40).CopyTo($dib, 0)
                [BitConverter]::GetBytes([int]$w).CopyTo($dib, 4)
                [BitConverter]::GetBytes([int]$h).CopyTo($dib, 8)
                [BitConverter]::GetBytes([int16]1).CopyTo($dib, 12)
                [BitConverter]::GetBytes([int16]32).CopyTo($dib, 14)
                [BitConverter]::GetBytes([int]($stride * $h)).CopyTo($dib, 20)
                $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                try {
                    for ($y = 0; $y -lt $h; $y++) {
                        $row = [IntPtr]($data.Scan0.ToInt64() + [long]$y * $data.Stride)
                        [System.Runtime.InteropServices.Marshal]::Copy($row, $dib, 40 + ($h - 1 - $y) * $stride, $stride)
                    }
                } finally { $bitmap.UnlockBits($data) }
                return , $dib
            } finally { $bitmap.Dispose() }
        } finally { $image.Dispose() }
    } finally { $source.Dispose() }
}

function Set-SshPasteClipboard {
    # Puts our entry on the clipboard: the image (PNG and CF_DIB) or the copied
    # file list, a marker with the owner window, the session and the text, the
    # documented flags that keep it out of Win+V history and cloud sync, and the
    # text. With -Promise the text is only promised: a paste waits for it until
    # Resolve or Fail is called on $script:Clipboard. -Basis is the clipboard
    # sequence number the caller decided on; if the clipboard changed since, the
    # write is refused (it throws) and the newer copy stays.
    param([byte[]]$Png, [string]$Text, [long]$Owner, [long]$Token, [string[]]$Files, [switch]$Promise,
        [Parameter(Mandatory)][long]$Basis)
    $textBytes = [System.Text.Encoding]::Unicode.GetBytes([string]$Text)
    $marker = New-Object byte[] (16 + $textBytes.Length)
    [BitConverter]::GetBytes($Owner).CopyTo($marker, 0)
    [BitConverter]::GetBytes($Token).CopyTo($marker, 8)
    $textBytes.CopyTo($marker, 16)
    $entry = New-Object PendingClipboard+Entry
    $entry.Marker = $marker
    $entry.Text = $Text
    $entry.PromiseText = [bool]$Promise
    $entry.Basis = $Basis
    if ($null -ne $Files -and $Files.Count -gt 0) {
        $entry.Files = $Files
    } else {
        $entry.Png = $Png
        $entry.Dib = New-DibBytes $Png
    }
    if ($script:Clipboard.Publish($entry) -eq 0) { throw (Get-Text 'could not write the clipboard: {0}' $script:Clipboard.LastError) }
}

function New-ChildStartInfo {
    # The one way this script starts a program: no shell, and an environment
    # without Win32-OpenSSH's private variables. -Redirect gives the child its
    # own stdin, stdout and stderr pipes and no console window; without it the
    # child shares our console (the interactive ssh of wrapper mode).
    # tests/lint.ps1 fails when ProcessStartInfo is created anywhere else.
    param([string]$FilePath, [string[]]$Arguments, [switch]$Redirect, [string[]]$RemoveVariables)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    Set-ProcessArguments $psi $Arguments
    $psi.UseShellExecute = $false
    foreach ($key in @($psi.EnvironmentVariables.Keys)) {
        if ([string]$key -and ([string]$key).StartsWith($script:InheritedSshPrefix, [StringComparison]::OrdinalIgnoreCase)) { $psi.EnvironmentVariables.Remove([string]$key) }
    }
    foreach ($name in @($RemoveVariables)) { if ($name) { $psi.EnvironmentVariables.Remove($name) } }
    if ($Redirect) {
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
    }
    return $psi
}

function Invoke-NativeCapture {
    # Run a program, capture stdout and stderr separately. (In Windows PowerShell
    # 5.1, `& prog 2>&1` turns stderr lines into errors under -ErrorAction Stop.)
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 20)
    $psi = New-ChildStartInfo -FilePath $FilePath -Arguments $Arguments -Redirect
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        try { $process.StandardInput.Close() } catch { }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw (Get-Text '{0} did not finish in {1} seconds' $FilePath $TimeoutSeconds)
        }
        [void]$stdout.Wait(5000)
        [void]$stderr.Wait(5000)
        $out = ''
        $err = ''
        if ($stdout.IsCompleted) { $out = $stdout.Result }
        if ($stderr.IsCompleted) { $err = $stderr.Result }
        return @{ ExitCode = $process.ExitCode; Out = $out; Err = $err }
    } finally {
        $process.Dispose()
    }
}

function Get-SshVersion {
    param([string]$SshPath)
    try {
        $r = Invoke-NativeCapture $SshPath @('-V')
        $text = $r.Err + ' ' + $r.Out
        if ($text -match 'OpenSSH[A-Za-z_]*_(\d+)\.(\d+)') { return [version]("{0}.{1}" -f $Matches[1], $Matches[2]) }
    } catch { }
    return $null
}

function Get-EffectiveSshConfig {
    # `ssh -G` with the session's own arguments: what ssh will really use.
    # $null if it cannot be read; callers then fall back to the arguments alone.
    param([string]$SshPath, [string[]]$Arguments)
    try {
        $r = Invoke-NativeCapture $SshPath (@('-G') + @($Arguments))
        if ($r.ExitCode -eq 0) { return (ConvertFrom-SshG $r.Out) }
    } catch { }
    return $null
}

function Get-SshModeSettings {
    # ssh mode's --keep and --dir for a connection, read from the ProxyCommand that ssh -G
    # says ssh will run: $null when that is not ssh-paste's relay (ssh mode is off for it).
    # ssh's own reading counts, not our block: -F, Include and an earlier Host win there.
    param($Effective)
    $proxy = ''
    if ($null -ne $Effective -and $Effective.ContainsKey('proxycommand')) { $proxy = [string]$Effective['proxycommand'] }
    if ($proxy -notmatch 'ssh-paste' -or $proxy -notmatch ' --proxy ') { return $null }
    return (Get-ProxySettings $proxy)
}

function Get-RemainingMilliseconds {
    param([DateTime]$Deadline)
    return [int][Math]::Max(0, ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
}

function Send-Image {
    # One ssh connection sends, verifies, prunes and publishes; returns the path.
    param([string]$SshPath, [string[]]$Arguments, [byte[]]$Png, [string]$Hash, [int]$TimeoutSeconds = 30, [string]$Ext = 'png', [string]$Dir = '/tmp', [string]$Class = '')
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $psi = New-ChildStartInfo -FilePath $SshPath -Arguments $Arguments -Redirect
    # The stdin writer must not start with a byte order mark: .NET Framework uses
    # Console.InputEncoding, which is UTF-8 *with* BOM when the code page is 65001.
    $restoreEncoding = $null
    if ($null -ne $psi.PSObject.Properties['StandardInputEncoding']) {
        $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
    } else {
        try {
            $current = [Console]::InputEncoding
            if ($current.GetPreamble().Length -gt 0) {
                $restoreEncoding = $current
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
            }
        } catch { $restoreEncoding = $null }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        try { [void]$process.Start() } finally {
            if ($null -ne $restoreEncoding) { try { [Console]::InputEncoding = $restoreEncoding } catch { } }
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $sendError = $null
        try {
            $stdin = $process.StandardInput.BaseStream
            $write = $stdin.WriteAsync($Png, 0, $Png.Length)
            if (-not $write.Wait((Get-RemainingMilliseconds $deadline))) { $sendError = 'timed out sending the image' }
            else { $stdin.Flush() }
        } catch {
            $sendError = $_.Exception.GetBaseException().Message
        }
        if ($null -eq $sendError) {
            try { $process.StandardInput.Close() } catch { $sendError = $_.Exception.GetBaseException().Message }
        }
        if ($null -ne $sendError -and -not $process.HasExited) { try { $process.Kill() } catch { } }
        if (-not $process.WaitForExit((Get-RemainingMilliseconds $deadline))) {
            try { $process.Kill() } catch { }
            # Killing ssh closes its pipes, so what it wrote on stderr can be read now.
            $tail = ''
            if ($stderr.Wait(3000)) { $tail = (@($stderr.Result.Trim() -split "`r?`n") | Select-Object -Last 12) -join ' | ' }
            throw (Get-Text 'ssh did not finish in {0} seconds (stdin sent: {1}); ssh said: {2}' $TimeoutSeconds ($null -eq $sendError) $tail)
        }
        $err = ''
        if ($stderr.Wait((Get-RemainingMilliseconds $deadline))) { $err = $stderr.Result.Trim() }
        if ($process.ExitCode -ne 0 -or $null -ne $sendError) {
            if ($err.Length -eq 0 -and $stdout.Wait((Get-RemainingMilliseconds $deadline))) {
                # The server's own word, e.g. "short 120", when ssh says nothing.
                $lines = @($stdout.Result -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
                if ($lines.Count -gt 0) { $err = $lines[$lines.Count - 1].Trim() }
            }
            if ($err.Length -eq 0) { $err = $sendError }
            if ([string]::IsNullOrEmpty($err)) { $err = 'no error message' }
            throw ('ssh exited with {0}: {1}' -f $process.ExitCode, $err)
        }
        if (-not $stdout.Wait((Get-RemainingMilliseconds $deadline))) { throw (Get-Text 'the reply from ssh did not arrive in time') }
        return (Read-UploadReply $stdout.Result $Png.Length $Hash $Ext $Dir $Class)
    } finally {
        # Closing our ends ends any read still pending on a pipe that a leftover
        # child of ssh keeps open.
        foreach ($stream in @($process.StandardInput, $process.StandardOutput, $process.StandardError)) {
            try { $stream.Dispose() } catch { }
        }
        $process.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Clipboard watcher (one tick every 250 ms while the session runs)
# ---------------------------------------------------------------------------

function New-Watcher {
    param([string]$SshPath, $Parsed, [switch]$NoProxy, [hashtable]$Pin, $Settings)
    $keep = $script:DefaultKeep
    $dir = $script:DefaultDir
    if ($null -ne $Settings) {
        if (-not [string]::IsNullOrEmpty($Settings.Keep)) { $keep = $Settings.Keep }
        if (-not [string]::IsNullOrEmpty($Settings.Dir)) { $dir = $Settings.Dir }
    }
    if (-not (Test-ServerDirectory $dir) -or $dir.StartsWith('~')) { throw (Get-Text 'bad --dir: {0}' $dir) }
    $minutes = ConvertTo-KeepMinutes $keep
    $tokenBytes = New-Object byte[] 8
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
    return @{
        SshPath = $SshPath; SshVersion = (Get-SshVersion $SshPath); Parsed = $Parsed; NoProxy = [bool]$NoProxy; Pin = $Pin
        Keep = $keep; KeepMinutes = $minutes; Class = (Get-KeepClass $keep); Dir = $dir; CacheHours = (Get-UploadCacheHours $minutes)
        Matcher = (Get-HostMatcher); Token = [BitConverter]::ToInt64($tokenBytes, 0)
        LastSeq = [long]-1; LastForeground = [long]0; State = $null; WakeAt = [DateTime]::MaxValue
        Uploaded = @{}; Failed = @{}; Blocked = $null
    }
}

function Get-UploadCacheHours {
    # How long a path is pasted again without a new upload. The server may delete the file
    # once it is KeepMinutes old, so this stays well under that.
    param([int]$KeepMinutes)
    if ($KeepMinutes -le 0) { return [double]$script:UploadCacheHours }
    return [Math]::Min([double]$script:UploadCacheHours, $KeepMinutes / 120.0)
}

function Get-WatcherValue {
    # A watcher field, or its default for a watcher made before the field existed.
    param($W, [string]$Name, $Default)
    if ($W.ContainsKey($Name) -and $null -ne $W[$Name]) { return $W[$Name] }
    return $Default
}

function Get-UploadedPath {
    # The text to paste for this clipboard state: the remote path of the image,
    # or the paths of all copied image files separated by spaces. $null until
    # every one is uploaded.
    param($W, $State)
    $W.WakeAt = [DateTime]::MaxValue
    $paths = New-Object System.Collections.ArrayList
    foreach ($item in (Get-StateItems $State)) {
        $path = Get-UploadedItemPath $W $item
        if ($null -eq $path) { return $null }
        [void]$paths.Add($path)
    }
    return ($paths -join ' ')
}

function Get-StateItems {
    param($State)
    $items = $State['Items']
    if ($null -eq $items) { $items = @(@{ Bytes = $State.Png; Hash = $State.Hash; Ext = 'png' }) }
    return , @($items)
}

function Get-ExpectedText {
    # The text Ctrl+V should paste, known before the upload: each file is named
    # after its content. An earlier upload's real path wins (it can carry a
    # per-user suffix when another user on the server owns the plain name).
    param($W, $State)
    $now = [DateTime]::UtcNow
    $paths = foreach ($item in (Get-StateItems $State)) {
        $done = $W.Uploaded[$item.Hash]
        if ($null -ne $done -and ($now - $done.At).TotalHours -lt (Get-WatcherValue $W 'CacheHours' $script:UploadCacheHours)) { $done.Path }
        else { (Get-WatcherValue $W 'Dir' $script:DefaultDir) + '/ssh-paste-' + (Get-WatcherValue $W 'Class' '') + $item.Hash + '.' + $item.Ext }
    }
    return (@($paths) -join ' ')
}

function Test-UploadFailing {
    param($W, $State)
    if (Get-WatcherValue $W 'Blocked' $null) { return $true }
    foreach ($item in (Get-StateItems $State)) { if ($W.Failed.ContainsKey($item.Hash)) { return $true } }
    return $false
}

function Sync-ClipboardText {
    # Re-reads the clipboard and, if it still holds the same image, makes its
    # text $Text (or removes our text when $Text is empty). Leaves alone what the
    # user copied since, and an entry another session in this window wrote.
    param($W, [string]$Hash, [string]$Text, [IntPtr]$Foreground)
    $fgKey = $Foreground.ToInt64()
    $cur = Read-ClipboardImage
    if ($cur.Hash -cne $Hash) { return }
    $ours = ($null -ne $cur.Owner)
    if (-not [string]::IsNullOrEmpty($Text)) {
        if (-not $ours -and ($cur.HasText -or ($cur['HasFiles'] -and $null -eq $cur['Files']))) { return }
        if ($ours -and $cur.HasText -and $cur.Text -ceq $Text -and $cur.Token -eq $W.Token -and (Test-ClipboardAnswers $Text)) { return }
        if ($ours -and $cur.HasText -and $cur.Owner -eq $fgKey -and $cur.Token -ne $W.Token) { return }
        $owner = $fgKey
    } else {
        if (-not ($ours -and $cur.HasText -and $cur.Token -eq $W.Token)) { return }
        $owner = 0
    }
    if ([long][SshPasteNative]::GetClipboardSequenceNumber() -ne $cur.Seq -or [SshPasteNative]::GetForegroundWindow() -ne $Foreground) { return }
    Set-SshPasteClipboard -Png $cur.Png -Files $cur['Files'] -Text $Text -Owner $owner -Token $W.Token -Basis $cur.Seq
}

function Get-UploadedItemPath {
    # Upload once per file. A failed upload is retried after 30 s, 1 min, 2 min
    # and so on (beeping only the first time). An upload is redone after a few
    # hours so the server's day-old cleanup never removes a path we paste.
    # Moves $W.WakeAt earlier so the watcher comes back for a retry or refresh.
    param($W, $Item)
    # After a failure that trying again cannot fix, this session uploads nothing more.
    if (Get-WatcherValue $W 'Blocked' $null) { return $null }
    $now = [DateTime]::UtcNow
    $done = $W.Uploaded[$Item.Hash]
    $cacheHours = Get-WatcherValue $W 'CacheHours' $script:UploadCacheHours
    if ($null -ne $done -and ($now - $done.At).TotalHours -lt $cacheHours) {
        Set-WakeAt $W $done.At.AddHours($cacheHours)
        return $done.Path
    }
    $failed = $W.Failed[$Item.Hash]
    if ($null -ne $failed) {
        $retryAt = $failed.At.AddSeconds([Math]::Min(1800, $script:RetryFailedSeconds * [Math]::Pow(2, $failed.Count - 1)))
        if ($now -lt $retryAt) { Set-WakeAt $W $retryAt; return $null }
    }
    try {
        $dir = Get-WatcherValue $W 'Dir' $script:DefaultDir
        $class = Get-WatcherValue $W 'Class' ''
        $argv = Get-UploadSshArguments -Parsed $W.Parsed -Hash $Item.Hash -Size $Item.Bytes.Length -NoProxy:$W.NoProxy -SshVersion $W.SshVersion -Pin $W.Pin -Ext $Item.Ext `
            -Keep (Get-WatcherValue $W 'Keep' $script:DefaultKeep) -Dir $dir
        if ($env:SSH_PASTE_DEBUG) {
            # -v makes ssh say on stderr how far it got; LogLevel=ERROR is ours, so
            # drop it together with its -o (a lone -o would take the next option as
            # its value, and ssh refuses the command line).
            $i = [Array]::IndexOf([object[]]$argv, 'LogLevel=ERROR')
            $argv = @('-v') + @(for ($k = 0; $k -lt $argv.Count; $k++) { if ($k -ne $i - 1 -and $k -ne $i) { $argv[$k] } })
            Write-WatchDebug ('upload command: ssh ' + (Join-NativeArguments ($argv[0..($argv.Count - 2)])) + ' <sh -c script> ')
        }
        # 30 s plus 1 s per 256 KB, at most 5 minutes: big images on slow links need longer.
        $timeout = [int][Math]::Min(300, 30 + [Math]::Ceiling($Item.Bytes.Length / 262144))
        $path = Send-Image -SshPath $W.SshPath -Arguments $argv -Png $Item.Bytes -Hash $Item.Hash -Ext $Item.Ext -TimeoutSeconds $timeout -Dir $dir -Class $class
        # The cache counts from the end of the upload: a slow upload is not stale at once.
        $now = [DateTime]::UtcNow
        $W.Uploaded[$Item.Hash] = @{ Path = $path; At = $now }
        $W.Failed.Remove($Item.Hash)
        Set-WakeAt $W $now.AddHours($cacheHours)
        return $path
    } catch {
        $count = 1
        if ($null -ne $failed) { $count = $failed.Count + 1 }
        $W.Failed[$Item.Hash] = @{ Message = $_.Exception.Message; At = [DateTime]::UtcNow; Count = $count }
        Write-WatchDebug ('upload failed ({0}x, {1} bytes): {2}' -f $count, $Item.Bytes.Length, $_.Exception.Message)
        $failure = Get-SshFailure $_.Exception.Message
        if (Test-FailureFinal $failure) {
            $W.Blocked = Get-LoginAdvice $failure $W.Parsed.Destination
            Write-WatchDebug ('no more uploads in this session: ' + $W.Blocked)
        }
        Set-WakeAt $W ([DateTime]::UtcNow.AddSeconds([Math]::Min(1800, $script:RetryFailedSeconds * [Math]::Pow(2, $count - 1))))
        if ($count -eq 1) { try { [System.Media.SystemSounds]::Hand.Play() } catch { } }
        return $null
    }
}

function Set-WakeAt {
    param($W, [DateTime]$At)
    if ($At -lt $W.WakeAt) { $W.WakeAt = $At }
}

function Invoke-WatcherTick {
    # Copy a screenshot, come back to this terminal: upload it once and put
    # "image + remote path" on the clipboard, so Windows Terminal pastes the path.
    # Leave for another app: put the plain image back. The marker records the
    # window and the session that wrote an entry, so sessions do not undo each
    # other: one in another window yields to the window in front, and one in the
    # same window leaves an entry alone that already carries a usable path.
    # Focus is per window here: Windows Terminal names no tab in front. The macOS
    # client makes the same decisions per tab in iTerm2 and Terminal.app (sameSpot
    # in src/ssh-paste.js); with one session per window the two are the same.
    param($W)
    $foreground = [SshPasteNative]::GetForegroundWindow()
    if ($foreground -eq [IntPtr]::Zero) { return }
    $fgKey = $foreground.ToInt64()
    $seq = [long][SshPasteNative]::GetClipboardSequenceNumber()
    if ($seq -ne $W.LastSeq) {
        $W.State = Read-ClipboardImage
        $W.LastSeq = $W.State.Seq
    } elseif ($fgKey -eq $W.LastForeground -and [DateTime]::UtcNow -lt $W.WakeAt) {
        return
    }
    $W.LastForeground = $fgKey
    $W.WakeAt = [DateTime]::MaxValue
    $state = $W.State
    Write-WatchDebug ('tick: foreground={0} terminal={1} {2}' -f $fgKey, (Test-HostForeground $W.Matcher $foreground), (Format-WatchState $W $state))
    if ($null -eq $state.Png -and $null -eq $state['Files']) { return }
    $ours = ($null -ne $state.Owner)
    # An app copied text along with the image, or files that are not all images: leave it alone.
    if (-not $ours -and ($state.HasText -or ($state['HasFiles'] -and $null -eq $state['Files']))) { return }

    if (Test-HostForeground $W.Matcher $foreground) {
        # Put the expected path on the clipboard first, then upload: a Ctrl+V
        # pressed during the upload already pastes the path, not a local one.
        $expected = Get-ExpectedText $W $state
        $otherSession = ($ours -and $state.HasText -and $state.Owner -eq $fgKey -and $state.Token -ne $W.Token)
        # Already shown: this session's entry carries the path and a paste still gets it.
        $shown = ($ours -and $state.HasText -and $state.Text -ceq $expected -and $state.Token -eq $W.Token -and (Test-ClipboardAnswers $expected))
        $wrote = $false
        if (-not $shown -and -not $otherSession -and -not (Test-UploadFailing $W $state)) {
            if ([long][SshPasteNative]::GetClipboardSequenceNumber() -ne $state.Seq -or [SshPasteNative]::GetForegroundWindow() -ne $foreground) {
                $W.LastSeq = -1
                return
            }
            # Promise the path: a paste during the upload waits for it (delayed rendering).
            Set-SshPasteClipboard -Png $state.Png -Files $state['Files'] -Text $expected -Owner $fgKey -Token $W.Token -Promise -Basis $state.Seq
            $W.LastSeq = -1
            $wrote = $true
            Write-WatchDebug ('promised the path before the upload: ' + $expected)
        }
        $path = Get-UploadedPath $W $state
        Write-WatchDebug ('upload result: ' + $path)
        if ($wrote) {
            if ($null -ne $path -and $path -ceq $expected) { Complete-ClipboardPromise $path } else { Complete-ClipboardPromise $null }
        }
        if ($null -eq $path) {
            # The upload failed: take the path back so Ctrl+V does not paste a missing file.
            Sync-ClipboardText $W $state.Hash $null $foreground
            $W.LastSeq = -1
            return
        }
        if ($path -cne $expected -or -not ($wrote -or $shown -or $otherSession)) {
            Sync-ClipboardText $W $state.Hash $path $foreground
            $W.LastSeq = -1
        }
        return
    } elseif ($ours -and $state.HasText -and $state.Owner -ne $fgKey) {
        $text = $null
    } else {
        return
    }
    # The upload takes time: write only if nothing changed since the snapshot.
    if ([long][SshPasteNative]::GetClipboardSequenceNumber() -ne $state.Seq -or [SshPasteNative]::GetForegroundWindow() -ne $foreground) {
        $W.LastSeq = -1
        return
    }
    $owner = $fgKey
    if ($null -eq $text) { $owner = 0 }
    Set-SshPasteClipboard -Png $state.Png -Files $state['Files'] -Text $text -Owner $owner -Token $W.Token -Basis $state.Seq
    $W.LastSeq = -1   # read our own write back on the next tick
}

function Invoke-WatcherStep {
    # One tick of the watch loop. A tick that fails (the clipboard was busy, or
    # changed under a write) reads the clipboard again on the next one.
    param($W)
    try { Invoke-WatcherTick $W } catch {
        $W.LastSeq = -1
        Write-WatchDebug ('tick error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
    }
}

function Restore-Clipboard {
    # On exit, put the plain image back if the clipboard still holds the path
    # this session wrote. Another session's entry is left alone.
    param($W)
    try {
        $state = Read-ClipboardImage
        if (($null -ne $state.Png -or $null -ne $state['Files']) -and $null -ne $state.Owner -and $state.HasText -and $state.Token -eq $W.Token -and
            [long][SshPasteNative]::GetClipboardSequenceNumber() -eq $state.Seq) {
            Set-SshPasteClipboard -Png $state.Png -Files $state['Files'] -Text $null -Owner 0 -Token $W.Token -Basis $state.Seq
        }
    } catch { }
}

function Get-FailureSummary {
    param($W)
    if ($null -eq $W) { return $null }
    if (Get-WatcherValue $W 'Blocked' $null) { return (Get-Text 'ssh-paste: screenshot paste was off for this session: {0}' $W.Blocked) }
    if ($W.Failed.Count -eq 0) { return $null }
    $last = @($W.Failed.Values | Sort-Object { $_.At })[-1]
    $parsed = Get-WatcherValue $W 'Parsed' $null
    $destination = ''
    if ($null -ne $parsed) { $destination = $parsed.Destination }
    $advice = Get-LoginAdvice (Get-SshFailure $last.Message) $destination
    if ($advice) { return (Get-Text 'ssh-paste: {0} screenshot upload(s) failed: {1}' $W.Failed.Count $advice) }
    return (Get-Text 'ssh-paste: {0} screenshot upload(s) failed: {1}' $W.Failed.Count $last.Message)
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

function Get-SshPath {
    if ($env:SSH_PASTE_SSH) { return $env:SSH_PASTE_SSH }
    $cmd = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    $inbox = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $inbox) { return $inbox }
    throw (Get-Text 'ssh.exe was not found. Add "OpenSSH Client" under Optional features in Windows Settings.')
}

function Write-Info {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-Wrapper {
    param([string[]]$SshArgs, $Settings)
    $ssh = Get-SshPath
    $parsed = $null
    try { $parsed = Split-SshArguments $SshArgs } catch { }
    $watcher = $null
    if ($null -ne $parsed -and -not [string]::IsNullOrEmpty($parsed.Destination)) {
        $effective = Get-EffectiveSshConfig $ssh $SshArgs
        if ($null -ne (Get-SshModeSettings $effective)) {
            # ssh mode already serves this connection; a second watcher would upload twice.
            if ($null -ne $Settings -and ($null -ne $Settings.Keep -or $null -ne $Settings.Dir)) {
                Write-Info (Get-Text 'ssh-paste: ssh mode serves {0}, with its own --keep and --dir; change them with ssh-paste --enable --keep TIME --dir DIR {0}' $parsed.Destination) 'Yellow'
            }
        } elseif (Test-InteractiveSsh $parsed $effective) {
            try {
                Initialize-Native
                if ($null -ne $Settings -and -not [string]::IsNullOrEmpty($Settings.Dir) -and $Settings.Dir.StartsWith('~')) {
                    $Settings.Dir = ConvertTo-AbsoluteDirectory $Settings.Dir (Get-ServerHome $ssh $parsed (Get-SshVersion $ssh))
                }
                $watcher = New-Watcher -SshPath $ssh -Parsed $parsed -Settings $Settings
                Write-Info (Get-Text 'ssh-paste: screenshot paste is on. Copy a screenshot, come back here, press Ctrl+V.') 'DarkGray'
            } catch {
                Write-Info (Get-Text 'ssh-paste: screenshot paste is off: {0}' $_.Exception.Message) 'Yellow'
            }
        }
    }
    $process = [System.Diagnostics.Process]::Start((New-ChildStartInfo -FilePath $ssh -Arguments $SshArgs))
    try {
        while (-not $process.WaitForExit(250)) {
            if ($null -ne $watcher) { Invoke-WatcherStep $watcher }
        }
        $process.WaitForExit()
    } finally {
        if ($null -ne $watcher) { Restore-Clipboard $watcher }
    }
    $summary = Get-FailureSummary $watcher
    if ($summary) {
        Write-Info $summary 'Yellow'
        Write-Info (Get-Text 'Run: ssh-paste --doctor {0}' $parsed.Destination) 'Yellow'
    }
    return $process.ExitCode
}

function Connect-Tcp {
    param([string]$TargetHost, [int]$Port)
    $errors = @()
    foreach ($address in [System.Net.Dns]::GetHostAddresses($TargetHost)) {
        $client = New-Object System.Net.Sockets.TcpClient -ArgumentList $address.AddressFamily
        try {
            $task = $client.ConnectAsync($address, $Port)
            if ($task.Wait(15000) -and $client.Connected) { $client.NoDelay = $true; return $client }
            $errors += (Get-Text '{0}: timed out' $address)
        } catch {
            $errors += (Get-Text '{0}: {1}' $address ($_.Exception.GetBaseException().Message))
        }
        $client.Close()
    }
    if ($errors.Count -eq 0) { $errors = @((Get-Text 'no address')) }
    throw (Get-Text 'cannot connect to {0} port {1}: {2}' $TargetHost $Port ($errors -join '; '))
}

function Split-CommandLine {
    # CommandLineToArgvW rules (the ones ssh.exe itself is parsed with).
    param([string]$CommandLine)
    $result = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false; $have = $false; $i = 0; $first = $true
    while ($i -lt $CommandLine.Length) {
        $c = $CommandLine[$i]
        if ($first) {
            # argv[0]: quotes delimit, backslashes are literal
            if ($c -eq [char]'"') { $inQuotes = -not $inQuotes; $have = $true; $i++; continue }
            if (-not $inQuotes -and ($c -eq [char]' ' -or $c -eq [char]"`t")) {
                if ($have) { [void]$result.Add($sb.ToString()); [void]$sb.Clear(); $have = $false }
                $first = $false; $i++; continue
            }
            [void]$sb.Append($c); $have = $true; $i++; continue
        }
        if ($c -eq [char]'\') {
            $n = 0
            while ($i -lt $CommandLine.Length -and $CommandLine[$i] -eq [char]'\') { $n++; $i++ }
            if ($i -lt $CommandLine.Length -and $CommandLine[$i] -eq [char]'"') {
                [void]$sb.Append([char]'\', [int][math]::Floor($n / 2))
                if ($n % 2 -eq 1) { [void]$sb.Append([char]'"'); $i++ }
            } else {
                [void]$sb.Append([char]'\', $n)
            }
            $have = $true
            continue
        }
        if ($c -eq [char]'"') {
            if ($inQuotes -and $i + 1 -lt $CommandLine.Length -and $CommandLine[$i + 1] -eq [char]'"') {
                [void]$sb.Append([char]'"'); $i += 2; continue
            }
            $inQuotes = -not $inQuotes; $have = $true; $i++; continue
        }
        if (-not $inQuotes -and ($c -eq [char]' ' -or $c -eq [char]"`t")) {
            if ($have) { [void]$result.Add($sb.ToString()); [void]$sb.Clear(); $have = $false }
            $i++; continue
        }
        [void]$sb.Append($c); $have = $true; $i++
    }
    if ($have) { [void]$result.Add($sb.ToString()) }
    return @($result)
}

function Get-ParentSshArguments {
    # The ssh.exe that started us as its ProxyCommand: its path and its arguments.
    # $null when the parent is not ssh or cannot be read; then we only relay.
    $self = Get-ProcessInfo $PID
    if ($null -eq $self) { return $null }
    $parent = Get-ProcessInfo ([int]$self.ParentProcessId)
    if ($null -eq $parent -or [string]::IsNullOrEmpty([string]$parent.CommandLine)) { return $null }
    $exe = [string]$parent.ExecutablePath
    if ([System.IO.Path]::GetFileNameWithoutExtension($exe) -ine 'ssh') { return $null }
    $argv = @(Split-CommandLine ([string]$parent.CommandLine))
    $rest = @()
    if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }
    return @{ Path = $exe; Args = $rest }
}

function Write-WatchDebug {
    # With SSH_PASTE_DEBUG=1, the watcher logs what it sees and decides to
    # %TEMP%\ssh-paste-debug.log (the terminal shows the ssh session).
    param([string]$Message)
    if (-not $env:SSH_PASTE_DEBUG) { return }
    try {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) 'ssh-paste-debug.log'
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('HH:mm:ss.fff'), $PID, $Message
        [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine)
    } catch { }
}

function Format-WatchState {
    param($W, $State)
    if ($null -eq $State) { return 'no state' }
    $kind = 'none'
    if ($null -ne $State['Files']) { $kind = 'files(' + @($State['Files']).Count + ')' } elseif ($null -ne $State.Png) { $kind = 'image(' + $State.Png.Length + ' bytes)' }
    $owner = 'app'
    if ($null -ne $State.Owner) { $owner = 'ours(window ' + $State.Owner + ', mine=' + ($State.Token -eq $W.Token) + ')' }
    return ('seq={0} {1} text={2} files={3} by={4} pasteText={5}' -f $State.Seq, $kind, $State.HasText, $State['HasFiles'], $owner, $State.Text)
}

function Write-ProxyDebug {
    # With SSH_PASTE_DEBUG=1, ProxyCommand mode reports its steps on stderr
    # (stdout carries the SSH stream).
    param([string]$Message)
    if ($env:SSH_PASTE_DEBUG) { [Console]::Error.WriteLine('ssh-paste debug: ' + $Message) }
    Write-WatchDebug ('proxy: ' + $Message)
}

function Invoke-Proxy {
    # ProxyCommand mode. stdout is the SSH byte stream: never write to it.
    param([string]$TargetHost, [string]$Port, [string]$Alias, $Settings, [string]$SettingsError)
    $client = Connect-Tcp $TargetHost ([int]$Port)
    Write-ProxyDebug ('connected to {0}' -f $client.Client.RemoteEndPoint)
    $network = $client.GetStream()
    $stdin = $null
    $stdout = $null
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            if (-not ('SshPasteNative' -as [type])) { Add-Type -TypeDefinition $script:NativeSource }
            $inOverlapped = $false
            $outOverlapped = $false
            $stdin = [SshPasteNative]::OpenStandardStream(-10, $false, [ref]$inOverlapped)
            $stdout = [SshPasteNative]::OpenStandardStream(-11, $true, [ref]$outOverlapped)
            Write-ProxyDebug ('stdin overlapped: {0}, stdout overlapped: {1}' -f $inOverlapped, $outOverlapped)
            # ssh gave us these pipes, and the socket is ours: children we start
            # (the upload ssh) must not hold copies of the session's pipes.
            $kept = @(
                [SshPasteNative]::KeepToSelf([SshPasteNative]::StandardHandle(-10)),
                [SshPasteNative]::KeepToSelf([SshPasteNative]::StandardHandle(-11)),
                [SshPasteNative]::KeepToSelf([SshPasteNative]::StandardHandle(-12)),
                [SshPasteNative]::KeepToSelf($client.Client.Handle))
            Write-ProxyDebug ('kept to self (stdin, stdout, stderr, socket): ' + ($kept -join ', '))
        } catch {
            Write-ProxyDebug ('native streams unavailable: ' + $_.Exception.Message)
            $stdin = $null
            $stdout = $null
        }
    }
    if ($null -eq $stdin) { $stdin = [Console]::OpenStandardInput() }
    if ($null -eq $stdout) { $stdout = [Console]::OpenStandardOutput() }
    $up = $stdin.CopyToAsync($network)
    $down = $network.CopyToAsync($stdout)

    $watcher = $null
    try {
        $parent = Get-ParentSshArguments
        if ($null -ne $parent) {
            $parsed = Split-SshArguments $parent.Args
            $effective = Get-EffectiveSshConfig $parent.Path $parent.Args
            if (Test-InteractiveSsh $parsed $effective) {
                if (-not [string]::IsNullOrEmpty($SettingsError)) { throw $SettingsError }
                Initialize-Native
                # Upload to the address this relay reached, checking the host key
                # under the name the session itself used.
                $alias = $TargetHost
                if ($Port -ne '22') { $alias = '[{0}]:{1}' -f $TargetHost, $Port }
                if ($null -ne $effective -and $effective.ContainsKey('hostkeyalias')) { $alias = [string]$effective['hostkeyalias'] }
                $remote = $client.Client.RemoteEndPoint
                $pin = @{ HostName = $remote.Address.ToString(); Port = $remote.Port; HostKeyAlias = $alias }
                $watcher = New-Watcher -SshPath $parent.Path -Parsed $parsed -NoProxy -Pin $pin -Settings $Settings
            }
        }
    } catch {
        [Console]::Error.WriteLine((Get-Text 'ssh-paste: screenshot paste is off: {0}' $_.Exception.Message))
        $watcher = $null
    }

    $code = 0
    try {
        while ($true) {
            $done = [System.Threading.Tasks.Task]::WaitAny(@($up, $down), 250)
            if ($done -eq 0) {
                Write-ProxyDebug ('ssh closed its side (faulted: {0})' -f $up.IsFaulted)
                # ssh closed its side: half-close and let the server finish.
                if (-not $up.IsFaulted) {
                    try { $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { }
                    if (-not $down.Wait(30000)) {
                        $code = 1
                        [Console]::Error.WriteLine((Get-Text 'ssh-paste: the server did not close the connection within 30 seconds'))
                    }
                }
                break
            }
            if ($done -eq 1) { Write-ProxyDebug ('the server closed its side (faulted: {0})' -f $down.IsFaulted); break }
            if ($null -ne $watcher) { Invoke-WatcherStep $watcher }
        }
        foreach ($t in @($up, $down)) {
            if ($t.IsFaulted) {
                $code = 1
                [Console]::Error.WriteLine((Get-Text 'ssh-paste: connection error: {0}' ($t.Exception.GetBaseException().Message)))
            }
        }
    } finally {
        if ($null -ne $watcher) { Restore-Clipboard $watcher }
        try { $stdout.Flush() } catch { }
        $client.Close()
    }
    $summary = Get-FailureSummary $watcher
    if ($summary) {
        [Console]::Error.WriteLine($summary)
        [Console]::Error.WriteLine((Get-Text 'Run: ssh-paste --doctor {0}' $Alias))
    }
    return $code
}

function Get-SshConfigPath {
    return (Join-Path $env:USERPROFILE '.ssh\config')
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function Update-SshConfig {
    # Rewrites ~/.ssh/config through a temp file, keeping a UTF-8 BOM if there
    # was one, and refuses if the file changed since we read it.
    param([string]$Path, [string]$OldText, [string]$NewText, [switch]$Delete)
    $current = Read-TextFile $Path
    if ([string]$current -cne [string]$OldText) { throw (Get-Text '{0} changed while ssh-paste was editing it; run the command again' $Path) }
    if ($Delete) { Remove-Item -LiteralPath $Path -Force; return }
    $hadBom = $false
    if (Test-Path -LiteralPath $Path) {
        $head = [System.IO.File]::ReadAllBytes($Path)
        $hadBom = ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $temp = $Path + '.ssh-paste-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($temp, $NewText, (New-Object System.Text.UTF8Encoding($hadBom)))
        if ([string](Read-TextFile $Path) -cne [string]$OldText) { throw (Get-Text '{0} changed while ssh-paste was editing it; run the command again' $Path) }
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($temp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Get-ResolvedSshConfig {
    param([string]$Alias)
    $r = Invoke-NativeCapture (Get-SshPath) @('-G', '--', $Alias)
    if ($r.ExitCode -ne 0) { throw (Get-Text 'ssh -G {0} failed: {1}' $Alias ($r.Err.Trim())) }
    return (ConvertFrom-SshG $r.Out)
}

function Test-HostResolves {
    param([string]$Name)
    try { return (@([System.Net.Dns]::GetHostAddresses($Name)).Count -gt 0) } catch { return $false }
}

function Invoke-Enable {
    # ssh-paste --enable [--keep TIME] [--dir DIR] HOST...: the settings go to the hosts given;
    # a host that is already enabled keeps the settings that are not given.
    param([string[]]$Arguments)
    $settings = Read-PasteSettings $Arguments
    # Each host once, in order; aliases are case-sensitive, as in ssh.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $hosts = @(@($settings.Rest) | Where-Object { $seen.Add([string]$_) })
    if ($hosts.Count -eq 0) { throw (Get-Text 'usage: ssh-paste --enable [--keep TIME] [--dir DIR] HOST [HOST...]') }
    $configPath = Get-SshConfigPath
    $text = Read-TextFile $configPath
    $block = Get-ManagedBlock $text
    # Host aliases are case-sensitive in ssh, so the map is too.
    $want = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($g in @($block.Groups)) {
        $s = Get-ProxySettings $g.ProxyCommand
        foreach ($h in @($g.Hosts)) { if (-not $want.Contains($h)) { $want[$h] = $s } }
    }
    $added = @()
    $changed = @()
    $logins = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $problems = @()
    $ssh = $null
    # Every name is checked before any connection, so a bad one stops the command at once.
    foreach ($h in $hosts) {
        if (-not (Test-HostAlias $h)) { throw (Get-Text 'use a host name or a Host alias from ~/.ssh/config (no user@, no options): {0}' $h) }
        if (-not $want.Contains($h)) {
            $resolved = Get-ResolvedSshConfig $h
            $hostName = $h
            if ($resolved.ContainsKey('hostname')) { $hostName = [string]$resolved['hostname'] }
            if (-not (Test-HostResolves $hostName)) {
                throw (Get-Text 'cannot find the host {0} (from {1}). Check the name, or add it to ~/.ssh/config, then run --enable again' $hostName $h)
            }
            foreach ($key in @('proxyjump', 'proxycommand')) {
                if ($resolved.ContainsKey($key) -and $resolved[$key] -ne 'none') {
                    throw (Get-Text '{0} already uses {1} ({2}); ssh-paste cannot take over its connection. Use wrapper mode instead: ssh-paste {0}' $h $key $resolved[$key])
                }
            }
        }
    }
    foreach ($h in $hosts) {
        if (-not $want.Contains($h)) {
            $want[$h] = @{ Keep = $script:DefaultKeep; Dir = $script:DefaultDir }
            $added += $h
        }
        # Check once, as an upload would log in, so a host that asks for a password is known
        # now and not at the first paste; the same connection reads the home folder for ~.
        if ($null -eq $ssh) { $ssh = Get-SshPath; $sshVersion = Get-SshVersion $ssh }
        if (-not $logins.ContainsKey($h)) { $logins[$h] = Test-ServerLogin $ssh (Split-SshArguments @($h)) $sshVersion -NoProxy }
        # A host whose uploads the server refuses is not enabled: ssh mode could never paste there.
        $refusal = Get-EnableRefusal $h $logins[$h].Error
        if ($null -ne $refusal) { $problems += $refusal; continue }
        $old = $want[$h]
        $new = @{ Keep = $old.Keep; Dir = $old.Dir }
        if ($null -ne $settings.Keep) { $new.Keep = $settings.Keep }
        if ($null -ne $settings.Dir) {
            # ~ is the home folder on that server, asked for once, so the block holds an
            # absolute path and the path to paste is known before an upload.
            $new.Dir = $settings.Dir
            if ($new.Dir.StartsWith('~')) {
                if ($null -eq $logins[$h].Home) { $problems += (Get-HomeError $h $logins[$h].Error); continue }
                $new.Dir = ConvertTo-AbsoluteDirectory $settings.Dir $logins[$h].Home
                Write-Info (Get-Text '{0}: {1} is {2} there' $h $settings.Dir $new.Dir)
            }
        }
        if ($added -notcontains $h -and $changed -notcontains $h -and ($new.Keep -cne $old.Keep -or $new.Dir -cne $old.Dir)) { $changed += $h }
        $want[$h] = $new
    }
    if ($problems.Count -gt 0) {
        # All or nothing: the reasons for every host, and the command to run again.
        throw (@((Get-Text 'nothing changed in ~/.ssh/config:')) + $problems + @((Get-Text 'Then run again: ssh-paste --enable {0}' (Format-ShellWords $Arguments))) -join [Environment]::NewLine)
    }
    $groups = @(Get-SettingsGroups $want (Get-ProxyScriptPath $PSCommandPath))
    $createdFile = $block.CreatedFile -or ($null -eq $text)
    if ($added.Count -gt 0 -or $changed.Count -gt 0) {
        Update-SshConfig $configPath $text (Set-ManagedBlock $text -Groups $groups -CreatedFile:$createdFile)
        if ($added.Count -gt 0) { Write-Info (Get-Text 'Enabled for: {0}' ($added -join ', ')) 'Green' }
        if ($changed.Count -gt 0) { Write-Info (Get-Text 'Changed for: {0}' ($changed -join ', ')) 'Green' }
    } else {
        Write-Info (Get-Text 'Already enabled with these settings; nothing changed.') 'Gray'
    }
    foreach ($h in $hosts) {
        Write-Info (Get-Text '{0}: {1}' $h (Format-PasteSettings $want[$h]))
        if ($null -eq $logins[$h].Home) { Write-Info (Get-LoginReport $h $logins[$h].Error) 'Yellow' }
        else { Write-Info (Get-LoginReport $h $null) 'Green' }
    }
    Write-Info (Get-Text 'This block is at the top of {0}:' $configPath)
    Write-Info ''
    foreach ($line in (Set-ManagedBlock '' -Groups $groups -CreatedFile:$createdFile).TrimEnd() -split "`r?`n") { Write-Info ('    ' + $line) 'Cyan' }
    Write-Info ''
    $example = $hosts[0]
    if ($added.Count -gt 0) { $example = $added[0] }
    Write-Info (Get-Text 'Now connect as usual: ssh {0}' $example)
    return 0
}

function Invoke-Disable {
    param([string[]]$Hosts)
    $configPath = Get-SshConfigPath
    $text = Read-TextFile $configPath
    $block = Get-ManagedBlock $text
    $managed = @($block.Hosts)
    if (-not $block.Present) { Write-Info (Get-Text 'ssh-paste is not enabled for any host.'); return 0 }
    if ($null -eq $Hosts -or $Hosts.Count -eq 0) { $keep = @() } else { $keep = @($managed | Where-Object { $Hosts -cnotcontains $_ }) }
    # Each remaining host keeps its group's line as it is.
    $groups = @(foreach ($g in @($block.Groups)) {
            $proxy = $g.ProxyCommand
            if ([string]::IsNullOrEmpty($proxy)) { $proxy = Get-ProxyCommandLine $PSCommandPath }
            @{ Hosts = @(@($g.Hosts) | Where-Object { $keep -ccontains $_ }); ProxyCommand = $proxy }
        })
    $newText = Set-ManagedBlock $text -Groups $groups -CreatedFile:$block.CreatedFile
    if ($keep.Count -eq 0 -and $block.CreatedFile -and $newText.Trim().Length -eq 0) {
        Update-SshConfig $configPath $text $null -Delete
        $dir = Split-Path -Parent $configPath
        if (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { Remove-Item -LiteralPath $dir -Force }
    } else {
        Update-SshConfig $configPath $text $newText
    }
    Write-Info (Get-DisableMessage $managed $Hosts) 'Green'
    return 0
}

function Get-DisableMessage {
    # What --disable says: the hosts it removed (all when none are named), or that none of
    # the named hosts was enabled. Host aliases are case-sensitive, as in ssh.
    param([string[]]$Managed, [string[]]$Asked)
    $removed = @(@($Managed) | Where-Object { $null -eq $Asked -or @($Asked).Count -eq 0 -or @($Asked) -ccontains $_ })
    if ($removed.Count -eq 0) { return (Get-Text 'ssh-paste is not enabled for: {0}' (@($Asked) -join ', ')) }
    return (Get-Text 'Disabled for: {0}' ($removed -join ', '))
}

function Invoke-Doctor {
    param([string[]]$SshArgs)
    $ok = $true
    function Report([bool]$Pass, [string]$What) {
        if ($Pass) { Write-Host '  ok    ' -ForegroundColor Green -NoNewline } else { Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline }
        Write-Host $What
    }
    Write-Host ('ssh-paste ' + $script:Version)
    Report $true ('PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    try { Initialize-Native; Report $true (Get-Text 'clipboard and window APIs available') } catch { Report $false $_.Exception.Message; return 1 }
    $ssh = $null
    try {
        $ssh = Get-SshPath
        $version = Invoke-NativeCapture $ssh @('-V')
        Report $true ('ssh: {0} ({1})' -f $ssh, ($version.Err + $version.Out).Trim())
    } catch { Report $false $_.Exception.Message; return 1 }
    $matcher = Get-HostMatcher
    Report $true (Get-Text 'terminal: {0}' $matcher.Kind)
    try {
        $state = Read-ClipboardImage
        if ($null -ne $state['Files']) { Report $true (Get-Text 'clipboard: {0} copied image file(s)' $state.Files.Count) } elseif ($null -eq $state.Png) { Report $true (Get-Text 'clipboard: readable (no image right now)') } else { Report $true (Get-Text 'clipboard: image, {0} bytes' $state.Png.Length) }
    } catch { Report $false (Get-Text 'clipboard: {0}' $_.Exception.Message); $ok = $false }
    if ($null -eq $SshArgs -or $SshArgs.Count -eq 0) {
        Write-Host ''
        Write-Host (Get-Text 'Add a host to test an upload: ssh-paste --doctor myhost')
        if ($ok) { return 0 } else { return 1 }
    }
    $parsed = Split-SshArguments $SshArgs
    $bitmap = New-Object System.Drawing.Bitmap -ArgumentList 8, 8
    try {
        $bitmap.SetPixel(0, 0, [System.Drawing.Color]::FromArgb((Get-Random -Maximum 256), (Get-Random -Maximum 256), (Get-Random -Maximum 256)))
        $ms = New-Object System.IO.MemoryStream
        $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $ms.ToArray()
    } finally { $bitmap.Dispose() }
    $hash = Get-ImageHash $png
    $sshMode = Get-SshModeSettings (Get-EffectiveSshConfig $ssh $SshArgs)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # The settings ssh mode uses for this connection, so the test prunes as an upload would.
        $settings = $sshMode
        if ($null -eq $settings) { $settings = @{ Keep = $script:DefaultKeep; Dir = $script:DefaultDir } }
        $argv = Get-UploadSshArguments -Parsed $parsed -Hash $hash -Size $png.Length -SshVersion (Get-SshVersion $ssh) -Keep $settings.Keep -Dir $settings.Dir
        $path = Send-Image -SshPath $ssh -Arguments $argv -Png $png -Hash $hash -Dir $settings.Dir -Class (Get-KeepClass $settings.Keep)
        Report $true (Get-Text 'upload to {0}: {1} ({2:N1} s)' $parsed.Destination $path $timer.Elapsed.TotalSeconds)
    } catch {
        Report $false (Get-Text 'upload to {0}: {1}' $parsed.Destination $_.Exception.Message)
        Write-Host ''
        $failure = Get-SshFailure $_.Exception.Message
        $advice = Get-LoginAdvice $failure $parsed.Destination -Here
        if ($advice) { Write-Host $advice }
        if ($null -ne $failure -and $failure.Kind -ceq 'auth' -and $failure.KeyLogin) {
            Write-Host ''
            $setup = Get-KeySetupTarget $parsed
            foreach ($line in (Get-KeySetupLines $setup.Target)) { Write-Host $line }
            if ($setup.Dropped) { Write-Host (Get-Text '  Add the other ssh options this host needs to the ssh line.') }
        } elseif (-not $advice) {
            Write-Host (Get-Text 'Uploads use a second, non-interactive ssh connection, so the server must')
            Write-Host (Get-Text 'accept your key without a prompt: a key without a passphrase, or a key loaded')
            Write-Host (Get-Text 'in ssh-agent (Get-Service ssh-agent; ssh-add). Password-only logins cannot work.')
        }
        return 1
    }
    if ($null -ne $sshMode) {
        Report $true (Get-Text 'ssh mode: enabled, "ssh {0}" pastes screenshots ({1})' (Join-NativeArguments $SshArgs) (Format-PasteSettings $sshMode))
    } else {
        Write-Host (Get-Text '  info  ssh mode is off for {0}. Turn it on: ssh-paste --enable {0}   (or use: ssh-paste {0})' $parsed.Destination)
    }
    if ($ok) { return 0 } else { return 1 }
}

function Get-InstallDirectory {
    return (Join-Path $env:LOCALAPPDATA 'Programs\ssh-paste')
}

function Test-ScoopInstall {
    # Scoop writes scoop-install.json (install.json before Scoop 0.6) next to the files of
    # each version it installs (<scoop>\apps\ssh-paste\<version>, called through the
    # apps\ssh-paste\current junction). Scoop then owns the files: scoop update and
    # scoop uninstall.
    param([string]$Directory)
    if ([string]::IsNullOrEmpty($Directory)) { return $false }
    foreach ($name in @('scoop-install.json', 'install.json')) {
        if (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf) { return $true }
    }
    return $false
}

function Get-ProxyScriptPath {
    # The ssh-paste.ps1 that --enable writes into the ProxyCommand. Under Scoop it is the one
    # in apps\ssh-paste\current, which scoop update keeps; a version folder goes away with
    # scoop cleanup. Without that junction (Scoop's no_junction setting) no path lasts.
    param([string]$ScriptPath)
    $dir = Split-Path -Parent $ScriptPath
    if (-not (Test-ScoopInstall $dir)) { return $ScriptPath }
    $current = Join-Path (Join-Path (Split-Path -Parent $dir) 'current') 'ssh-paste.ps1'
    if (Test-Path -LiteralPath $current -PathType Leaf) { return $current }
    throw (Get-Text 'Scoop installed ssh-paste without the apps\ssh-paste\current junction (its no_junction setting), so no path to it stays after scoop update. Use wrapper mode instead: ssh-paste HOST')
}

function Remove-UserPathEntry {
    # Edits HKCU\Environment\Path without expanding other entries' %VARS%.
    param([string]$Entry)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) { return $false }
    try {
        if ($key.GetValueNames() -notcontains 'Path') { return $false }
        $kind = $key.GetValueKind('Path')
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kept = @($raw -split ';' | Where-Object { $_.TrimEnd('\') -ine $Entry.TrimEnd('\') })
        $new = ($kept -join ';')
        if ($new -ceq $raw) { return $false }
        if ($new.Trim(';').Length -eq 0) { $key.DeleteValue('Path') } else { $key.SetValue('Path', $new, $kind) }
        return $true
    } finally { $key.Close() }
}

function Send-EnvironmentChange {
    # Setting a variable through .NET broadcasts WM_SETTINGCHANGE, so new Explorer
    # and Windows Terminal windows see the new PATH. The variable is then deleted
    # in the registry: PowerShell 7 passes $null to .NET as an empty string, which
    # .NET keeps instead of deleting. Leftovers from earlier runs are removed too.
    $name = 'ssh_paste_' + [guid]::NewGuid().ToString('N')
    [Environment]::SetEnvironmentVariable($name, '1', 'User')
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) { return }
    try {
        foreach ($value in $key.GetValueNames()) {
            if ($value -cmatch '^ssh_paste_[0-9a-f]{32}\z') { $key.DeleteValue($value, $false) }
        }
    } finally { $key.Close() }
}

function Invoke-Uninstall {
    if ((Get-ManagedBlock (Read-TextFile (Get-SshConfigPath))).Present) {
        [void](Invoke-Disable @())
    }
    $dir = Get-InstallDirectory
    $changedPath = Remove-UserPathEntry $dir
    Send-EnvironmentChange   # also removes values that older versions left behind
    if ($changedPath) { Write-Info (Get-Text 'Removed from your PATH: {0}' $dir) 'Green' }
    if (Test-Path -LiteralPath $dir) {
        Set-Location -LiteralPath $env:USERPROFILE
        [Environment]::CurrentDirectory = $env:USERPROFILE
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-Info (Get-Text 'Deleted {0}' $dir) 'Green'
        $parent = Split-Path -Parent $dir
        if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent -Force }
    }
    Write-Info (Get-Text 'ssh-paste is uninstalled.')
    Write-Info (Get-Text 'Images already uploaded stay in /tmp on your servers until the server clears /tmp.')
    Write-Info (Get-Text 'To delete them now: {0}' 'ssh HOST "rm -f /tmp/ssh-paste-*"')
    return 0
}

function Get-UpdateBase {
    if ($env:SSH_PASTE_UPDATE_URL) { return $env:SSH_PASTE_UPDATE_URL.TrimEnd('/') }
    return 'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download'
}

function Invoke-WebDownload {
    # Bytes of a URL, through the system proxy with the user's credentials. One
    # place for web access, so tests can replace it.
    param([string]$Url)
    $old = [System.Net.ServicePointManager]::SecurityProtocol
    try {
        if ($old -ne 0) { [System.Net.ServicePointManager]::SecurityProtocol = $old -bor [System.Net.SecurityProtocolType]::Tls12 }
        $client = New-Object System.Net.WebClient
        try {
            $client.Headers.Add('User-Agent', 'ssh-paste')
            if ($null -ne $client.Proxy) { $client.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
            return , $client.DownloadData($Url)
        } finally { $client.Dispose() }
    } finally {
        [System.Net.ServicePointManager]::SecurityProtocol = $old
    }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

function Test-ReleaseChecksum {
    # SHA256SUMS lines are "<hex>  <name>"; true when $Name is listed with $Bytes' hash.
    param([string]$Sums, [string]$Name, [byte[]]$Bytes)
    $hash = Get-Sha256Hex $Bytes
    foreach ($line in ($Sums -split "`r?`n")) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$' -and $Matches[2] -ceq $Name) { return ($Matches[1].ToLowerInvariant() -ceq $hash) }
    }
    return $false
}

function Start-Installer {
    # Runs a downloaded install.ps1 in Windows PowerShell on this console and
    # returns its exit code. Its own output goes to the console, not to us.
    # SSH_PASTE_UNINSTALL and SSH_PASTE_REF are for running the installer by
    # hand; an update must not inherit them.
    param([string]$Path)
    $powershell = [System.IO.Path]::Combine([string]$env:SystemRoot, 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi = New-ChildStartInfo -FilePath $powershell -Arguments @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) -RemoveVariables @('SSH_PASTE_UNINSTALL', 'SSH_PASTE_REF')
    $process = [System.Diagnostics.Process]::Start($psi)
    try { $process.WaitForExit(); return $process.ExitCode } finally { $process.Dispose() }
}

function Invoke-Update {
    # ssh-paste --update: run the latest release's install.ps1 after checking it
    # against that release's SHA256SUMS. The installer replaces the files in
    # place and says what changed ("Upgraded", or "Reinstalled" when current).
    param([string[]]$Options)
    if (@($Options).Count -gt 0) { throw (Get-Text '--update takes no options: {0}' (@($Options) -join ' ')) }
    $base = Get-UpdateBase
    Write-Info (Get-Text 'Downloading the latest release from {0}' $base)
    $installer = Invoke-WebDownload ($base + '/install.ps1')
    $sums = [System.Text.Encoding]::ASCII.GetString((Invoke-WebDownload ($base + '/SHA256SUMS')))
    if (-not (Test-ReleaseChecksum $sums 'install.ps1' $installer)) { throw (Get-Text 'install.ps1 does not match SHA256SUMS; nothing was changed') }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-paste-update-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($dir)
    try {
        $file = Join-Path $dir 'install.ps1'
        [System.IO.File]::WriteAllBytes($file, $installer)
        return (Start-Installer $file)
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-Usage {
    return @(
        (Get-Text 'ssh-paste {0} - paste Windows screenshots into programs running over SSH' $script:Version),
        '',
        (Get-Text 'Start:'),
        (Get-Text '    ssh-paste --enable myhost    once per host'),
        (Get-Text '    ssh myhost                   then connect as usual'),
        (Get-Text '    Copy a screenshot (Win+Shift+S), switch to the ssh window, press Ctrl+V:'),
        (Get-Text '    the image goes to the server and its path is pasted. Other apps still'),
        (Get-Text '    paste the image.'),
        '',
        (Get-Text 'Or without changing ~/.ssh/config:'),
        '    ssh-paste myhost',
        '',
        (Get-Text 'All commands:'),
        (Get-Text '  ssh-paste --enable [OPTIONS] HOST...    make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)'),
        (Get-Text '  ssh-paste --disable [HOST...]           undo --enable (all hosts if none given)'),
        (Get-Text '  ssh-paste [OPTIONS] [ssh options] HOST  wrapper mode: ssh with screenshot paste, no config'),
        (Get-Text '  ssh-paste --doctor [HOST]               check this computer and test an upload to HOST'),
        (Get-Text '  ssh-paste --update                      install the latest release'),
        (Get-Text '  ssh-paste --uninstall                   remove ssh-paste and everything it changed'),
        '  ssh-paste --version | --help',
        '',
        (Get-Text 'OPTIONS (images on the server; per host for --enable):'),
        (Get-Text '  --keep TIME   delete them when older than TIME: 30m, 2h, 7d (default 1d), or never'),
        (Get-Text '  --dir DIR     keep them in DIR: /tmp (default), any /path, or ~/path (quote the ~)'),
        '',
        'https://github.com/xuing/ssh-please-paste-picture'
    ) -join [Environment]::NewLine
}

function Invoke-WrapperWithSettings {
    # ssh-paste [--keep TIME] [--dir DIR] [ssh options] HOST
    param([string[]]$Argv)
    $settings = Read-PasteSettings $Argv
    if (@($settings.Rest).Count -eq 0) { throw (Get-Text 'usage: ssh-paste [--keep TIME] [--dir DIR] [ssh options] HOST') }
    return (Invoke-Wrapper @($settings.Rest) -Settings $settings)
}

function Invoke-Main {
    param([string[]]$Argv)
    if ($null -eq $Argv) { $Argv = @() }
    $Argv = @($Argv | ForEach-Object { [string]$_ })
    if ($Argv.Count -eq 0) { Write-Host (Get-Usage); return 0 }
    $rest = @()
    if ($Argv.Count -gt 1) { $rest = @($Argv[1..($Argv.Count - 1)]) }
    switch -CaseSensitive ($Argv[0]) {
        '--proxy' {
            if ($rest.Count -lt 3) { [Console]::Error.WriteLine((Get-Text 'ssh-paste: --proxy needs %h %p %n')); return 2 }
            # A bad --keep or --dir must not stop the connection: it only turns paste off.
            $settings = $null
            $settingsError = $null
            try {
                $settings = Read-PasteSettings @($rest | Select-Object -Skip 3)
                if (@($settings.Rest).Count -gt 0) { throw (Get-Text 'unknown --proxy arguments: {0}' (@($settings.Rest) -join ' ')) }
            } catch { $settingsError = $_.Exception.Message }
            return (Invoke-Proxy $rest[0] $rest[1] $rest[2] -Settings $settings -SettingsError $settingsError)
        }
        '--enable' { return (Invoke-Enable $rest) }
        '--disable' { return (Invoke-Disable $rest) }
        '--doctor' { return (Invoke-Doctor $rest) }
        '--update' {
            if (Test-ScoopInstall $PSScriptRoot) { [Console]::Error.WriteLine((Get-Text 'ssh-paste was installed with Scoop. Update it with: scoop update ssh-paste')); return 1 }
            return (Invoke-Update $rest)
        }
        '--uninstall' {
            if (Test-ScoopInstall $PSScriptRoot) { [Console]::Error.WriteLine((Get-Text 'ssh-paste was installed with Scoop. Remove it with: scoop uninstall ssh-paste (it also runs ssh-paste --disable)')); return 1 }
            return (Invoke-Uninstall)
        }
        '--keep' { return (Invoke-WrapperWithSettings $Argv) }
        '--dir' { return (Invoke-WrapperWithSettings $Argv) }
        '--version' { Write-Host $script:Version; return 0 }
        '--help' { Write-Host (Get-Usage); return 0 }
        '-h' { Write-Host (Get-Usage); return 0 }
        default { return (Invoke-Wrapper $Argv) }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $code = 1
    try {
        Initialize-Language
        $code = Invoke-Main $args
    } catch {
        [Console]::Error.WriteLine((Get-Text 'ssh-paste: {0}' $_.Exception.Message))
        $code = 1
    }
    exit $code
}
