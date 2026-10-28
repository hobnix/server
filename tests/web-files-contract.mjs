// The contract: REAL outputs of scripts/fm.sh (tests/fixtures/fm, via the web server's own parsing, see web-files-contract-build.py) through the page's parsers
// (web/src/files/api.js) with a mocked fetch. Run by tests/web-files-contract.sh (FM_BUNDLE = the bundle json).
import { readFileSync } from 'node:fs';

const bundle = JSON.parse(readFileSync(process.env.FM_BUNDLE, 'utf8'));
let ok = 0, bad = 0;
const eq = (name, got, want) => { if (JSON.stringify(got) === JSON.stringify(want)) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); } };

// the mock: a GET answers the fixture `next.read`, a POST records its body and answers `next.change`
const calls = [];
let next = {};
globalThis.fetch = async (url, opts = {}) => {
  const body = opts.body ? JSON.parse(opts.body) : undefined;
  calls.push({ url: String(url), method: opts.method ?? 'GET', body });
  const data = (opts.method ?? 'GET') === 'GET' ? bundle[next.read] : bundle[next.change];
  if (!data) throw new Error('no fixture for ' + JSON.stringify(next));
  return { ok: true, status: 200, headers: { get: () => null }, json: async () => data };
};
const api = await import('../web/src/files/api.js');
const last = () => calls[calls.length - 1];

console.log('-- locations');
next = { read: 'locations' };
let r = await api.locations();
eq('url', last().url, '/api/sys/fm/locations');
eq('ok, write on, not locked', [r.ok, r.write, r.locked], [true, true, false]);
const d4 = r.locs.find((l) => l.id === 'disk:data-04');
eq('a disk row', [d4.kind, d4.label, d4.writable, d4.reason, d4.pool, d4.disk, d4.size > 0, d4.free > 0], ['disk', 'data-04', true, '', 'bulk', 'data-04', true, true]);
const closed = r.locs.find((l) => l.id === 'disk:data-06');
eq('a closed disk is read only with a reason', [closed.writable, /closed/.test(closed.reason)], [false, true]);
eq('detached', r.locs.find((l) => l.id === 'disk:data-08').writable, false);
eq('a temp disk has a reason', /source only/.test(r.locs.find((l) => l.id === 'temp:usb').reason), true);
eq('a pool has no disk member', [r.locs.find((l) => l.id === 'pool:bulk').disk, r.locs.find((l) => l.id === 'pool:bulk').pool], ['', 'bulk']);
next = { read: 'locations-write-off' };
eq('the write switch off', (await api.locations()).write, false);
next = { read: 'locations-locked' };
r = await api.locations();
eq('locked: ok, locked, no locations', [r.ok, r.locked, r.locs.length], [true, true, 0]);

console.log('-- pair');
next = { read: 'pair-ok' };
eq('ok', await api.pair('disk:data-04', 'disk:data-05'), { ok: true, reason: '' });
eq('url keeps the colon', last().url, '/api/sys/fm/pair/disk:data-04/disk:data-05');
next = { read: 'pair-refused' };
r = await api.pair('disk:data-04', 'pool:bulk');
eq('refused with the reason', [r.ok, /Same files as data-04/.test(r.reason)], [false, true]);

console.log('-- ls');
next = { read: 'ls-folder' };
r = await api.ls('disk:data-04', '/shares/media');
eq('url: leading slash path, no cursor', last().url, '/api/sys/fm/ls/disk:data-04?path=%2Fshares%2Fmedia&limit=500');
eq('rows', r.rows.map((x) => [x.type, x.name]), [['d', 'busyfolder'], ['d', 'movies'], ['f', 'bad\\x01name.txt'], ['f', 'notes.txt'], ['f', 'readme.txt']]);
eq('a folder has no size (the server sends 0): NaN, the page draws an em dash', r.rows.filter((x) => x.type === 'd').every((x) => Number.isNaN(x.bytes)), true);
eq('a file has its size', r.rows.find((x) => x.name === 'notes.txt').bytes, 5);
eq('badname flag', r.rows.find((x) => x.name.startsWith('bad')).flags, ['badname']);
eq('busy row', r.rows.find((x) => x.name === 'busyfolder').busy, { op: 'move', pct: 34 });
eq('end: no next page', r.next, null);
next = { read: 'ls-page' };
r = await api.ls('disk:data-04', '/shares/media', '', 2);
eq('a page has a cursor', r.next, '2');
next = { read: 'ls-disk-top' };
r = await api.ls('disk:data-04', '/');
eq('array and system flags', r.rows.map((x) => [x.name, x.flags]), [['lost+found', ['system']], ['sensitive', ['array']], ['shares', ['array', 'busyparent']]]);
next = { read: 'ls-pool-top' };
r = await api.ls('pool:bulk', '/');
eq('a pool view: top folder is array, with the disks that hold it', [r.rows[0].flags, r.rows[0].disks], [['array', 'busyparent'], ['data-04', 'data-05']]);
next = { read: 'ls-refused' };
r = await api.ls('disk:data-04', '/nope');
eq('refused', [r.ok, r.reason, r.rows.length], [false, 'no such folder', 0]);

console.log('-- plan');
const spec = { op: 'copy', from: 'disk:data-04', path: '/shares/media/movies', to: 'disk:data-05', toPath: '/shares/media/movies', names: ['Avatar', 'Heat'] };
next = { change: 'plan-copy' };
let p = await api.plan(spec, { conflict: 'skip', verify: 'size' });
const b = last().body;
eq('plan request: area, args, selection, no stdin, no confirm', [last().url, b.area, b.selection, b.stdin, b.confirm], ['/api/plan', 'fm', ['Avatar', 'Heat'], undefined, undefined]);
eq('plan request: the arguments', b.args, ['copy', '--from', 'disk:data-04', '--path', '/shares/media/movies', '--to', 'disk:data-05', '--to-path', '/shares/media/movies', '--conflict', 'skip']);
eq('plan request: nothing the server adds itself', b.args.some((a) => ['--by', '--sel-file', '--now', '--job-id', '--confirm'].includes(a)), false);
eq('ok, heading, counts', [p.ok, /^copy 2 item/.test(p.heading), p.files, p.folders, p.bytes > 0, p.freeAfter > 0, p.conflicts, p.parity, p.confirmName, p.long], [true, true, 3, 2, true, true, 1, false, '', false]);
eq('steps keep their mark', p.steps.map((s) => s.mark), ['+', '~', '~']);
eq('notes', p.notes.length, 1);
next = { change: 'plan-copy-conflicts' };
p = await api.plan(spec, { conflicts: true });
eq('conflict rows', p.conflictRows, [{ path: 'Heat', srcBytes: 60, dstBytes: 4, srcMtime: p.conflictRows[0].srcMtime, dstMtime: p.conflictRows[0].dstMtime }]);
next = { change: 'plan-copy-overwrite' };
p = await api.plan({ ...spec, path: '/shares/media', toPath: '/shares/media', names: ['readme.txt'] }, { conflict: 'overwrite' });
eq('overwrite asks for the target name', [p.ok, p.confirmName, p.warns.length > 0], [true, 'media', true]);
next = { change: 'plan-delete' };
p = await api.plan({ op: 'delete', from: 'disk:data-04', path: '/shares/media', names: ['readme.txt', 'notes.txt'] });
eq('delete: confirm name, parity, a warning', [p.ok, p.confirmName, p.parity, p.warns.length], [true, 'delete 2 files', true, 1]);
next = { change: 'plan-refused' };
p = await api.plan(spec);
eq('refused', [p.ok, /Same files/.test(p.reason)], [false, true]);
next = { change: 'plan-rename' };
p = await api.plan({ op: 'rename', from: 'disk:data-04', path: '/shares/media', names: ['readme.txt'] }, { newname: 'readme2.txt' });
eq('rename: the new name is an argument', [p.ok, last().body.args.slice(-2)], [true, ['--newname', 'readme2.txt']]);
next = { change: 'plan-write-off' };
p = await api.plan(spec);
eq('the plan carries a warning while the switch is off', [p.ok, p.warns.some((w) => /read only/.test(w))], [true, true]);

console.log('-- start');
next = { change: 'start-copy' };
let s = await api.start(spec, { conflict: 'skip' }, '');
eq('start request: area, selection, no confirm', [last().url, last().body.area, last().body.selection, last().body.confirm, last().body.stdin], ['/api/start', 'fm', ['Avatar', 'Heat'], undefined, undefined]);
eq('done + unit is a started job', [s.ok, s.unit.startsWith('hs-job-fm-test-')], [true, true]);
next = { change: 'start-delete' };
s = await api.start({ op: 'delete', from: 'disk:data-04', path: '/shares/media', names: ['readme.txt', 'notes.txt'] }, {}, 'delete 2 files');
eq('the typed confirmation is the body field confirm', [last().body.confirm, last().body.args.includes('--confirm')], ['delete 2 files', false]);
next = { change: 'start-confirm-missing' };
s = await api.start({ op: 'delete', from: 'disk:data-04', path: '/shares/media', names: ['readme.txt'] }, {}, '');
eq('refused without the confirmation', [s.ok, /confirmation/.test(s.reason), s.unit], [false, true, '']);
next = { change: 'start-write-off' };
s = await api.start({ op: 'rename', from: 'disk:data-04', path: '/shares/media', names: ['x'] }, { newname: 'y' }, '');
eq('refused while the switch is off, with the way to switch it on', [s.ok, /fileManagerWrite/.test(s.reason)], [false, true]);

console.log('-- progress');
next = { read: 'progress-done' };
let g = await api.progress('hs-job-fm-test-1');
eq('url', last().url, '/api/sys/fm/progress/hs-job-fm-test-1');
eq('a finished job', [g.ok, g.result, g.filesDone, g.filesTotal, g.bytesDone, g.bytesTotal, g.speed, g.eta, g.current, g.phase, g.skipped.n, g.failed.n], [true, 'done', 2, 2, 300007, 300007, 0, 0, '', 'finished', 0, 0]);
next = { read: 'progress-skipped' };
g = await api.progress('x');
eq('skipped items: count and rows', [g.skipped.n, g.skipped.items.map((i) => i.path), g.skipped.items[0].why, g.failed.n], [2, ['Avatar/poster.jpg', 'Avatar/Avatar.mkv'], 'exists at the target', 0]);
next = { read: 'progress-failed' };
g = await api.progress('x');
eq('a failed job', [g.result, g.failed.n, g.failed.items, g.skipped.n], ['failed', 1, [{ path: 'Heat', why: 'a file with that name is in the way' }], 1]);
next = { read: 'progress-unknown' };
g = await api.progress('nothing');
eq('an unknown job is a refusal', [g.ok, /no file manager job/.test(g.reason)], [false, true]);

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
