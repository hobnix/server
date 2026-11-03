// Helpers for the Docker page and the Instances page: map the 10/11-field app row and group docker-list rows by parent.
export function appOf(r) {
  if (!Array.isArray(r) || r.length < 10) return null;
  return {
    name: r[0],
    parent: r[1],
    project: r[2],
    state: r[3],
    running: r[4],
    ports: r[5],
    address: r[6],
    images: r[7],
    managed: r[8],
    update: r[9],
    files: r.length > 10 && r[10] ? r[10] : '-',   // same|changed|new|invalid|- (compose files on disk against what runs)
  };
}

export const UNMANAGED_TIP = 'Started by hand with docker run; copy it into a compose app to manage it';

// The chip of the list for an app: { text, tone, tip } or null. Nothing deploys by itself: changed/new only tell, Apply is the owner's click.
export function filesChip(a) {
  if (!a) return null;
  if (a.managed === 'unmanaged') return { text: 'Unmanaged', tone: '', tip: UNMANAGED_TIP };
  if (a.files === 'changed') return { text: 'Changed, not applied', tone: 'warn', tip: 'The compose files on disk differ from what runs' };
  if (a.files === 'new') return { text: 'New, not started', tone: 'info', tip: 'The compose files are on disk but the app was never started' };
  if (a.files === 'invalid') return { text: 'Invalid compose file', tone: 'bad', tip: 'docker compose config fails or the name exists twice' };
  return null;
}

// The Apply action of the list: { show, ok, reason }. Only for apps with files to apply; refused for invalid files and for apps the web does not manage.
export function applyOf(a) {
  if (!a || a.managed === 'unmanaged' || (a.files !== 'changed' && a.files !== 'new' && a.files !== 'invalid')) return { show: false, ok: false, reason: '' };
  if (a.files === 'invalid') return { show: true, ok: false, reason: 'The compose file is not valid: open the editor and fix it first.' };
  if (a.managed !== 'web' && a.managed !== 'recipe') return { show: true, ok: false, reason: 'This app is not managed by hobnix.' };
  return { show: true, ok: true, reason: '' };
}

// Unmanaged rows are read-only: no start, stop, restart, pull, edit
export const isActionable = (a) => !!a && a.managed !== 'unmanaged';

// The revision line of `docker rev <app>` ({ text } answer of the read), '' when unknown
export const revOf = (d) => String(d?.text ?? '').trim();

// The editor found the app changed on disk: another revision than the one it loaded (a new app has none)
export const diskChanged = (loaded, polled) => !!polled && !!loaded && loaded !== 'new' && polled !== loaded;

export function childrenOf(listRows) {
  const map = new Map();
  if (!Array.isArray(listRows)) return map;
  for (const r of listRows) {
    if (!Array.isArray(r) || r.length < 5) continue;
    const parent = r[1];
    if (!parent || parent === '-') continue;
    if (!map.has(parent)) map.set(parent, []);
    map.get(parent).push(r);
  }
  return map;
}
