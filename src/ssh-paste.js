// ssh-paste for macOS - paste screenshots into programs running over SSH.
//
//   ssh mode      ssh-paste --enable myhost     then use plain `ssh myhost`
//   wrapper mode  ssh-paste myhost              same arguments as ssh
//
// While connected, copy a screenshot (Cmd+Ctrl+Shift+4) or image files in Finder,
// return to the terminal window and press Cmd+V: the image is uploaded to /tmp on
// the server and its path is pasted.
//
// One JavaScript for Automation file, run by `osascript -l JavaScript` (macOS ships
// it). The zsh launcher src/ssh-paste-mac (installed as `ssh-paste`) starts it.
// This file is the macOS twin of src/ssh-paste.ps1: the same commands, the same
// server script and the same watcher rules. The pure functions near the top use no
// macOS API; node loads this file through module.exports to test them on any OS.
// Keep this file ASCII. https://github.com/xuing/ssh-please-paste-picture

'use strict';

var VERSION = '0.0.0-dev';
var MARKER_TYPE = 'com.github.xuing.ssh-paste.owner';
var BLOCK_BEGIN = '# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>';
var BLOCK_END = '# <<< ssh-paste <<<';
var BLOCK_CREATED_FILE = '# ssh-paste created this file; it is deleted when the last host is disabled.';
// The UTF-8 byte order mark read as ISO-8859-1 (three characters).
var UTF8_BOM_LATIN1 = String.fromCharCode(0xEF, 0xBB, 0xBF);
var MAX_IMAGE_BYTES = 64 * 1024 * 1024;
var IMAGE_EXTENSIONS = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
var MAX_COPIED_FILES = 20;
var RETRY_FAILED_SECONDS = 30;
var UPLOAD_CACHE_HOURS = 6;
// --keep and --dir (ssh-paste --enable, wrapper mode): how long the server keeps your
// images, and in which folder. The defaults are what ssh-paste always did.
var DEFAULT_KEEP = '1d';
var DEFAULT_DIR = '/tmp';
var PROMISE_WAIT_SECONDS = 30;
var TICK_SECONDS = 0.25;
var UPDATE_BASE = 'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download';

// Runs on the server through `sh -c`, with $1 = content hash (32 hex digits, made
// by us), $2 = byte count, $3 = file extension, $4 = minutes to keep this class of
// images (0: keep them), $5 = the absolute folder (/tmp when absent) and $6 = the class (k7d- in ssh-paste-k7d-<hash>.png; empty for --keep 1d). The same text as $script:RemoteScript in src/ssh-paste.ps1 (which says more);
// a test fails when the two differ.
var REMOTE_SCRIPT = 'umask 077; set -fC; n=$2; e=${3:-png}; k=${4:-1440}; d=${5:-/tmp}; c=${6:-}; u=$(id -u); a=[A-Za-z0-9]; h=[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]; ' +
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
    'if mv -f $t $f 2> /dev/null && [ -f $f ]; then echo $n $f; exit 0; fi; done; rm -f $t; exit 1';

// ssh(1) getopt string, from ssh.c: letters without and with an argument.
var SSH_FLAGS_NO_ARG = '1246ACGKMNTVXYZafgknqstvxy';
var SSH_FLAGS_WITH_ARG = 'BDEFIJLOPQRSWbceilmopw';
// Options that identify the server and its credentials; kept for the upload connection.
var SSH_KEEP_NO_ARG = '46C';
var SSH_KEEP_WITH_ARG = 'BFIJbcilmopP';
// `-o` settings from the user that would break or redirect the upload connection.
var SSH_DROP_OPTIONS = ['requesttty', 'remotecommand', 'localcommand', 'permitlocalcommand', 'localforward',
    'remoteforward', 'dynamicforward', 'clearallforwardings', 'controlmaster', 'controlpath', 'controlpersist',
    'forwardx11', 'forwardx11trusted', 'forwardx11timeout', 'forwardagent', 'tunnel', 'tunneldevice', 'batchmode',
    'stdinnull', 'sessiontype', 'forkafterauthentication', 'exitonforwardfailure', 'gatewayports', 'escapechar',
    'loglevel', 'proxyusefdpass', 'enableescapecommandline', 'permitremoteopen', 'streamlocalbindunlink'];

// TERM_PROGRAM values of terminals whose bundle id is known, for when the process
// tree does not lead to the terminal app (tmux, a terminal that starts shells
// through a helper). SSH_PASTE_TERMINAL=<bundle id> overrides everything.
var TERM_PROGRAM_BUNDLES = {
    'Apple_Terminal': 'com.apple.Terminal',
    'iTerm.app': 'com.googlecode.iterm2',
    'WezTerm': 'com.github.wez.wezterm',
    'ghostty': 'com.mitchellh.ghostty',
    'vscode': 'com.microsoft.VSCode'
};

// ---------------------------------------------------------------------------
// Pure helpers (no macOS API; covered by the node tests on any OS)
// ---------------------------------------------------------------------------

function splitSshArguments(argv) {
    // Mirrors ssh's own parsing: options may appear before and after the
    // destination; the first non-option after the destination starts the command.
    // Each option remembers which side of the destination it was on, because ssh
    // applies the destination's user@ and :port between the two option passes.
    var options = [];
    var destination = null;
    var command = [];
    var i = 0;
    argv = argv || [];
    while (i < argv.length) {
        var token = String(argv[i]);
        if (token === '--') {
            i++;
            if (destination === null && i < argv.length) { destination = String(argv[i]); i++; }
            if (i < argv.length) command = argv.slice(i).map(String);
            break;
        }
        if (token.length > 1 && token[0] === '-') {
            var after = (destination !== null);
            var j = 1;
            while (j < token.length) {
                var letter = token[j];
                if (SSH_FLAGS_NO_ARG.indexOf(letter) >= 0) {
                    options.push({ Flag: letter, Value: null, After: after });
                    j++;
                } else if (SSH_FLAGS_WITH_ARG.indexOf(letter) >= 0) {
                    var value;
                    if (j + 1 < token.length) {
                        value = token.substring(j + 1);
                    } else {
                        i++;
                        if (i >= argv.length) throw new Error('ssh option -' + letter + ' needs an argument');
                        value = String(argv[i]);
                    }
                    options.push({ Flag: letter, Value: value, After: after });
                    j = token.length;
                } else {
                    throw new Error('unknown ssh option -' + letter);
                }
            }
            i++;
            continue;
        }
        if (destination === null) { destination = token; i++; continue; }
        command = argv.slice(i).map(String);
        break;
    }
    return { Options: options, Destination: destination, Command: command };
}

function sshOptionKey(value) {
    return String(value).replace(/^\s+/, '').split(/[=\s]/)[0].trim().toLowerCase();
}

function sshOptionValue(value) {
    // The part after the first run of '=' and white space, as `-split '[=\s]+', 2`.
    var s = String(value).replace(/^\s+/, '');
    var m = /[=\s]+/.exec(s);
    return (m ? s.substring(m.index + m[0].length) : s).trim().toLowerCase();
}

function destinationHost(destination) {
    // The host part of an ssh destination, as ssh expands it for %n: the text
    // after the last @, or the host of an ssh:// URI (whose trailing dot ssh drops).
    var d = String(destination);
    var m = /^ssh:\/\/(?:[^\/]*@)?(\[[^\]]*\]|[^:\/]*)/.exec(d);
    if (m) return m[1].replace(/^\[(.*)\]$/, '$1').replace(/\.$/, '');
    return d.replace(/^.*@/, '');
}

function testInteractiveSsh(parsed, effective) {
    // Only interactive sessions get the clipboard watcher. scp/sftp/git, VS Code
    // Remote-SSH (-T), port forwards (-N), stdio forwards (-W) stay plain relays.
    // effective is the `ssh -G` output for the same arguments, when available:
    // it adds what ~/.ssh/config sets (RequestTTY, SessionType, RemoteCommand).
    if (!parsed || !parsed.Destination) return false;
    var tty = null;
    var hasCommand = parsed.Command.length > 0;
    for (var k = 0; k < parsed.Options.length; k++) {
        var o = parsed.Options[k];
        if (['N', 'W', 'f', 's', 'G', 'V', 'O', 'Q', 'n'].indexOf(o.Flag) >= 0) return false;
        if (o.Flag === 't' || o.Flag === 'T') tty = o.Flag;   // the last one wins, as in ssh
        if (o.Flag === 'o') {
            var key = sshOptionKey(o.Value);
            var value = sshOptionValue(o.Value);
            if (key === 'sessiontype' && value !== 'default') return false;
            if (key === 'stdinnull' && value === 'yes') return false;
            if (key === 'requesttty') {
                if (value === 'no' || value === 'false') tty = 'T';
                else if (value === 'yes' || value === 'true' || value === 'force') tty = 't';
            }
            if (key === 'remotecommand' && value !== 'none') hasCommand = true;
        }
    }
    if (effective) {
        var get = function (name) { return Object.prototype.hasOwnProperty.call(effective, name) ? String(effective[name]).toLowerCase() : null; };
        var st = get('sessiontype');
        if (st !== null && st !== 'default') return false;
        if (get('stdinnull') === 'yes') return false;
        var rt = get('requesttty');
        if (rt === 'no' || rt === 'false') tty = 'T';
        else if (rt === 'yes' || rt === 'true' || rt === 'force') tty = 't';
        var rc = get('remotecommand');
        if (rc !== null && rc !== 'none') hasCommand = true;
    }
    if (tty === 'T') return false;
    if (hasCommand && tty !== 't') return false;
    return true;
}

function parseSshG(text) {
    // `ssh -G` prints "key value" lines; keys are lowercase. The first one wins.
    var map = {};
    String(text || '').split(/\r?\n/).forEach(function (line) {
        var m = /^(\S+)\s+(.*)$/.exec(line);
        if (m) {
            var key = m[1].toLowerCase();
            if (!Object.prototype.hasOwnProperty.call(map, key)) map[key] = m[2];
        }
    });
    return map;
}

function parseSshVersion(text) {
    // [major, minor] from `ssh -V`, or null.
    var m = /OpenSSH[A-Za-z_]*_(\d+)\.(\d+)/.exec(String(text || ''));
    return m ? [Number(m[1]), Number(m[2])] : null;
}

function uploadSshArguments(parsed, hash, size, opts) {
    // Arguments for the separate, non-interactive upload connection: those of
    // serverSshArguments, then the upload command.
    opts = opts || {};
    var ext = opts.ext || 'png';
    if (!/^[0-9a-f]{32}$/.test(String(hash))) throw new Error('bad image hash: ' + hash);
    if (IMAGE_EXTENSIONS.indexOf(ext) < 0) throw new Error('bad image extension: ' + ext);
    var keep = opts.keep || DEFAULT_KEEP;
    var keepMinutes = keepMinutesOf(keep);
    var folder = opts.dir || DEFAULT_DIR;
    if (!testServerDirectory(folder) || folder.charAt(0) === '~') throw new Error('bad --dir: ' + folder);
    var argv = serverSshArguments(parsed, opts);
    argv.push(uploadCommand(hash, size, ext, keep, keepMinutes, folder));
    return argv;
}

function uploadCommand(hash, size, ext, keep, keepMinutes, folder) {
    // The command the server runs for one upload. The folder in single quotes, as the
    // remote login shell reads the command.
    var command = "sh -c '" + REMOTE_SCRIPT + "' ssh-paste " + hash + ' ' + size + ' ' + ext + ' ' + keepMinutes + " '" + folder + "'";
    var cls = keepClass(keep);
    return cls ? command + ' ' + cls : command;
}

// Wrapper mode on macOS makes the session itself the ControlMaster of a private socket,
// so uploads open a channel on the connection the user already logged in to: a server
// that asks for a password or a code asks once, as always (kitty's kitten ssh does the
// same). The mux client needs no config (-F none): it sends its command over the socket,
// not the destination, so the host is a fixed name; ProxyCommand=/usr/bin/false makes it
// fail at once instead of opening a new connection when the master is gone.
var MUX_HOST = 'ssh-paste-mux';

function muxSshArguments(socket) {
    if (!/^\/[A-Za-z0-9._\/-]+$/.test(String(socket))) throw new Error('bad control socket: ' + socket);
    return ['-F', 'none', '-T', '-x', '-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=' + socket,
        '-o', 'ProxyCommand=/usr/bin/false', '-o', 'RequestTTY=no', '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes',
        '-o', 'LogLevel=ERROR', MUX_HOST];
}

function muxUploadArguments(socket, hash, size, opts) {
    // uploadSshArguments for an upload through the session's own connection.
    opts = opts || {};
    var ext = opts.ext || 'png';
    if (!/^[0-9a-f]{32}$/.test(String(hash))) throw new Error('bad image hash: ' + hash);
    if (IMAGE_EXTENSIONS.indexOf(ext) < 0) throw new Error('bad image extension: ' + ext);
    var keep = opts.keep || DEFAULT_KEEP;
    var folder = opts.dir || DEFAULT_DIR;
    if (!testServerDirectory(folder) || folder.charAt(0) === '~') throw new Error('bad --dir: ' + folder);
    return muxSshArguments(socket).concat([uploadCommand(hash, size, ext, keep, keepMinutesOf(keep), folder)]);
}

function muxEligible(parsed, effective) {
    // Whether the session may become the master of our private socket: the user has no
    // multiplexing of their own for it (on the command line or in the config ssh -G shows),
    // and ssh -G was read. Anything else keeps today's separate connections.
    if (!parsed || !effective || effective.controlmaster === undefined) return false;
    var mine = ['controlmaster', 'controlpath', 'controlpersist', 'forkafterauthentication'];
    for (var i = 0; i < parsed.Options.length; i++) {
        var o = parsed.Options[i];
        if (o.Flag === 'M' || o.Flag === 'S' || o.Flag === 'O' || o.Flag === 'f') return false;
        if (o.Flag === 'o' && mine.indexOf(sshOptionKey(o.Value)) >= 0) return false;
    }
    if (String(effective.controlmaster).toLowerCase() !== 'false' && String(effective.controlmaster).toLowerCase() !== 'no') return false;
    if (effective.controlpath !== undefined && String(effective.controlpath).toLowerCase() !== 'none') return false;
    if (effective.controlpersist !== undefined && String(effective.controlpersist).toLowerCase() !== 'no') return false;
    if (effective.forkafterauthentication !== undefined && String(effective.forkafterauthentication).toLowerCase() !== 'no') return false;
    return true;
}

function serverSshArguments(parsed, opts) {
    // Arguments for a separate, non-interactive connection to the server of the session
    // (uploads, and the home folder for --dir ~/...), up to the destination and its
    // options; the caller adds the command. Our options come first because ssh uses the
    // first value it sees for each option; the user's options keep their place before or
    // after the destination.
    opts = opts || {};
    var argv = ['-T', '-x',
        '-o', 'BatchMode=yes', '-o', 'PermitLocalCommand=no', '-o', 'ClearAllForwardings=yes',
        '-o', 'RemoteCommand=none', '-o', 'RequestTTY=no', '-o', 'ForwardAgent=no',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', '-o', 'LogLevel=ERROR'];
    var v = opts.sshVersion;
    if (v && (v[0] > 8 || (v[0] === 8 && v[1] >= 7))) {
        // Options that ~/.ssh/config could otherwise set; unknown to older ssh.
        argv.push('-o', 'StdinNull=no', '-o', 'SessionType=default', '-o', 'ForkAfterAuthentication=no');
    }
    if (opts.noProxy) argv.push('-o', 'ProxyCommand=none');
    if (opts.pin) {
        // ssh mode: reach the host the session's relay reached, and check the
        // host key under the name the session used.
        argv.push('-o', 'HostName=' + opts.pin.HostName, '-o', 'Port=' + opts.pin.Port,
            '-o', 'HostKeyAlias=' + opts.pin.HostKeyAlias, '-o', 'CheckHostIP=no', '-o', 'CanonicalizeHostname=no');
    }
    var before = [];
    var after = [];
    parsed.Options.forEach(function (o) {
        var target = o.After ? after : before;
        if (o.Value === null) {
            if (SSH_KEEP_NO_ARG.indexOf(o.Flag) >= 0) target.push('-' + o.Flag);
            return;
        }
        if (SSH_KEEP_WITH_ARG.indexOf(o.Flag) < 0) return;
        if (opts.noProxy && o.Flag === 'J') return;
        if (o.Flag === 'o') {
            var key = sshOptionKey(o.Value);
            if (SSH_DROP_OPTIONS.indexOf(key) >= 0) return;
            if (opts.noProxy && (key === 'proxycommand' || key === 'proxyjump')) return;
        }
        target.push('-' + o.Flag, String(o.Value));
    });
    return argv.concat(before, [String(parsed.Destination)], after);
}

function absoluteDirectory(dir, home) {
    // --dir with ~ made absolute with the home folder on the server; any other --dir as it is.
    if (dir.charAt(0) !== '~') return dir;
    var abs = String(home).replace(/\/+$/, '') + dir.substring(1);
    if (abs.charAt(0) !== '/' || !testServerDirectory(abs)) {
        throw new Error('the home folder on the server (' + home + ') makes ' + abs + ', which --dir cannot use; give an absolute --dir');
    }
    return abs;
}

function testServerLogin(ssh, parsed, noProxy) {
    // Test-ServerLogin: one connection as an upload makes (no prompt): home when it logs in,
    // else error, what ssh said. --enable runs it once for each host it names, with noProxy
    // as ssh mode's uploads connect (not through the relay of an older block).
    var r;
    try {
        r = runCapture(ssh, serverSshArguments(parsed, { sshVersion: sshVersionOf(ssh), noProxy: !!noProxy }).concat(['echo $HOME']), 30);
    } catch (e) { return { home: null, error: e.message }; }
    var lines = String(r.out || '').split(/\r?\n/).filter(function (l) { return l.trim().length > 0; });
    var line = lines.length > 0 ? lines[lines.length - 1].trim() : '';
    if (r.code === 0 && line.charAt(0) === '/') return { home: line, error: null };
    var err = String(r.err || '').trim();
    return { home: null, error: err ? 'ssh exited with ' + r.code + ': ' + err : 'ssh exited with ' + r.code + ', and the server sent no home folder' };
}

function serverHome(ssh, parsed) {
    // The home folder on the server, for --dir ~/... in wrapper mode.
    var login = testServerLogin(ssh, parsed);
    if (login.home === null) throw new Error(homeError(parsed.Destination, login.error));
    return login.home;
}

function homeError(host, errorText) {
    return 'cannot ask ' + host + ' for its home folder (' + loginReport(host, errorText) + '); give an absolute --dir';
}

function sshFailure(text) {
    // Get-SshFailure: what an ssh error says. kind auth (methods as ssh lists them; keyLogin:
    // a key would do; typed: every method needs a person to type), toomany, hostkey,
    // network, or null. Only ssh's own list of method names counts.
    text = String(text || '');
    // ssh exits 255 for its own errors; another status is the remote command's, whatever it said.
    var st = /^ssh exited with (\d+):/.exec(text);
    if (st && st[1] !== '255') return null;
    var m = /Permission denied \(([a-z][a-z0-9@.-]*(,[a-z][a-z0-9@.-]*)*)\)\./.exec(text);
    if (m) {
        var methods = m[1].split(',');
        var typed = methods.every(function (x) { return x === 'password' || x === 'keyboard-interactive'; });
        return { kind: 'auth', methods: methods, keyLogin: methods.indexOf('publickey') >= 0, typed: typed };
    }
    if (/Too many authentication failures/.test(text)) return { kind: 'toomany' };
    if (/Session open refused by peer|mux_client_request_session: session request failed/.test(text)) return { kind: 'muxrefused' };
    if (/Host key verification failed/.test(text)) return { kind: 'hostkey' };
    if (/Could not resolve hostname|Connection refused|Connection timed out|No route to host|Network is unreachable|Operation timed out/.test(text)) return { kind: 'network' };
    return null;
}

function failureFinal(f) {
    // Test-FailureFinal: trying again in this session cannot help: the server takes only
    // methods that a person types. Anything else may change while the session runs.
    return !!f && ((f.kind === 'auth' && f.typed) || f.kind === 'muxrefused');
}

function loginAdvice(f, host, here) {
    // Get-LoginAdvice: one line on why uploads to host cannot log in, or null. here: the key
    // commands follow, so the pointer to --doctor is left out.
    if (!f) return null;
    if (f.kind === 'auth' && f.keyLogin) return host + ' did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add' + (here ? '' : '; ssh-paste --doctor ' + host + ' shows how');
    if (f.kind === 'auth' && f.typed) return host + ' wants a password or a one-time code (' + f.methods.join(',') + '), which uploads cannot type, so ssh-paste cannot upload to it';
    if (f.kind === 'toomany') return host + ' closed the login after too many keys were tried: name the right key for it with IdentityFile and IdentitiesOnly yes in ~/.ssh/config';
    if (f.kind === 'muxrefused') return host + ' refused a second session on this connection, so uploads cannot share it; with a key, ssh-paste -S none ' + host + ' uploads over new connections';
    if (f.kind === 'hostkey') return 'ssh could not verify the host key of ' + host + ': run ssh ' + host + ' to see why (a new host asks you to accept its key)';
    return null;
}

function loginReport(host, errorText) {
    // Get-LoginReport: the line --enable prints about a host.
    if (!errorText) return host + ': uploads log in without a password';
    var advice = loginAdvice(sshFailure(errorText), host);
    if (advice) return advice;
    var first = String(errorText).split(/\r?\n/).filter(function (l) { return l.trim().length > 0; })[0] || '';
    return 'could not check the login to ' + host + ' now (' + first.trim() + '); ssh-paste --doctor ' + host + ' tests it';
}

function formatShellWords(words) {
    // Format-ShellWords: words as a command line to type again in zsh.
    return words.map(function (w) { return /^[A-Za-z0-9._@%+=:,\/-]+$/.test(w) ? w : "'" + w.replace(/'/g, "'\\''") + "'"; }).join(' ');
}

// On a Mac, wrapper mode pastes where uploads cannot log in on their own: they share the
// connection the user logged in to (see muxEligible).
var WRAPPER_HINT = '  Or paste there without a key: ssh-paste HOST (wrapper mode) shares the connection you log in to.';

function enableRefusal(host, errorText, wrapperCan) {
    // Get-EnableRefusal: what --enable says instead of enabling host, whose uploads were
    // refused; null when the check logged in or could not tell (then the host is enabled).
    var f = sshFailure(errorText);
    if (!f || (f.kind !== 'auth' && f.kind !== 'toomany')) return null;
    var advice = loginAdvice(f, host, true);
    if (!advice) {
        var first = String(errorText).split(/\r?\n/).filter(function (l) { return l.trim().length > 0; })[0] || '';
        advice = host + ' refused the login for uploads (' + first.trim() + ')';
    }
    var lines = [advice];
    if (f.kind === 'auth' && f.keyLogin) lines = lines.concat(keySetupLines(host));
    if (f.kind === 'auth' && wrapperCan) lines.push(WRAPPER_HINT.replace(/HOST/g, formatShellWords([host])));
    return lines;
}

function keySetupTarget(parsed) {
    // Get-KeySetupTarget: [-p PORT] [USER@]HOST from the --doctor arguments, which ssh and
    // ssh-copy-id both read alike; dropped says other options were left out.
    var user = null, port = null, dropped = false;
    parsed.Options.forEach(function (o) {
        if (o.Flag === 'l') { if (user === null) user = o.Value; }
        else if (o.Flag === 'p') { if (port === null) port = o.Value; }
        else dropped = true;
    });
    var target = parsed.Destination;
    if (user !== null && target.indexOf('@') < 0 && target.indexOf('ssh://') !== 0) target = user + '@' + target;
    if (port !== null) target = '-p ' + port + ' ' + target;
    return { Target: target, Dropped: dropped };
}

function keySetupLines(hostArgs) {
    // The commands that set up a key, as --doctor prints them (Get-KeySetupLines is the
    // Windows twin). macOS has ssh-copy-id; a key with a passphrase works through ssh-agent.
    return [
        '  Set up a key (once; ssh-copy-id asks your password one last time):',
        '    ssh-keygen -t ed25519',
        '    ssh-copy-id -i ~/.ssh/id_ed25519.pub ' + hostArgs,
        '    ssh-paste --doctor ' + hostArgs,
        '  ssh-keygen: press Enter at each question; if the key file exists already, answer n.',
        '  With a passphrase, also run: ssh-add --apple-use-keychain ~/.ssh/id_ed25519',
        '  If you log in with ssh -i KEY, or ~/.ssh/config names an IdentityFile for this host,',
        '  use that key instead, and name it with IdentityFile in the Host entry.'
    ];
}

function readUploadReply(output, expectedSize, hash, ext, dir, cls) {
    // The last non-empty line of the reply is "<size> <path>".
    ext = ext || 'png';
    dir = dir || DEFAULT_DIR;
    cls = cls || '';
    var lines = String(output === null || output === undefined ? '' : output).split(/\r?\n/).filter(function (l) { return l.trim().length > 0; });
    if (lines.length === 0) throw new Error('the server sent no reply (is sh available there?)');
    var last = lines[lines.length - 1].trim();
    var m = /^short (\d+)$/.exec(last);
    if (m) throw new Error('the server received ' + m[1] + ' of ' + expectedSize + ' bytes');
    if (last === 'nodir') throw new Error('the server cannot write to the folder ' + dir + ' (--dir)');
    if (last === 'notprivate') throw new Error('the folder ' + dir + ' on the server is not yours alone (owned by you, not a link, not writable by group or others); use /tmp or such a folder');
    m = /^(\d+) (\/\S+)$/.exec(last);
    if (!m) throw new Error('unexpected reply from the server: ' + last);
    var size = Number(m[1]);
    var path = m[2];
    if (size !== Number(expectedSize)) throw new Error('size mismatch: sent ' + expectedSize + ' bytes, server has ' + size);
    if (!new RegExp(replyPathPattern(dir, hash, ext, cls)).test(path)) throw new Error('unexpected path from the server: ' + path);
    return path;
}

function uploadOutcome(r) {
    // What one upload ended with, as Send-Image reports it: { path } or { error }.
    // r: code, out, err (texts), timedOut, timeoutSeconds, size, hash, ext.
    var err = String(r.err || '').trim();
    if (r.timedOut) {
        var tail = err.split(/\r?\n/).slice(-12).join(' | ');
        return { error: 'ssh did not finish in ' + r.timeoutSeconds + ' seconds; ssh said: ' + tail };
    }
    if (r.code !== 0) {
        if (err.length === 0) {
            // The server's own word, e.g. "short 120", when ssh says nothing.
            var lines = String(r.out || '').split(/\r?\n/).filter(function (l) { return l.trim().length > 0; });
            if (lines.length > 0) err = lines[lines.length - 1].trim();
        }
        if (err.length === 0) err = 'no error message';
        return { error: 'ssh exited with ' + r.code + ': ' + err };
    }
    try {
        return { path: readUploadReply(r.out, r.size, r.hash, r.ext, r.dir, r.cls) };
    } catch (e) {
        return { error: e.message };
    }
}

function regexEscape(text) {
    return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function replyPathPattern(dir, hash, ext, cls) {
    // The paths the server may answer for this image: <folder>/ssh-paste-<class><hash>[-<uid>].<ext>,
    // in exactly the --dir folder.
    return '^' + regexEscape(dir) + '/ssh-paste-' + regexEscape(cls || '') + hash + '(-[0-9]+)?\\.' + ext + '$';
}

function keepClass(keep) {
    // The part of the file name that says which --keep made it: empty for the default
    // (the names of every earlier release), else k<keep>- such as k7d- or knever-.
    return (!keep || keep === DEFAULT_KEEP) ? '' : 'k' + keep + '-';
}

function keepMinutesOf(keep) {
    // --keep: 30m, 2h, 7d, or never (0: the server keeps every image). From 10 minutes
    // (a path must stay good for a while after the paste; the cache, half of it, then
    // outlasts the longest upload, 5 minutes) to 3650 days.
    if (keep === 'never') return 0;
    var m = /^([1-9][0-9]{0,6})([mhd])$/.exec(String(keep));
    if (!m) throw new Error('--keep takes a time like 30m, 2h or 7d, or never: ' + keep);
    var minutes = Number(m[1]) * (m[2] === 'h' ? 60 : m[2] === 'd' ? 1440 : 1);
    if (minutes < 10) throw new Error('--keep is at least 10m: ' + keep);
    if (minutes > 5256000) throw new Error('--keep is at most 3650d: ' + keep);
    return minutes;
}

function testServerDirectory(dir) {
    // --dir: a folder on the server, absolute or under ~ (the home folder there): names of
    // letters, digits and . _ - only, none of them . or .., no // and no / at the end.
    if (typeof dir !== 'string' || dir.length === 0 || dir.length > 200) return false;
    return /^(~|~?(\/(?!\.\.?(\/|$))[A-Za-z0-9._-]+)+)$/.test(dir);
}

function readPasteSettings(argv) {
    // The leading --keep TIME and --dir DIR (each at most once) of --enable, wrapper mode
    // and --proxy: Keep and Dir (null when not given) and the arguments after them.
    var r = { Keep: null, Dir: null, Rest: [] };
    var i = 0;
    while (i < argv.length && (argv[i] === '--keep' || argv[i] === '--dir')) {
        var name = argv[i];
        if (i + 1 >= argv.length) throw new Error(name + ' needs a value');
        var value = String(argv[i + 1]);
        if (name === '--keep') {
            if (r.Keep !== null) throw new Error('--keep is given twice');
            keepMinutesOf(value);
            r.Keep = value;
        } else {
            if (r.Dir !== null) throw new Error('--dir is given twice');
            if (value.length > 1) value = value.replace(/\/+$/, '') || '/';
            if (!testServerDirectory(value)) {
                throw new Error('--dir takes a folder on the server, /... or ~/... (quote ~ so that your shell keeps it), with letters, digits and . _ - / only: ' + value);
            }
            r.Dir = value;
        }
        i += 2;
    }
    r.Rest = argv.slice(i);
    return r;
}

function proxySettings(proxyCommand) {
    // --keep and --dir of a ProxyCommand line that --enable wrote (the defaults when absent).
    // Only the words after --proxy count: a path before it may hold anything.
    var s = { Keep: DEFAULT_KEEP, Dir: DEFAULT_DIR };
    var text = String(proxyCommand || '');
    var at = text.lastIndexOf(' --proxy ');
    if (at < 0) return s;
    var tail = text.substring(at);
    var m = / --keep '?([^' ]+)'?/.exec(tail);
    if (m) s.Keep = m[1];
    m = / --dir '?([^' ]+)'?/.exec(tail);
    if (m) s.Dir = m[1];
    return s;
}

function formatPasteSettings(s) {
    return 'images in ' + s.Dir + ' on the server, ' + (s.Keep === 'never' ? 'never deleted' : 'kept ' + s.Keep);
}

function uploadCacheHours(keepMinutes) {
    // How long a path is pasted again without a new upload. The server may delete the file
    // once it is keepMinutes old, so this stays well under that.
    if (!(keepMinutes > 0)) return UPLOAD_CACHE_HOURS;
    return Math.min(UPLOAD_CACHE_HOURS, keepMinutes / 120);
}

function testHostAlias(name) {
    // A Host alias as written in ~/.ssh/config: no user@, no option-like dash.
    return /^[A-Za-z0-9_\[][A-Za-z0-9._:\[\]-]*$/.test(String(name));
}

function imageFileExtension(path) {
    // The lowercase extension when the path names an image type we upload, else null.
    var base = String(path).replace(/^.*\//, '');
    var dot = base.lastIndexOf('.');
    if (dot <= 0) return null;
    var ext = base.substring(dot + 1).toLowerCase();
    return IMAGE_EXTENSIONS.indexOf(ext) >= 0 ? ext : null;
}

function proxyCommandLine(launcher, keep, dir) {
    // The ProxyCommand that --enable writes. ssh runs it as `$SHELL -c "exec ..."`
    // under the user's login shell, so it is one absolute path in single quotes
    // (POSIX quoting, the same in sh, bash and zsh) and three ssh tokens. ssh
    // expands % before the shell sees the line, so % in the path is doubled.
    if (!/^\//.test(launcher)) throw new Error('the ssh-paste command path is not absolute: ' + launcher);
    if (/[\r\n]/.test(launcher)) throw new Error('the ssh-paste command path contains a line break');
    var quoted = "'" + launcher.replace(/%/g, '%%').replace(/'/g, "'\\''") + "'";
    // %h and %n are quoted: a Host alias may contain [ and ], which zsh would
    // take for a file pattern. ssh refuses quotes in a host name.
    // --keep and --dir only when they are not the defaults, so a block from an older release
    // reads the same; in single quotes, so the shell keeps a ~ for the server.
    var line = quoted + " --proxy '%h' %p '%n'";
    if (keep && keep !== DEFAULT_KEEP) line += " --keep '" + keep + "'";
    if (dir && dir !== DEFAULT_DIR) line += " --dir '" + dir + "'";
    return line;
}

function getManagedBlock(configText) {
    // Our block: its groups (each a Host line with its ProxyCommand; hosts with the same
    // --keep and --dir share one), all their hosts, and the "created the file" flag.
    var info = { Hosts: [], Groups: [], ProxyCommand: null, CreatedFile: false, Present: false };
    if (!configText) return info;
    var inBlock = false;
    var current = null;
    configText.split(/\r?\n/).forEach(function (line) {
        if (line === BLOCK_BEGIN) { inBlock = true; info.Present = true; return; }
        if (line === BLOCK_END) { inBlock = false; return; }
        if (!inBlock) return;
        if (line === BLOCK_CREATED_FILE) { info.CreatedFile = true; return; }
        var m = /^Host\s+(.+)$/i.exec(line);
        if (m) {
            var hosts = m[1].trim().split(/\s+/).filter(function (h) { return h !== '*'; });
            current = null;
            if (hosts.length > 0) { current = { Hosts: hosts, ProxyCommand: null }; info.Groups.push(current); }
            return;
        }
        m = /^\s+ProxyCommand\s+(.+)$/i.exec(line);
        if (m && current && current.ProxyCommand === null) current.ProxyCommand = m[1].trim();
    });
    info.Groups.forEach(function (g) { info.Hosts = info.Hosts.concat(g.Hosts); });
    if (info.Groups.length > 0) info.ProxyCommand = info.Groups[0].ProxyCommand;
    return info;
}

function settingsGroups(want, launcher) {
    // Hosts (in order) with the same settings share one Host line and ProxyCommand.
    // want: [[host, { Keep, Dir }], ...].
    var groups = [];
    var index = {};
    want.forEach(function (pair) {
        var s = pair[1];
        var key = s.Keep + ' ' + s.Dir;
        if (!Object.prototype.hasOwnProperty.call(index, key)) {
            index[key] = groups.length;
            groups.push({ Hosts: [], ProxyCommand: proxyCommandLine(launcher, s.Keep, s.Dir) });
        }
        groups[index[key]].Hosts.push(pair[0]);
    });
    return groups;
}

function setManagedBlock(configText, hosts, proxyCommand, createdFile, groups) {
    // Returns the config text with our block removed and, if a group has hosts, a
    // fresh block put first (ssh uses the first value it finds): one Host line and
    // ProxyCommand per group. The trailing "Host *" keeps any global options that
    // follow in effect for every host. hosts and proxyCommand make one group.
    if (!groups) groups = [{ Hosts: hosts || [], ProxyCommand: proxyCommand }];
    configText = configText || '';
    var newline = configText.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
    var kept = [];
    var inBlock = false;
    var lines = configText.length > 0 ? configText.split(/\r?\n/) : [];
    lines.forEach(function (line) {
        if (line === BLOCK_BEGIN) { inBlock = true; return; }
        if (inBlock) {
            if (line === BLOCK_END) inBlock = false;
            return;
        }
        kept.push(line);
    });
    if (inBlock) throw new Error('the ssh-paste block in the ssh config has no end marker; fix it by hand');
    var rest = kept.join(newline);
    var used = groups.filter(function (g) { return g && g.Hosts && g.Hosts.length > 0; });
    if (used.length === 0) return rest;
    var block = [BLOCK_BEGIN];
    if (createdFile) block.push(BLOCK_CREATED_FILE);
    used.forEach(function (g) { block.push('Host ' + g.Hosts.join(' '), '    ProxyCommand ' + g.ProxyCommand, '    ProxyUseFdpass no'); });
    block.push('Host *', BLOCK_END);
    var text = block.join(newline);
    if (rest.length === 0) return text + newline;
    return text + newline + rest;
}

function checkReleaseChecksum(sums, name, hex) {
    // SHA256SUMS lines are "<hex>  <name>"; true when name is listed with this hash.
    var lines = String(sums || '').split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var m = /^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$/.exec(lines[i]);
        if (m && m[2] === name) return m[1].toLowerCase() === String(hex).toLowerCase();
    }
    return false;
}

function parseShasum(output) {
    // The 64 hex digits that `shasum -a 256 FILE` prints first, or null.
    var m = /^([0-9a-f]{64})\s/.exec(String(output || ''));
    return m ? m[1] : null;
}

function makeMarker(owner, token, text, files) {
    // The private pasteboard type on our entries: the window it was written for
    // (0 for none), this session's token, the text and the copied files.
    return JSON.stringify({ owner: owner, token: token, text: text || '', files: files || null });
}

function parseMarker(text) {
    // The marker's fields, or null when the text is not one of our markers.
    var m;
    try { m = JSON.parse(String(text)); } catch (e) { return null; }
    if (!m || typeof m !== 'object') return null;
    if (typeof m.owner !== 'number' || !(m.owner >= 0) || Math.floor(m.owner) !== m.owner) return null;
    if (typeof m.token !== 'string' || !/^[0-9a-f]{16}$/.test(m.token)) return null;
    if (typeof m.text !== 'string') return null;
    var files = null;
    if (m.files !== null && m.files !== undefined) {
        if (!Array.isArray(m.files) || m.files.length === 0 || m.files.length > MAX_COPIED_FILES) return null;
        for (var i = 0; i < m.files.length; i++) if (typeof m.files[i] !== 'string' || m.files[i].charAt(0) !== '/') return null;
        files = m.files.slice();
    }
    return { owner: m.owner, token: m.token, text: m.text, files: files };
}

function splitPsArgs(text) {
    // `ps -o args=` joins argv with spaces, so this split is only exact for
    // arguments without white space. A wrong split makes the session look
    // non-interactive or the upload fail; it never sends the image elsewhere,
    // because ssh mode pins the host name, port and host key alias.
    return String(text || '').trim().split(/\s+/).filter(function (s) { return s.length > 0; });
}

function parseProcessTable(text) {
    // `ps -axo pid=,ppid=` -> { pid: ppid }.
    var map = {};
    String(text || '').split(/\r?\n/).forEach(function (line) {
        var m = /^\s*(\d+)\s+(\d+)\s*$/.exec(line);
        if (m) map[Number(m[1])] = Number(m[2]);
    });
    return map;
}

function terminalFromEnvironment(env) {
    // The bundle id of the terminal app this session runs in, from the
    // environment: SSH_PASTE_TERMINAL wins, then what macOS sets for apps
    // (__CFBundleIdentifier), then TERM_PROGRAM. null when nothing says.
    if (env.SSH_PASTE_TERMINAL) return { bundle: env.SSH_PASTE_TERMINAL, from: 'SSH_PASTE_TERMINAL' };
    if (env.__CFBundleIdentifier) return { bundle: env.__CFBundleIdentifier, from: '__CFBundleIdentifier' };
    if (env.TERM_PROGRAM && Object.prototype.hasOwnProperty.call(TERM_PROGRAM_BUNDLES, env.TERM_PROGRAM)) {
        return { bundle: TERM_PROGRAM_BUNDLES[env.TERM_PROGRAM], from: 'TERM_PROGRAM=' + env.TERM_PROGRAM };
    }
    return null;
}

function crc32(bytes) {
    var c, crc = 0xFFFFFFFF;
    for (var n = 0; n < bytes.length; n++) {
        c = (crc ^ bytes[n]) & 0xFF;
        for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        crc = (crc >>> 8) ^ c;
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
}

function doctorPng(note) {
    // A 1x1 PNG with a tEXt chunk that holds note, so each --doctor run uploads
    // a new file. Returns the bytes as an array of numbers.
    var base = [137, 80, 78, 71, 13, 10, 26, 10,
        0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137,
        0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 240, 31, 0, 5, 0, 1, 255, 137, 153, 61, 29];
    var iend = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
    var data = [];
    var text = 'Comment\u0000' + note;
    for (var i = 0; i < text.length; i++) data.push(text.charCodeAt(i) & 0xFF);
    var type = [116, 69, 88, 116];
    var len = data.length;
    var chunk = [(len >>> 24) & 255, (len >>> 16) & 255, (len >>> 8) & 255, len & 255].concat(type, data);
    var crc = crc32(type.concat(data));
    chunk.push((crc >>> 24) & 255, (crc >>> 16) & 255, (crc >>> 8) & 255, crc & 255);
    return base.concat(chunk, iend);
}

function retryDelaySeconds(count) {
    // A failed upload is retried after 30 s, 1 min, 2 min, ... at most 30 min.
    return Math.min(1800, RETRY_FAILED_SECONDS * Math.pow(2, count - 1));
}

function usage() {
    return [
        'ssh-paste ' + VERSION + ' - paste macOS screenshots into programs running over SSH',
        '',
        'Start:',
        '    ssh-paste --enable myhost    once per host',
        '    ssh myhost                   then connect as usual',
        '    Copy a screenshot (Cmd+Ctrl+Shift+4) or image files in Finder, switch to',
        '    the ssh window, press Cmd+V: the image goes to the server and its path is',
        '    pasted. Other apps still paste the image.',
        '',
        'Or without changing ~/.ssh/config:',
        '    ssh-paste myhost',
        '',
        'All commands:',
        '  ssh-paste --enable [OPTIONS] HOST...    make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)',
        '  ssh-paste --disable [HOST...]           undo --enable (all hosts if none given)',
        '  ssh-paste [OPTIONS] [ssh options] HOST  wrapper mode: ssh with screenshot paste, no config',
        '  ssh-paste --doctor [HOST]               check this computer and test an upload to HOST',
        '  ssh-paste --update                      install the latest release',
        '  ssh-paste --uninstall                   remove ssh-paste and everything it changed',
        '  ssh-paste --version | --help',
        '',
        'OPTIONS (images on the server; per host for --enable):',
        '  --keep TIME   delete them when older than TIME: 30m, 2h, 7d (default 1d), or never',
        '  --dir DIR     keep them in DIR: /tmp (default), any /path, or ~/path (quote the ~)',
        '',
        'https://github.com/xuing/ssh-please-paste-picture'
    ].join('\n');
}

// ---------------------------------------------------------------------------
// Clipboard watcher (one tick every 250 ms while the session runs)
//
// The same decisions as Invoke-WatcherTick in src/ssh-paste.ps1, written against
// a platform object P so that node tests can run them on a simulated pasteboard:
//   P.now()                 milliseconds
//   P.foreground()          number of the window in front (the front app's first
//                           window), 0 when there is none
//   P.changeCount()         the pasteboard's change count
//   P.readState()           one snapshot of the pasteboard (see macReadState)
//   P.publish(entry)        write our entry; throws when the pasteboard moved past
//                           entry.basis, so a newer copy is never erased
//   P.completePromise(text) give a paste waiting for the promised text this path,
//                           or nothing (null)
//   P.canAnswer(text)       the pasteboard holds our entry with this text and a
//                           paste of it gets the text
//   P.startUpload(ssh, argv, item, timeoutSeconds, dir, cls) -> handle (throws when ssh
//                           cannot start)
//   P.finishUpload(handle)  undefined while it runs, then { path } or { error }
//   P.beep(), P.log(text)
// One difference from Windows: an upload runs as a child process, so a tick that
// starts one returns and later ticks finish it (W.Inflight). Until then the
// watcher does nothing else, as the Windows watcher does while Send-Image runs.
// ---------------------------------------------------------------------------

function newWatcher(P, o) {
    var s = o.settings || {};
    var keep = s.Keep || DEFAULT_KEEP;
    var dir = s.Dir || DEFAULT_DIR;
    if (!testServerDirectory(dir) || dir.charAt(0) === '~') throw new Error('bad --dir: ' + dir);
    var minutes = keepMinutesOf(keep);
    return {
        P: P, SshPath: o.sshPath, SshVersion: o.sshVersion || null, Parsed: o.parsed, NoProxy: !!o.noProxy, Pin: o.pin || null,
        Keep: keep, KeepMinutes: minutes, Class: keepClass(keep), Dir: dir, CacheHours: uploadCacheHours(minutes),
        Window: o.window, Token: o.token, Debug: !!o.debug,
        LastSeq: -1, LastForeground: 0, State: null, WakeAt: Infinity, Uploaded: {}, Failed: {}, Blocked: null, Inflight: null,
        Mux: o.mux ? { Socket: o.mux.socket, Ready: false, NextCheck: 0, HomeDir: o.mux.homeDir || null } : null
    };
}

function stateItems(state) {
    return state.Items || [];
}

function setWakeAt(W, at) {
    if (at < W.WakeAt) W.WakeAt = at;
}

function cacheMs(W) {
    return (W.CacheHours === undefined ? UPLOAD_CACHE_HOURS : W.CacheHours) * 3600000;
}

function expectedText(W, state) {
    // The text Cmd+V should paste, known before the upload: each file is named
    // after its content. An earlier upload's real path wins (it can carry a
    // per-user suffix when another user on the server owns the plain name).
    var now = W.P.now();
    return stateItems(state).map(function (item) {
        var done = W.Uploaded[item.Hash];
        if (done && now - done.At < cacheMs(W)) return done.Path;
        return (W.Dir || DEFAULT_DIR) + '/ssh-paste-' + (W.Class || '') + item.Hash + '.' + item.Ext;
    }).join(' ');
}

function uploadFailing(W, state) {
    if (W.Blocked) return true;
    return stateItems(state).some(function (item) { return Object.prototype.hasOwnProperty.call(W.Failed, item.Hash); });
}

function muxReady(W) {
    // Whether the session's connection can carry uploads yet, checked at most every half
    // second. The first time it can, the folder for --dir ~/... is read through it, and
    // the pasteboard is looked at again, so an image copied before the login counts.
    var P = W.P;
    var now = P.now();
    if (now < W.Mux.NextCheck) return false;
    W.Mux.NextCheck = now + 500;
    if (!P.muxCheck(W.Mux.Socket)) return false;
    if (W.Mux.HomeDir) {
        try {
            W.Dir = absoluteDirectory(W.Mux.HomeDir, P.muxHome(W.Mux.Socket));
        } catch (e) {
            // A server that refuses the extra channel refuses uploads too: say that, not "give a path".
            var f = sshFailure(e.message);
            W.Blocked = f && f.kind === 'muxrefused' ? loginAdvice(f, W.Parsed.Destination)
                : 'cannot ask ' + W.Parsed.Destination + ' for its home folder (' + e.message + '); give an absolute --dir';
        }
        W.Mux.HomeDir = null;
    }
    W.Mux.Ready = true;
    W.LastSeq = -1;
    W.LastForeground = 0;
    P.log('the session shares its connection for uploads: ' + W.Mux.Socket);
    return true;
}

function uploadedItemPath(W, item, since) {
    // Upload once per file. A failed upload is retried after 30 s, 1 min, 2 min
    // and so on (beeping only the first time). An upload is redone after a few
    // hours so the server's day-old cleanup never removes a path we paste.
    // An upload that ended at or after since (the start of this batch) counts for
    // the batch at any age, so each file is uploaded at most once per batch, as in
    // one pass of Get-UploadedPath, even when the batch outlasts the cache.
    // Returns the path, null, or { Pending } when an upload was started.
    // After a failure that trying again cannot fix, this session uploads nothing more.
    if (W.Blocked) return null;
    var P = W.P;
    var now = P.now();
    var done = W.Uploaded[item.Hash];
    if (done && ((since !== undefined && done.At >= since) || now - done.At < cacheMs(W))) {
        setWakeAt(W, done.At + cacheMs(W));
        return done.Path;
    }
    var failed = W.Failed[item.Hash];
    if (failed) {
        var retryAt = failed.At + retryDelaySeconds(failed.Count) * 1000;
        if (now < retryAt) { setWakeAt(W, retryAt); return null; }
    }
    var pending = { Item: item, At: now, Handle: null };
    try {
        var uploadOpts = { noProxy: W.NoProxy, sshVersion: W.SshVersion, pin: W.Pin, ext: item.Ext, keep: W.Keep || DEFAULT_KEEP, dir: W.Dir || DEFAULT_DIR };
        var argv = W.Mux ? muxUploadArguments(W.Mux.Socket, item.Hash, item.Size, uploadOpts) : uploadSshArguments(W.Parsed, item.Hash, item.Size, uploadOpts);
        if (W.Debug) {
            // -v makes ssh say on stderr how far it got; LogLevel=ERROR is ours, so
            // drop it together with its -o (a lone -o would take the next option as
            // its value, and ssh refuses the command line).
            var i = argv.indexOf('LogLevel=ERROR');
            argv = ['-v'].concat(argv.slice(0, i - 1), argv.slice(i + 1));
            P.log('upload command: ssh ' + argv.slice(0, -1).join(' ') + ' <sh -c script>');
        }
        // 30 s plus 1 s per 256 KB, at most 5 minutes: big images on slow links need longer.
        var timeout = Math.min(300, 30 + Math.ceil(item.Size / 262144));
        pending.Handle = P.startUpload(W.SshPath, argv, item, timeout, W.Dir || DEFAULT_DIR, W.Class || '');
        return { Pending: pending };
    } catch (e) {
        recordUpload(W, pending, { error: e.message });
        return null;
    }
}

function recordUpload(W, pending, outcome) {
    var P = W.P;
    var hash = pending.Item.Hash;
    if (outcome.path) {
        // The cache counts from the end of the upload: a slow upload is not stale at once.
        var doneAt = P.now();
        W.Uploaded[hash] = { Path: outcome.path, At: doneAt };
        delete W.Failed[hash];
        setWakeAt(W, doneAt + cacheMs(W));
        return;
    }
    var failed = W.Failed[hash];
    var count = failed ? failed.Count + 1 : 1;
    var now = P.now();
    W.Failed[hash] = { Message: outcome.error, At: now, Count: count };
    P.log('upload failed (' + count + 'x, ' + pending.Item.Size + ' bytes): ' + outcome.error);
    var failure = sshFailure(outcome.error);
    if (failureFinal(failure)) {
        W.Blocked = loginAdvice(failure, W.Parsed.Destination);
        P.log('no more uploads in this session: ' + W.Blocked);
    }
    setWakeAt(W, now + retryDelaySeconds(count) * 1000);
    if (count === 1) { try { P.beep(); } catch (e) { /* no sound is fine */ } }
}

function uploadedPath(W, state, since) {
    // The text to paste for this pasteboard state: the remote path of the image,
    // or the paths of all copied image files separated by spaces. null until
    // every one is uploaded; { Pending } while an upload runs.
    W.WakeAt = Infinity;
    var paths = [];
    var items = stateItems(state);
    for (var i = 0; i < items.length; i++) {
        var r = uploadedItemPath(W, items[i], since);
        if (r !== null && typeof r === 'object') return r;
        if (r === null) return null;
        paths.push(r);
    }
    return paths.join(' ');
}

function advanceInflight(W) {
    // Moves the upload of the current tick on. True once the path (or null) is
    // known and a promised text has been answered with it; false while an upload
    // runs. The pasteboard provider calls this too, while a paste waits.
    var f = W.Inflight;
    if (!f) return true;
    while (!f.Ready) {
        if (f.Pending) {
            var outcome = W.P.finishUpload(f.Pending.Handle);
            if (outcome === undefined) return false;
            recordUpload(W, f.Pending, outcome);
            f.Pending = null;
        }
        var r = uploadedPath(W, f.State, f.Since);
        if (r !== null && typeof r === 'object') { f.Pending = r.Pending; continue; }
        f.Path = r;
        f.Ready = true;
        W.P.log('upload result: ' + r);
    }
    if (f.Wrote && !f.Completed) {
        f.Completed = true;
        W.P.completePromise(f.Path !== null && f.Path === f.Expected ? f.Path : null);
    }
    return true;
}

function finishInflight(W) {
    // The rest of the tick that started the upload, with what it saw then.
    var f = W.Inflight;
    W.Inflight = null;
    if (f.Path === null) {
        // The upload failed: take the path back so Cmd+V does not paste a missing file.
        syncClipboardText(W, f.State.Hash, null, f.Foreground);
        W.LastSeq = -1;
        return;
    }
    if (f.Path !== f.Expected || !(f.Wrote || f.Shown || f.OtherSession)) {
        syncClipboardText(W, f.State.Hash, f.Path, f.Foreground);
        W.LastSeq = -1;
    }
}

function syncClipboardText(W, hash, text, foreground) {
    // Re-reads the pasteboard and, if it still holds the same image, makes its
    // text `text` (or removes our text when text is null). Leaves alone what the
    // user copied since, and an entry another session in this window wrote.
    var P = W.P;
    var cur = P.readState();
    if (cur.Hash !== hash) return;
    var ours = cur.Owner !== null;
    var owner;
    if (text) {
        if (!ours && (cur.HasText || (cur.HasFiles && !cur.Files))) return;
        if (ours && cur.HasText && cur.Text === text && cur.Token === W.Token && P.canAnswer(text)) return;
        if (ours && cur.HasText && cur.Owner === foreground && cur.Token !== W.Token) return;
        owner = foreground;
    } else {
        if (!(ours && cur.HasText && cur.Token === W.Token)) return;
        owner = 0;
    }
    if (P.changeCount() !== cur.Seq || P.foreground() !== foreground) return;
    P.publish({ state: cur, text: text || null, owner: owner, token: W.Token, promise: false, basis: cur.Seq });
}

function watcherTick(W) {
    // Copy a screenshot, come back to this terminal window: upload it once and
    // put "image + remote path" on the pasteboard, so the terminal pastes the
    // path. Leave for another app: put the plain image back. The marker records
    // the window and the session that wrote an entry, so sessions do not undo
    // each other: one in another window yields to the window in front, and one
    // in the same window leaves an entry alone that already carries a usable path.
    var P = W.P;
    if (W.Inflight) {
        if (!advanceInflight(W)) return;
        finishInflight(W);
        return;
    }
    // Sharing the session's connection: nothing to do until the user has logged in.
    if (W.Mux && !W.Mux.Ready && !muxReady(W)) return;
    var fg = P.foreground();
    if (!fg) return;
    var seq = P.changeCount();
    if (seq !== W.LastSeq) {
        W.State = P.readState();
        W.LastSeq = W.State.Seq;
    } else if (fg === W.LastForeground && P.now() < W.WakeAt) {
        return;
    }
    W.LastForeground = fg;
    W.WakeAt = Infinity;
    var state = W.State;
    if (W.Debug) P.log('tick: foreground=' + fg + ' terminal=' + (fg === W.Window) + ' ' + formatWatchState(W, state));
    if (!state.Png && !state.Files) return;
    var ours = state.Owner !== null;
    // An app copied text along with the image, or files that are not all images: leave it alone.
    if (!ours && (state.HasText || (state.HasFiles && !state.Files))) return;

    if (fg === W.Window) {
        // Put the expected path on the pasteboard first, then upload: a Cmd+V
        // pressed during the upload already pastes the path, not a local one.
        var expected = expectedText(W, state);
        var otherSession = ours && state.HasText && state.Owner === fg && state.Token !== W.Token;
        // Already shown: this session's entry carries the path and a paste still gets it.
        var shown = ours && state.HasText && state.Text === expected && state.Token === W.Token && P.canAnswer(expected);
        var wrote = false;
        if (!shown && !otherSession && !uploadFailing(W, state)) {
            if (P.changeCount() !== state.Seq || P.foreground() !== fg) { W.LastSeq = -1; return; }
            // Promise the path: a paste during the upload waits for it (delayed rendering).
            P.publish({ state: state, text: expected, owner: fg, token: W.Token, promise: true, basis: state.Seq });
            W.LastSeq = -1;
            wrote = true;
            P.log('promised the path before the upload: ' + expected);
        }
        W.Inflight = { State: state, Expected: expected, Wrote: wrote, Shown: shown, OtherSession: otherSession, Foreground: fg,
            Pending: null, Ready: false, Path: null, Completed: false, Since: P.now() };
        if (!advanceInflight(W)) return;
        finishInflight(W);
        return;
    }
    if (!(ours && state.HasText && state.Owner !== fg)) return;
    // Another window is in front: put the plain image back. Write only if
    // nothing changed since the snapshot.
    if (P.changeCount() !== state.Seq || P.foreground() !== fg) { W.LastSeq = -1; return; }
    P.publish({ state: state, text: null, owner: 0, token: W.Token, promise: false, basis: state.Seq });
    W.LastSeq = -1;   // read our own write back on the next tick
}

function watcherStep(W) {
    // One tick of the watch loop. A tick that fails (the pasteboard changed
    // under a write) reads the pasteboard again on the next one.
    try { watcherTick(W); } catch (e) {
        W.LastSeq = -1;
        W.P.log('tick error: ' + (e && e.message ? e.message : e));
    }
}

function restoreClipboard(W) {
    // On exit, put the plain image back if the pasteboard still holds the path
    // this session wrote. Another session's entry is left alone.
    var P = W.P;
    try {
        var s = P.readState();
        if ((s.Png || s.Files) && s.Owner !== null && s.HasText && s.Token === W.Token && P.changeCount() === s.Seq) {
            P.publish({ state: s, text: null, owner: 0, token: W.Token, promise: false, basis: s.Seq });
        }
    } catch (e) { /* the session is over either way */ }
}

function failureSummary(W) {
    if (!W) return null;
    if (W.Blocked) return 'ssh-paste: screenshot paste was off for this session: ' + W.Blocked;
    var keys = Object.keys(W.Failed);
    if (keys.length === 0) return null;
    var last = keys.map(function (k) { return W.Failed[k]; }).sort(function (a, b) { return a.At - b.At; })[keys.length - 1];
    var advice = loginAdvice(sshFailure(last.Message), W.Parsed.Destination);
    return 'ssh-paste: ' + keys.length + ' screenshot upload(s) failed: ' + (advice || last.Message);
}

function formatWatchState(W, s) {
    if (!s) return 'no state';
    var kind = 'none';
    if (s.Files) kind = 'files(' + s.Files.length + ')';
    else if (s.Png) kind = 'image(' + (stateItems(s)[0] ? stateItems(s)[0].Size : '?') + ' bytes)';
    var owner = 'app';
    if (s.Owner !== null) owner = 'ours(window ' + s.Owner + ', mine=' + (s.Token === W.Token) + ')';
    return 'seq=' + s.Seq + ' ' + kind + ' text=' + s.HasText + ' files=' + s.HasFiles + ' by=' + owner + ' pasteText=' + s.Text;
}

// ---------------------------------------------------------------------------
// macOS integration (JXA: the Objective-C bridge of osascript)
// ---------------------------------------------------------------------------

var mac = null;   // set by initMac()

function initMac() {
    if (mac) return mac;
    ObjC.import('Foundation');
    ObjC.import('AppKit');
    ObjC.import('CoreGraphics');
    ObjC.import('stdlib');
    ObjC.bindFunction('getppid', ['int', []]);
    ObjC.bindFunction('kill', ['int', ['int', 'int']]);
    mac = { work: null, taskCount: 0 };
    return mac;
}

function env(name) {
    var v = $.NSProcessInfo.processInfo.environment.objectForKey(name);
    return v.isNil() ? '' : ObjC.unwrap(v);
}

function writeTo(fd, text) {
    try {
        var h = fd === 1 ? $.NSFileHandle.fileHandleWithStandardOutput : $.NSFileHandle.fileHandleWithStandardError;
        h.writeData($(text + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
    } catch (e) { /* a closed stdout or stderr is not our problem */ }
}

function say(text) { writeTo(1, text); }
function warn(text) { writeTo(2, text); }

function debugLog(text) {
    // With SSH_PASTE_DEBUG=1, the watcher logs what it sees and decides to
    // $TMPDIR/ssh-paste-debug.log (the terminal shows the ssh session).
    if (!env('SSH_PASTE_DEBUG')) return;
    try {
        var path = $.NSTemporaryDirectory().js + 'ssh-paste-debug.log';
        var fm = $.NSFileManager.defaultManager;
        if (!fm.fileExistsAtPath(path)) fm.createFileAtPathContentsAttributes(path, $.NSData.data, $({ NSFilePosixPermissions: 384 }));
        var h = $.NSFileHandle.fileHandleForWritingAtPath(path);
        if (h.isNil()) return;
        h.seekToEndOfFile;
        var d = $.NSDate.date;
        var f = $.NSDateFormatter.alloc.init;
        f.dateFormat = 'HH:mm:ss.SSS';
        h.writeData($(f.stringFromDate(d).js + ' [' + $.NSProcessInfo.processInfo.processIdentifier + '] ' + text + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
        h.closeFile;
    } catch (e) { /* logging never breaks the watcher */ }
}

function nowMs() {
    return Math.round($.NSDate.date.timeIntervalSince1970 * 1000);
}

function sleepSeconds(s) {
    // Only outside the watch loop, or for a few milliseconds while a child runs:
    // a sleeping main thread serves no paste and sees no window change.
    $.NSThread.sleepForTimeInterval(s);
}

function spinRunLoop(seconds) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(seconds));
}

function privateDirectory() {
    // A folder only this user can read, for the image bytes an upload sends and
    // for the output of the programs we run. Deleted when ssh-paste exits.
    var m = initMac();
    if (m.work) return m.work;
    var base = $.NSTemporaryDirectory().js;
    var fm = $.NSFileManager.defaultManager;
    for (var i = 0; i < 10; i++) {
        var path = base + 'ssh-paste.' + $.NSProcessInfo.processInfo.processIdentifier + '.' + randomHex(8);
        if (fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, false, $({ NSFilePosixPermissions: 448 }), null)) {
            m.work = path;
            return path;
        }
    }
    throw new Error('could not create a private folder in ' + base);
}

function removePrivateDirectory() {
    if (mac && mac.work) {
        $.NSFileManager.defaultManager.removeItemAtPathError(mac.work, null);
        mac.work = null;
    }
}

function randomHex(n) {
    var hex = '';
    while (hex.length < n) hex += $.NSUUID.UUID.UUIDString.js.replace(/-/g, '').toLowerCase().substring(12, 28);
    return hex.substring(0, n);
}

function readFileText(path) {
    // The text of a file, as UTF-8 or else ISO-8859-1 (output of ssh, which can
    // carry any bytes from a login banner). '' when the file cannot be read.
    var d = $.NSData.dataWithContentsOfFile(path);
    if (d.isNil()) return '';
    var s = $.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding);
    if (s.isNil()) s = $.NSString.alloc.initWithDataEncoding(d, $.NSISOLatin1StringEncoding);
    return s.isNil() ? '' : s.js;
}

function newOutputFile(name) {
    var path = privateDirectory() + '/' + name;
    $.NSFileManager.defaultManager.createFileAtPathContentsAttributes(path, $.NSData.data, $({ NSFilePosixPermissions: 384 }));
    return path;
}

function startTask(path, args, o) {
    // Starts a program directly (no shell). Its stdout and stderr go to files
    // in the private folder unless o.inherit; stdin is o.stdinFile or nothing.
    o = o || {};
    var m = initMac();
    var n = ++m.taskCount;
    var t = $.NSTask.alloc.init;
    t.setLaunchPath(path);
    t.setArguments($(args));
    if (o.env) t.setEnvironment($(o.env));
    var h = { task: t, out: null, err: null, handles: [] };
    if (!o.inherit) {
        var input = o.stdinFile ? $.NSFileHandle.fileHandleForReadingAtPath(o.stdinFile) : $.NSFileHandle.fileHandleWithNullDevice;
        if (input.isNil()) throw new Error('cannot read ' + o.stdinFile);
        h.out = newOutputFile('task' + n + '.out');
        h.err = newOutputFile('task' + n + '.err');
        var out = $.NSFileHandle.fileHandleForWritingAtPath(h.out);
        var err = $.NSFileHandle.fileHandleForWritingAtPath(h.err);
        t.setStandardInput(input);
        t.setStandardOutput(out);
        t.setStandardError(err);
        h.handles = [input, out, err];
    }
    try {
        t.launch;
    } catch (e) {
        finishTask(h);
        throw new Error('could not start ' + path + ': ' + e.message);
    }
    return h;
}

function finishTask(h) {
    // Exit code, stdout and stderr of a program that ended; removes its files.
    h.handles.forEach(function (x) { try { x.closeFile; } catch (e) { /* closed already */ } });
    var r = { code: -1, out: '', err: '' };
    try { r.code = Number(h.task.terminationStatus); } catch (e) { /* it never started */ }
    var fm = $.NSFileManager.defaultManager;
    if (h.out) { r.out = readFileText(h.out); fm.removeItemAtPathError(h.out, null); }
    if (h.err) { r.err = readFileText(h.err); fm.removeItemAtPathError(h.err, null); }
    return r;
}

function stopTask(h) {
    if (!h.task.isRunning) return;
    h.task.terminate;
    for (var i = 0; i < 300 && h.task.isRunning; i++) sleepSeconds(0.01);
    if (h.task.isRunning) $.kill(Number(h.task.processIdentifier), 9);
    for (var j = 0; j < 300 && h.task.isRunning; j++) sleepSeconds(0.01);
}

function runCapture(path, args, timeoutSeconds, o) {
    // Runs a program to its end and returns { code, out, err }. It waits with
    // short sleeps, not the run loop, so no pasteboard request is served halfway
    // through a watcher tick.
    var h = startTask(path, args, o);
    var deadline = nowMs() + (timeoutSeconds || 20) * 1000;
    while (h.task.isRunning) {
        if (nowMs() > deadline) {
            stopTask(h);
            finishTask(h);
            throw new Error(path + ' did not finish in ' + (timeoutSeconds || 20) + ' seconds');
        }
        sleepSeconds(0.005);
    }
    return finishTask(h);
}

function findInPath(name) {
    var dirs = env('PATH').split(':');
    var fm = $.NSFileManager.defaultManager;
    for (var i = 0; i < dirs.length; i++) {
        if (!dirs[i]) continue;
        var p = dirs[i].replace(/\/+$/, '') + '/' + name;
        if (fm.isExecutableFileAtPath(p)) return p;
    }
    return null;
}

function sshPath() {
    var configured = env('SSH_PASTE_SSH');
    if (configured) return configured;
    return findInPath('ssh') || '/usr/bin/ssh';
}

function sshVersionOf(path) {
    try {
        var r = runCapture(path, ['-V'], 20);
        return parseSshVersion(r.err + ' ' + r.out);
    } catch (e) { return null; }
}

function effectiveSshConfig(path, args) {
    // `ssh -G` with the session's own arguments: what ssh will really use.
    // null if it cannot be read; callers then fall back to the arguments alone.
    try {
        var r = runCapture(path, ['-G'].concat(args), 20);
        if (r.code === 0) return parseSshG(r.out);
    } catch (e) { /* unknown */ }
    return null;
}

function sshModeSettings(effective) {
    // Get-SshModeSettings: ssh mode's --keep and --dir for a connection, read from the
    // ProxyCommand that ssh -G says ssh will run; null when that is not ssh-paste's relay.
    // ssh's own reading counts, not our block: -F, Include and an earlier Host win there.
    var proxy = effective && effective.proxycommand ? String(effective.proxycommand) : '';
    if (!/ssh-paste/.test(proxy) || proxy.indexOf(' --proxy ') < 0) return null;
    return proxySettings(proxy);
}

// --- windows and the terminal ----------------------------------------------

function firstWindowOf(pid) {
    // The number of the front-most normal window (layer 0) of a process, 0 when
    // it has none on screen. CGWindowListCopyWindowInfo lists windows front to
    // back, and needs no Screen Recording permission for numbers and owners.
    var list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0));
    if (list.isNil()) return 0;
    var n = Number(list.count);
    for (var i = 0; i < n; i++) {
        var d = list.objectAtIndex(i);
        if (Number(ObjC.unwrap(d.objectForKey('kCGWindowOwnerPID'))) !== pid) continue;
        if (Number(ObjC.unwrap(d.objectForKey('kCGWindowLayer'))) !== 0) continue;
        return Number(ObjC.unwrap(d.objectForKey('kCGWindowNumber')));
    }
    return 0;
}

function frontWindow() {
    var app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
    if (app.isNil()) return 0;
    return firstWindowOf(Number(app.processIdentifier));
}

function findTerminal(startPid) {
    // The terminal app that runs this session: SSH_PASTE_TERMINAL, else the first
    // GUI app among the ancestors of startPid, else the app the environment names.
    // Returns { pid, bundle, from } or throws with the reason.
    var named = terminalFromEnvironment({ SSH_PASTE_TERMINAL: env('SSH_PASTE_TERMINAL') });
    if (!named) {
        var r = runCapture('/bin/ps', ['-axo', 'pid=,ppid='], 20);
        var parents = parseProcessTable(r.out);
        var pid = startPid;
        for (var n = 0; n < 64 && pid > 1; n++) {
            var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
            if (!app.isNil() && Number(app.activationPolicy) === 0 && !app.bundleIdentifier.isNil()) {
                return { pid: pid, bundle: app.bundleIdentifier.js, from: 'process tree' };
            }
            if (!Object.prototype.hasOwnProperty.call(parents, pid)) break;
            pid = parents[pid];
        }
        named = terminalFromEnvironment({ __CFBundleIdentifier: env('__CFBundleIdentifier'), TERM_PROGRAM: env('TERM_PROGRAM') });
    }
    if (!named) throw new Error('cannot tell which terminal app runs this session; set SSH_PASTE_TERMINAL to its bundle id');
    var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(named.bundle);
    if (apps.isNil() || Number(apps.count) === 0) throw new Error('the terminal app ' + named.bundle + ' (from ' + named.from + ') is not running');
    return { pid: Number(apps.objectAtIndex(0).processIdentifier), bundle: named.bundle, from: named.from };
}

// --- the pasteboard ---------------------------------------------------------

function pasteboard() {
    return $.NSPasteboard.generalPasteboard;
}

function macPlatform(sessionDebug) {
    // The P object of the watcher for the real pasteboard, windows and ssh.
    var pb = pasteboard();
    var work = privateDirectory();
    var memo = [];          // recently hashed image bytes: { data, hash, file, size }
    var keep = {};          // files an upload still reads
    var rec = null;         // the promise of our current entry
    var P = { watcher: null };

    function hashData(data) {
        var size = Number(data.length);
        for (var i = 0; i < memo.length; i++) {
            if (memo[i].size === size && memo[i].data.isEqualToData(data)) {
                // Most recently used first, so eviction never takes a file of the copy being read.
                var hit = memo.splice(i, 1)[0];
                memo.unshift(hit);
                return hit;
            }
        }
        var tmp = work + '/hash.tmp';
        if (!data.writeToFileAtomically(tmp, true)) throw new Error('could not write ' + tmp);
        var r = runCapture('/usr/bin/shasum', ['-a', '256', tmp], 60);
        var hex = parseShasum(r.out);
        if (!hex) throw new Error('shasum failed: ' + r.err.trim());
        var entry = { data: data, hash: hex.substring(0, 32), size: size, file: work + '/' + hex.substring(0, 32) };
        var fm = $.NSFileManager.defaultManager;
        fm.removeItemAtPathError(entry.file, null);
        if (!fm.moveItemAtPathToPathError(tmp, entry.file, null)) throw new Error('could not keep ' + entry.file);
        memo.unshift(entry);
        // Keep every file of one copy (up to MAX_COPIED_FILES) plus a few recent
        // images: an upload reads the file of each item it has not started yet.
        while (memo.length > MAX_COPIED_FILES + 8) {
            var old = memo.pop();
            if (!keep[old.file] && !memo.some(function (x) { return x.file === old.file; })) fm.removeItemAtPathError(old.file, null);
        }
        return entry;
    }

    function readImageFiles(paths) {
        // Items to upload when every path is an image file of an accepted type
        // and size; null otherwise (then the copied files are left alone).
        if (!paths || paths.length === 0 || paths.length > MAX_COPIED_FILES) return null;
        var fm = $.NSFileManager.defaultManager;
        var items = [];
        for (var i = 0; i < paths.length; i++) {
            var ext = imageFileExtension(paths[i]);
            if (!ext) return null;
            var attrs = fm.attributesOfItemAtPathError(paths[i], null);
            if (attrs.isNil() || ObjC.unwrap(attrs.objectForKey('NSFileType')) !== 'NSFileTypeRegular') return null;
            var size = Number(ObjC.unwrap(attrs.objectForKey('NSFileSize')));
            if (!(size > 0) || size > MAX_IMAGE_BYTES) return null;
            var data = $.NSData.dataWithContentsOfFile(paths[i]);
            if (data.isNil()) return null;
            var h = hashData(data);
            items.push({ Path: paths[i], Hash: h.hash, Ext: ext, Size: h.size, File: h.file, Data: data });
        }
        return items;
    }

    function urlPath(u) {
        // Finder writes file reference URLs (file:///.file/id=...); filePathURL
        // resolves them to a path.
        if (u.isNil() || !u.isFileURL) return null;
        var fp = u.filePathURL;
        var p = (fp.isNil() ? u : fp).path;
        return p.isNil() ? null : p.js;
    }

    function fileUrlPaths() {
        // The copied files. Apps fill the representations differently (one item
        // per file, or one list), so read all three and keep the longest list:
        // each item's public.file-url, readObjectsForClasses, NSFilenamesPboardType.
        var lists = [[], [], []];
        var items = pb.pasteboardItems;
        if (!items.isNil()) for (var i = 0; i < Number(items.count); i++) {
            var s = items.objectAtIndex(i).stringForType('public.file-url');
            var p = s.isNil() ? null : urlPath($.NSURL.URLWithString(s));
            if (p) lists[0].push(p);
        }
        var objs = pb.readObjectsForClassesOptions($([$.NSURL]), $({ NSPasteboardURLReadingFileURLsOnlyKey: true }));
        if (!objs.isNil()) for (var j = 0; j < Number(objs.count); j++) {
            var q = urlPath(objs.objectAtIndex(j));
            if (q) lists[1].push(q);
        }
        var names = pb.propertyListForType('NSFilenamesPboardType');
        if (!names.isNil()) lists[2] = (ObjC.deepUnwrap(names) || []).filter(function (x) { return typeof x === 'string' && x.charAt(0) === '/'; });
        return lists.sort(function (a, b) { return b.length - a.length; })[0];
    }

    P.now = nowMs;
    P.foreground = frontWindow;
    P.changeCount = function () { return Number(pb.changeCount); };
    P.log = debugLog;
    P.beep = function () { $.NSBeep(); };
    P.muxCheck = function (socket) {
        // ssh -O check through the socket: the session has logged in and listens.
        if (!$.NSFileManager.defaultManager.fileExistsAtPath(socket)) return false;
        var ssh = P.watcher ? P.watcher.SshPath : '/usr/bin/ssh';
        try {
            return runCapture(ssh, ['-F', 'none', '-o', 'ControlPath=' + socket, '-O', 'check', MUX_HOST], 5).code === 0;
        } catch (e) { return false; }
    };
    P.muxHome = function (socket) {
        var ssh = P.watcher ? P.watcher.SshPath : '/usr/bin/ssh';
        var r = runCapture(ssh, muxSshArguments(socket).concat(['echo $HOME']), 10);
        var lines = String(r.out || '').split(/\r?\n/).filter(function (l) { return l.trim().length > 0; });
        var line = lines.length > 0 ? lines[lines.length - 1].trim() : '';
        if (r.code !== 0 || line.charAt(0) !== '/') throw new Error('ssh exited with ' + r.code + ': ' + String(r.err || '').trim());
        return line;
    };

    P.readState = function () {
        // One snapshot of the pasteboard: the change count, the image or the
        // copied image files, and our marker.
        var seq = Number(pb.changeCount);
        var types = ObjC.deepUnwrap(pb.types) || [];
        var has = function (t) { return types.indexOf(t) >= 0; };
        var state = { Seq: seq, Png: null, Hash: null, HasText: has('public.utf8-plain-text') || has('NSStringPboardType') || has('public.utf16-external-plain-text'),
            HasFiles: has('public.file-url') || has('NSFilenamesPboardType'), Owner: null, Token: null, Text: null, Files: null, Items: null };
        var marker = null;
        if (has(MARKER_TYPE)) {
            var ms = pb.stringForType(MARKER_TYPE);
            if (!ms.isNil()) marker = parseMarker(ms.js);
        }
        if (marker) {
            state.Owner = marker.owner;
            state.Token = marker.token;
            // Our entries carry their text in the marker, so we never ask for the
            // text itself: it may be promised and would make us wait on ourselves.
            if (state.HasText) state.Text = marker.text;
        }
        var paths = marker && marker.files ? marker.files : (state.HasFiles ? fileUrlPaths() : null);
        if (paths) {
            // Image files copied in Finder: upload the files themselves. Finder also
            // puts the file names on the pasteboard as text; that text is not an
            // app's caption, so it does not count as text here.
            var items = readImageFiles(paths);
            if (items) {
                state.Files = paths;
                state.Items = items;
                state.Hash = items.map(function (x) { return x.Hash; }).join(' ');
                if (!marker) state.HasText = false;
                return state;
            }
            // Our entry, but a copied file was moved or deleted since: go on with
            // the image the entry carries, so the path can still be taken back.
            if (!marker) return state;
        }
        var png = null;
        if (has('public.png')) png = pb.dataForType('public.png');
        if ((!png || png.isNil()) && has('public.tiff')) {
            var tiff = pb.dataForType('public.tiff');
            if (!tiff.isNil() && Number(tiff.length) <= MAX_IMAGE_BYTES) {
                var rep = $.NSBitmapImageRep.imageRepWithData(tiff);
                if (!rep.isNil()) png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
            }
        }
        if (!png || png.isNil() || Number(png.length) === 0 || Number(png.length) > MAX_IMAGE_BYTES) return state;
        var h = hashData(png);
        state.Png = png;
        state.Hash = h.hash;
        state.Items = [{ Hash: h.hash, Ext: 'png', Size: h.size, File: h.file, Data: png }];
        return state;
    };

    P.publish = function (e) {
        // Puts our entry on the pasteboard: one item with the image (or, for a
        // plain copy of files, the file URLs again), the marker, the history
        // markers of nspasteboard.org, and the text, written or promised. It
        // refuses when the pasteboard moved past e.basis: a newer copy stays.
        var s = e.state;
        var items = [];
        var head;
        if (s.Files && !e.text) {
            // The copied files again, as file URLs (one item each, as writeObjects
            // makes them for NSURL), and the marker on an item of its own.
            s.Files.forEach(function (p) { items.push($.NSURL.fileURLWithPath(p)); });
            head = $.NSPasteboardItem.alloc.init;
            items.push(head);
        } else {
            var item = $.NSPasteboardItem.alloc.init;
            var png = s.Png;
            if (!png && s.Items && s.Items.length > 0) {
                // Copied files: offer the first image as PNG, never a file URL (a
                // terminal would paste the local path instead of the text).
                var first = s.Items[0];
                if (first.Ext === 'png') png = first.Data;
                else {
                    var rep = $.NSBitmapImageRep.imageRepWithData(first.Data);
                    if (!rep.isNil()) png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
                }
            }
            if (png && !png.isNil()) item.setDataForType(png, 'public.png');
            items.push(item);
            head = item;
        }
        head.setStringForType($(makeMarker(e.owner, e.token, e.text, s.Files)), MARKER_TYPE);
        head.setDataForType($.NSData.data, 'org.nspasteboard.TransientType');
        head.setDataForType($.NSData.data, 'org.nspasteboard.AutoGeneratedType');
        if (e.text) {
            if (e.promise) head.setDataProviderForTypes(providerObject(), $(['public.utf8-plain-text']));
            else head.setStringForType($(e.text), 'public.utf8-plain-text');
        }
        // An older promise can no longer be kept.
        if (rec && rec.open && !rec.done) { rec.done = true; rec.result = null; }
        // macOS has no clipboard lock (Windows checks the sequence number while it
        // holds the clipboard open), so a copy that lands between this check and
        // clearContents is lost. Everything is built before the check to keep
        // that gap as short as two calls.
        if (Number(pb.changeCount) !== e.basis) throw new Error('could not write the clipboard: the clipboard changed since it was read');
        var count = Number(pb.clearContents);
        rec = { count: count, open: !!(e.text && e.promise), done: false, result: null, owner: e.owner, text: e.text || null,
            written: !!(e.text && !e.promise), answered: false, dead: false };
        if (!pb.writeObjects($(items))) throw new Error('could not write the clipboard');
        return count;
    };

    P.completePromise = function (text) {
        if (rec && rec.open && !rec.done) { rec.done = true; rec.result = text || null; }
    };

    P.canAnswer = function (text) {
        // True when the pasteboard holds this session's entry with this text, and
        // a paste of it gets the text: written at once, answered, or promised
        // and not failed. macOS asks a promise once: an answer of nothing is final.
        if (!rec || Number(pb.changeCount) !== rec.count || rec.text !== text) return false;
        if (rec.written || rec.answered) return true;
        return rec.open && !rec.dead && !(rec.done && !rec.result);
    };

    P.provide = function (item, type) {
        // A paste asks for the promised text. Only the window the entry was written
        // for gets it; a paste in another window gets nothing at once. A paste
        // during the upload waits here, up to 30 s, spinning a nested run loop
        // so the upload can finish.
        var r = rec;
        if (!r || !r.open || Number(pb.changeCount) !== r.count) return;
        if (frontWindow() !== r.owner) { r.dead = true; debugLog('a paste in another window gets nothing'); return; }
        var deadline = nowMs() + PROMISE_WAIT_SECONDS * 1000;
        while (!r.done && nowMs() < deadline && Number(pb.changeCount) === r.count && !(P.stopped && P.stopped())) {
            spinRunLoop(0.05);
            if (P.stopped && P.stopped()) break;
            if (P.watcher) {
                try { advanceInflight(P.watcher); } catch (e) { debugLog('upload during a paste: ' + e.message); }
            }
        }
        // The user may have switched windows while the paste waited: answer only
        // if the window the entry was written for is still in front.
        if (r.done && r.result && Number(pb.changeCount) === r.count && frontWindow() === r.owner && !(P.stopped && P.stopped())) {
            item.setStringForType($(r.result), type);
            r.answered = true;
        } else {
            r.dead = true;
            debugLog('a paste got nothing (upload failed or took too long)');
        }
    };

    P.startUpload = function (ssh, argv, item, timeoutSeconds, dir, cls) {
        keep[item.File] = true;
        var h = startTask(ssh, argv, { stdinFile: item.File });
        h.item = item;
        h.dir = dir || DEFAULT_DIR;
        h.cls = cls || '';
        h.timeoutSeconds = timeoutSeconds;
        h.deadline = nowMs() + timeoutSeconds * 1000;
        h.killAt = 0;
        return h;
    };

    P.finishUpload = function (h) {
        if (h.task.isRunning) {
            var now = nowMs();
            if (!h.killAt && now > h.deadline) {
                h.task.terminate;
                h.killAt = now + 3000;
            } else if (h.killAt && now > h.killAt) {
                $.kill(Number(h.task.processIdentifier), 9);
            }
            return undefined;
        }
        delete keep[h.item.File];
        var r = finishTask(h);
        if (sessionDebug && r.err) debugLog('ssh said: ' + r.err.trim().split(/\r?\n/).slice(-20).join(' | '));
        return uploadOutcome({ code: r.code, out: r.out, err: r.err, timedOut: !!h.killAt, timeoutSeconds: h.timeoutSeconds,
            size: h.item.Size, hash: h.item.Hash, ext: h.item.Ext, dir: h.dir, cls: h.cls });
    };

    P.stopUploads = function () {
        var w = P.watcher;
        if (w && w.Inflight && w.Inflight.Pending && w.Inflight.Pending.Handle) {
            stopTask(w.Inflight.Pending.Handle);
            finishTask(w.Inflight.Pending.Handle);
            w.Inflight = null;
        }
        P.completePromise(null);
    };

    currentPlatform = P;
    return P;
}

var currentPlatform = null;
var providerInstance = null;

function providerObject() {
    // The NSPasteboardItemDataProvider of our promised text. It calls back into
    // the platform object; JavaScript errors stay inside the callback.
    if (providerInstance) return providerInstance;
    ObjC.registerSubclass({
        name: 'SshPasteProvider',
        superclass: 'NSObject',
        protocols: ['NSPasteboardItemDataProvider'],
        methods: {
            'pasteboard:item:provideDataForType:': {
                types: ['void', ['id', 'id', 'id']],
                implementation: function (pb, item, type) {
                    try { if (currentPlatform) currentPlatform.provide(item, type); } catch (e) { debugLog('provider error: ' + e.message); }
                }
            },
            'pasteboardFinishedWithDataProvider:': {
                types: ['void', ['id']],
                implementation: function (pb) { /* ownership is read from the change count */ }
            }
        }
    });
    providerInstance = $.SshPasteProvider.alloc.init;
    return providerInstance;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

function bindTerminal(startPid) {
    // The terminal app and its window in front, read first thing: ps and ssh -G
    // take a moment, and the user may bring another window forward meanwhile.
    // Returns { terminal, window } or { error }.
    try {
        var terminal = findTerminal(startPid);
        var window = firstWindowOf(terminal.pid);
        if (!window) return { error: 'the terminal app ' + terminal.bundle + ' has no window on screen' };
        return { terminal: terminal, window: window };
    } catch (e) {
        return { error: e.message };
    }
}

function startWatcher(o) {
    // A watcher for the terminal window that bindTerminal found. Throws with the
    // reason when screenshot paste cannot work here.
    var debug = !!env('SSH_PASTE_DEBUG');
    if (o.bound.error) throw new Error(o.bound.error);
    var terminal = o.bound.terminal;
    var window = o.bound.window;
    var P = macPlatform(debug);
    var W = newWatcher(P, { sshPath: o.sshPath, sshVersion: sshVersionOf(o.sshPath), parsed: o.parsed, noProxy: o.noProxy, pin: o.pin,
        window: window, token: randomHex(16), debug: debug, settings: o.settings, mux: o.mux });
    P.watcher = W;
    debugLog('watching ' + terminal.bundle + ' (pid ' + terminal.pid + ', from ' + terminal.from + ') window ' + window);
    return W;
}

function watchLoop(W, stop) {
    // A paste that waits for an upload spins its own run loop; it ends too when
    // the session does.
    W.P.stopped = stop;
    while (!stop()) {
        spinRunLoop(TICK_SECONDS);
        if (stop()) break;
        watcherStep(W);
    }
}

function endWatcher(W) {
    try { W.P.stopUploads(); } catch (e) { /* ending anyway */ }
    restoreClipboard(W);
}

function watchWrapper(args) {
    // Wrapper mode, started by the launcher before it runs ssh: decide, say so,
    // write DIR/ready, then watch until DIR/stop appears or the launcher is gone.
    // args: DIR, the launcher's pid, ssh, --keep and --dir ('' when not given), ssh's arguments.
    var dir = args[0];
    var parent = Number(args[1]);
    var ssh = args[2];
    var given = [];
    if (args[3]) given.push('--keep', args[3]);
    if (args[4]) given.push('--dir', args[4]);
    var sshArgs = args.slice(5);
    var fm = $.NSFileManager.defaultManager;
    var W = null;
    var parsed = null;
    var bound = bindTerminal(parent);
    try { parsed = splitSshArguments(sshArgs); } catch (e) { parsed = null; }
    if (parsed && parsed.Destination) {
        var effective = effectiveSshConfig(ssh, sshArgs);
        if (sshModeSettings(effective) !== null) {
            // ssh mode already serves this connection; a second watcher would upload twice.
            if (given.length > 0) {
                warn('ssh-paste: ssh mode serves ' + parsed.Destination + ', with its own --keep and --dir; change them with ssh-paste --enable --keep TIME --dir DIR ' + parsed.Destination);
            }
        } else if (testInteractiveSsh(parsed, effective)) {
            try {
                // The same reading as --enable and --proxy, so the folder is normalized (no / at the end).
                var settings = readPasteSettings(given);
                var mux = null;
                if (muxEligible(parsed, effective)) {
                    // The launcher reads DIR/mux and makes the session the master of DIR/s.
                    mux = { socket: dir + '/s', homeDir: settings.Dir && settings.Dir.charAt(0) === '~' ? settings.Dir : null };
                    if (mux.homeDir) settings.Dir = null;   // read through the session once it is up
                } else if (settings.Dir && settings.Dir.charAt(0) === '~') {
                    settings.Dir = absoluteDirectory(settings.Dir, serverHome(ssh, parsed));
                }
                W = startWatcher({ bound: bound, sshPath: ssh, parsed: parsed, settings: settings, mux: mux });
                if (mux) fm.createFileAtPathContentsAttributes(dir + '/mux', $.NSData.data, $());
                warn('ssh-paste: screenshot paste is on. Copy a screenshot, come back here, press Cmd+V.');
            } catch (e) {
                warn('ssh-paste: screenshot paste is off: ' + e.message);
                W = null;
            }
        }
    }
    fm.createFileAtPathContentsAttributes(dir + '/ready', $.NSData.data, $());
    if (!W) return 0;
    watchLoop(W, function () { return fm.fileExistsAtPath(dir + '/stop') || $.getppid() !== parent; });
    endWatcher(W);
    var summary = failureSummary(W);
    if (summary) {
        warn(summary);
        warn('Run: ssh-paste --doctor ' + parsed.Destination);
    }
    return 0;
}

function watchProxy(args) {
    // ssh mode: the launcher relays the connection with nc and starts this
    // watcher next to it. It reads the parent ssh's arguments and watches only
    // interactive sessions, until the relay ends (our parent goes away).
    var host = args[0];
    var port = args[1];
    var alias = args[2];
    var sshPid = Number(args[3]);
    var parent = Number(args[4]);
    // --keep and --dir from the ProxyCommand line. A bad one must not stop the connection:
    // it only turns paste off.
    var settings = null;
    var settingsError = null;
    try {
        settings = readPasteSettings(args.slice(5));
        if (settings.Rest.length > 0) throw new Error('unknown --proxy arguments: ' + settings.Rest.join(' '));
    } catch (e) { settingsError = e.message; }
    var W = null;
    var bound = bindTerminal(sshPid);
    try {
        var r = runCapture('/bin/ps', ['-ww', '-o', 'args=', '-p', String(sshPid)], 20);
        var argv = splitPsArgs(r.out);
        if (argv.length === 0 || argv[0].replace(/^.*\//, '') !== 'ssh') {
            debugLog('ssh mode: no watcher: the parent is not a running ssh (it may have ended already)');
            return 0;
        }
        var ssh = argv[0].indexOf('/') >= 0 ? argv[0] : (findInPath(argv[0]) || '/usr/bin/ssh');
        var rest = argv.slice(1);
        var parsed = splitSshArguments(rest);
        // ps joins the arguments with spaces, so an argument that contains one
        // splits in two. The destination must then still be the host ssh named
        // as %n; if not, these are not ssh's real arguments.
        if (!parsed.Destination || destinationHost(parsed.Destination) !== alias) {
            debugLog('ssh mode: no watcher: cannot read the ssh arguments of this session (an argument with a space?)');
            return 0;
        }
        var effective = effectiveSshConfig(ssh, rest);
        if (!testInteractiveSsh(parsed, effective)) {
            debugLog('ssh mode: no watcher: not an interactive session');
            return 0;
        }
        // Upload to the host and port this relay reached, checking the host key
        // under the name the session itself used.
        var keyAlias = port !== '22' ? '[' + host + ']:' + port : host;
        if (effective && effective.hostkeyalias) keyAlias = effective.hostkeyalias;
        if (settingsError) throw new Error(settingsError);
        W = startWatcher({ bound: bound, sshPath: ssh, parsed: parsed, noProxy: true, pin: { HostName: host, Port: port, HostKeyAlias: keyAlias }, settings: settings });
    } catch (e) {
        warn('ssh-paste: screenshot paste is off: ' + e.message);
        return 0;
    }
    // The session ends when the relay goes away, or when the ssh that started it
    // does: with ControlPersist, a background master keeps the relay alive after
    // the user logs out, while the ssh in the terminal exits.
    var ended = function () { return $.getppid() !== parent || $.kill(sshPid, 0) !== 0; };
    if (ended()) { endWatcher(W); return 0; }
    watchLoop(W, ended);
    endWatcher(W);
    var summary = failureSummary(W);
    if (summary) {
        warn(summary);
        warn('Run: ssh-paste --doctor ' + alias);
    }
    return 0;
}

// --- ~/.ssh/config ----------------------------------------------------------

function homeDirectory() {
    return env('HOME') || $.NSHomeDirectory().js;
}

function sshConfigPath() {
    return homeDirectory() + '/.ssh/config';
}

function readConfig(path) {
    // { text, bom } with every byte kept (ISO-8859-1), or null when the file does
    // not exist. A file that exists but cannot be read throws: it is not empty.
    var fm = $.NSFileManager.defaultManager;
    if (!fm.fileExistsAtPath(path)) return null;
    var d = $.NSData.dataWithContentsOfFile(path);
    if (d.isNil()) throw new Error('cannot read ' + path);
    var s = $.NSString.alloc.initWithDataEncoding(d, $.NSISOLatin1StringEncoding).js;
    var bom = s.substring(0, 3) === UTF8_BOM_LATIN1;
    return { text: bom ? s.substring(3) : s, bom: bom };
}

function sameConfig(a, b) {
    if (a === null || b === null) return a === b;
    return a.text === b.text && a.bom === b.bom;
}

function updateSshConfig(path, old, newText, remove) {
    // Rewrites ~/.ssh/config (through a temp file, keeping its permissions and a
    // UTF-8 byte order mark if there was one), and refuses if the file changed
    // since it was read.
    var fm = $.NSFileManager.defaultManager;
    var changed = path + ' changed while ssh-paste was editing it; run the command again';
    if (!sameConfig(readConfig(path), old)) throw new Error(changed);
    if (remove) { fm.removeItemAtPathError(path, null); return; }
    var dir = path.replace(/\/[^\/]*$/, '');
    if (!fm.fileExistsAtPath(dir)) fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $({ NSFilePosixPermissions: 448 }), null);
    var target = $(path).stringByResolvingSymlinksInPath.js;
    var mode = 384;
    if (old !== null) {
        var attrs = fm.attributesOfItemAtPathError(target, null);
        if (!attrs.isNil()) mode = Number(ObjC.unwrap(attrs.objectForKey('NSFilePosixPermissions')));
    }
    var text = (old !== null && old.bom ? UTF8_BOM_LATIN1 : '') + newText;
    var data = $(text).dataUsingEncoding($.NSISOLatin1StringEncoding);
    if (data.isNil()) throw new Error('the new ssh config text is not plain text');
    if (!sameConfig(readConfig(path), old)) throw new Error(changed);
    if (!data.writeToFileAtomically(target, true)) throw new Error('could not write ' + target);
    fm.setAttributesOfItemAtPathError($({ NSFilePosixPermissions: mode }), target, null);
}

function launcherPath() {
    var p = env('SSH_PASTE_LAUNCHER');
    if (!p) throw new Error('SSH_PASTE_LAUNCHER is not set; run this through the ssh-paste command');
    return p;
}

function resolvedSshConfig(alias) {
    var r = runCapture(sshPath(), ['-G', '--', alias], 20);
    if (r.code !== 0) throw new Error('ssh -G ' + alias + ' failed: ' + r.err.trim());
    return parseSshG(r.out);
}

function hostResolves(name) {
    try {
        var h = $.NSHost.hostWithName(name);
        return !h.isNil() && !h.addresses.isNil() && Number(h.addresses.count) > 0;
    } catch (e) { return false; }
}

function enableHosts(args) {
    // ssh-paste --enable [--keep TIME] [--dir DIR] HOST...: the settings go to the hosts given;
    // a host that is already enabled keeps the settings that are not given.
    var settings = readPasteSettings(args || []);
    // Each host once, in order; aliases are case-sensitive, as in ssh.
    var hosts = settings.Rest.filter(function (h, i) { return settings.Rest.indexOf(h) === i; });
    if (hosts.length === 0) throw new Error('usage: ssh-paste --enable [--keep TIME] [--dir DIR] HOST [HOST...]');
    if (settings.Dir) warnLocalHome(settings.Dir);
    var configPath = sshConfigPath();
    var old = readConfig(configPath);
    var text = old ? old.text : null;
    var block = getManagedBlock(text);
    var want = [];
    var find = function (h) { for (var k = 0; k < want.length; k++) if (want[k][0] === h) return want[k]; return null; };
    block.Groups.forEach(function (g) {
        var s = proxySettings(g.ProxyCommand);
        g.Hosts.forEach(function (h) { if (!find(h)) want.push([h, s]); });
    });
    var added = [];
    var changed = [];
    var logins = {};
    var problems = [];
    var ssh = null;
    // Every name is checked before any connection, so a bad one stops the command at once.
    hosts.forEach(function (h) {
        if (!testHostAlias(h)) throw new Error('use a host name or a Host alias from ~/.ssh/config (no user@, no options): ' + h);
        if (!find(h)) {
            var resolved = resolvedSshConfig(h);
            var hostName = resolved.hostname || h;
            if (!hostResolves(hostName)) throw new Error('cannot find the host ' + hostName + ' (from ' + h + '). Check the name, or add it to ~/.ssh/config, then run --enable again');
            ['proxyjump', 'proxycommand'].forEach(function (key) {
                if (resolved[key] && resolved[key] !== 'none') {
                    throw new Error(h + ' already uses ' + key + ' (' + resolved[key] + '); ssh-paste cannot take over its connection. Use wrapper mode instead: ssh-paste ' + h);
                }
            });
        }
    });
    hosts.forEach(function (h) {
        var pair = find(h);
        if (!pair) {
            pair = [h, { Keep: DEFAULT_KEEP, Dir: DEFAULT_DIR }];
            want.push(pair);
            added.push(h);
        }
        // Check once, as an upload would log in, so a host that asks for a password is known
        // now and not at the first paste; the same connection reads the home folder for ~.
        if (ssh === null) ssh = sshPath();
        if (!Object.prototype.hasOwnProperty.call(logins, h)) logins[h] = testServerLogin(ssh, splitSshArguments([h]), true);
        // A host whose uploads the server refuses is not enabled: ssh mode could never paste there.
        var refusal = enableRefusal(h, logins[h].error, muxEligible(splitSshArguments([h]), effectiveSshConfig(ssh, [h])));
        if (refusal) { problems = problems.concat(refusal); return; }
        var before = pair[1];
        var after = { Keep: settings.Keep || before.Keep, Dir: settings.Dir || before.Dir };
        if (settings.Dir && settings.Dir.charAt(0) === '~') {
            // ~ is the home folder on that server, asked for once, so the block holds an
            // absolute path and the path to paste is known before an upload.
            if (logins[h].home === null) { problems.push(homeError(h, logins[h].error)); return; }
            after.Dir = absoluteDirectory(settings.Dir, logins[h].home);
            say(h + ': ' + settings.Dir + ' is ' + after.Dir + ' there');
        }
        if (added.indexOf(h) < 0 && changed.indexOf(h) < 0 && (after.Keep !== before.Keep || after.Dir !== before.Dir)) changed.push(h);
        pair[1] = after;
    });
    if (problems.length > 0) {
        // All or nothing: the reasons for every host, and the command to run again.
        throw new Error(['nothing changed in ~/.ssh/config:'].concat(problems, ['Then run again: ssh-paste --enable ' + formatShellWords(args || [])]).join('\n'));
    }
    var groups = settingsGroups(want, launcherPath());
    var createdFile = block.CreatedFile || old === null;
    if (added.length > 0 || changed.length > 0) {
        updateSshConfig(configPath, old, setManagedBlock(text, null, null, createdFile, groups), false);
        if (added.length > 0) say('Enabled for: ' + added.join(', '));
        if (changed.length > 0) say('Changed for: ' + changed.join(', '));
    } else {
        say('Already enabled with these settings; nothing changed.');
    }
    hosts.forEach(function (h) {
        say(h + ': ' + formatPasteSettings(find(h)[1]));
        say(loginReport(h, logins[h].error));
    });
    say('This block is at the top of ' + configPath + ':');
    say('');
    setManagedBlock('', null, null, createdFile, groups).replace(/\s+$/, '').split(/\r?\n/).forEach(function (line) { say('    ' + line); });
    say('');
    say('Now connect as usual: ssh ' + (added.length > 0 ? added[0] : hosts[0]));
    return 0;
}

function warnLocalHome(dir) {
    // zsh turns an unquoted ~/x into this Mac's home folder before ssh-paste sees it.
    var home = homeDirectory().replace(/\/+$/, '');
    if (home && (dir === home || dir.indexOf(home + '/') === 0)) {
        warn('ssh-paste: --dir ' + dir + ' is a folder of this Mac; if you meant the home folder on the server, quote the ~: --dir \'~' + dir.substring(home.length) + '\'');
    }
}

function disableHosts(hosts) {
    var configPath = sshConfigPath();
    var old = readConfig(configPath);
    var text = old ? old.text : null;
    var block = getManagedBlock(text);
    if (!block.Present) { say('ssh-paste is not enabled for any host.'); return 0; }
    var keep = (!hosts || hosts.length === 0) ? [] : block.Hosts.filter(function (h) { return hosts.indexOf(h) < 0; });
    // Each remaining host keeps its group's line as it is.
    var groups = block.Groups.map(function (g) {
        return { Hosts: g.Hosts.filter(function (h) { return keep.indexOf(h) >= 0; }), ProxyCommand: g.ProxyCommand || proxyCommandLine(launcherPath()) };
    });
    var newText = setManagedBlock(text, null, null, block.CreatedFile, groups);
    if (keep.length === 0 && block.CreatedFile && newText.trim().length === 0) {
        updateSshConfig(configPath, old, null, true);
        var dir = configPath.replace(/\/[^\/]*$/, '');
        var fm = $.NSFileManager.defaultManager;
        var rest = fm.contentsOfDirectoryAtPathError(dir, null);
        if (!rest.isNil() && Number(rest.count) === 0) fm.removeItemAtPathError(dir, null);
    } else {
        updateSshConfig(configPath, old, newText, false);
    }
    say(disableMessage(block.Hosts, hosts));
    return 0;
}

function disableMessage(managed, asked) {
    // Get-DisableMessage: the hosts --disable removed (all when none are named), or that
    // none of the named hosts was enabled. Host aliases are case-sensitive, as in ssh.
    var all = !asked || asked.length === 0;
    var removed = managed.filter(function (h) { return all || asked.indexOf(h) >= 0; });
    if (removed.length === 0) return 'ssh-paste is not enabled for: ' + asked.join(', ');
    return 'Disabled for: ' + removed.join(', ');
}

// --- --doctor ---------------------------------------------------------------

function doctor(args) {
    var ok = true;
    function report(pass, what) { say((pass ? '  ok    ' : '  FAIL  ') + what); if (!pass) ok = false; }
    say('ssh-paste ' + VERSION);
    var os = $.NSProcessInfo.processInfo.operatingSystemVersionString.js;
    report(true, 'macOS ' + os + ', osascript JavaScript');
    try {
        var count = Number(pasteboard().changeCount);
        var fw = frontWindow();
        report(true, 'pasteboard and window APIs available (change count ' + count + ', front window ' + fw + ')');
    } catch (e) { report(false, 'pasteboard or window API: ' + e.message); return 1; }
    var ssh;
    try {
        ssh = sshPath();
        var v = runCapture(ssh, ['-V'], 20);
        report(true, 'ssh: ' + ssh + ' (' + (v.err + v.out).trim() + ')');
    } catch (e) { report(false, 'ssh: ' + e.message); return 1; }
    try {
        var t = findTerminal(Number($.getppid()));
        var w = firstWindowOf(t.pid);
        report(w !== 0, 'terminal: ' + t.bundle + ' (from ' + t.from + ')' + (w ? ', window ' + w : ', no window on screen'));
    } catch (e) { report(false, 'terminal: ' + e.message); }
    try {
        var P = macPlatform(false);
        var s = P.readState();
        if (s.Files) report(true, 'clipboard: ' + s.Files.length + ' copied image file(s)');
        else if (s.Png) report(true, 'clipboard: image, ' + s.Items[0].Size + ' bytes');
        else report(true, 'clipboard: readable (no image right now)');
    } catch (e) { report(false, 'clipboard: ' + e.message); }
    if (!args || args.length === 0) {
        say('');
        say('Add a host to test an upload: ssh-paste --doctor myhost');
        return ok ? 0 : 1;
    }
    var parsed = splitSshArguments(args);
    var bytes = doctorPng(randomHex(16));
    var data = $.NSData.alloc.initWithBase64EncodedStringOptions($(base64FromBytes(bytes)), 0);
    var file = privateDirectory() + '/doctor.png';
    data.writeToFileAtomically(file, true);
    var hashOut = runCapture('/usr/bin/shasum', ['-a', '256', file], 20);
    var hash = (parseShasum(hashOut.out) || '').substring(0, 32);
    var effective = effectiveSshConfig(ssh, args);
    var sshMode = sshModeSettings(effective);
    var started = nowMs();
    try {
        // The settings ssh mode uses for this connection, so the test prunes as an upload would.
        var settings = sshMode || { Keep: DEFAULT_KEEP, Dir: DEFAULT_DIR };
        var argv = uploadSshArguments(parsed, hash, bytes.length, { sshVersion: sshVersionOf(ssh), keep: settings.Keep, dir: settings.Dir });
        var h = startTask(ssh, argv, { stdinFile: file });
        var deadline = nowMs() + 30000;
        var timedOut = false;
        while (h.task.isRunning) {
            if (nowMs() > deadline) { stopTask(h); timedOut = true; break; }
            sleepSeconds(0.02);
        }
        var r = finishTask(h);
        var outcome = uploadOutcome({ code: r.code, out: r.out, err: r.err, timedOut: timedOut, timeoutSeconds: 30, size: bytes.length, hash: hash, ext: 'png', dir: settings.Dir, cls: keepClass(settings.Keep) });
        if (outcome.error) throw new Error(outcome.error);
        report(true, 'upload to ' + parsed.Destination + ': ' + outcome.path + ' (' + ((nowMs() - started) / 1000).toFixed(1) + ' s)');
    } catch (e) {
        report(false, 'upload to ' + parsed.Destination + ': ' + e.message);
        say('');
        var failure = sshFailure(e.message);
        var advice = loginAdvice(failure, parsed.Destination, true);
        if (advice) say(advice);
        if (failure && failure.kind === 'auth' && failure.keyLogin) {
            say('');
            var setup = keySetupTarget(parsed);
            keySetupLines(setup.Target).forEach(say);
            if (setup.Dropped) say('  Add the other ssh options this host needs to the ssh-copy-id line.');
        }
        if (failure && failure.kind === 'auth' && muxEligible(parsed, effective)) {
            say(WRAPPER_HINT.replace(/HOST/g, formatShellWords(args)));
        } else if (!advice) {
            say('Uploads use a second, non-interactive ssh connection, so the server must');
            say('accept your key without a prompt: a key without a passphrase, or a key loaded');
            say('in ssh-agent (ssh-add --apple-use-keychain). Password-only logins cannot work.');
        }
        return 1;
    }
    if (sshMode) {
        report(true, 'ssh mode: enabled, "ssh ' + args.join(' ') + '" pastes screenshots (' + formatPasteSettings(sshMode) + ')');
    } else {
        say('  info  ssh mode is off for ' + parsed.Destination + '. Turn it on: ssh-paste --enable ' + parsed.Destination + '   (or use: ssh-paste ' + parsed.Destination + ')');
    }
    return ok ? 0 : 1;
}

function base64FromBytes(bytes) {
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
        var a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
        var n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += chars[(n >> 18) & 63] + chars[(n >> 12) & 63] + (b === undefined ? '=' : chars[(n >> 6) & 63]) + (c === undefined ? '=' : chars[n & 63]);
    }
    return out;
}

// --- --update ---------------------------------------------------------------

function update(options) {
    // ssh-paste --update: run the latest release's install.sh after checking it
    // against that release's SHA256SUMS. The installer replaces the files in
    // place and says what changed ("Upgraded", or "Reinstalled" when current).
    if (options.length > 0) throw new Error('--update takes no options: ' + options.join(' '));
    var base = (env('SSH_PASTE_UPDATE_URL') || UPDATE_BASE).replace(/\/+$/, '');
    say('Downloading the latest release from ' + base);
    var dir = privateDirectory();
    ['install.sh', 'SHA256SUMS'].forEach(function (name) {
        var r = runCapture('/usr/bin/curl', ['-fsSL', '--proto-redir', '=https', '-o', dir + '/' + name, base + '/' + name], 120);
        if (r.code !== 0) throw new Error('could not download ' + base + '/' + name + ': ' + r.err.trim());
    });
    var sums = readFileText(dir + '/SHA256SUMS');
    var hex = parseShasum(runCapture('/usr/bin/shasum', ['-a', '256', dir + '/install.sh'], 20).out);
    if (!hex || !checkReleaseChecksum(sums, 'install.sh', hex)) throw new Error('install.sh does not match SHA256SUMS; nothing was changed');
    // SSH_PASTE_UNINSTALL and SSH_PASTE_REF are for running the installer by
    // hand; an update must not inherit them.
    var e = ObjC.deepUnwrap($.NSProcessInfo.processInfo.environment);
    delete e.SSH_PASTE_UNINSTALL;
    delete e.SSH_PASTE_REF;
    var h = startTask('/bin/sh', [dir + '/install.sh'], { inherit: true, env: e });
    while (h.task.isRunning) sleepSeconds(0.05);
    return Number(h.task.terminationStatus);
}

// --- main -------------------------------------------------------------------

function main(argv) {
    if (argv.length === 0) { say(usage()); return 0; }
    var rest = argv.slice(1);
    switch (argv[0]) {
        case '--watch-proxy': return watchProxy(rest);
        case '--watch-wrapper': return watchWrapper(rest);
        case '--enable': return enableHosts(rest);
        case '--check-settings': return checkSettings(rest);
        case '--disable': return disableHosts(rest);
        case '--doctor': return doctor(rest);
        case '--update': return update(rest);
        case '--version': say(VERSION); return 0;
        case '--help': case '-h': say(usage()); return 0;
        default:
            warn('ssh-paste: unknown command ' + argv[0] + '; run ssh-paste --help');
            return 2;
    }
}

function checkSettings(args) {
    // The launcher's check of wrapper mode's --keep TIME --dir DIR ('' when not given),
    // before it runs ssh: a bad value stops it with the reason.
    if (args[0]) keepMinutesOf(args[0]);
    if (args[1]) {
        if (!testServerDirectory(args[1])) readPasteSettings(['--dir', args[1]]);
        warnLocalHome(args[1]);
    }
    return 0;
}

// osascript calls run(argv).
function run(argv) {
    initMac();
    var code = 1;
    try {
        code = main(argv.map(String));
    } catch (e) {
        warn('ssh-paste: ' + (e && e.message ? e.message : e));
        code = 1;
    }
    try { removePrivateDirectory(); } catch (e) { /* best effort */ }
    $.exit(code);
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        VERSION: VERSION, MARKER_TYPE: MARKER_TYPE, BLOCK_BEGIN: BLOCK_BEGIN, BLOCK_END: BLOCK_END, BLOCK_CREATED_FILE: BLOCK_CREATED_FILE,
        REMOTE_SCRIPT: REMOTE_SCRIPT, IMAGE_EXTENSIONS: IMAGE_EXTENSIONS, MAX_COPIED_FILES: MAX_COPIED_FILES, MAX_IMAGE_BYTES: MAX_IMAGE_BYTES,
        RETRY_FAILED_SECONDS: RETRY_FAILED_SECONDS, UPLOAD_CACHE_HOURS: UPLOAD_CACHE_HOURS, PROMISE_WAIT_SECONDS: PROMISE_WAIT_SECONDS,
        DEFAULT_KEEP: DEFAULT_KEEP, DEFAULT_DIR: DEFAULT_DIR, keepMinutesOf: keepMinutesOf, testServerDirectory: testServerDirectory,
        readPasteSettings: readPasteSettings, proxySettings: proxySettings, replyPathPattern: replyPathPattern, uploadCacheHours: uploadCacheHours,
        settingsGroups: settingsGroups, disableMessage: disableMessage, sshModeSettings: sshModeSettings,
        sshFailure: sshFailure, failureFinal: failureFinal, loginAdvice: loginAdvice, loginReport: loginReport, keySetupLines: keySetupLines, keySetupTarget: keySetupTarget, enableRefusal: enableRefusal,
        muxEligible: muxEligible, muxSshArguments: muxSshArguments, muxUploadArguments: muxUploadArguments, uploadCommand: uploadCommand, MUX_HOST: MUX_HOST, formatShellWords: formatShellWords, keepClass: keepClass, absoluteDirectory: absoluteDirectory,
        serverSshArguments: serverSshArguments,
        SSH_FLAGS_NO_ARG: SSH_FLAGS_NO_ARG, SSH_FLAGS_WITH_ARG: SSH_FLAGS_WITH_ARG, SSH_KEEP_NO_ARG: SSH_KEEP_NO_ARG,
        SSH_KEEP_WITH_ARG: SSH_KEEP_WITH_ARG, SSH_DROP_OPTIONS: SSH_DROP_OPTIONS, TERM_PROGRAM_BUNDLES: TERM_PROGRAM_BUNDLES,
        splitSshArguments: splitSshArguments, destinationHost: destinationHost, sshOptionKey: sshOptionKey, testInteractiveSsh: testInteractiveSsh, parseSshG: parseSshG,
        parseSshVersion: parseSshVersion, uploadSshArguments: uploadSshArguments, readUploadReply: readUploadReply, uploadOutcome: uploadOutcome,
        testHostAlias: testHostAlias, imageFileExtension: imageFileExtension, proxyCommandLine: proxyCommandLine,
        getManagedBlock: getManagedBlock, setManagedBlock: setManagedBlock, checkReleaseChecksum: checkReleaseChecksum,
        parseShasum: parseShasum, makeMarker: makeMarker, parseMarker: parseMarker, splitPsArgs: splitPsArgs,
        parseProcessTable: parseProcessTable, terminalFromEnvironment: terminalFromEnvironment, crc32: crc32, doctorPng: doctorPng,
        base64FromBytes: base64FromBytes, retryDelaySeconds: retryDelaySeconds, usage: usage,
        newWatcher: newWatcher, watcherTick: watcherTick, watcherStep: watcherStep, restoreClipboard: restoreClipboard,
        failureSummary: failureSummary, expectedText: expectedText, uploadedPath: uploadedPath, advanceInflight: advanceInflight
    };
}
