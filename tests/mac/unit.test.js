// Unit tests of the macOS client's logic (src/ssh-paste.js), with node on any OS:
//
//   node --test tests/mac/
//
// The pure functions and the clipboard watcher run here against a simulated
// pasteboard; nothing touches a real pasteboard, window, ssh or profile. The
// tables in tests/cases.json are shared with the Pester tests of the Windows
// client, and the other cases are ports of the Pester cases of the same name
// (Describe names in the comments), so both clients are held to the same rules.
// tests/mac/jxa.sh and tests/mac/e2e.sh run the macOS parts on a Mac.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const repo = path.resolve(__dirname, '..', '..');
const m = require(path.join(repo, 'src', 'ssh-paste.js'));
const cases = JSON.parse(fs.readFileSync(path.join(repo, 'tests', 'cases.json'), 'utf8'));
const read = (p) => fs.readFileSync(path.join(repo, p), 'utf8');

function fmt(parsed) {
    return parsed.Options.map((o) => (o.Value === null ? o.Flag : o.Flag + '=' + o.Value)).join(' ');
}

// --- Split-SshArguments ------------------------------------------------------------

test('splitSshArguments (Split-SshArguments)', async (t) => {
    const s = m.splitSshArguments;
    await t.test('finds the destination; no arguments give none', () => {
        const p = s(['myhost']);
        assert.equal(p.Destination, 'myhost');
        assert.equal(p.Options.length, 0);
        assert.equal(p.Command.length, 0);
        assert.equal(s([]).Destination, null);
        assert.equal(s(null).Destination, null);
    });
    await t.test('reads option arguments glued and separate, and -oKey=Value', () => {
        assert.equal(fmt(s(['-p2222', 'h'])), 'p=2222');
        assert.equal(fmt(s(['-p', '2222', '-i', 'C:\\k y', 'h'])), 'p=2222 i=C:\\k y');
        assert.equal(fmt(s(['-oPort=22', 'h'])), 'o=Port=22');
        assert.equal(fmt(s(['-o', 'Port=22', 'h'])), 'o=Port=22');
    });
    await t.test('splits clusters, which may end in an option with an argument', () => {
        assert.equal(fmt(s(['-vT', 'h'])), 'v T');
        assert.equal(fmt(s(['-vvv', 'h'])), 'v v v');
        assert.equal(fmt(s(['-vp2222', 'h'])), 'v p=2222');
        assert.equal(fmt(s(['-vp', '2222', 'h'])), 'v p=2222');
        assert.equal(fmt(s(['-tti', 'key', 'h'])), 't t i=key');
        assert.equal(fmt(s(['-t', '-T', '-N', '-n', 'h'])), 't T N n');
    });
    await t.test('accepts options after the destination and remembers the side', () => {
        const p = s(['h', '-p', '22', '-v']);
        assert.equal(p.Destination, 'h');
        assert.equal(fmt(p), 'p=22 v');
        const q = s(['-p', '1', '-vi', 'k', 'alice@h', '-o', 'User=bob', '-t']);
        assert.equal(q.Options.map((o) => o.Flag + ':' + o.After).join(' '), 'p:false v:false i:false o:true t:true');
        assert.equal(s(['-v', '-p', '1', 'h']).Options.filter((o) => o.After).length, 0);
    });
    await t.test('starts the command at the first word after the destination, and after --', () => {
        let p = s(['h', '-v', 'ls', '-l', '-o', 'x']);
        assert.equal(fmt(p), 'v');
        assert.deepEqual(p.Command, ['ls', '-l', '-o', 'x']);
        p = s(['-p', '22', 'h', 'echo', '-n', 'hi there']);
        assert.deepEqual(p.Command, ['echo', '-n', 'hi there']);
        p = s(['-v', '--', 'h', 'ls', '-l']);
        assert.equal(p.Destination, 'h');
        assert.deepEqual(p.Command, ['ls', '-l']);
        p = s(['h', '--', '-l']);
        assert.deepEqual(p.Command, ['-l']);
        assert.equal(s(['ssh://user@host:2222/']).Destination, 'ssh://user@host:2222/');
        assert.deepEqual(s(['h', 'ls', '-j']).Command, ['ls', '-j']);
        assert.equal(fmt(s(['-o', '-weird', 'h'])), 'o=-weird');
    });
    await t.test('throws on a missing argument and on an unknown option', () => {
        assert.throws(() => s(['-p']), /-p needs an argument/);
        assert.throws(() => s(['-vi']), /-i needs an argument/);
        assert.throws(() => s(['h', '-o']), /-o needs an argument/);
        assert.throws(() => s(['-j', 'h']), /unknown ssh option -j/);
        assert.throws(() => s(['-vH', 'h']), /unknown ssh option -H/);
    });
    await t.test('covers every flag in the ssh.c getopt string', () => {
        for (const letter of '1246ACGKMNTVXYZafgknqstvxy') assert.equal(fmt(s(['-' + letter, 'h'])), letter);
        for (const letter of 'BDEFIJLOPQRSWbceilmopw') assert.equal(fmt(s(['-' + letter + 'x', 'h'])), letter + '=x');
    });
});

// --- Test-InteractiveSsh (tables shared with Pester) -----------------------------

test('testInteractiveSsh (Test-InteractiveSsh)', async (t) => {
    for (const c of cases.interactive) {
        await t.test(c.Name, () => assert.equal(m.testInteractiveSsh(m.splitSshArguments(c.Argv)), c.Expected));
    }
    for (const c of cases.interactiveEffective) {
        await t.test('with ssh -G: ' + c.Name, () => assert.equal(m.testInteractiveSsh(m.splitSshArguments(c.Argv), c.Effective), c.Expected));
    }
    for (const c of cases.lastTtyWins) {
        await t.test('the last of -t and -T wins: ' + c.Name, () => assert.equal(m.testInteractiveSsh(m.splitSshArguments(c.Argv)), c.Expected));
    }
    await t.test('reads an -o setting with white space before its name', () => {
        for (const o of [' RequestTTY=no', ' StdinNull=yes', ' SessionType=none']) {
            assert.equal(m.testInteractiveSsh(m.splitSshArguments(['-o', o, 'host'])), false, o);
        }
    });
    await t.test('a null map is no map; null and an empty destination are not interactive', () => {
        assert.equal(m.testInteractiveSsh(m.splitSshArguments(['host']), null), true);
        assert.equal(m.testInteractiveSsh(m.splitSshArguments(['host', 'uname']), null), false);
        assert.equal(m.testInteractiveSsh(null), false);
        assert.equal(m.testInteractiveSsh({ Destination: '', Options: [], Command: [] }), false);
        assert.equal(m.testInteractiveSsh(m.splitSshArguments(['host', '-N'])), false);
        assert.equal(m.testInteractiveSsh(m.splitSshArguments(['host', '-W', 'x:22'])), false);
    });
    await t.test('compares ssh -G values without regard to case, as PowerShell does', () => {
        assert.equal(m.testInteractiveSsh(m.splitSshArguments(['host']), { sessiontype: 'DEFAULT' }), true);
        assert.equal(m.testInteractiveSsh(m.splitSshArguments(['host']), { remotecommand: 'NONE' }), true);
    });
});

test('sshOptionKey (Get-SshOptionKey)', async (t) => {
    for (const c of cases.optionKey) {
        await t.test(JSON.stringify(c.Value), () => assert.equal(m.sshOptionKey(c.Value), c.Expected));
    }
    await t.test('ignores white space before the name', () => {
        assert.equal(m.sshOptionKey('  RequestTTY=force'), 'requesttty');
        assert.equal(m.sshOptionKey('\tProxyJump a'), 'proxyjump');
        assert.equal(m.sshOptionKey('   '), '');
    });
});

test('parseSshG (ConvertFrom-SshG) and parseSshVersion (Get-SshVersion)', () => {
    const g = m.parseSshG('user me\r\nHostName h.example\nport 22\nuser second\n\nbadline\nproxycommand ssh -W %h:%p j\n');
    assert.equal(g.user, 'me');
    assert.equal(g.hostname, 'h.example');
    assert.equal(g.proxycommand, 'ssh -W %h:%p j');
    assert.equal(g.badline, undefined);
    assert.deepEqual(m.parseSshVersion('OpenSSH_9.6p1 Ubuntu-3ubuntu13, OpenSSL 3.0.13 30 Jan 2024'), [9, 6]);
    assert.deepEqual(m.parseSshVersion('OpenSSH_for_Windows_8.6p1, LibreSSL 3.4.3'), [8, 6]);
    assert.deepEqual(m.parseSshVersion('OpenSSH_8.10p1, OpenSSL 3.0.2'), [8, 10]);
    assert.deepEqual(m.parseSshVersion('OpenSSH_10.5p1, LibreSSL 3.3.6'), [10, 5]);
    assert.equal(m.parseSshVersion('hello'), null);
});

// --- Get-UploadSshArguments --------------------------------------------------------

test('paste settings (--keep, --dir), the tables of tests/cases.json and the block groups', async (t) => {
    const H = '0123456789abcdef0123456789abcdef';
    await t.test('takes and refuses --keep values', () => {
        for (const c of cases.keepAccept) assert.equal(m.keepMinutesOf(c.Value), c.Minutes, c.Value);
        for (const c of cases.keepReject) assert.throws(() => m.keepMinutesOf(c.Value), /--keep/, JSON.stringify(c.Value));
    });
    await t.test('takes and refuses --dir values', () => {
        for (const c of cases.dirAccept) assert.equal(m.testServerDirectory(c.Value), true, c.Value);
        for (const c of cases.dirReject) assert.equal(m.testServerDirectory(c.Value), false, c.Value);
    });
    await t.test('checks the path the server answers', () => {
        for (const c of cases.replyPaths) {
            if (c.Ok) assert.equal(m.readUploadReply('9 ' + c.Path, 9, H, 'png', c.Dir, c.Class), c.Path, c.Name);
            else assert.throws(() => m.readUploadReply('9 ' + c.Path, 9, H, 'png', c.Dir, c.Class), /unexpected/, c.Name);
        }
        assert.throws(() => m.readUploadReply('nodir', 9, H, 'png', '~/shots'), /cannot write to the folder ~\/shots/);
        assert.throws(() => m.readUploadReply('notprivate', 9, H, 'png', '/data/x'), /not yours alone/);
    });
    await t.test('reads ssh mode and its settings from the ProxyCommand of ssh -G (Get-SshModeSettings)', () => {
        for (const c of cases.sshModeSettings) {
            const got = m.sshModeSettings(c.Line === null ? {} : { proxycommand: c.Line });
            assert.deepEqual(got, c.Keep === null ? null : { Keep: c.Keep, Dir: c.Dir }, c.Name);
        }
        assert.equal(m.sshModeSettings(null), null);
    });
    await t.test('reads what an ssh error says, and whether trying again can help (Get-SshFailure)', () => {
        for (const c of cases.sshFailures) {
            const f = m.sshFailure(c.Text);
            if (c.Kind === null) assert.equal(f, null, c.Name);
            else assert.equal(f.kind, c.Kind, c.Name);
            if (c.Methods) { assert.deepEqual(f.methods, c.Methods, c.Name); assert.equal(f.keyLogin, c.KeyLogin, c.Name); assert.equal(f.typed, c.Typed, c.Name); }
            assert.equal(m.failureFinal(f), c.Final, c.Name);
        }
    });
    await t.test('gives the key setup commands [-p PORT] [USER@]HOST from the --doctor arguments (Get-KeySetupTarget)', () => {
        for (const c of cases.keySetupTargets) assert.deepEqual(m.keySetupTarget(m.splitSshArguments(c.SshArgs)), { Target: c.Target, Dropped: c.Dropped }, c.Name);
    });
    await t.test('refuses --enable for a host only when the server refused the login (Get-EnableRefusal)', () => {
        for (const c of cases.enableRefusals) assert.equal(m.enableRefusal('h', c.Said) !== null, c.Refuse, c.Name);
        const lines = m.enableRefusal('build', 'xu@build: Permission denied (publickey,password).');
        assert.equal(lines[0], 'build did not accept a key for uploads (they cannot type a password): set up a key, or load yours with ssh-add');
        assert.ok(lines.includes('    ssh-copy-id -i ~/.ssh/id_ed25519.pub build'));
    });
    await t.test('writes words as a command line to type again in zsh (Format-ShellWords)', () => {
        for (const c of cases.shellWords) assert.equal(m.formatShellWords(c.Words), c.Expected, c.Name);
        assert.equal(m.formatShellWords(["it's"]), "'it'\\''s'");
    });
    await t.test('says whether uploads to a host log in, and what to do (Get-LoginReport)', () => {
        for (const c of cases.loginReports) assert.equal(m.loginReport(c.HostName, c.Said), c.Expected, c.Name);
    });
    await t.test('prints the commands that set up a key on macOS, as the READMEs show them', () => {
        const lines = m.keySetupLines('-p 2222 build');
        assert.ok(lines.includes('    ssh-keygen -t ed25519'));
        assert.ok(lines.includes('    ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 build'));
        assert.ok(lines.includes('    ssh-paste --doctor -p 2222 build'));
        for (const readme of ['README.md', 'README.zh-CN.md']) {
            const text = fs.readFileSync(path.join(__dirname, '..', '..', readme), 'utf8');
            assert.ok(text.includes('ssh-copy-id -i ~/.ssh/id_ed25519.pub myhost'), readme + ' shows ssh-copy-id');
            assert.ok(text.includes('ssh-add --apple-use-keychain ~/.ssh/id_ed25519'), readme + ' shows ssh-add');
        }
    });
    await t.test('says what --disable removed, or that the host was not enabled (Get-DisableMessage)', () => {
        for (const c of cases.disableMessages) assert.equal(m.disableMessage(c.Managed, c.Asked), c.Expected, c.Name);
    });
    await t.test('makes --dir absolute with the home folder on the server', () => {
        for (const c of cases.absoluteDirs) {
            if (c.Expected !== null) assert.equal(m.absoluteDirectory(c.Dir, c.ServerHome), c.Expected, c.Name);
            else assert.throws(() => m.absoluteDirectory(c.Dir, c.ServerHome), /cannot use/, c.Name);
        }
    });
    await t.test('reads the settings of ProxyCommand lines', () => {
        for (const c of cases.proxySettings) assert.deepEqual(m.proxySettings(c.Line), { Keep: c.Keep, Dir: c.Dir }, c.Name);
    });
    await t.test('reads leading --keep and --dir in any order, once each', () => {
        const r = m.readPasteSettings(['--dir', '~/s', '--keep', '2h', '-p', '22', 'host']);
        assert.deepEqual([r.Keep, r.Dir, r.Rest], ['2h', '~/s', ['-p', '22', 'host']]);
        assert.deepEqual(m.readPasteSettings(['host', '--keep', '2h']).Rest, ['host', '--keep', '2h']);
        assert.throws(() => m.readPasteSettings(['--keep', '1d', '--keep', '2d', 'h']), /given twice/);
        assert.throws(() => m.readPasteSettings(['--dir']), /needs a value/);
        assert.throws(() => m.readPasteSettings(['--dir', '/Users/x y', 'h']), /quote ~/);
        assert.equal(m.readPasteSettings(['--dir', '/data/x/', 'h']).Dir, '/data/x');
        assert.equal(m.readPasteSettings(['--dir', '~/', 'h']).Dir, '~');
        assert.throws(() => m.readPasteSettings(['--dir', '/', 'h']), /--dir takes/);
        assert.throws(() => m.readPasteSettings(['--keep', '', 'h']), /--keep/);
        assert.deepEqual(['1d', undefined, '7d', 'never'].map(m.keepClass), ['', '', 'k7d-', 'knever-']);
        assert.deepEqual(['alice@build', 'ssh://alice@build:2222', 'ssh://[::1]:22'].map(m.destinationHost), ['build', 'build', '::1']);
    });
    await t.test('writes --keep and --dir into the ProxyCommand only when not the defaults, in single quotes', () => {
        const base = m.proxyCommandLine('/a/ssh-paste');
        assert.equal(m.proxyCommandLine('/a/ssh-paste', '1d', '/tmp'), base);
        assert.equal(m.proxyCommandLine('/a/ssh-paste', 'never', '~/shots'), base + " --keep 'never' --dir '~/shots'");
        assert.deepEqual(m.proxySettings(m.proxyCommandLine('/a/ssh-paste', '30m', '/data/x')), { Keep: '30m', Dir: '/data/x' });
    });
    await t.test('groups hosts with the same settings, and reads the groups back', () => {
        const groups = m.settingsGroups([['h1', { Keep: '7d', Dir: '~/s' }], ['h2', { Keep: '1d', Dir: '/tmp' }], ['h3', { Keep: '7d', Dir: '~/s' }]], '/a/ssh-paste');
        assert.deepEqual(groups.map((g) => g.Hosts), [['h1', 'h3'], ['h2']]);
        const text = m.setManagedBlock('Host other\n', null, null, true, groups);
        const b = m.getManagedBlock(text);
        assert.deepEqual(b.Hosts, ['h1', 'h3', 'h2']);
        assert.deepEqual(m.proxySettings(b.Groups[0].ProxyCommand), { Keep: '7d', Dir: '~/s' });
        assert.deepEqual(m.proxySettings(b.Groups[1].ProxyCommand), { Keep: '1d', Dir: '/tmp' });
        assert.equal(m.setManagedBlock(text, null, null, false, [{ Hosts: [], ProxyCommand: 'x' }]), 'Host other\n');
        assert.equal(m.setManagedBlock('', ['a'], 'P', false), m.setManagedBlock('', null, null, false, [{ Hosts: ['a'], ProxyCommand: 'P' }]));
    });
    await t.test('pastes a path again without a new upload for at most half of --keep, and 6 hours at most', () => {
        assert.deepEqual([1440, 0, 60, 30].map(m.uploadCacheHours), [6, 6, 0.5, 0.25]);
    });
});

test('uploadSshArguments (Get-UploadSshArguments)', async (t) => {
    const H = '0123456789abcdef0123456789abcdef';
    const up = (argv, o) => m.uploadSshArguments(m.splitSshArguments(argv), H, (o && o.size) || 1234, o || {});
    const optionPart = (a) => a.slice(0, -1);
    await t.test('starts with -T -x and the hardening options, before every user option', () => {
        const a = up(['host']);
        assert.equal(a[0], '-T');
        assert.equal(a[1], '-x');
        for (const o of ['BatchMode=yes', 'PermitLocalCommand=no', 'ClearAllForwardings=yes', 'RemoteCommand=none', 'RequestTTY=no',
            'ForwardAgent=no', 'ControlMaster=no', 'ControlPath=none', 'ConnectTimeout=10', 'ServerAliveInterval=10',
            'ServerAliveCountMax=2', 'LogLevel=ERROR']) {
            assert.equal(a[a.indexOf(o) - 1], '-o', o);
        }
        const b = up(['-o', 'ConnectTimeout=99', '-F', 'cfg', 'host', '-o', 'ServerAliveInterval=99']);
        assert.ok(b.indexOf('ConnectTimeout=10') < b.indexOf('ConnectTimeout=99'));
        assert.ok(b.indexOf('ServerAliveInterval=10') < b.indexOf('ServerAliveInterval=99'));
        assert.ok(b.indexOf('LogLevel=ERROR') < b.indexOf('-F'));
    });
    await t.test('keeps the options that identify the server and the credentials, in order', () => {
        const a = up(['-4', '-C', '-i', 'C:\\k y', '-p', '2222', '-l', 'me', '-F', 'cfg', '-o', 'IdentitiesOnly=yes', '-b', '10.0.0.1', '-c', 'aes128-ctr', '-m', 'hmac-sha2-256', 'host']);
        assert.ok(a.includes('-4') && a.includes('-C'));
        for (const [f, v] of [['-i', 'C:\\k y'], ['-p', '2222'], ['-l', 'me'], ['-F', 'cfg'], ['-o', 'IdentitiesOnly=yes'], ['-b', '10.0.0.1'], ['-c', 'aes128-ctr'], ['-m', 'hmac-sha2-256']]) {
            assert.equal(a[a.lastIndexOf(f) + 1], v);
        }
        const b = up(['-p', '1', '-i', 'k', '-l', 'u', 'host']);
        assert.ok(b.lastIndexOf('-p') < b.lastIndexOf('-i') && b.lastIndexOf('-i') < b.lastIndexOf('-l'));
    });
    await t.test('keeps each user option on its side of the destination and never uses --', () => {
        let a = up(['alice@h', '-o', 'User=bob']);
        assert.ok(a.lastIndexOf('User=bob') > a.indexOf('alice@h'));
        a = up(['-o', 'User=bob', 'alice@h']);
        assert.ok(a.lastIndexOf('User=bob') < a.indexOf('alice@h'));
        a = up(['-p', '1', '-i', 'k1', 'alice@h', '-l', 'zed', '-i', 'k2']);
        const d = a.indexOf('alice@h');
        assert.ok(a.indexOf('k1') < d && a.indexOf('-l') > d);
        assert.equal(a.lastIndexOf('k2'), a.length - 2);
        assert.ok(!up(['-p', '22', 'user@host']).includes('--'));
        a = up(['host', '-p', '22']);
        assert.deepEqual(a.slice(-4, -1), ['host', '-p', '22']);
        assert.match(a[a.length - 1], /^sh -c /);
    });
    await t.test('adds StdinNull, SessionType and ForkAfterAuthentication from ssh 8.7 on', () => {
        for (const [v, want] of [[[8, 7], true], [[8, 8], true], [[8, 10], true], [[9, 9], true], [[10, 0], true], [[8, 6], false], [[7, 9], false], [[8, 1], false]]) {
            const joined = ' ' + up(['host'], { sshVersion: v }).join(' ') + ' ';
            for (const pin of ['StdinNull=no', 'SessionType=default', 'ForkAfterAuthentication=no']) assert.equal(joined.includes(' ' + pin + ' '), want, pin + ' ' + v);
        }
        assert.doesNotMatch(up(['host']).join(' '), /StdinNull|SessionType|ForkAfterAuthentication/);
        const a = up(['-o', 'StdinNull=yes', '-o', 'SessionType=none', 'host'], { sshVersion: [9, 0] });
        assert.ok(!a.includes('StdinNull=yes') && !a.includes('SessionType=none'));
    });
    await t.test('drops every setting of the drop list, in every spelling', () => {
        const leaked = [];
        for (const key of m.SSH_DROP_OPTIONS) {
            for (const argv of [['-o', key + '=USERVAL', 'host'], ['-o', key.toUpperCase() + '=USERVAL', 'host'], ['-o', key + ' USERVAL', 'host'],
                ['-o' + key + '=USERVAL', 'host'], ['host', '-o', key + '=USERVAL'], ['host', '-o', key + ' = USERVAL']]) {
                if (optionPart(up(argv)).join(' ').includes('USERVAL')) leaked.push(argv.join(' '));
            }
        }
        assert.deepEqual(leaked, []);
        const a = up(['-o', 'IdentitiesOnly=yes', '-o', 'ProxyCommand=ssh -W %h:%p jump', '-o', 'ProxyJump=j2', 'host']);
        assert.ok(a.includes('ProxyCommand=ssh -W %h:%p jump') && a.includes('ProxyJump=j2'));
        const joined = ' ' + optionPart(up(['-A', '-X', '-Y', '-g', '-k', '-q', '-v', '-a', '-t', '-L', '1:h:2', '-R', '3:h:4', '-D', '5', '-E', 'log', '-S', 'ctl', '-w', '0:0', '-e', '^', '-s', '-V', 'host'])).join(' ') + ' ';
        for (const bad of [' -A ', ' -X ', ' -Y ', ' -g ', ' -k ', ' -q ', ' -v ', ' -a ', ' -t ', ' -L ', ' -R ', ' -D ', ' -E ', ' -S ', ' -w ', ' -e ', ' -s ', ' -V ', ' 1:h:2 ']) {
            assert.ok(!joined.includes(bad), bad);
        }
        assert.doesNotMatch(optionPart(up(['-N', '-f', '-W', 'x:1', 'host'])).join(' '), / -[NfW] /);
    });
    await t.test('with noProxy, drops -J, ProxyCommand and ProxyJump and adds ProxyCommand=none', () => {
        assert.equal(up(['-J', 'jump', 'host'])[up(['-J', 'jump', 'host']).indexOf('-J') + 1], 'jump');
        const b = up(['-J', 'jump', 'host'], { noProxy: true });
        assert.ok(!b.includes('-J') && !b.includes('jump'));
        const c = up(['-o', 'ProxyCommand=evil', '-o', 'proxyjump=evil2', 'host', '-o', 'PROXYCOMMAND=evil3', '-oProxyJump=evil4', '-J', 'evil5'], { noProxy: true });
        assert.doesNotMatch(optionPart(c).join(' '), /evil/);
        assert.doesNotMatch(up(['host']).join(' '), /ProxyCommand/);
        const d = up(['-o', 'IdentitiesOnly=yes', 'host'], { noProxy: true });
        assert.ok(d.indexOf('ProxyCommand=none') > 0 && d.indexOf('ProxyCommand=none') < d.indexOf('IdentitiesOnly=yes'));
    });
    await t.test('with a pin, adds HostName, Port, HostKeyAlias, CheckHostIP and CanonicalizeHostname before the user options', () => {
        const pin = { HostName: '203.0.113.7', Port: 2200, HostKeyAlias: '[myhost]:2200' };
        const a = up(['-p', '2222', '-o', 'HostName=evil', '-o', 'IdentitiesOnly=yes', 'me@host', '-o', 'Port=1'], { noProxy: true, pin });
        const none = a.indexOf('ProxyCommand=none');
        assert.equal(a[none + 2], 'HostName=203.0.113.7');
        const last = a.indexOf('CanonicalizeHostname=no');
        for (const o of ['Port=2200', 'HostKeyAlias=[myhost]:2200', 'CheckHostIP=no']) assert.equal(a[a.indexOf(o) - 1], '-o');
        for (const user of ['-p', 'HostName=evil', 'IdentitiesOnly=yes', 'me@host', 'Port=1']) assert.ok(a.indexOf(user) > last, user);
        assert.doesNotMatch(up(['host'], { noProxy: true }).join(' '), /HostName=|Port=|HostKeyAlias|CheckHostIP|CanonicalizeHostname/);
    });
    await t.test('makes the last argument exactly the sh -c command, never the session command', () => {
        const a = up(['host'], { size: 4321 });
        assert.equal(a[a.length - 1], "sh -c '" + m.REMOTE_SCRIPT + "' ssh-paste " + H + " 4321 png 1440 '/tmp'");
        const b = up(['host', 'rm', '-rf', '/']);
        assert.doesNotMatch(b.join(' '), /rm -rf/);
        assert.equal(b[b.length - 2], 'host');
        assert.match(m.uploadSshArguments(m.splitSshArguments(['h']), H, 1, { ext: 'jpeg' }).pop(), / 1 jpeg 1440 '\/tmp'$/);
        assert.match(m.uploadSshArguments(m.splitSshArguments(['h']), H, 9, { keep: 'never', dir: '/home/u/shots' }).pop(), / 9 png 0 '\/home\/u\/shots' knever-$/);
        assert.throws(() => m.uploadSshArguments(m.splitSshArguments(['h']), H, 9, { dir: '~/shots' }), /bad --dir/);
        assert.match(m.uploadSshArguments(m.splitSshArguments(['h']), H, 9, { keep: '2h' }).pop(), / 9 png 120 '\/tmp' k2h-$/);
        assert.throws(() => m.uploadSshArguments(m.splitSshArguments(['h']), H, 9, { dir: "/tmp'x" }), /bad --dir/);
        assert.throws(() => m.uploadSshArguments(m.splitSshArguments(['h']), H, 9, { keep: '1w' }), /--keep/);
    });
    await t.test('rejects anything that is not 32 lower-case hex digits, and an unknown extension', () => {
        const parsed = m.splitSshArguments(['host']);
        for (const bad of ['', 'abc', '../x.png', H + '.png', H.slice(1), H + '0', H.toUpperCase(), H.slice(0, 31) + 'g', H + '\n', '\n' + H, ' ' + H, H + ';id', '/tmp/' + H]) {
            assert.throws(() => m.uploadSshArguments(parsed, bad, 1), /bad image hash/, JSON.stringify(bad));
        }
        assert.throws(() => m.uploadSshArguments(parsed, H, 1, { ext: 'exe' }), /bad image extension/);
        assert.throws(() => m.uploadSshArguments(parsed, H, 1, { ext: 'PNG' }), /bad image extension/);
    });
});

// --- Read-UploadReply ----------------------------------------------------------------

test('readUploadReply (Read-UploadReply)', async (t) => {
    const H = '0123456789abcdef0123456789abcdef';
    const P = '/tmp/ssh-paste-' + H + '.png';
    const r = m.readUploadReply;
    await t.test('returns the path of a good reply, the per-user name, CRLF, and after noise lines', () => {
        assert.equal(r('1234 ' + P + '\n', 1234, H), P);
        assert.equal(r('1234 /tmp/ssh-paste-' + H + '-1000.png\n', 1234, H), '/tmp/ssh-paste-' + H + '-1000.png');
        assert.equal(r('1234 /tmp/ssh-paste-' + H + '-4294967295.png', 1234, H), '/tmp/ssh-paste-' + H + '-4294967295.png');
        assert.equal(r('1234 ' + P + '\r\n', 1234, H), P);
        assert.equal(r('Welcome to Ubuntu\n\nLast login: Mon Nov 23\nsome rc output\n1234 ' + P + '\n\n', 1234, H), P);
        assert.equal(r('5000000000 ' + P, 5000000000, H), P);
        assert.equal(r('7 /tmp/ssh-paste-' + H + '.jpg', 7, H, 'jpg'), '/tmp/ssh-paste-' + H + '.jpg');
    });
    await t.test('rejects a size mismatch, a short upload and an empty reply', () => {
        assert.throws(() => r('1233 ' + P, 1234, H), /size mismatch.*sent 1234.*server has 1233/);
        assert.throws(() => r('short 10\n', 1234, H), /received 10 of 1234 bytes/);
        assert.throws(() => r('banner\nshort 0\r\n', 1234, H), /received 0 of 1234 bytes/);
        assert.throws(() => r('', 1, H), /no reply/);
        assert.throws(() => r('  \n\r\n ', 1, H), /no reply/);
        assert.throws(() => r(null, 1, H), /no reply/);
    });
    for (const c of cases.badReplyPaths) {
        await t.test('rejects ' + c.Name, () => assert.throws(() => r('1234 ' + c.Path, 1234, H), /unexpected path/));
    }
    await t.test('rejects a last line that is not a reply', () => {
        assert.throws(() => r('1234 ' + P + '\nConnection closed.', 1234, H), /unexpected reply.*Connection closed/);
        for (const bad of ['Permission denied', '1234 ' + P + ' extra', 'abc ' + P, 'short', 'short x']) {
            assert.throws(() => r(bad, 1234, H), /unexpected reply/, bad);
        }
    });
});

test('uploadOutcome (the errors of Send-Image)', () => {
    const H = '0123456789abcdef0123456789abcdef';
    const base = { code: 0, out: '', err: '', timedOut: false, timeoutSeconds: 30, size: 4, hash: H, ext: 'png' };
    assert.deepEqual(m.uploadOutcome({ ...base, out: '4 /tmp/ssh-paste-' + H + '.png\n' }), { path: '/tmp/ssh-paste-' + H + '.png' });
    assert.deepEqual(m.uploadOutcome({ ...base, code: 255, err: 'Permission denied (publickey).\n' }), { error: 'ssh exited with 255: Permission denied (publickey).' });
    assert.deepEqual(m.uploadOutcome({ ...base, code: 4, out: 'banner\nshort 120\n' }), { error: 'ssh exited with 4: short 120' });
    assert.deepEqual(m.uploadOutcome({ ...base, code: 1 }), { error: 'ssh exited with 1: no error message' });
    assert.match(m.uploadOutcome({ ...base, timedOut: true, err: 'a\nb\nconnect to host x port 22: timed out' }).error, /^ssh did not finish in 30 seconds; ssh said: a \| b \| connect to host/);
    assert.match(m.uploadOutcome({ ...base, out: 'junk' }).error, /unexpected reply/);
});

// --- host aliases, the ProxyCommand and the managed block ---------------------------

test('testHostAlias (Test-HostAlias)', async (t) => {
    for (const c of cases.hostAliasAccept) await t.test('accepts ' + c.Name, () => assert.equal(m.testHostAlias(c.Value), true));
    for (const c of cases.hostAliasReject) await t.test('rejects ' + c.Name, () => assert.equal(m.testHostAlias(c.Value), false));
});

test('proxyCommandLine (the macOS ProxyCommand)', () => {
    const tail = " --proxy '%h' %p '%n'";
    assert.equal(m.proxyCommandLine('/Users/me/.local/share/ssh-paste/bin/ssh-paste'), "'/Users/me/.local/share/ssh-paste/bin/ssh-paste'" + tail);
    // ssh expands % first; the shell then reads one single-quoted word.
    assert.equal(m.proxyCommandLine('/Users/Jo Doe/50%off/ssh-paste'), "'/Users/Jo Doe/50%%off/ssh-paste'" + tail);
    assert.equal(m.proxyCommandLine("/Users/o'neil/ssh-paste"), "'/Users/o'\\''neil/ssh-paste'" + tail);
    assert.throws(() => m.proxyCommandLine('relative/ssh-paste'), /not absolute/);
    assert.throws(() => m.proxyCommandLine('/a\nb'), /line break/);
});

test('the ProxyCommand passes a Host alias with [ ] to the launcher unchanged under zsh', { skip: !require('node:fs').existsSync('/bin/zsh') && 'no zsh' }, () => {
    // ssh expands %h %p %n, then runs the line with the login shell. Unquoted,
    // zsh takes work[1] for a file pattern and stops with "no matches found".
    const line = m.proxyCommandLine('/bin/echo').replace(/%h/g, 'work[1]').replace(/%p/g, '22').replace(/%n/g, 'work[1]');
    const r = require('node:child_process').spawnSync('/bin/zsh', ['-c', 'exec ' + line], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, '--proxy work[1] 22 work[1]\n');
});

test('destinationHost is the host ssh expands as %n', () => {
    // Measured with OpenSSH 10.2: ProxyCommand "echo %n" for each destination.
    const seen = { 'Work[1]': 'Work[1]', 'u@Work': 'Work', 'ssh://u@Host:2222': 'Host', 'u@h@x': 'x', 'HOST': 'HOST', 'ssh://[::1]:22': '::1',
        'ssh://alice@ops.example.:2222': 'ops.example', 'ops.example.': 'ops.example.', 'alice@ops.example.': 'ops.example.' };
    for (const [d, n] of Object.entries(seen)) assert.equal(m.destinationHost(d), n, d);
    // ps joins arguments with spaces: -i "/Users/me/SSH Keys/id" host reads as -i /Users/me/SSH, destination Keys/id.
    const parsed = m.splitSshArguments('-t -i /Users/me/SSH Keys/id_ed25519 alice@host'.split(' '));
    assert.notEqual(m.destinationHost(parsed.Destination), 'host');
});

test('the managed block (Get-ManagedBlock, Set-ManagedBlock)', async (t) => {
    const B = m.BLOCK_BEGIN, E = m.BLOCK_END, C = m.BLOCK_CREATED_FILE;
    const proxy = m.proxyCommandLine('/Users/me/.local/share/ssh-paste/bin/ssh-paste');
    const add = (text, hosts, created) => m.setManagedBlock(text, hosts, proxy, created);
    const remove = (text) => m.setManagedBlock(text, [], proxy);
    await t.test('writes the documented block into an empty config, with and without the created-file line', () => {
        assert.equal(add('', ['myhost']), B + '\nHost myhost\n    ProxyCommand ' + proxy + '\n    ProxyUseFdpass no\nHost *\n' + E + '\n');
        assert.equal(add('', ['myhost'], true), B + '\n' + C + '\nHost myhost\n    ProxyCommand ' + proxy + '\n    ProxyUseFdpass no\nHost *\n' + E + '\n');
        assert.equal(add(null, ['a']), add('', ['a']));
        assert.equal(remove(null), '');
        assert.match(add('', ['a', 'b', 'c']), /^Host a b c$/m);
    });
    for (const c of cases.blockRoundTrip) {
        await t.test('removes everything it added: ' + c.Name, () => {
            const added = add(c.Text, ['myhost']);
            assert.ok(m.getManagedBlock(added).Hosts.includes('myhost'));
            assert.equal(remove(added), c.Text);
            assert.equal(remove(add(c.Text, ['h1', 'h2'], true)), c.Text);
        });
    }
    await t.test('uses CRLF when the file does, replaces instead of stacking, and keeps other hosts', () => {
        const crlf = 'Host a\r\n  HostName x\r\n';
        const n = add(crlf, ['myhost']);
        assert.equal(n.replace(/\r\n/g, '').includes('\n'), false);
        assert.equal(remove(n), crlf);
        const orig = 'Host a\n  HostName x\n';
        const twice = m.setManagedBlock(add(orig, ['myhost']), ['myhost', 'other'], proxy);
        assert.equal(twice.split(B).length - 1, 1);
        assert.deepEqual(m.getManagedBlock(twice).Hosts, ['myhost', 'other']);
        assert.equal(m.setManagedBlock(add(orig, ['myhost']), ['myhost'], proxy), add(orig, ['myhost']));
        assert.deepEqual(m.getManagedBlock(m.setManagedBlock(add(orig, ['h1', 'h2']), ['h2'], proxy)).Hosts, ['h2']);
    });
    await t.test('keeps global options after the trailing Host *, and refuses a block without an end', () => {
        const lines = add('ServerAliveInterval 30\nAddKeysToAgent yes\n\nHost a\n', ['myhost']).split('\n');
        const star = lines.indexOf('Host *');
        assert.equal(lines[star + 1], E);
        assert.equal(lines[star + 2], 'ServerAliveInterval 30');
        assert.throws(() => remove(B + '\nHost a\n    ProxyCommand x\nHost b\n'), /no end marker/);
        const note = '# note: ' + B + '\nHost a\n';
        assert.equal(remove(note), note);
    });
    await t.test('reads hosts, ProxyCommand and the created-file flag only inside the block', () => {
        for (const text of [null, '', 'Host a\n  HostName x\n']) {
            const b = m.getManagedBlock(text);
            assert.deepEqual([b.Present, b.Hosts.length, b.ProxyCommand, b.CreatedFile], [false, 0, null, false]);
        }
        const text = C + '\nHost before\n    ProxyCommand before\n' + B + '\r\n' + C + '\r\nHost a b *\r\n    ProxyCommand x y\r\nHost *\r\n' + E + '\r\nHost after\n    ProxyCommand after\n';
        const b = m.getManagedBlock(text);
        assert.deepEqual([b.Present, b.Hosts, b.ProxyCommand, b.CreatedFile], [true, ['a', 'b'], 'x y', true]);
        assert.equal(m.getManagedBlock(B + '\nHost a\n    ProxyCommand x\nHost *\n' + E + '\n').CreatedFile, false);
        assert.equal(m.getManagedBlock('# >>> ssh-paste something else >>>\nHost a\n').Present, false);
        const back = m.getManagedBlock(add('Host z\n', ['h1', 'h2'], true));
        assert.deepEqual([back.Hosts, back.ProxyCommand, back.CreatedFile], [['h1', 'h2'], proxy, true]);
    });
    await t.test('writes ASCII only', () => assert.match(add('', ['a']), /^[\x20-\x7e\r\n]+$/));
});

test('checkReleaseChecksum (Test-ReleaseChecksum) and parseShasum', () => {
    const hex = 'a'.repeat(64);
    const sums = 'b'.repeat(64) + '  ssh-paste.js\n' + hex.toUpperCase() + ' *install.sh\r\n';
    assert.equal(m.checkReleaseChecksum(sums, 'install.sh', hex), true);
    assert.equal(m.checkReleaseChecksum(sums, 'install.sh', 'c'.repeat(64)), false);
    assert.equal(m.checkReleaseChecksum(sums, 'install', hex), false);
    assert.equal(m.checkReleaseChecksum('', 'install.sh', hex), false);
    assert.equal(m.parseShasum(hex + '  /tmp/x\n'), hex);
    assert.equal(m.parseShasum('shasum: /tmp/x: No such file'), null);
});

// --- macOS-only helpers ------------------------------------------------------------

test('the pasteboard marker', () => {
    const tok = '0123456789abcdef';
    const s = m.makeMarker(77, tok, '/tmp/a.png', ['/Users/me/a.png']);
    assert.deepEqual(m.parseMarker(s), { owner: 77, token: tok, text: '/tmp/a.png', files: ['/Users/me/a.png'] });
    assert.deepEqual(m.parseMarker(m.makeMarker(0, tok, null, null)), { owner: 0, token: tok, text: '', files: null });
    for (const bad of ['', 'x', '{}', '[]', 'null', JSON.stringify({ owner: -1, token: tok, text: '' }), JSON.stringify({ owner: 1.5, token: tok, text: '' }),
        JSON.stringify({ owner: 1, token: 'XYZ', text: '' }), JSON.stringify({ owner: 1, token: tok, text: 3 }),
        JSON.stringify({ owner: 1, token: tok, text: '', files: [] }), JSON.stringify({ owner: 1, token: tok, text: '', files: ['relative.png'] }),
        JSON.stringify({ owner: 1, token: tok, text: '', files: new Array(21).fill('/a.png') })]) {
        assert.equal(m.parseMarker(bad), null, bad);
    }
});

test('processes, the terminal and image files', () => {
    assert.deepEqual(m.splitPsArgs('  ssh -p 22  host\n'), ['ssh', '-p', '22', 'host']);
    // ps joins argv with spaces: an option value with a space reads as a destination and a
    // command, so the session looks non-interactive (the README says to use wrapper mode).
    assert.equal(m.testInteractiveSsh(m.splitSshArguments(m.splitPsArgs('ssh -i /path/with space/key myhost').slice(1))), false);
    assert.equal(m.testInteractiveSsh(m.splitSshArguments(m.splitPsArgs('ssh -i /path/key myhost').slice(1))), true);
    assert.deepEqual(m.splitPsArgs(''), []);
    assert.deepEqual(m.parseProcessTable('    1     0\n  501   1\n junk\n 777  501 \n'), { 1: 0, 501: 1, 777: 501 });
    assert.deepEqual(m.terminalFromEnvironment({ SSH_PASTE_TERMINAL: 'x.y', __CFBundleIdentifier: 'com.apple.Terminal' }), { bundle: 'x.y', from: 'SSH_PASTE_TERMINAL' });
    assert.equal(m.terminalFromEnvironment({ __CFBundleIdentifier: 'com.apple.Terminal', TERM_PROGRAM: 'iTerm.app' }).bundle, 'com.apple.Terminal');
    assert.equal(m.terminalFromEnvironment({ TERM_PROGRAM: 'iTerm.app' }).bundle, 'com.googlecode.iterm2');
    assert.equal(m.terminalFromEnvironment({ TERM_PROGRAM: 'tmux' }), null);
    assert.equal(m.terminalFromEnvironment({}), null);
    assert.equal(m.imageFileExtension('/a/b/Shot 1.PNG'), 'png');
    assert.equal(m.imageFileExtension('/a/b.c/photo.JpEg'), 'jpeg');
    assert.equal(m.imageFileExtension('/a/b/notes.txt'), null);
    assert.equal(m.imageFileExtension('/a/b/.png'), null);
    assert.equal(m.imageFileExtension('/a/b/png'), null);
    assert.equal(m.retryDelaySeconds(1), 30);
    assert.equal(m.retryDelaySeconds(7), 1800);
});

test('doctorPng is a valid PNG with a note, and base64FromBytes matches node', () => {
    const bytes = Buffer.from(m.doctorPng('ssh-paste test 1234'));
    assert.deepEqual([...bytes.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    let pos = 8;
    const types = [];
    while (pos < bytes.length) {
        const len = bytes.readUInt32BE(pos);
        const type = bytes.subarray(pos + 4, pos + 8);
        const data = bytes.subarray(pos + 8, pos + 8 + len);
        const crc = bytes.readUInt32BE(pos + 8 + len);
        assert.equal(m.crc32([...type, ...data]), crc, 'CRC of ' + type);
        if (type.toString() === 'IDAT') require('node:zlib').inflateSync(data);
        types.push(type.toString());
        pos += 12 + len;
    }
    assert.deepEqual(types, ['IHDR', 'IDAT', 'tEXt', 'IEND']);
    assert.ok(bytes.includes(Buffer.from('ssh-paste test 1234')));
    assert.notDeepEqual(m.doctorPng('a'), m.doctorPng('b'));
    for (const n of [0, 1, 2, 3, 4, 5, 64, 100]) {
        const b = crypto.randomBytes(n);
        assert.equal(m.base64FromBytes([...b]), b.toString('base64'));
    }
});

// --- the watcher against a simulated pasteboard ---------------------------------
//
// The port of Pester's "watcher state machine (Invoke-WatcherTick, Restore-Clipboard)
// against a simulated clipboard". The world is the entry on the pasteboard and its
// change count; P is the platform object of src/ssh-paste.js. Windows 1001 and 3003
// are terminal windows, 2002 and 5005 other apps.

const TerminalA = 1001, Other = 2002, TerminalB = 3003, OtherToo = 5005;
let tokenCounter = 0;

function hash16(buf) {
    return crypto.createHash('sha256').update(buf).digest('hex').substring(0, 32);
}

function fakePng(seed) {
    const b = Buffer.alloc(64);
    for (let i = 0; i < 64; i++) b[i] = (i * 7 + seed * 31) % 251;
    return b;
}

function pathFor(png, dir) {
    return (dir || '/tmp') + '/ssh-paste-' + hash16(png) + '.png';
}

function newWorld() {
    const w = {
        fg: 0, seq: 1, entry: null, writes: [], uploads: [], reads: 0, failNext: 0, duringUpload: null, afterRead: null,
        beforeWrite: null, readFails: 0, prefix: {}, clock: 1700000000000, hold: false, beeps: 0, logs: []
    };
    w.P = {
        now: () => w.clock,
        foreground: () => w.fg,
        changeCount: () => w.seq,
        readState: () => {
            if (w.readFails > 0) { w.readFails--; throw new Error('the clipboard is busy'); }
            w.reads++;
            const e = w.entry;
            const s = { Seq: w.seq, Png: null, Hash: null, HasText: false, HasFiles: false, Owner: null, Token: null, Text: null, Files: null, Items: null };
            if (e) {
                s.HasText = !!e.Text;
                s.HasFiles = !!e.HasFiles;
                if (e.Png) {
                    s.Png = e.Png;
                    s.Hash = hash16(e.Png);
                    s.Items = e.Items || [{ Hash: s.Hash, Ext: 'png', Size: e.Png.length }];
                    if (e.Owner !== null) {
                        s.Owner = e.Owner;
                        s.Token = e.Token;
                        if (s.HasText) s.Text = e.Text;
                    }
                }
            }
            if (w.afterRead) w.afterRead();
            return s;
        },
        publish: (e) => {
            // Like the real publish: refuses when the pasteboard moved past basis.
            if (w.beforeWrite) w.beforeWrite();
            if (e.basis !== w.seq) throw new Error('could not write the clipboard: the clipboard changed since it was read');
            w.entry = { Png: e.state.Png, Items: w.entry && w.entry.Items, Text: e.text, HasFiles: false, Owner: e.owner, Token: e.token, Promise: e.promise ? 'open' : null };
            w.seq++;
            w.writes.push({ Text: e.text, Owner: e.owner, Token: e.token });
        },
        completePromise: (text) => {
            if (w.entry && w.entry.Promise === 'open') w.entry.Promise = text ? 'resolved' : 'failed';
        },
        canAnswer: (text) => !!w.entry && w.entry.Text === text && w.entry.Promise !== 'failed',
        startUpload: (ssh, argv, item) => {
            w.uploads.push({ Hash: item.Hash, SshPath: ssh, Arguments: argv });
            if (w.duringUpload) w.duringUpload();
            return { ssh, hash: item.Hash, fail: w.failNext > 0 ? (w.failNext--, true) : false };
        },
        finishUpload: (h) => {
            if (w.hold) return undefined;
            if (h.fail) return { error: w.failText || 'ssh exited with 255: Permission denied (publickey).' };
            return { path: (w.prefix[h.ssh] || '/tmp') + '/ssh-paste-' + h.hash + '.png' };
        },
        beep: () => { w.beeps++; },
        log: (s) => { w.logs.push(s); }
    };
    w.focus = (win) => { w.fg = win; };
    w.copy = (png, text, files) => { w.entry = { Png: png, Text: text || null, HasFiles: !!files, Owner: null, Token: null }; w.seq++; };
    w.copyText = (text) => { w.entry = { Png: null, Text: text, HasFiles: false, Owner: null, Token: null }; w.seq++; };
    w.watcher = (window, ssh, dir) => {
        if (dir) w.prefix[ssh || 'ssh-a'] = dir;
        tokenCounter++;
        return m.newWatcher(w.P, { sshPath: ssh || 'ssh-a', sshVersion: [9, 6], parsed: m.splitSshArguments(['alice@h']), window,
            token: (tokenCounter.toString(16) + '0000000000000000').substring(0, 16) });
    };
    w.ticks = (W, n) => { for (let i = 0; i < (n || 1); i++) m.watcherTick(W); };
    return w;
}

test('uploadedPath (Get-UploadedPath)', async (t) => {
    const state = { Hash: '0123456789abcdef0123456789abcdef', Items: [{ Hash: '0123456789abcdef0123456789abcdef', Ext: 'png', Size: 40 }] };
    const imagePath = '/tmp/ssh-paste-0123456789abcdef0123456789abcdef.png';
    const watcher = (w) => m.newWatcher(w.P, { sshPath: 'ssh', sshVersion: [9, 0], parsed: m.splitSshArguments(['-p', '2222', 'alice@h']), window: 1, token: '0000000000000001' });
    // What a tick does with the upload: start it, let the (instant) fake finish it.
    const resolve = (W, s) => {
        W.Inflight = { State: s, Pending: null, Ready: false, Wrote: false, Completed: false };
        assert.equal(m.advanceInflight(W), true);
        const p = W.Inflight.Path;
        W.Inflight = null;
        return p;
    };
    await t.test('uploads once per image, passes the hash, size and options, and then answers from the cache', () => {
        const w = newWorld();
        const W = watcher(w);
        assert.equal(resolve(W, state), imagePath);
        assert.equal(resolve(W, state), imagePath);
        assert.equal(w.uploads.length, 1);
        const a = w.uploads[0].Arguments;
        assert.ok(a[a.length - 1].endsWith(" ssh-paste 0123456789abcdef0123456789abcdef 40 png 1440 '/tmp'"));
        assert.ok(a.includes('-p') && a.includes('alice@h') && a.includes('StdinNull=no'));
        assert.equal(W.Uploaded[state.Hash].Path, imagePath);
        assert.equal(W.WakeAt, W.Uploaded[state.Hash].At + m.UPLOAD_CACHE_HOURS * 3600000);
    });
    await t.test('passes --keep and --dir on, promises the folder and class, and caches for half of --keep', () => {
        const w = newWorld();
        w.prefix.ssh = '/home/u/s';
        const W = m.newWatcher(w.P, { sshPath: 'ssh', sshVersion: [9, 0], parsed: m.splitSshArguments(['alice@h']), window: 1, token: '0000000000000001',
            settings: { Keep: '30m', Dir: '/home/u/s' } });
        const other = { Hash: 'f'.repeat(32), Items: [{ Hash: 'f'.repeat(32), Ext: 'png', Size: 40 }] };
        assert.equal(m.expectedText(W, other), '/home/u/s/ssh-paste-k30m-' + 'f'.repeat(32) + '.png');
        assert.equal(resolve(W, state), '/home/u/s/ssh-paste-0123456789abcdef0123456789abcdef.png');
        const a = w.uploads[0].Arguments;
        assert.ok(a[a.length - 1].endsWith(" ssh-paste 0123456789abcdef0123456789abcdef 40 png 30 '/home/u/s' k30m-"));
        assert.equal(W.WakeAt, W.Uploaded[state.Hash].At + 0.25 * 3600000);
        assert.throws(() => m.newWatcher(w.P, { sshPath: 'ssh', parsed: m.splitSshArguments(['h']), settings: { Keep: '1w' } }), /--keep/);
        assert.throws(() => m.newWatcher(w.P, { sshPath: 'ssh', parsed: m.splitSshArguments(['h']), settings: { Dir: '~/s' } }), /bad --dir/);
    });
    await t.test('with SSH_PASTE_DEBUG, adds -v and drops LogLevel=ERROR with its -o, leaving no -o without a value', () => {
        const w = newWorld();
        const W = watcher(w);
        W.Debug = true;
        resolve(W, state);
        const a = w.uploads[0].Arguments;
        assert.equal(a[0], '-v');
        assert.ok(!a.includes('LogLevel=ERROR'));
        a.forEach((x, i) => { if (x === '-o') assert.match(a[i + 1], /^[A-Za-z]+=/, 'the value after -o at ' + i); });
        assert.deepEqual(a.slice(1), m.uploadSshArguments(W.Parsed, state.Hash, 40, { sshVersion: [9, 0] }).filter((x, i, all) => x !== 'LogLevel=ERROR' && all[i + 1] !== 'LogLevel=ERROR'));
    });
    await t.test('uploads to the pinned address when the watcher has a pin', () => {
        const w = newWorld();
        const W = watcher(w);
        W.NoProxy = true;
        W.Pin = { HostName: '203.0.113.7', Port: 2200, HostKeyAlias: '[h]:2200' };
        resolve(W, state);
        for (const o of ['HostName=203.0.113.7', 'Port=2200', 'HostKeyAlias=[h]:2200', 'ProxyCommand=none']) assert.ok(w.uploads[0].Arguments.includes(o), o);
    });
    await t.test('uploads again after the cache time', () => {
        const w = newWorld();
        const W = watcher(w);
        resolve(W, state);
        w.clock += (m.UPLOAD_CACHE_HOURS + 1) * 3600000;
        resolve(W, state);
        assert.equal(w.uploads.length, 2);
    });
    await t.test('a failing upload returns null, beeps once, backs off 30 s doubling to 30 min, and is forgotten after a success', () => {
        const w = newWorld();
        const W = watcher(w);
        w.failNext = 100;
        assert.equal(resolve(W, state), null);
        assert.equal(resolve(W, state), null);
        assert.equal(w.uploads.length, 1);
        assert.equal(W.Failed[state.Hash].Count, 1);
        assert.match(W.Failed[state.Hash].Message, /Permission denied/);
        assert.equal(W.WakeAt, W.Failed[state.Hash].At + 30000);
        assert.equal(w.beeps, 1);
        for (const [count, delay] of [[1, 30], [2, 60], [3, 120], [6, 960], [7, 1800], [20, 1800]]) {
            W.Failed[state.Hash] = { Message: 'x', At: w.clock - (delay - 5) * 1000, Count: count };
            const before = w.uploads.length;
            assert.equal(resolve(W, state), null);
            assert.equal(w.uploads.length, before, 'no retry before ' + delay + ' s');
            W.Failed[state.Hash] = { Message: 'x', At: w.clock - (delay + 1) * 1000, Count: count };
            resolve(W, state);
            assert.equal(w.uploads.length, before + 1, 'a retry after ' + delay + ' s');
            assert.equal(W.Failed[state.Hash].Count, count + 1);
        }
        assert.equal(w.beeps, 1);
        w.failNext = 0;
        w.clock += 3600000;
        assert.equal(resolve(W, state), imagePath);
        assert.equal(W.Failed[state.Hash], undefined);
    });
    await t.test('a failure recorded after a cached success does not hide the cached path', () => {
        const w = newWorld();
        const W = watcher(w);
        resolve(W, state);
        W.Failed[state.Hash] = { Message: 'old', At: w.clock, Count: 3 };
        assert.equal(resolve(W, state), imagePath);
        assert.equal(w.uploads.length, 1);
    });
});

test('the watcher: one watcher, one terminal window', async (t) => {
    await t.test('does not upload a screenshot copied while another app is in front, until the terminal comes to the front', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(Other);
        w.copy(png);
        w.ticks(W, 10);
        assert.equal(w.uploads.length, 0);
        assert.equal(w.writes.length, 0);
        assert.equal(w.entry.Owner, null);
        w.focus(TerminalA);
        w.ticks(W, 1);
        assert.equal(w.uploads.length, 1);
        assert.equal(w.writes.length, 1);
        assert.equal(w.entry.Text, pathFor(png));
        assert.equal(w.entry.Png, png);
    });
    await t.test('uploads and writes once, however many ticks follow', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(W, 20);
        assert.equal(w.uploads.length, 1);
        assert.equal(w.writes.length, 1);
        assert.equal(w.entry.Text, pathFor(png));
        assert.equal(w.entry.Owner, TerminalA);
        assert.equal(w.entry.Token, W.Token);
    });
    await t.test('puts the plain image back when another app comes to the front, and the path again on return, with one upload', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(W, 3);
        w.focus(Other);
        w.ticks(W, 5);
        assert.equal(w.entry.Text, null);
        assert.equal(w.entry.Png, png);
        assert.equal(w.entry.Owner, 0);
        assert.equal(w.entry.Token, W.Token);
        assert.equal(w.writes.length, 2);
        w.focus(TerminalA);
        w.ticks(W, 5);
        assert.equal(w.entry.Text, pathFor(png));
        assert.equal(w.writes.length, 3);
        w.focus(OtherToo);
        w.ticks(W, 2);
        w.focus(TerminalA);
        w.ticks(W, 2);
        assert.equal(w.entry.Text, pathFor(png));
        assert.equal(w.uploads.length, 1);
    });
    await t.test('uploads a new screenshot that replaces the old one', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.ticks(W, 3);
        w.copy(fakePng(2));
        w.ticks(W, 3);
        assert.equal(w.uploads.length, 2);
        assert.equal(w.entry.Text, pathFor(fakePng(2)));
    });
    await t.test('has the remote path on the pasteboard while the upload runs', () => {
        const w = newWorld(), png = fakePng(4), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        let seen = 'not called';
        w.duringUpload = () => { seen = w.entry.Text; };
        w.ticks(W, 1);
        assert.equal(seen, pathFor(png));
        assert.equal(w.entry.Text, pathFor(png));
        assert.equal(w.writes.length, 1, 'the real path equals the expected one, so there is no second write');
    });
    await t.test('does not overwrite an image or text copied during the upload', () => {
        let w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.duringUpload = () => w.copy(fakePng(2));
        w.ticks(W, 1);
        assert.equal(w.writes.length, 1);
        assert.deepEqual(w.entry.Png, fakePng(2));
        assert.equal(w.entry.Owner, null);
        w.duringUpload = null;
        w.ticks(W, 3);
        assert.equal(w.uploads.length, 2);
        assert.equal(w.entry.Text, pathFor(fakePng(2)));

        w = newWorld();
        W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.duringUpload = () => w.copyText('meeting at 3');
        w.ticks(W, 6);
        assert.equal(w.writes.length, 1);
        assert.equal(w.entry.Text, 'meeting at 3');
        assert.equal(w.uploads.length, 1);
    });
    await t.test('puts the plain image back when another app comes to the front during the upload, and the path after coming back', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.duringUpload = () => w.focus(Other);
        w.ticks(W, 1);
        assert.equal(w.writes.length, 1);
        w.duringUpload = null;
        w.ticks(W, 3);
        assert.equal(w.writes.length, 2);
        assert.equal(w.entry.Text, null);
        w.focus(TerminalA);
        w.ticks(W, 3);
        assert.equal(w.writes.length, 3);
        assert.equal(w.entry.Text, pathFor(png));
        assert.equal(w.uploads.length, 1);
    });
    for (const [name, text, files] of [['text', 'a caption', false], ['files', null, true], ['text and files', 'report.png', true]]) {
        await t.test('leaves an image that an app copied together with ' + name + ' alone', () => {
            const w = newWorld(), W = w.watcher(TerminalA);
            w.copy(fakePng(3), text, files);
            const before = w.entry, seq = w.seq;
            for (const win of [Other, TerminalA, Other, TerminalA]) { w.focus(win); w.ticks(W, 4); }
            assert.equal(w.uploads.length, 0);
            assert.equal(w.writes.length, 0);
            assert.equal(w.entry, before);
            assert.equal(w.seq, seq);
        });
    }
    await t.test('ignores text only, an empty pasteboard, and does nothing without a front window', () => {
        let w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.ticks(W, 3);
        w.copyText('just text');
        w.ticks(W, 3);
        assert.equal(w.uploads.length + w.writes.length, 0);
        w = newWorld();
        W = w.watcher(TerminalA);
        w.copy(fakePng(1));
        w.focus(0);
        w.ticks(W, 3);
        assert.equal(w.reads + w.uploads.length + w.writes.length, 0);
    });
    await t.test('reads the pasteboard only when the change count moves', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.ticks(W, 3);
        const reads = w.reads;
        w.ticks(W, 25);
        assert.equal(w.reads, reads);
        w.copy(fakePng(2));
        w.ticks(W, 1);
        assert.equal(w.reads, reads + 1);
    });
    await t.test('retries a busy pasteboard on the next tick', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.readFails = 2;
        assert.throws(() => m.watcherTick(W), /busy/);
        assert.throws(() => m.watcherTick(W), /busy/);
        w.ticks(W, 2);
        assert.equal(w.entry.Text, pathFor(png));
    });
    await t.test('uploads again when the cached upload is old, and leaves the pasteboard as it is', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(W, 8);
        assert.equal(w.uploads.length, 1);
        w.clock += m.UPLOAD_CACHE_HOURS * 3600000 + 60000;
        w.ticks(W, 3);
        assert.equal(w.uploads.length, 2);
        assert.equal(w.writes.length, 1);
        assert.equal(w.entry.Text, pathFor(png));
        w.ticks(W, 5);
        assert.equal(w.uploads.length, 2);
    });
    await t.test('uploads nothing more in the session after a server that takes no key refused it, and says why', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.failNext = 5;
        w.failText = 'ssh exited with 255: alice@h: Permission denied (password,keyboard-interactive).';
        w.copy(fakePng(1));
        w.ticks(W, 4);
        assert.equal(w.uploads.length, 1);
        assert.equal(W.Blocked, 'alice@h wants a password or a one-time code (password,keyboard-interactive), which uploads cannot type, so ssh-paste cannot upload to it');
        const writes = w.writes.length;
        w.copy(fakePng(2));
        w.clock += 3600000;
        w.ticks(W, 4);
        assert.equal(w.uploads.length, 1, 'no upload of the new image');
        assert.equal(w.writes.length, writes, 'no path promised for it');
        assert.equal(m.failureSummary(W), 'ssh-paste: screenshot paste was off for this session: ' + W.Blocked);
    });
    await t.test('tries again after the backoff when the server takes keys (the user may load one with ssh-add)', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.failNext = 1;
        w.failText = 'ssh exited with 255: alice@h: Permission denied (publickey,password).';
        w.copy(fakePng(1));
        w.ticks(W, 4);
        assert.equal(w.uploads.length, 1);
        assert.equal(W.Blocked, null);
        w.clock += 31000;
        w.ticks(W, 4);
        assert.equal(w.uploads.length, 2, 'the retry ran');
        assert.equal(w.entry.Text, pathFor(fakePng(1)));
    });
    await t.test('uploads each file of a batch once, even when the batch outlasts the cache (--keep 30m)', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        W.CacheHours = m.uploadCacheHours(30);   // 15 minutes
        const a = 'a'.repeat(32), b = 'b'.repeat(32);
        w.focus(TerminalA);
        w.copy(png);
        w.entry.Items = [{ Hash: a, Ext: 'png', Size: 40 }, { Hash: b, Ext: 'png', Size: 40 }];
        // Each upload takes 20 minutes, so a is past the cache when b ends. One tick runs
        // the whole batch (the fake uploads end at once); later ticks would refresh it.
        w.duringUpload = () => { w.clock += 20 * 60000; if (w.uploads.length > 4) throw new Error('uploads again and again'); };
        w.ticks(W, 1);
        assert.deepEqual(w.uploads.map((u) => u.Hash), [a, b]);
        assert.equal(w.entry.Text, '/tmp/ssh-paste-' + a + '.png /tmp/ssh-paste-' + b + '.png');
    });
});

test('the watcher: an upload that runs over several ticks (macOS runs it as a child process)', async (t) => {
    await t.test('promises the path, waits for the upload without reading or writing, then completes the promise', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.hold = true;
        w.ticks(W, 1);
        assert.equal(w.writes.length, 1);
        assert.equal(w.entry.Promise, 'open');
        const reads = w.reads;
        w.focus(Other);
        w.ticks(W, 10);
        assert.equal(w.reads, reads, 'nothing else happens while the upload runs');
        assert.equal(w.writes.length, 1);
        assert.equal(w.entry.Promise, 'open');
        w.hold = false;
        w.ticks(W, 1);
        assert.equal(w.entry.Promise, 'resolved');
        w.ticks(W, 2);
        assert.equal(w.entry.Text, null, 'another app is in front by now: the plain image goes back');
        assert.equal(w.uploads.length, 1);
    });
    await t.test('a failed upload fails the promise and takes the path back', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.hold = true;
        w.failNext = 1;
        w.ticks(W, 1);
        w.hold = false;
        w.ticks(W, 1);
        assert.equal(w.writes.length, 2);
        assert.equal(w.entry.Text, null);
        assert.equal(Object.keys(W.Failed).length, 1);
    });
    await t.test('advanceInflight (what a waiting paste calls) completes the promise before the next tick', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.hold = true;
        w.ticks(W, 1);
        assert.equal(m.advanceInflight(W), false);
        w.hold = false;
        assert.equal(m.advanceInflight(W), true);
        assert.equal(w.entry.Promise, 'resolved');
        assert.equal(m.advanceInflight(W), true, 'idempotent');
        assert.equal(w.writes.length, 1, 'no write from inside a paste');
        w.ticks(W, 3);
        assert.equal(w.writes.length, 1);
        assert.equal(w.entry.Text, pathFor(png));
    });
});

test('the watcher: a failing upload', async (t) => {
    await t.test('takes its path back, is quiet while it waits, and retries by itself after the backoff', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.failNext = 2;
        w.ticks(W, 1);
        assert.equal(w.uploads.length, 1);
        assert.equal(W.Failed[hash16(png)].Count, 1);
        assert.equal(w.writes.length, 2);
        assert.equal(w.entry.Text, null);
        w.ticks(W, 30);
        w.clock += 20000;
        w.ticks(W, 5);
        assert.equal(w.uploads.length, 1);
        w.clock += 11000;
        w.ticks(W, 1);
        assert.equal(w.uploads.length, 2);
        assert.equal(W.Failed[hash16(png)].Count, 2);
        assert.equal(w.writes.length, 2, 'a retry after a failure uploads first and writes only on success');
        w.clock += 31000;
        w.ticks(W, 5);
        assert.equal(w.uploads.length, 2);
        w.clock += 30000;
        w.ticks(W, 1);
        assert.equal(w.uploads.length, 3);
        assert.equal(Object.keys(W.Failed).length, 0);
        assert.equal(w.writes.length, 3);
        assert.equal(w.entry.Text, pathFor(png));
        w.ticks(W, 10);
        assert.equal(w.uploads.length, 3);
    });
    await t.test('does not retry while another app is in front, nor early on a window change', () => {
        let w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.failNext = 1;
        w.ticks(W, 1);
        w.focus(Other);
        w.clock += 100000;
        w.ticks(W, 5);
        assert.equal(w.uploads.length, 1);
        w.focus(TerminalA);
        w.ticks(W, 2);
        assert.equal(w.uploads.length, 2);
        assert.equal(w.entry.Text, pathFor(png));

        w = newWorld();
        W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.failNext = 1;
        w.ticks(W, 1);
        w.focus(Other);
        w.ticks(W, 1);
        w.focus(TerminalA);
        w.ticks(W, 3);
        assert.equal(w.uploads.length, 1);
        assert.equal(w.entry.Text, null);
    });
    await t.test('a different screenshot is not held back, and the failure is in the summary', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.failNext = 1;
        w.ticks(W, 1);
        assert.match(m.failureSummary(W), /1 screenshot upload\(s\) failed: alice@h did not accept a key for uploads/);
        w.copy(fakePng(2));
        w.ticks(W, 2);
        assert.equal(w.uploads.length, 2);
        assert.equal(w.entry.Text, pathFor(fakePng(2)));
        assert.equal(m.failureSummary(null), null);
    });
});

test('the watcher: two watchers in two terminal windows', async (t) => {
    await t.test('does not ping-pong, and each window gets its own path', () => {
        const w = newWorld(), png = fakePng(1);
        const a = w.watcher(TerminalA, 'ssh-a', '/srv-a'), b = w.watcher(TerminalB, 'ssh-b', '/srv-b');
        w.copy(png);
        const order = [TerminalA, Other, TerminalB, Other, TerminalB, TerminalA, OtherToo, TerminalA, TerminalB, OtherToo, Other, TerminalB];
        let changes = 0, previous = 0;
        for (let round = 0; round < 4; round++) {
            for (const win of order) {
                w.focus(win);
                if (win !== previous) changes++;
                previous = win;
                for (let i = 0; i < 6; i++) {
                    if ((i + round) % 2 === 0) { m.watcherTick(a); m.watcherTick(b); } else { m.watcherTick(b); m.watcherTick(a); }
                }
                if (win === TerminalA) { assert.equal(w.entry.Text, pathFor(png, '/srv-a')); assert.equal(w.entry.Token, a.Token); }
                else if (win === TerminalB) { assert.equal(w.entry.Text, pathFor(png, '/srv-b')); assert.equal(w.entry.Token, b.Token); }
                else assert.equal(w.entry.Text, null);
                assert.equal(w.entry.Png, png);
            }
        }
        assert.equal(w.uploads.length, 2);
        assert.ok(w.writes.length <= 2 * changes);
        const writes = w.writes.length;
        w.ticks(a, 20);
        w.ticks(b, 20);
        assert.equal(w.writes.length, writes);
    });
    await t.test('lets the window in front win, and the second window takes over after the first leaves', () => {
        let w = newWorld(), png = fakePng(1);
        let a = w.watcher(TerminalA, 'ssh-a', '/srv-a'), b = w.watcher(TerminalB, 'ssh-b', '/srv-b');
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(a, 2);
        w.ticks(b, 10);
        assert.equal(w.writes.length, 2);
        assert.equal(w.entry.Text, pathFor(png, '/srv-a'));
        assert.equal(w.uploads.length, 1);

        w = newWorld();
        a = w.watcher(TerminalA, 'ssh-a', '/srv-a');
        b = w.watcher(TerminalB, 'ssh-b', '/srv-b');
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(a, 2);
        w.focus(TerminalB);
        w.ticks(b, 1);
        w.ticks(a, 1);
        w.ticks(b, 3);
        w.ticks(a, 3);
        assert.equal(w.entry.Text, pathFor(png, '/srv-b'));
        assert.equal(w.entry.Token, b.Token);
    });
});

test('the watcher: two watchers in the same terminal window (two tabs)', async (t) => {
    await t.test('never overwrite each other, both upload, and the first to write keeps the entry', () => {
        for (const first of ['a', 'b']) {
            const w = newWorld(), png = fakePng(1);
            const a = w.watcher(TerminalA, 'ssh-a', '/srv-a'), b = w.watcher(TerminalA, 'ssh-b', '/srv-b');
            w.focus(TerminalA);
            w.copy(png);
            const [x, y] = first === 'a' ? [a, b] : [b, a];
            for (let i = 0; i < 10; i++) { m.watcherTick(i % 2 === 0 ? x : y); m.watcherTick(i % 2 === 0 ? y : x); }
            assert.equal(w.uploads.length, 2);
            assert.equal(w.writes.length, 2);
            assert.equal(w.entry.Token, x.Token);
            assert.equal(w.entry.Text, pathFor(png, first === 'a' ? '/srv-a' : '/srv-b'));
        }
    });
    await t.test('restores the plain image once when the window loses the focus, and writes once when it returns', () => {
        const w = newWorld(), png = fakePng(1);
        const a = w.watcher(TerminalA, 'ssh-a', '/srv-a'), b = w.watcher(TerminalA, 'ssh-b', '/srv-b');
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(a, 2);
        w.ticks(b, 2);
        const writes = w.writes.length;
        w.focus(Other);
        w.ticks(a, 2);
        w.ticks(b, 2);
        assert.equal(w.writes.length, writes + 1);
        assert.equal(w.entry.Text, null);
        w.focus(TerminalA);
        w.ticks(b, 2);
        w.ticks(a, 2);
        assert.equal(w.writes.length, writes + 2);
        assert.equal(w.entry.Text, pathFor(png, '/srv-b'));
        assert.equal(w.uploads.length, 2);
    });
    await t.test('a watcher with a working server still serves the window when the other upload fails', () => {
        const w = newWorld(), png = fakePng(1);
        const a = w.watcher(TerminalA, 'ssh-a', '/srv-a'), b = w.watcher(TerminalA, 'ssh-b', '/srv-b');
        w.focus(TerminalA);
        w.copy(png);
        w.failNext = 1;
        w.ticks(a, 1);
        w.ticks(b, 2);
        assert.equal(w.entry.Text, pathFor(png, '/srv-b'));
        w.ticks(a, 5);
        assert.equal(w.entry.Token, b.Token);
    });
});

test('the watcher: the counterexamples of the model check (verify/watcher, commit 6396fae)', async (t) => {
    await t.test('leaves a copy made while it writes alone (NoLostCopy)', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.beforeWrite = () => { w.beforeWrite = null; w.copyText('copied meanwhile'); };
        m.watcherStep(W);
        assert.equal(w.entry.Text, 'copied meanwhile');
        w.ticks(W, 5);
        assert.equal(w.entry.Text, 'copied meanwhile');
        assert.equal(w.writes.length, 0);
    });
    await t.test('writes the path again when a failed promise was left behind and the retry succeeds (ReadyPathPastes)', () => {
        const w = newWorld(), png = fakePng(1), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(png);
        w.failNext = 1;
        w.duringUpload = () => w.focus(Other);
        w.ticks(W, 1);
        assert.equal(w.entry.Promise, 'failed');
        w.duringUpload = null;
        w.focus(TerminalA);
        w.clock += 31000;
        w.ticks(W, 1);
        assert.equal(w.uploads.length, 2);
        assert.equal(w.entry.Text, pathFor(png));
        assert.notEqual(w.entry.Promise, 'failed');
    });
    await t.test('does not rely on the entry of a session in another window (NoLocalPathDuringUpload)', () => {
        const w = newWorld(), png = fakePng(1);
        const a = w.watcher(TerminalA, 'ssh-a'), b = w.watcher(TerminalB, 'ssh-b');
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(a, 1);
        assert.equal(w.entry.Token, a.Token);
        w.focus(TerminalB);
        w.ticks(b, 1);
        assert.equal(w.entry.Token, b.Token);
        assert.equal(w.entry.Owner, TerminalB);
        assert.equal(w.entry.Text, pathFor(png));
    });
});

test('restoreClipboard (Restore-Clipboard, on exit)', async (t) => {
    await t.test('puts the plain image back when the pasteboard holds this session\'s path, and leaves another session\'s entry', () => {
        const w = newWorld(), png = fakePng(1);
        const a = w.watcher(TerminalA, 'ssh-a', '/srv-a'), b = w.watcher(TerminalA, 'ssh-b', '/srv-b');
        w.focus(TerminalA);
        w.copy(png);
        w.ticks(a, 3);
        const writes = w.writes.length;
        m.restoreClipboard(b);
        assert.equal(w.writes.length, writes);
        assert.equal(w.entry.Token, a.Token);
        m.restoreClipboard(a);
        assert.equal(w.entry.Text, null);
        assert.equal(w.entry.Png, png);
        assert.equal(w.entry.Owner, 0);
        assert.equal(w.entry.Token, a.Token);
    });
    await t.test('leaves an app\'s image, its own plain image, text and an empty pasteboard alone', () => {
        for (const text of [null, 'caption']) {
            const w = newWorld(), W = w.watcher(TerminalA);
            w.copy(fakePng(1), text);
            const before = w.entry;
            m.restoreClipboard(W);
            assert.equal(w.writes.length, 0);
            assert.equal(w.entry, before);
        }
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.ticks(W, 3);
        w.focus(Other);
        w.ticks(W, 2);
        const writes = w.writes.length;
        m.restoreClipboard(W);
        w.copyText('hello');
        m.restoreClipboard(W);
        w.entry = null;
        m.restoreClipboard(W);
        assert.equal(w.writes.length, writes);
    });
    await t.test('does not write when the pasteboard changes between read and write, nor throw when it is busy', () => {
        const w = newWorld(), W = w.watcher(TerminalA);
        w.focus(TerminalA);
        w.copy(fakePng(1));
        w.ticks(W, 3);
        const writes = w.writes.length;
        w.afterRead = () => w.copy(fakePng(2));
        m.restoreClipboard(W);
        assert.equal(w.writes.length, writes);
        assert.equal(w.entry.Owner, null);
        w.afterRead = null;
        w.readFails = 1;
        assert.doesNotThrow(() => m.restoreClipboard(W));
    });
});

// --- repository guards ------------------------------------------------------------------

function psSingleQuoted(text, name) {
    // The value of `$script:<name> = '...'` (one line) in src/ssh-paste.ps1.
    const mm = new RegExp('^\\$script:' + name + " = '([^']*)'\\r?$", 'm').exec(text);
    assert.ok(mm, name + ' in src/ssh-paste.ps1');
    return mm[1];
}

test('repository guards', async (t) => {
    const ps = read('src/ssh-paste.ps1');
    const js = read('src/ssh-paste.js');
    const sh = read('install.sh');
    const launcher = read('src/ssh-paste-mac');
    await t.test('the server script is the same text in both clients', () => {
        const start = ps.indexOf('$script:RemoteScript = ');
        assert.ok(start > 0);
        let text = '';
        for (const line of ps.substring(start + '$script:RemoteScript = '.length).split(/\r?\n/)) {
            const pieces = line.trim().match(/^'([^']*)'( \+)?$/);
            assert.ok(pieces, 'a line of $script:RemoteScript: ' + line);
            text += pieces[1];
            if (!pieces[2]) break;
        }
        assert.equal(m.REMOTE_SCRIPT, text);
    });
    await t.test('the ssh option tables and the limits are the same in both clients', () => {
        assert.equal(m.SSH_FLAGS_NO_ARG, psSingleQuoted(ps, 'SshFlagsNoArg'));
        assert.equal(m.SSH_FLAGS_WITH_ARG, psSingleQuoted(ps, 'SshFlagsWithArg'));
        assert.equal(m.SSH_KEEP_NO_ARG, psSingleQuoted(ps, 'SshKeepNoArg'));
        assert.equal(m.SSH_KEEP_WITH_ARG, psSingleQuoted(ps, 'SshKeepWithArg'));
        const drop = /\$script:SshDropOptions = @\(([^)]*)\)/.exec(ps);
        assert.deepEqual(m.SSH_DROP_OPTIONS, drop[1].match(/'([^']*)'/g).map((s) => s.slice(1, -1)));
        const exts = /\$script:ImageExtensions = @\(([^)]*)\)/.exec(ps);
        assert.deepEqual(m.IMAGE_EXTENSIONS, exts[1].match(/'([^']*)'/g).map((s) => s.slice(1, -1)));
        assert.match(ps, new RegExp('^\\$script:MaxCopiedFiles = ' + m.MAX_COPIED_FILES + '\\r?$', 'm'));
        assert.match(ps, new RegExp('^\\$script:RetryFailedSeconds = ' + m.RETRY_FAILED_SECONDS + '\\r?$', 'm'));
        assert.match(ps, new RegExp('^\\$script:UploadCacheHours = ' + m.UPLOAD_CACHE_HOURS + '\\r?$', 'm'));
        assert.match(ps, /^\$script:MaxImageBytes = 64MB\r?$/m);
        assert.equal(m.MAX_IMAGE_BYTES, 64 * 1024 * 1024);
        assert.match(ps, new RegExp('public int PromiseWaitMilliseconds = ' + m.PROMISE_WAIT_SECONDS * 1000 + ';'));
    });
    await t.test('the ssh config markers are the same in both clients and in install.sh', () => {
        assert.equal(m.BLOCK_BEGIN, psSingleQuoted(ps, 'BlockBegin'));
        assert.equal(m.BLOCK_END, psSingleQuoted(ps, 'BlockEnd'));
        assert.equal(m.BLOCK_CREATED_FILE, psSingleQuoted(ps, 'BlockCreatedFile'));
        assert.ok(sh.includes("SSH_BEGIN='" + m.BLOCK_BEGIN + "'\n"));
        assert.ok(sh.includes("SSH_END='" + m.BLOCK_END + "'\n"));
        assert.ok(sh.includes("SSH_CREATED='" + m.BLOCK_CREATED_FILE + "'\n"));
    });
    await t.test('keeps the version at 0.0.0-dev in one line, and one default ref line in install.sh', () => {
        assert.equal(m.VERSION, '0.0.0-dev');
        assert.equal(js.split('\n').filter((l) => /^var VERSION\b/.test(l)).join('|'), "var VERSION = '0.0.0-dev';");
        assert.equal(sh.split('\n').filter((l) => /^DEFAULT_REF=/.test(l)).join('|'), "DEFAULT_REF='main'");
    });
    await t.test('a release stamps ssh-paste.js, bakes its tag into install.sh, and ships, sums and attests the macOS files', () => {
        const publish = read('.github/workflows/publish.yml');
        const stamp = read('.github/scripts/stamp-version.sh');
        const release = read('.github/scripts/publish-release.sh');
        assert.ok(stamp.includes(`from="var VERSION = '0.0.0-dev';"`), 'stamp-version.sh looks for the line in src/ssh-paste.js');
        assert.ok(publish.includes('stamp-version.sh src/ssh-paste.js out/dist/ssh-paste.js "${TAG#v}"'));
        assert.ok(publish.includes('cp src/ssh-paste-mac install.sh out/dist/'), 'the launcher and the installer are copied, the script is stamped');
        assert.ok(publish.includes(`sed -i "s/^DEFAULT_REF='main'\\$/DEFAULT_REF='$TAG'/" out/dist/install.sh`));
        assert.ok(publish.includes('sha256sum ssh-paste.ps1 ssh-paste.cmd install.ps1 ssh-paste.js ssh-paste-mac install.sh > SHA256SUMS'));
        for (const f of ['install.sh', 'ssh-paste.js', 'ssh-paste-mac']) assert.ok(publish.includes('out/dist/' + f + '\n'), 'attested: ' + f);
        assert.ok(release.includes('files="SHA256SUMS install.ps1 install.sh ssh-paste-mac ssh-paste.cmd ssh-paste.js ssh-paste.ps1"'));
        assert.ok(read('.github/scripts/plan-release.sh').includes('-- src install.ps1 install.sh)'), 'a change to install.sh is released');
    });
    await t.test('lists every command of the help text in both READMEs, and the launcher passes each on', () => {
        const commands = [...new Set(m.usage().match(/(?<![\w-])--[a-z][a-z-]*/g))].sort();
        assert.ok(commands.length > 3);
        for (const readme of ['README.md', 'README.zh-CN.md']) {
            const text = read(readme);
            assert.deepEqual(commands.filter((c) => !text.includes(c)), [], readme);
        }
        for (const c of commands) assert.ok(launcher.includes(c), 'src/ssh-paste-mac handles ' + c);
        assert.deepEqual(m.usage().match(/^ {2}ssh-paste .*$/gm).map((l) => l.replace(/\s{2,}.*$/, '')),
            read('src/ssh-paste.ps1').match(/^ {8}' {2}ssh-paste .*$/gm).map((l) => l.trim().slice(1).replace(/\s{2,}.*$/, '').trim()),
            'the same commands as the Windows help text');
    });
    await t.test('the macOS files are ASCII without carriage returns, and the launcher is executable', () => {
        for (const f of ['src/ssh-paste.js', 'src/ssh-paste-mac', 'install.sh', 'tests/cases.json', 'tests/mac/unit.test.js', 'tests/mac/jxa.sh', 'tests/mac/e2e.sh', 'tests/mac/footprint.sh', 'tests/mac/lib.sh']) {
            const bytes = fs.readFileSync(path.join(repo, f));
            const bad = bytes.findIndex((b) => b > 126 || (b < 32 && b !== 9 && b !== 10));
            assert.equal(bad, -1, f + ' has a byte that is not printable ASCII at offset ' + bad);
        }
        for (const f of ['src/ssh-paste-mac', 'install.sh']) assert.ok(fs.statSync(path.join(repo, f)).mode & 0o100, f + ' is executable');
        assert.equal(launcher.split('\n')[0], '#!/bin/zsh');
        assert.equal(sh.split('\n')[0], '#!/bin/sh');
    });
});
