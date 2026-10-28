// The pure logic of the file manager (web/src/files/selection.js): locks, selection (click, Ctrl, Shift, all, invert, pattern), paths, the tray, texts. Run with node.
import * as S from '../web/src/files/selection.js';

let ok = 0, bad = 0;
const eq = (name, got, want) => { if (JSON.stringify(got) === JSON.stringify(want)) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); } };
const arr = (s) => [...s];

console.log('-- parsing and locks');
const r1 = S.parseRow(['d', '4096', '1700000000', 'shares', '-', 'array', '-']);
eq('a row', [r1.type, r1.bytes, r1.name, r1.disks, r1.flags, r1.busy], ['d', null, 'shares', [], ['array'], null]);
const r2 = S.parseRow(['f', '12', '1700000000', 'a.mkv', 'data-04,data-07', '-', 'move:34']);
eq('disks and a busy tag', [r2.disks, r2.busy], [['data-04', 'data-07'], { op: 'move', pct: 34 }]);
eq('an unknown size', Number.isNaN(S.parseRow(['d', '-', '0', 'x', '-', '-', '-']).bytes), true);
eq('an array folder opens but never selects', [S.lockOf(r1).locked, S.lockOf(r1).openable, S.lockOf(r1).tag], [true, true, 'array']);
eq('a system entry does not open', [S.lockOf({ type: 'd', flags: ['system'] }).locked, S.lockOf({ type: 'd', flags: ['system'] }).openable], [true, false]);
eq('a busy item shows the job and its percent', S.lockOf(r2).tag, 'Moving · 34 %');
eq('a parent of a busy item', S.lockOf({ type: 'd', flags: ['busyparent'] }).tag, 'Job running inside');
eq('a plain file is free', S.lockOf({ type: 'f', flags: [] }).locked, false);
eq('a pool root folder is locked like an array folder', S.lockOf({ type: 'd', flags: [] }, { poolRoot: true }).locked, true);
eq('a pool root FILE is locked too (the server marks every entry there array)', S.lockOf({ type: 'f', flags: [] }, { poolRoot: true }).locked, true);
eq('a folder has no size (the server sends 0)', Number.isNaN(S.parseRow(['d', '0', '1', 'x', '-', '-', '-']).bytes), true);
eq('no access neither opens nor selects', [S.lockOf({ type: 'd', flags: ['noaccess'] }).locked, S.lockOf({ type: 'd', flags: ['noaccess'] }).openable], [true, false]);

console.log('-- clicks');
const order = ['a', 'b', 'c', 'd', 'e', 'f'];
const locked = new Set(['c']);
let st = { sel: new Set(), anchor: '', locked };
st = { ...st, ...S.click(st, order, 'b') };
eq('a plain click selects one', [arr(st.sel), st.anchor], [['b'], 'b']);
st = { ...st, ...S.click(st, order, 'a') };
eq('a plain click replaces', arr(st.sel), ['a']);
st = { ...st, ...S.click(st, order, 'd', { ctrl: true }) };
eq('Ctrl adds', arr(st.sel).sort(), ['a', 'd']);
st = { ...st, ...S.click(st, order, 'd', { ctrl: true }) };
eq('Ctrl again removes', arr(st.sel), ['a']);
st = { sel: new Set(['a']), anchor: 'a', locked };
st = { ...st, ...S.click(st, order, 'e', { shift: true }) };
eq('Shift selects the range and skips the locked row', arr(st.sel), ['a', 'b', 'd', 'e']);
st = { ...st, ...S.click(st, order, 'b', { shift: true }) };
eq('Shift again from the same anchor re-ranges', arr(st.sel), ['a', 'b']);
st = { ...st, ...S.click(st, order, 'f', { shift: true, ctrl: true }) };
eq('Ctrl+Shift adds a range', arr(st.sel), ['a', 'b', 'd', 'e', 'f']);
eq('a click on a locked row changes nothing', arr(S.click({ sel: new Set(['a']), anchor: 'a', locked }, order, 'c').sel), ['a']);
eq('Shift without an anchor is a plain click', arr(S.click({ sel: new Set(), anchor: '', locked }, order, 'e', { shift: true }).sel), ['e']);

console.log('-- all, invert, pattern');
eq('select all skips the locked', arr(S.selectAll(order, locked, new Set())), ['a', 'b', 'd', 'e', 'f']);
eq('select all again clears', arr(S.selectAll(order, locked, new Set(['a', 'b', 'd', 'e', 'f']))), []);
eq('invert', arr(S.invert(order, locked, new Set(['a', 'b']))), ['d', 'e', 'f']);
const files = ['Movie.MKV', 'movie.srt', 'notes.txt', 'S01E02.mkv', 'S01E03.mkv'];
eq('a glob, case ignored', arr(S.byPattern(files, new Set(), new Set(), '*.mkv')), ['Movie.MKV', 'S01E02.mkv', 'S01E03.mkv']);
eq('? is one character', arr(S.byPattern(files, new Set(), new Set(), 'S01E0?.mkv')), ['S01E02.mkv', 'S01E03.mkv']);
eq('a word without a wildcard is a part of the name', arr(S.byPattern(files, new Set(), new Set(), 'movie')), ['Movie.MKV', 'movie.srt']);
eq('minus deselects by pattern', arr(S.byPattern(files, new Set(), new Set(files), '*.mkv', true)), ['movie.srt', 'notes.txt']);
eq('a dot in the pattern is literal', arr(S.byPattern(['axtxt', 'a.txt'], new Set(), new Set(), 'a.txt')), ['a.txt']);
eq('a pattern skips the locked', arr(S.byPattern(['a1', 'a2'], new Set(['a1']), new Set(), 'a*')), ['a2']);

console.log('-- totals and the cursor');
const rows = [{ name: 'a', type: 'f', bytes: 100 }, { name: 'b', type: 'd', bytes: NaN }, { name: 'c', type: 'd', bytes: 50 }, { name: 'd', type: 'f', bytes: 1 }];
eq('totals', S.totals(rows, new Set(['a', 'b', 'c'])), { n: 3, bytes: 150, dirs: 2, files: 1, unknownDirs: 1 });
eq('the line', S.selText(S.totals(rows, new Set(['a', 'c']))), '2 selected · 150 B · 1 folder');
eq('the line, a folder of unknown size', S.selText(S.totals(rows, new Set(['a', 'b']))), '2 selected · 100 B+ · 1 folder');
eq('nothing', S.selText(S.totals(rows, new Set())), 'Nothing selected');
eq('the cursor moves and stops at the ends', [S.step(order, 'a', -1), S.step(order, 'a', 1), S.step(order, 'f', 1), S.step(order, '', 1), S.step(order, 'x', -1), S.step([], 'a', 1)], ['a', 'b', 'f', 'a', 'f', '']);

console.log('-- paths');
eq('join', [S.joinPath('/', 'a'), S.joinPath('/shares', 'a b'), S.joinPath('/shares/', 'a')], ['/a', '/shares/a b', '/shares/a']);
eq('parent', [S.parentPath('/shares/x'), S.parentPath('/shares'), S.parentPath('/')], ['/shares', '/', '/']);
eq('crumbs', S.crumbs('/shares/x'), [{ name: 'shares', path: '/shares' }, { name: 'x', path: '/shares/x' }]);
eq('clean path', [S.cleanPath('shares//x/'), S.cleanPath('/a/../b'), S.cleanPath('/a/./b'), S.cleanPath(undefined), S.cleanPath('/a/\u0001')], ['/shares/x', '/', '/a/b', '/', '/']);

console.log('-- the tray');
eq('the common folder', [S.commonDir(['/a/b', '/a/c']), S.commonDir(['/a/b']), S.commonDir(['/a', '/b']), S.commonDir([])], ['/a', '/a/b', '/', '/']);
const items = [{ dir: "/shares/x", name: "a.mkv", type: "f" }, { dir: "/shares/y", name: "b.mkv", type: "f" }, { dir: "/shares/x", name: "a.mkv", type: "f" }];
eq('items from two folders (pure function; the page never builds this, the tray holds ONE folder)', S.sourceOf(items), { path: '/shares', names: ['x/a.mkv', 'y/b.mkv'] });
eq('items of one folder have plain names', S.sourceOf([{ dir: '/shares/x', name: 'a', type: 'd' }, { dir: '/shares/x', name: 'b', type: 'f' }]), { path: '/shares/x', names: ['a', 'b'] });
eq('items at the root', S.sourceOf([{ dir: '/', name: 'a', type: 'd' }, { dir: '/', name: 'b', type: 'f' }]), { path: '/', names: ['a', 'b'] });
eq('the tray does not hold an item twice', S.addToTray([items[0]], items).length, 2);
eq('a folder is not a target for itself or below', [S.insideAny('/a/b', [{ dir: '/a', name: 'b', type: 'd' }]), S.insideAny('/a/b/c', [{ dir: '/a', name: 'b', type: 'd' }]), S.insideAny('/a/bc', [{ dir: '/a', name: 'b', type: 'd' }])], [true, true, false]);

console.log('-- text');
eq('bytes', [S.bytesTxt(0), S.bytesTxt(999), S.bytesTxt(4300000000), S.bytesTxt(NaN)], ['0 B', '999 B', '4.3 GB', '—']);
eq('eta', [S.etaTxt(30), S.etaTxt(600), S.etaTxt(7500), S.etaTxt(NaN)], ['30 s', '10 min', '2 h 5 min', '']);
eq('plural', [S.plural(1, 'file'), S.plural(3, 'file')], ['1 file', '3 files']);

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
