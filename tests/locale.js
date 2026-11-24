#!/usr/bin/env node
// Builds the catalogs that both clients carry from src/locale/<name>.json (UTF-8, English
// text -> translation) and writes them, ASCII with \u escapes, between the "locale" markers
// of src/ssh-paste.ps1 ($script:LocaleData) and src/ssh-paste.js (LOCALE_DATA).
//
//   node tests/locale.js           exits 1 when a client's copy is stale
//   node tests/locale.js --write   rewrites both copies
//
// The node tests also run the check (tests/mac/unit.test.js).
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const repo = path.resolve(__dirname, '..');

function catalogs() {
    const dir = path.join(repo, 'src', 'locale');
    const data = {};
    for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
        const entries = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
        const sorted = {};
        for (const key of Object.keys(entries).sort()) sorted[key] = entries[key];
        data[file.replace(/\.json$/, '')] = sorted;
    }
    return data;
}

function asciiJson(value) {
    // JSON with every character outside printable ASCII, and the single quote, as \uXXXX,
    // so it sits in a single-quoted PowerShell string and in JavaScript unchanged.
    return JSON.stringify(value).replace(/[^\x20-\x26\x28-\x7e]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
}

function rewrite(file, line) {
    const full = path.join(repo, file);
    const text = fs.readFileSync(full, 'utf8');
    const nl = text.includes('\r\n') ? '\r\n' : '\n';
    const begin = text.indexOf('>>> locale');
    const end = text.indexOf('<<< locale');
    if (begin < 0 || end < begin) throw new Error(file + ': no locale markers');
    const from = text.indexOf(nl, begin) + nl.length;
    const to = text.lastIndexOf(nl, end) + nl.length;
    return { full, before: text, after: text.slice(0, from) + line + nl + text.slice(to) };
}

function expected() {
    const json = asciiJson(catalogs());
    return [
        rewrite('src/ssh-paste.ps1', "$script:LocaleData = '" + json + "'"),
        rewrite('src/ssh-paste.js', 'var LOCALE_DATA = ' + json + ';')
    ];
}

if (require.main === module) {
    const write = process.argv.includes('--write');
    let stale = 0;
    for (const f of expected()) {
        if (f.before === f.after) continue;
        if (write) { fs.writeFileSync(f.full, f.after); console.log('wrote ' + path.relative(repo, f.full)); }
        else { console.error(path.relative(repo, f.full) + ' has a stale copy of the catalogs: run node tests/locale.js --write'); stale++; }
    }
    process.exit(stale > 0 ? 1 : 0);
}

module.exports = { catalogs, expected, asciiJson };
