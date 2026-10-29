// The ONLY place the file manager talks to the backend (the contract is `hs sys fm ...`, docs/PLAN-file-manager.md section 7). Everything else in
// web/src/files works with the objects this module returns, so a change of the wire format is a change here.
//
// READS (GET /api/sys/fm/<words>, tsv rows; the first row is `status<TAB>ok|refused`, a refusal has `reason<TAB>text`):
//   fm/locations                     loc <id> <kind> <label> <fs> <size> <free> <writable yes|no> <reason|-> <pool|-> <disk|-> <modifiable yes|no>
//   fm/pair/<left>/<right>           status ok | refused + reason (the same-files rule)
//   fm/ls/<loc>?path=&cursor=&limit= row <type d|f|l> <bytes> <mtime> <name> <disks|-> <flags|-> <busy op:pct|->, then `cursor <X>` or `end`
//   fm/progress/<unit>               key<TAB>value: files_done files_total bytes_done bytes_total speed eta current phase result skipped failed
//   fm/locations also carries `write<TAB>yes|no` (the runtime setting fileManagerWrite: no = copy, move, delete, rename and new folder are refused) and,
//   while the encrypted storage is locked, `locked<TAB>yes` and no loc rows.
// CHANGES (POST /api/plan and /api/start, area `fm`): args = [op, --from, <loc>, --path, <P>, (--to, <loc>, --to-path, <Q>), (--conflict ..), (--verify ..),
//   (--parity-after), (--newname N), (--conflicts)]; the selection (item names INSIDE --path, one folder, no slash) is the body field `selection`, the typed
//   confirmation the body field `confirm`; web-serve.py adds --by/--confirm itself. Paths start with `/` and are relative to the location root.
//   start answers `status done` + `unit` (or `refused` + `reason`).
import { get, plan as askPlan, start as doStart } from '../api.js';
import { parseRow } from './selection.js';

const A = '/api/sys/fm/';
// a location id is `kind:name` (disk:data-04): the colon may stay, anything else that is not a name character is encoded
const enc = (id) => encodeURIComponent(id).replace(/%3A/gi, ':');

// the rows of a read as { head, rows } where rows are the field lists after the first word; `status` and `reason` are taken out
function split(d) {
  const all = d?.rows ?? [];
  const out = { ok: true, reason: '', rows: [], kv: {} };
  for (const r of all) {
    if (r[0] === 'status') out.ok = r[1] === 'ok';
    else if (r[0] === 'reason') out.reason = r.slice(1).join('\t');
    else { out.rows.push(r); if (!(r[0] in out.kv)) out.kv[r[0]] = r.slice(1).join('\t'); }
  }
  return out;
}

export async function locations() {
  const s = split(await get(A + 'locations'));
  const locs = s.rows.filter((r) => r[0] === 'loc').map((r) => ({
    id: r[1], kind: r[2], label: r[3], fs: r[4] === '-' ? '' : r[4], size: Number(r[5]) || 0, free: r[6] === '-' || r[6] === '' ? NaN : Number(r[6]),
    writable: r[7] === 'yes', reason: r[8] === '-' ? '' : (r[8] ?? ''), pool: r[9] === '-' ? '' : (r[9] ?? ''), disk: r[10] === '-' ? '' : (r[10] ?? ''),
    // files may be removed or renamed in it: a closed disk takes no new files (writable no) but is still a source that can be emptied; an older server sends no column
    modifiable: r[11] ? r[11] === 'yes' : r[7] === 'yes',
  }));
  return { ok: s.ok, reason: s.reason, locs, locked: s.kv.locked === 'yes', write: s.kv.write !== 'no' };
}

// may these two be the two sides of a copy or move? { ok, reason }
export async function pair(left, right) {
  const s = split(await get(`${A}pair/${enc(left)}/${enc(right)}`));
  return { ok: s.ok, reason: s.reason };
}

// one page of a folder: { ok, reason, rows, next } (next = the cursor of the following page, null at the end)
export async function ls(loc, path = '/', cursor = '', limit = 500) {
  const q = new URLSearchParams({ path });
  if (cursor) q.set('cursor', cursor);
  if (limit) q.set('limit', String(limit));
  const s = split(await get(`${A}ls/${enc(loc)}?${q}`));
  return { ok: s.ok, reason: s.reason, rows: s.rows.filter((r) => r[0] === 'row').map((r) => parseRow(r.slice(1))), next: s.kv.cursor ?? null };
}

// the state of a running or finished job: numbers as numbers; `skipped` and `failed` are lists of { path, why } (a bare number = only a count)
export async function progress(unit) {
  const s = split(await get(`${A}progress/${enc(unit)}`));
  const num = (k) => (s.kv[k] === undefined || s.kv[k] === '-' ? NaN : Number(s.kv[k]));
  // `skipped<TAB>N` / `failed<TAB>N` are the counts, `skip<TAB>path<TAB>why` / `fail<TAB>path<TAB>why` the first 200 items
  const list = (k, tag) => {
    const items = s.rows.filter((r) => r[0] === tag).map((r) => ({ path: r[1] ?? '', why: r.slice(2).join(' ') }));
    const c = num(k);
    return { n: Number.isFinite(c) ? Math.max(c, items.length) : items.length, items };
  };
  return {
    ok: s.ok, reason: s.reason, filesDone: num('files_done'), filesTotal: num('files_total'), bytesDone: num('bytes_done'), bytesTotal: num('bytes_total'),
    speed: num('speed'), eta: num('eta'), current: s.kv.current && s.kv.current !== '-' ? s.kv.current : '', phase: s.kv.phase && s.kv.phase !== '-' ? s.kv.phase : '',
    result: s.kv.result || 'running', skipped: list('skipped', 'skip'), failed: list('failed', 'fail'),
  };
}

// ── changes ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
// spec: { op, from, path, to?, toPath?, names? }, opts: { conflict, verify, parity, newname, conflicts }
export function args(spec, opts = {}) {
  const a = [spec.op, '--from', spec.from, '--path', spec.path];
  if (spec.to) a.push('--to', spec.to, '--to-path', spec.toPath ?? '/');
  const moves = spec.op === 'copy' || spec.op === 'move';
  if (moves && opts.conflict) a.push('--conflict', opts.conflict);
  if (moves && opts.verify === 'checksum') a.push('--verify', 'checksum');
  if (spec.op === 'move' && opts.parity) a.push('--parity-after');
  if (opts.newname !== undefined && opts.newname !== '' && (spec.op === 'rename' || spec.op === 'mkdir')) a.push('--newname', opts.newname);
  if (opts.conflicts) a.push('--conflicts');
  return a;
}
const selOf = (names) => (names?.length ? names : undefined);

// The plan, as the dialog needs it. Fields the backend sends as text become numbers; the steps keep the mark they start with (+ ~ -).
export async function plan(spec, opts = {}) {
  const r = await askPlan('fm', args(spec, opts), undefined, selOf(spec.names));
  const n = (v) => (v === undefined || v === '' || v === '-' ? NaN : Number(v));
  const steps = [], notes = [], warns = [];
  for (const [k, v] of r.steps ?? []) {
    if (k === 'step') { const m = /^([+~\-−])\s+(.*)$/.exec(v); steps.push({ mark: m ? (m[1] === '−' ? '-' : m[1]) : '+', text: m ? m[2] : v }); }
    else if (k === 'note') notes.push(v);
    else if (k === 'warn' || k === 'danger') warns.push(v);
  }
  // the dry-run rows `conflict<TAB>path<TAB>src_bytes<TAB>dst_bytes<TAB>src_mtime<TAB>dst_mtime` (the web server hands every extra key through as `rows`)
  const conflictRows = (r.conflict_rows ?? r.rows ?? []).map((c) => ({ path: c[0], srcBytes: n(c[1]), dstBytes: n(c[2]), srcMtime: n(c[3]), dstMtime: n(c[4]) }));
  return {
    ok: r.status === 'ok', reason: r.reason ?? '', heading: r.heading ?? '', steps, notes, warns, files: n(r.files), folders: n(r.folders), bytes: n(r.bytes), freeAfter: n(r.free_after),
    conflicts: n(r.conflicts) || 0, parity: r.parity === true || r.parity === 'yes', confirmName: r.confirm_name ?? '', long: !!r.long, conflictRows,
  };
}

// start it: { ok, reason, unit }; `confirm` is the typed text the plan asked for
export async function start(spec, opts, confirm) {
  const r = await doStart('fm', args(spec, opts), confirm, undefined, selOf(spec.names));
  return { ok: r.status === 'done' || r.status === 'started', reason: r.reason ?? '', unit: r.unit ?? '' };
}

// stop a running job (the existing jobs stop)
export async function cancel(unit) {
  const r = await doStart('jobs', ['stop', unit]);
  return { ok: r.status !== 'refused', reason: r.reason ?? '' };
}
