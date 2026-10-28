// The pure logic of the file manager (Storage > Files): rows, locks, selection, paths. No Svelte, no browser: tests/web-files-selection.mjs runs it with node.
//
// A listing row (api.js `ls`): { type: 'd' | 'f' | 'l', bytes, mtime (epoch s), name, disks: [], flags: [], busy: { op, pct } | null }.
// A selection is a Set of names inside ONE folder; `anchor` is the row a Shift range starts from.

// ── locks: why a row cannot be selected (HANDOFF.md "Locked rows") ─────────────────────────────────────────────────────────────────────────
// -> { locked, openable, tag, tone, reason }. tone: warn (amber), info (blue: a job works on it), off (grey).
const OPS = { move: 'Moving', copy: 'Copying', delete: 'Deleting', rename: 'Renaming' };
export function lockOf(row, ctx = {}) {
  const f = row.flags ?? [];
  const dir = row.type === 'd';
  if (f.includes('system')) return { locked: true, openable: false, tag: 'system', tone: 'off', reason: 'System entry of the array: it cannot be opened, moved, renamed or deleted.' };
  if (f.includes('noaccess')) return { locked: true, openable: false, tag: 'no access', tone: 'warn', reason: 'The server is not allowed to read this entry.' };
  if (row.busy) {
    const pct = Number.isFinite(row.busy.pct) ? ` · ${row.busy.pct} %` : '';
    return { locked: true, openable: dir, tag: `${OPS[row.busy.op] ?? 'Working'}${pct}`, tone: 'info', reason: 'A job is working on this item. It is locked until the job ends.' };
  }
  if (f.includes('busyparent')) return { locked: true, openable: dir, tag: 'Job running inside', tone: 'info', reason: 'A job is working on something inside this folder, so the folder itself is locked.' };
  // an array folder (shares, sensitive on a bulk disk), and the top-level folders of a pool view, which are the same folders seen through the merge
  if (f.includes('array') || (ctx.poolRoot && dir)) return { locked: true, openable: dir, tag: 'array', tone: 'warn', reason: ctx.poolRoot && !f.includes('array') ? 'Top-level folder of a pool: open it, but it is never moved, renamed or deleted.' : 'Array folder: it can be opened, never selected, so it cannot be moved, renamed or deleted.' };
  return { locked: false, openable: dir };
}
export const selectable = (row, ctx) => !lockOf(row, ctx).locked;

// ── parsing the contract ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
// one `row<TAB>type<TAB>bytes<TAB>mtime<TAB>name<TAB>disks<TAB>flags<TAB>busy` line (as the fields after the word `row`)
const list = (v) => (!v || v === '-' ? [] : v.split(',').filter(Boolean));
export function parseRow(f) {
  const [type, bytes, mtime, name, disks, flags, busy] = f;
  let b = null;
  if (busy && busy !== '-') { const [op, pct] = busy.split(':'); b = { op, pct: pct === undefined || pct === '' ? NaN : Number(pct) }; }
  return { type: type === 'd' || type === 'l' ? type : 'f', bytes: bytes === '-' || bytes === '' ? NaN : Number(bytes), mtime: Number(mtime) || 0, name, disks: list(disks), flags: list(flags), busy: b };
}

// ── selection ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
// A click with modifiers on the row `name`. `order` = the names as shown (sorted, filtered), only the selectable ones count for a range.
// -> { sel: Set, anchor }
export function click(state, order, name, mods = {}) {
  const { sel, anchor } = state;
  const pickable = new Set(order.filter((n) => !state.locked?.has(n)));
  if (state.locked?.has(name)) return { sel, anchor };
  if (mods.shift && anchor && order.includes(anchor)) {
    const a = order.indexOf(anchor), b = order.indexOf(name);
    const span = order.slice(Math.min(a, b), Math.max(a, b) + 1).filter((n) => pickable.has(n));
    return { sel: mods.ctrl ? new Set([...sel, ...span]) : new Set(span), anchor };
  }
  if (mods.ctrl) return { sel: toggle(sel, name), anchor: name };
  return { sel: new Set([name]), anchor: name };
}

export function toggle(sel, name) {
  const n = new Set(sel);
  if (n.has(name)) n.delete(name); else n.add(name);
  return n;
}

// all selectable rows of `order` (a Set); when they are all selected already, none (so the header box and Ctrl+A both toggle)
export function selectAll(order, locked, sel) {
  const all = order.filter((n) => !locked.has(n));
  return all.length && all.every((n) => sel.has(n)) ? new Set() : new Set(all);
}

// `*`: every selectable row that was not selected, and the others not
export function invert(order, locked, sel) {
  return new Set(order.filter((n) => !locked.has(n) && !sel.has(n)));
}

// a glob (`*.mkv`, `S0?E*`, case ignored) as a RegExp: * any run, ? one character, everything else literal
export function globRe(pat) {
  const esc = pat.trim().replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp(`^${esc}$`, 'i');
}
// `+` (add) and `-` (remove) a pattern; a pattern without a wildcard is a part of the name ("holiday" = *holiday*)
export function byPattern(order, locked, sel, pat, remove = false) {
  const p = pat.trim();
  if (!p) return sel;
  const re = globRe(/[*?]/.test(p) ? p : `*${p}*`);
  const hit = order.filter((n) => !locked.has(n) && re.test(n));
  const n = new Set(sel);
  for (const h of hit) remove ? n.delete(h) : n.add(h);
  return n;
}

// the sizes of the selection: { n, bytes, dirs, files, unknownDirs } (a folder's size is unknown until calculated: bytes is NaN for it)
export function totals(rows, sel) {
  let n = 0, bytes = 0, dirs = 0, files = 0, unknownDirs = 0;
  for (const r of rows) {
    if (!sel.has(r.name)) continue;
    n++;
    if (r.type === 'd') { dirs++; if (Number.isFinite(r.bytes)) bytes += r.bytes; else unknownDirs++; } else { files++; if (Number.isFinite(r.bytes)) bytes += r.bytes; }
  }
  return { n, bytes, dirs, files, unknownDirs };
}

// the next row for the keyboard cursor: d = +1 / -1 along `order`; stays at the ends; nothing current -> the first
export function step(order, cur, d) {
  if (!order.length) return '';
  const i = order.indexOf(cur);
  if (i < 0) return d > 0 ? order[0] : order[order.length - 1];
  return order[Math.max(0, Math.min(order.length - 1, i + d))];
}

// ── paths (a location-relative path always starts with /) ───────────────────────────────────────────────────────────────────────────────
export const joinPath = (dir, name) => (dir === '/' || !dir ? `/${name}` : `${dir.replace(/\/+$/, '')}/${name}`);
export function parentPath(p) {
  const parts = (p ?? '/').split('/').filter(Boolean);
  parts.pop();
  return '/' + parts.join('/');
}
// [{ name, path }] from the root: "/shares/x" -> shares (/shares), x (/shares/x); the root itself is the location's label (the pane draws it)
export function crumbs(p) {
  const parts = (p ?? '/').split('/').filter(Boolean);
  return parts.map((name, i) => ({ name, path: '/' + parts.slice(0, i + 1).join('/') }));
}
// a path only ever comes from a link or the address bar: no .., no control characters, one leading slash
export function cleanPath(p) {
  const parts = String(p ?? '/').split('/').filter((x) => x && x !== '.');
  if (parts.some((x) => x === '..' || /[\x00-\x1f]/.test(x))) return '/';
  return '/' + parts.join('/');
}

// ── the tray: items collected from several folders of ONE location ───────────────────────────────────────────────────────────────────────
// An item is { dir, name, type, bytes }. The operation gets the deepest folder they all share as its path and the items as paths below it.
export const commonDir = (dirs) => {
  if (!dirs.length) return '/';
  const split = dirs.map((d) => d.split('/').filter(Boolean));
  const out = [];
  for (let i = 0; i < split[0].length; i++) {
    if (split.every((s) => s[i] === split[0][i])) out.push(split[0][i]); else break;
  }
  return '/' + out.join('/');
}
// items -> { path, names } (names relative to path: "a.mkv" or "sub/b.mkv"); duplicates dropped
export function sourceOf(items) {
  const path = commonDir(items.map((i) => i.dir));
  const cut = path === '/' ? 1 : path.length + 1;
  const names = [];
  for (const i of items) {
    const rel = joinPath(i.dir, i.name).slice(cut);
    if (!names.includes(rel)) names.push(rel);
  }
  return { path, names };
}
export const trayKey = (i) => joinPath(i.dir, i.name);
export function addToTray(tray, items) {
  const seen = new Set(tray.map(trayKey));
  return [...tray, ...items.filter((i) => !seen.has(trayKey(i)))];
}
// a folder that is (or lies inside) an item cannot be the target of that item
export const insideAny = (target, items) => items.some((i) => i.type === 'd' && (target === trayKey(i) || target.startsWith(trayKey(i) + '/')));

// ── text ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
export function bytesTxt(b) {
  if (!Number.isFinite(b)) return '—';
  const u = ['B', 'kB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0, v = b;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return `${i === 0 || v >= 100 ? Math.round(v) : v.toFixed(1).replace(/\.0$/, '')} ${u[i]}`;
}
export function etaTxt(s) {
  if (!Number.isFinite(s) || s < 0) return '';
  if (s < 90) return `${Math.round(s)} s`;
  if (s < 5400) return `${Math.round(s / 60)} min`;
  return `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min`;
}
export function dateTxt(epoch, now = Date.now()) {
  if (!epoch) return '—';
  const d = new Date(epoch * 1000);
  const p = (n) => String(n).padStart(2, '0');
  const day = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  return now - d.getTime() < 180 * 86400000 && now > d.getTime() ? `${day} ${p(d.getHours())}:${p(d.getMinutes())}` : day;
}
export const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;
// the line above a pane: "12 selected · 4.3 GB · 3 folders"
export function selText(t) {
  if (!t.n) return 'Nothing selected';
  const bits = [`${t.n} selected`];
  if (t.bytes || !t.unknownDirs) bits.push(bytesTxt(t.bytes) + (t.unknownDirs ? '+' : ''));
  if (t.dirs) bits.push(plural(t.dirs, 'folder'));
  return bits.join(' · ');
}
