// The pasteboard helper of the macOS tests (tests/mac/*.sh). It writes the
// pasteboard the way other apps do, reads it without asking for a promised text,
// and loads src/ssh-paste.js to call its macOS functions directly.
//
//   osascript -l JavaScript tests/mac/pb.js COMMAND ARGS...
//     png FILE            put a PNG on the pasteboard, as a screenshot tool does
//     tiff FILE           put only a TIFF there
//     finder FILE...      file reference URLs and the file names as text, as Finder's Cmd+C
//     text STRING         plain text
//     dump                JSON: change count, types, marker, file paths, PNG size
//     marker-text         the text in our marker (empty when there is none)
//     file-paths          the copied files another process reads, one per line (the
//                         longest of the three lists the watcher reads too)
//     items               JSON: each item's types and file URL, and the file paths other APIs read
//     save-png FILE       write the pasteboard's public.png to FILE
//     stale-write         publish() of src/ssh-paste.js with a change count that moved:
//                         prints "refused" when it refuses and leaves the pasteboard alone
//     png-of FILE OUT     convert an image file to PNG (to make test files)
'use strict';
ObjC.import('AppKit');
ObjC.import('stdlib');

function err(s) { $.NSFileHandle.fileHandleWithStandardError.writeData($(s + '\n').dataUsingEncoding($.NSUTF8StringEncoding)); }
function out(s) { $.NSFileHandle.fileHandleWithStandardOutput.writeData($(s + '\n').dataUsingEncoding($.NSUTF8StringEncoding)); }

function loadClient() {
    var dir = $(ObjC.unwrap($.NSProcessInfo.processInfo.arguments.objectAtIndex(3))).stringByDeletingLastPathComponent.js;
    var src = $.NSString.stringWithContentsOfFileEncodingError(dir + '/../../src/ssh-paste.js', $.NSUTF8StringEncoding, null).js;
    return eval(src + '\n;({ initMac: initMac, macPlatform: macPlatform, newWatcher: newWatcher, removePrivateDirectory: removePrivateDirectory })');
}

function write(items) {
    var pb = $.NSPasteboard.generalPasteboard;
    pb.clearContents;
    if (!pb.writeObjects($(items))) throw new Error('writeObjects failed');
}

function run(argv) {
    var pb = $.NSPasteboard.generalPasteboard;
    var cmd = argv[0];
    var item;
    if (cmd === 'png' || cmd === 'tiff') {
        item = $.NSPasteboardItem.alloc.init;
        item.setDataForType($.NSData.dataWithContentsOfFile(argv[1]), cmd === 'png' ? 'public.png' : 'public.tiff');
        write([item]);
    } else if (cmd === 'finder') {
        // NSURL objects write one item per file; Finder also puts the file names
        // on the pasteboard as text.
        var objects = [];
        var names = [];
        for (var i = 1; i < argv.length; i++) {
            var plain = $.NSURL.fileURLWithPath(argv[i]);
            var ref = plain.fileReferenceURL;
            err('finder: ' + argv[i] + ' -> ' + (ref.isNil() ? 'no reference URL' : ref.absoluteString.js));
            objects.push(ref.isNil() ? plain : ref);
            names.push(argv[i].replace(/^.*\//, ''));
        }
        objects.push($(names.join('\r')));
        write(objects);
        err('finder: wrote ' + objects.length + ' objects; the pasteboard has ' + Number(pb.pasteboardItems.count) + ' items');
    } else if (cmd === 'text') {
        item = $.NSPasteboardItem.alloc.init;
        item.setStringForType($(argv[1]), 'public.utf8-plain-text');
        write([item]);
    } else if (cmd === 'dump') {
        var types = ObjC.deepUnwrap(pb.types) || [];
        var marker = pb.stringForType('com.github.xuing.ssh-paste.owner');
        var png = pb.dataForType('public.png');
        var paths = [];
        var all = pb.pasteboardItems;
        for (var j = 0; j < Number(all.count); j++) {
            var s = all.objectAtIndex(j).stringForType('public.file-url');
            if (s.isNil()) continue;
            var u = $.NSURL.URLWithString(s), fp = u.filePathURL;
            paths.push((fp.isNil() ? u : fp).path.js);
        }
        out(JSON.stringify({ changeCount: Number(pb.changeCount), types: types, marker: marker.isNil() ? null : JSON.parse(marker.js),
            files: paths, png: png.isNil() ? 0 : Number(png.length) }));
    } else if (cmd === 'items') {
        var list = [];
        var its = pb.pasteboardItems;
        for (var k = 0; k < Number(its.count); k++) {
            var it = its.objectAtIndex(k), fu = it.stringForType('public.file-url');
            list.push({ types: ObjC.deepUnwrap(it.types), fileUrl: fu.isNil() ? null : fu.js });
        }
        var objs = pb.readObjectsForClassesOptions($([$.NSURL]), $({ NSPasteboardURLReadingFileURLsOnlyKey: true }));
        var viaObjects = [];
        if (!objs.isNil()) for (var n = 0; n < Number(objs.count); n++) viaObjects.push(objs.objectAtIndex(n).absoluteString.js);
        var names = pb.propertyListForType('NSFilenamesPboardType');
        out(JSON.stringify({ items: list, readObjects: viaObjects, filenames: names.isNil() ? null : ObjC.deepUnwrap(names) }));
    } else if (cmd === 'file-paths') {
        var lists = [[], [], []];
        var pi = pb.pasteboardItems;
        var toPath = function (u) { if (u.isNil() || !u.isFileURL) return null; var f = u.filePathURL; return (f.isNil() ? u : f).path.js; };
        for (var a = 0; a < Number(pi.count); a++) {
            var fs = pi.objectAtIndex(a).stringForType('public.file-url');
            if (!fs.isNil()) lists[0].push(toPath($.NSURL.URLWithString(fs)));
        }
        var ro = pb.readObjectsForClassesOptions($([$.NSURL]), $({ NSPasteboardURLReadingFileURLsOnlyKey: true }));
        if (!ro.isNil()) for (var b = 0; b < Number(ro.count); b++) lists[1].push(toPath(ro.objectAtIndex(b)));
        var fn = pb.propertyListForType('NSFilenamesPboardType');
        if (!fn.isNil()) lists[2] = ObjC.deepUnwrap(fn) || [];
        out(lists.sort(function (x, y) { return y.length - x.length; })[0].join('\n'));
    } else if (cmd === 'marker-text') {
        var mt = pb.stringForType('com.github.xuing.ssh-paste.owner');
        out(mt.isNil() ? '' : JSON.parse(mt.js).text);
    } else if (cmd === 'save-png') {
        var d = pb.dataForType('public.png');
        if (d.isNil() || !d.writeToFileAtomically(argv[1], true)) throw new Error('no PNG on the pasteboard');
    } else if (cmd === 'stale-write') {
        var lib = loadClient();
        lib.initMac();
        var P = lib.macPlatform(false);
        var s = P.readState();
        var before = Number(pb.changeCount);
        var result = 'written';
        try {
            P.publish({ state: s, text: '/tmp/x', owner: 0, token: '0123456789abcdef', promise: false, basis: s.Seq - 1 });
        } catch (e) { result = /changed since it was read/.test(e.message) ? 'refused' : 'error: ' + e.message; }
        if (Number(pb.changeCount) !== before) result += ', but the pasteboard changed';
        lib.removePrivateDirectory();
        out(result);
    } else if (cmd === 'png-of') {
        var rep = $.NSBitmapImageRep.imageRepWithData($.NSData.dataWithContentsOfFile(argv[1]));
        rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $()).writeToFileAtomically(argv[2], true);
    } else {
        throw new Error('unknown command ' + cmd);
    }
    $.exit(0);
}
