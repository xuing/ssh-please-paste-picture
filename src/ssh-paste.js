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
var PROMISE_WAIT_SECONDS = 30;
var TICK_SECONDS = 0.25;
var UPDATE_BASE = 'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download';

// Runs on the server through `sh -c`, with $1 = content hash (32 hex digits, made
// by us), $2 = byte count and $3 = file extension. The same text as
// $script:RemoteScript in src/ssh-paste.ps1; a test fails when the two differ.
var REMOTE_SCRIPT = 'umask 077; set -fC; n=$2; e=${3:-png}; ' +
    't=$(mktemp /tmp/ssh-paste-tmp.XXXXXXXXXX 2> /dev/null) || { t=/tmp/ssh-paste-tmp.$$; : > $t; } || exit 3; ' +
    'cat >> $t; s=$(wc -c < $t); if [ $s -eq $n ]; then :; else rm -f $t; echo short $s; exit 4; fi; ' +
    'for x in png jpg jpeg gif webp bmp; do find /tmp -maxdepth 1 -user $(id -u) -name ssh-paste-????????????????????????????????*.$x -mmin +1440 -exec rm -f {} + 2> /dev/null; done; ' +
    'find /tmp -maxdepth 1 -user $(id -u) -name ssh-paste-tmp.* -mmin +1440 -exec rm -f {} + 2> /dev/null; ' +
    'for f in /tmp/ssh-paste-$1.$e /tmp/ssh-paste-$1-$(id -u).$e; do ' +
    'if [ -h $f ]; then :; elif [ -f $f ] && [ -O $f ] && cmp -s $t $f; then rm -f $t; touch $f; echo $n $f; exit 0; fi; ' +
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
    // after the last @, or the host of an ssh:// URI.
    var d = String(destination);
    var m = /^ssh:\/\/(?:[^\/]*@)?(\[[^\]]*\]|[^:\/]*)/.exec(d);
    if (m) return m[1].replace(/^\[(.*)\]$/, '$1');
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
    // Arguments for the separate, non-interactive upload connection. Our options
    // come first because ssh uses the first value it sees for each option; the
    // user's options keep their place before or after the destination.
    opts = opts || {};
    var ext = opts.ext || 'png';
    if (!/^[0-9a-f]{32}$/.test(String(hash))) throw new Error('bad image hash: ' + hash);
    if (IMAGE_EXTENSIONS.indexOf(ext) < 0) throw new Error('bad image extension: ' + ext);
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
    argv = argv.concat(before, [String(parsed.Destination)], after);
    argv.push("sh -c '" + REMOTE_SCRIPT + "' ssh-paste " + hash + ' ' + size + ' ' + ext);
    return argv;
}

function readUploadReply(output, expectedSize, hash, ext) {
    // The last non-empty line of the reply is "<size> <path>".
    ext = ext || 'png';
    var lines = String(output === null || output === undefined ? '' : output).split(/\r?\n/).filter(function (l) { return l.trim().length > 0; });
    if (lines.length === 0) throw new Error('the server sent no reply (is sh available there?)');
    var last = lines[lines.length - 1].trim();
    var m = /^short (\d+)$/.exec(last);
    if (m) throw new Error('the server received ' + m[1] + ' of ' + expectedSize + ' bytes');
    m = /^(\d+) (\/\S+)$/.exec(last);
    if (!m) throw new Error('unexpected reply from the server: ' + last);
    var size = Number(m[1]);
    var path = m[2];
    if (size !== Number(expectedSize)) throw new Error('size mismatch: sent ' + expectedSize + ' bytes, server has ' + size);
    if (!new RegExp('^/tmp/ssh-paste-' + hash + '(-[0-9]+)?\\.' + ext + '$').test(path)) throw new Error('unexpected path from the server: ' + path);
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
        return { path: readUploadReply(r.out, r.size, r.hash, r.ext) };
    } catch (e) {
        return { error: e.message };
    }
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

function proxyCommandLine(launcher) {
    // The ProxyCommand that --enable writes. ssh runs it as `$SHELL -c "exec ..."`
    // under the user's login shell, so it is one absolute path in single quotes
    // (POSIX quoting, the same in sh, bash and zsh) and three ssh tokens. ssh
    // expands % before the shell sees the line, so % in the path is doubled.
    if (!/^\//.test(launcher)) throw new Error('the ssh-paste command path is not absolute: ' + launcher);
    if (/[\r\n]/.test(launcher)) throw new Error('the ssh-paste command path contains a line break');
    var quoted = "'" + launcher.replace(/%/g, '%%').replace(/'/g, "'\\''") + "'";
    // %h and %n are quoted: a Host alias may contain [ and ], which zsh would
    // take for a file pattern. ssh refuses quotes in a host name.
    return quoted + " --proxy '%h' %p '%n'";
}

function getManagedBlock(configText) {
    // Hosts, ProxyCommand and "created the file" flag from our block, if any.
    var info = { Hosts: [], ProxyCommand: null, CreatedFile: false, Present: false };
    if (!configText) return info;
    var inBlock = false;
    configText.split(/\r?\n/).forEach(function (line) {
        if (line === BLOCK_BEGIN) { inBlock = true; info.Present = true; return; }
        if (line === BLOCK_END) { inBlock = false; return; }
        if (!inBlock) return;
        if (line === BLOCK_CREATED_FILE) { info.CreatedFile = true; return; }
        var m = /^Host\s+(.+)$/i.exec(line);
        if (m && info.Hosts.length === 0) {
            info.Hosts = m[1].trim().split(/\s+/).filter(function (h) { return h !== '*'; });
            return;
        }
        m = /^\s+ProxyCommand\s+(.+)$/i.exec(line);
        if (m && info.ProxyCommand === null) info.ProxyCommand = m[1].trim();
    });
    return info;
}

function setManagedBlock(configText, hosts, proxyCommand, createdFile) {
    // Returns the config text with our block removed and, if hosts is non-empty,
    // a fresh block put first (ssh uses the first value it finds). The trailing
    // "Host *" keeps any global options that follow in effect for every host.
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
    if (!hosts || hosts.length === 0) return rest;
    var block = [BLOCK_BEGIN];
    if (createdFile) block.push(BLOCK_CREATED_FILE);
    block.push('Host ' + hosts.join(' '), '    ProxyCommand ' + proxyCommand, '    ProxyUseFdpass no', 'Host *', BLOCK_END);
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
        '  ssh-paste --enable HOST [HOST...]   make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)',
        '  ssh-paste --disable [HOST...]       undo --enable (all hosts if none given)',
        '  ssh-paste [ssh options] HOST        wrapper mode: ssh with screenshot paste, no config',
        '  ssh-paste --doctor [HOST]           check this computer and test an upload to HOST',
        '  ssh-paste --update                  install the latest release',
        '  ssh-paste --uninstall               remove ssh-paste and everything it changed',
        '  ssh-paste --version | --help',
        '',
        'While connected: copy a screenshot (Cmd+Ctrl+Shift+4) or image files in Finder,',
        'come back to the terminal window, press Cmd+V. The image goes to',
        '/tmp/ssh-paste-<hash>.png on the server and that path is pasted. Other apps',
        'still paste the image. https://github.com/xuing/ssh-please-paste-picture'
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
//   P.startUpload(ssh, argv, item, timeoutSeconds) -> handle (throws when ssh
//                           cannot start)
//   P.finishUpload(handle)  undefined while it runs, then { path } or { error }
//   P.beep(), P.log(text)
// One difference from Windows: an upload runs as a child process, so a tick that
// starts one returns and later ticks finish it (W.Inflight). Until then the
// watcher does nothing else, as the Windows watcher does while Send-Image runs.
// ---------------------------------------------------------------------------

function newWatcher(P, o) {
    return {
        P: P, SshPath: o.sshPath, SshVersion: o.sshVersion || null, Parsed: o.parsed, NoProxy: !!o.noProxy, Pin: o.pin || null,
        Window: o.window, Token: o.token, Debug: !!o.debug,
        LastSeq: -1, LastForeground: 0, State: null, WakeAt: Infinity, Uploaded: {}, Failed: {}, Inflight: null
    };
}

function stateItems(state) {
    return state.Items || [];
}

function setWakeAt(W, at) {
    if (at < W.WakeAt) W.WakeAt = at;
}

function expectedText(W, state) {
    // The text Cmd+V should paste, known before the upload: each file is named
    // after its content. An earlier upload's real path wins (it can carry a
    // per-user suffix when another user on the server owns the plain name).
    var now = W.P.now();
    return stateItems(state).map(function (item) {
        var done = W.Uploaded[item.Hash];
        if (done && now - done.At < UPLOAD_CACHE_HOURS * 3600000) return done.Path;
        return '/tmp/ssh-paste-' + item.Hash + '.' + item.Ext;
    }).join(' ');
}

function uploadFailing(W, state) {
    return stateItems(state).some(function (item) { return Object.prototype.hasOwnProperty.call(W.Failed, item.Hash); });
}

function uploadedItemPath(W, item) {
    // Upload once per file. A failed upload is retried after 30 s, 1 min, 2 min
    // and so on (beeping only the first time). An upload is redone after a few
    // hours so the server's day-old cleanup never removes a path we paste.
    // Returns the path, null, or { Pending } when an upload was started.
    var P = W.P;
    var now = P.now();
    var done = W.Uploaded[item.Hash];
    if (done && now - done.At < UPLOAD_CACHE_HOURS * 3600000) {
        setWakeAt(W, done.At + UPLOAD_CACHE_HOURS * 3600000);
        return done.Path;
    }
    var failed = W.Failed[item.Hash];
    if (failed) {
        var retryAt = failed.At + retryDelaySeconds(failed.Count) * 1000;
        if (now < retryAt) { setWakeAt(W, retryAt); return null; }
    }
    var pending = { Item: item, At: now, Handle: null };
    try {
        var argv = uploadSshArguments(W.Parsed, item.Hash, item.Size, { noProxy: W.NoProxy, sshVersion: W.SshVersion, pin: W.Pin, ext: item.Ext });
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
        pending.Handle = P.startUpload(W.SshPath, argv, item, timeout);
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
        W.Uploaded[hash] = { Path: outcome.path, At: pending.At };
        delete W.Failed[hash];
        setWakeAt(W, pending.At + UPLOAD_CACHE_HOURS * 3600000);
        return;
    }
    var failed = W.Failed[hash];
    var count = failed ? failed.Count + 1 : 1;
    var now = P.now();
    W.Failed[hash] = { Message: outcome.error, At: now, Count: count };
    P.log('upload failed (' + count + 'x, ' + pending.Item.Size + ' bytes): ' + outcome.error);
    setWakeAt(W, now + retryDelaySeconds(count) * 1000);
    if (count === 1) { try { P.beep(); } catch (e) { /* no sound is fine */ } }
}

function uploadedPath(W, state) {
    // The text to paste for this pasteboard state: the remote path of the image,
    // or the paths of all copied image files separated by spaces. null until
    // every one is uploaded; { Pending } while an upload runs.
    W.WakeAt = Infinity;
    var paths = [];
    var items = stateItems(state);
    for (var i = 0; i < items.length; i++) {
        var r = uploadedItemPath(W, items[i]);
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
        var r = uploadedPath(W, f.State);
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
            Pending: null, Ready: false, Path: null, Completed: false };
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
    var keys = Object.keys(W.Failed);
    if (keys.length === 0) return null;
    var last = keys.map(function (k) { return W.Failed[k]; }).sort(function (a, b) { return a.At - b.At; })[keys.length - 1];
    return 'ssh-paste: ' + keys.length + ' screenshot upload(s) failed: ' + last.Message;
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
            if (memo[i].size === size && memo[i].data.isEqualToData(data)) return memo[i];
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
            if (P.watcher) {
                try { advanceInflight(P.watcher); } catch (e) { debugLog('upload during a paste: ' + e.message); }
            }
        }
        // The user may have switched windows while the paste waited: answer only
        // if the window the entry was written for is still in front.
        if (r.done && r.result && Number(pb.changeCount) === r.count && frontWindow() === r.owner) {
            item.setStringForType($(r.result), type);
            r.answered = true;
        } else {
            r.dead = true;
            debugLog('a paste got nothing (upload failed or took too long)');
        }
    };

    P.startUpload = function (ssh, argv, item, timeoutSeconds) {
        keep[item.File] = true;
        var h = startTask(ssh, argv, { stdinFile: item.File });
        h.item = item;
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
            size: h.item.Size, hash: h.item.Hash, ext: h.item.Ext });
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
        window: window, token: randomHex(16), debug: debug });
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
    var dir = args[0];
    var parent = Number(args[1]);
    var ssh = args[2];
    var sshArgs = args.slice(3);
    var fm = $.NSFileManager.defaultManager;
    var W = null;
    var parsed = null;
    var bound = bindTerminal(parent);
    try { parsed = splitSshArguments(sshArgs); } catch (e) { parsed = null; }
    if (parsed && parsed.Destination) {
        var effective = effectiveSshConfig(ssh, sshArgs);
        var proxy = effective && effective.proxycommand ? effective.proxycommand : '';
        if (/ssh-paste/.test(proxy) && /--proxy/.test(proxy)) {
            // ssh mode already serves this connection; a second watcher would upload twice.
        } else if (testInteractiveSsh(parsed, effective)) {
            try {
                W = startWatcher({ bound: bound, sshPath: ssh, parsed: parsed });
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
        W = startWatcher({ bound: bound, sshPath: ssh, parsed: parsed, noProxy: true, pin: { HostName: host, Port: port, HostKeyAlias: keyAlias } });
    } catch (e) {
        warn('ssh-paste: screenshot paste is off: ' + e.message);
        return 0;
    }
    if ($.getppid() !== parent) { endWatcher(W); return 0; }
    watchLoop(W, function () { return $.getppid() !== parent; });
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

function enableHosts(hosts) {
    if (!hosts || hosts.length === 0) throw new Error('usage: ssh-paste --enable HOST [HOST...]');
    var configPath = sshConfigPath();
    var old = readConfig(configPath);
    var text = old ? old.text : null;
    var block = getManagedBlock(text);
    var managed = block.Hosts.slice();
    var proxy = proxyCommandLine(launcherPath());
    var added = [];
    hosts.forEach(function (h) {
        if (!testHostAlias(h)) throw new Error('use a host name or a Host alias from ~/.ssh/config (no user@, no options): ' + h);
        if (managed.indexOf(h) >= 0 || added.indexOf(h) >= 0) return;
        var resolved = resolvedSshConfig(h);
        var hostName = resolved.hostname || h;
        if (!hostResolves(hostName)) throw new Error('cannot find the host ' + hostName + ' (from ' + h + '). Check the name, or add it to ~/.ssh/config, then run --enable again');
        ['proxyjump', 'proxycommand'].forEach(function (key) {
            if (resolved[key] && resolved[key] !== 'none') {
                throw new Error(h + ' already uses ' + key + ' (' + resolved[key] + '); ssh-paste cannot take over its connection. Use wrapper mode instead: ssh-paste ' + h);
            }
        });
        added.push(h);
    });
    var all = managed.concat(added);
    var createdFile = block.CreatedFile || old === null;
    if (added.length > 0) {
        updateSshConfig(configPath, old, setManagedBlock(text, all, proxy, createdFile), false);
        say('Enabled for: ' + added.join(', '));
    } else {
        say('Already enabled; nothing changed.');
    }
    say('This block is at the top of ' + configPath + ':');
    say('');
    setManagedBlock('', all, proxy, createdFile).replace(/\s+$/, '').split(/\r?\n/).forEach(function (line) { say('    ' + line); });
    say('');
    say('Now connect as usual: ssh ' + (added.length > 0 ? added[0] : all[0]));
    return 0;
}

function disableHosts(hosts) {
    var configPath = sshConfigPath();
    var old = readConfig(configPath);
    var text = old ? old.text : null;
    var block = getManagedBlock(text);
    if (!block.Present) { say('ssh-paste is not enabled for any host.'); return 0; }
    var keep = (!hosts || hosts.length === 0) ? [] : block.Hosts.filter(function (h) { return hosts.indexOf(h) < 0; });
    var proxy = block.ProxyCommand || proxyCommandLine(launcherPath());
    var newText = setManagedBlock(text, keep, proxy, block.CreatedFile);
    if (keep.length === 0 && block.CreatedFile && newText.trim().length === 0) {
        updateSshConfig(configPath, old, null, true);
        var dir = configPath.replace(/\/[^\/]*$/, '');
        var fm = $.NSFileManager.defaultManager;
        var rest = fm.contentsOfDirectoryAtPathError(dir, null);
        if (!rest.isNil() && Number(rest.count) === 0) fm.removeItemAtPathError(dir, null);
    } else {
        updateSshConfig(configPath, old, newText, false);
    }
    say('Disabled for: ' + block.Hosts.filter(function (h) { return keep.indexOf(h) < 0; }).join(', '));
    return 0;
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
    var started = nowMs();
    try {
        var argv = uploadSshArguments(parsed, hash, bytes.length, { sshVersion: sshVersionOf(ssh) });
        var h = startTask(ssh, argv, { stdinFile: file });
        var deadline = nowMs() + 30000;
        var timedOut = false;
        while (h.task.isRunning) {
            if (nowMs() > deadline) { stopTask(h); timedOut = true; break; }
            sleepSeconds(0.02);
        }
        var r = finishTask(h);
        var outcome = uploadOutcome({ code: r.code, out: r.out, err: r.err, timedOut: timedOut, timeoutSeconds: 30, size: bytes.length, hash: hash, ext: 'png' });
        if (outcome.error) throw new Error(outcome.error);
        report(true, 'upload to ' + parsed.Destination + ': ' + outcome.path + ' (' + ((nowMs() - started) / 1000).toFixed(1) + ' s)');
    } catch (e) {
        report(false, 'upload to ' + parsed.Destination + ': ' + e.message);
        say('');
        say('Uploads use a second, non-interactive ssh connection, so the server must');
        say('accept your key without a prompt: a key without a passphrase, or a key loaded');
        say('in ssh-agent (ssh-add --apple-use-keychain). Password-only logins cannot work.');
        return 1;
    }
    var cfg = readConfig(sshConfigPath());
    if (getManagedBlock(cfg ? cfg.text : null).Hosts.indexOf(parsed.Destination) >= 0) {
        report(true, 'ssh mode: enabled, "ssh ' + parsed.Destination + '" pastes screenshots');
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
