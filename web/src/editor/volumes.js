// Shares in the compose editor, on plain data (no CodeMirror, no yaml; tests/web-docker-editor.mjs runs it with node).
//   - the mounts of the container docker (rows of `ct storage docker`) and where a share is seen: /shares/<share>
//   - the volume line the Bind share dialog adds, and the text edit that puts it under the right service
//   - what completion offers inside a `volumes:` entry
export const SHARES_ROOT = '/shares';
export const mountPathOf = (share) => `${SHARES_ROOT}/${share}`;
export const DEFAULT_AS = '1000:1000';

const SHARE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const PEER_RE = /^[a-z0-9][a-z0-9-]{0,19}$/;

// rows of `ct storage docker` (device kind source path access cache) -> [{ device, kind, source, path, ro, share, peer }]
// share = a local share under /bulk/shares; peer = a remote peer under /mnt/remote (always read only)
export function mountsOf(rows) {
  const out = [];
  for (const r of rows || []) {
    if (!Array.isArray(r) || r.length < 5) continue;
    const [device, kind, source, path, access] = r;
    if (!path || path === '/' || !String(path).startsWith('/')) continue;
    const m = { device, kind, source, path, ro: access === 'read', share: '', peer: '' };
    if (String(source).startsWith('/bulk/shares/')) m.share = String(source).slice('/bulk/shares/'.length).split('/')[0];
    else if (String(source).startsWith('/mnt/remote/')) { m.peer = String(source).slice('/mnt/remote/'.length).split('/')[0]; m.ro = true; }
    out.push(m);
  }
  return out;
}

// the mount that already gives `target` ({ share } or { peer }) to Docker, or undefined
export const findMount = (mounts, target) =>
  (mounts || []).find((m) => (target.share ? m.share === target.share : m.peer === target.peer && !!target.peer));

// the mount a path lies in (the longest match), or undefined
export function mountOfPath(mounts, p) {
  let best;
  for (const m of mounts || []) {
    if ((p === m.path || String(p).startsWith(m.path + '/')) && (!best || m.path.length > best.path.length)) best = m;
  }
  return best;
}

// what the dialog accepts for the container path, the subfolder and the share value
export const validContainerPath = (p) => /^\/(?!.*\.\.)[A-Za-z0-9._/-]{1,200}$/.test(String(p || '').trim());
export const validSub = (s) => !s || /^(?!.*(^|\/)\.\.(\/|$))[A-Za-z0-9._ -]+(\/[A-Za-z0-9._ -]+)*$/.test(String(s).replace(/^\/+|\/+$/g, ''));
export const validShareValue = (v) => (String(v).startsWith('remote:') ? PEER_RE.test(String(v).slice(7)) : SHARE_RE.test(String(v)));

// source host path: the mount path and the subfolder
export function joinHost(mountPath, sub) {
  const s = String(sub || '').replace(/^\/+|\/+$/g, '');
  return s ? `${mountPath}/${s}` : mountPath;
}

// the entry (without the dash) the dialog inserts: <host>:<container path>[:ro]
export function volumeEntryText({ host, cpath, ro }) {
  return `${host}:${String(cpath).trim()}${ro ? ':ro' : ''}`;
}

// the arguments of `hs sys docker plan|start` for the mount: ['mount', src, '--path', p, '--as', a]
export function mountArgs(value, path, as) {
  const a = ['mount', value, '--path', path];
  if (as && !String(value).startsWith('remote:')) a.push('--as', as);
  return a;
}

// ── the source of a volumes entry (string or object) ──
// -> { source, ro, bind } ; bind is false for a named volume or a tmpfs
export function volumeSource(entry) {
  if (entry && typeof entry === 'object') {
    const type = entry.type || (entry.source && /^[./~]/.test(String(entry.source)) ? 'bind' : 'volume');
    return { source: String(entry.source ?? ''), ro: entry.read_only === true, bind: type === 'bind' };
  }
  if (typeof entry !== 'string') return { source: '', ro: false, bind: false };
  const parts = entry.split(':');
  if (parts.length < 2) return { source: '', ro: false, bind: false };      // a lone container path: an anonymous volume
  const source = parts[0];
  const opts = (parts[2] || '').split(',');
  return { source, ro: opts.includes('ro'), bind: /^[./~]/.test(source) };
}

// ── where does a new volume line go? ──
const indentOf = (l) => /^ */.exec(l)[0].length;
const isBlank = (l) => /^\s*(#.*)?$/.test(l);

// -> { from, insert, cursor } to put `- <entry>` under the volumes: of the service the cursor is in (created when missing), or null when the
// text has no readable services: block or the volumes are written inline ([...]); the caller then inserts at the cursor
export function insertVolumeEdit(text, pos, entry) {
  const lines = String(text).split('\n');
  const starts = [];
  let off = 0;
  for (const l of lines) { starts.push(off); off += l.length + 1; }
  const row = Math.max(0, Math.min(lines.length - 1, String(text).slice(0, pos).split('\n').length - 1));
  const sIdx = lines.findIndex((l) => /^services:\s*(#.*)?$/.test(l));
  if (sIdx < 0) return null;
  let end = lines.length;
  for (let i = sIdx + 1; i < lines.length; i++) if (!isBlank(lines[i]) && indentOf(lines[i]) === 0) { end = i; break; }
  let si = -1;
  for (let i = sIdx + 1; i < end; i++) if (!isBlank(lines[i])) { si = indentOf(lines[i]); break; }
  if (si <= 0) return null;
  const svc = [];      // the line numbers of the service keys
  for (let i = sIdx + 1; i < end; i++) if (indentOf(lines[i]) === si && /^ *[A-Za-z0-9_.-]+:\s*(#.*)?$/.test(lines[i])) svc.push(i);
  if (!svc.length) return null;
  let k = 0;
  for (let j = 0; j < svc.length; j++) if (svc[j] <= row) k = j;
  const from = svc[k] + 1;
  let to = k + 1 < svc.length ? svc[k + 1] : end;
  while (to > from && isBlank(lines[to - 1])) to--;       // the block ends at its last content line
  if (to <= from) return null;
  let ci = -1;
  for (let i = from; i < to; i++) if (!isBlank(lines[i])) { ci = indentOf(lines[i]); break; }
  if (ci <= si) return null;
  const lineEnd = (i) => starts[i] + lines[i].length;
  const vIdx = (() => { for (let i = from; i < to; i++) if (indentOf(lines[i]) === ci && /^ *volumes:/.test(lines[i])) return i; return -1; })();
  if (vIdx < 0) {
    const insert = `\n${' '.repeat(ci)}volumes:\n${' '.repeat(ci + 2)}- ${entry}`;
    return { from: lineEnd(to - 1), insert, cursor: lineEnd(to - 1) + insert.length };
  }
  if (!/^ *volumes:\s*(#.*)?$/.test(lines[vIdx])) return null;      // volumes: [..] written inline
  let last = vIdx;
  let dash = ci + 2;
  let seen = false;
  for (let i = vIdx + 1; i < to; i++) {
    if (isBlank(lines[i])) continue;
    const ind = indentOf(lines[i]);
    const isItem = /^ *- /.test(lines[i]) || /^ *-$/.test(lines[i]);
    if (ind < ci || (ind === ci && !isItem)) break;
    if (isItem && !seen) { dash = ind; seen = true; }
    last = i;
  }
  const insert = `\n${' '.repeat(dash)}- ${entry}`;
  return { from: lineEnd(last), insert, cursor: lineEnd(last) + insert.length };
}

// ── completion in a volumes entry ──
// the line up to the cursor is `  - <typed>` (before the first colon) inside a `volumes:` list -> { prefix } or null
export function volumeEntryAt(text, pos) {
  const lines = String(text).slice(0, pos).split('\n');
  const cur = lines[lines.length - 1];
  const m = /^(\s*)-\s+["']?([^:"'\s]*)$/.exec(cur);
  if (!m) return null;
  const dash = m[1].length;
  for (let r = lines.length - 2; r >= 0; r--) {
    const l = lines[r];
    if (isBlank(l)) continue;
    const ind = indentOf(l);
    if (/^\s*-(\s|$)/.test(l) && ind >= dash) continue;     // an earlier item of the same list
    if (ind > dash) continue;                               // inside an earlier item (a mapping entry)
    return /^\s*volumes:\s*(#.*)?$/.test(l) ? { prefix: m[2] } : null;
  }
  return null;
}

// what to offer for the typed start of a host path:
//   { kind: 'roots', items: [path...] }   nothing typed that is a path yet: the mount paths and ./
//   { kind: 'dir', mount, rel, typed }    after <mount>/ : list the folder `rel` (no leading slash) of the mount; `typed` = the letters after the last /
//   { kind: 'none' }
export function volumeCandidates(prefix, mounts) {
  const p = String(prefix || '');
  const paths = (mounts || []).map((m) => m.path);
  const m = mountOfPath(mounts, p.replace(/\/[^/]*$/, '/').replace(/\/$/, '') || p);
  if (m && p.startsWith(m.path + '/')) {
    const rest = p.slice(m.path.length + 1);
    const i = rest.lastIndexOf('/');
    return { kind: 'dir', mount: m, rel: i < 0 ? '' : rest.slice(0, i), typed: i < 0 ? rest : rest.slice(i + 1) };
  }
  if (p === '' || p === '.' || p === './' || p.startsWith('/')) {
    return { kind: 'roots', items: ['./', ...paths.map((x) => x + '/')].filter((x) => x.startsWith(p) || p === '') };
  }
  return { kind: 'none' };
}

// the name typed after `${` at the end of `before` (the text up to the cursor), or null: independent of any YAML context
export const varPrefixAt = (before) => /\$\{([A-Za-z0-9_]*)$/.exec(String(before))?.[1] ?? null;

// ── enum hints for values the compose spec leaves open ──
export const VALUE_HINTS = {
  restart: ['no', 'always', 'on-failure', 'unless-stopped'],
  network_mode: ['host', 'bridge', 'none'],
  pull_policy: ['always', 'never', 'missing', 'build', 'daily', 'weekly'],
};
