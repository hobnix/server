// Polled reads. `poll('/api/sys/ct/list', 5000)` gives a reactive { data, error, loaded }. The path may be a function (or return
// '' to pause, e.g. while a panel is collapsed). A failed read keeps the last data, so a page never flashes empty on one bad answer.
import { get } from './api.js';
export { ageOf } from './api.js';

// The last answer per path, for the whole session: a page revisited (or the tree's counts) shows it at once and then reads again.
const cache = new Map();
export const clearPollCache = () => cache.clear();

// Read these paths once, one after the other, when the browser is idle (after sign-in), so the first click on a page finds its data.
export function prefetch(paths) {
  const idle = window.requestIdleCallback || ((f) => setTimeout(f, 300));
  let i = 0;
  const next = () => {
    if (i >= paths.length) return;
    const p = paths[i++];
    (cache.has(p) ? Promise.resolve() : get(p).then((d) => cache.set(p, d)).catch(() => {})).finally(() => idle(next));
  };
  idle(next);
}

// Fetch these paths now (all at once) and keep the answers in the cache; for the moment before a page opens (the pointer is on its tree entry).
// An error leaves the old answer where it is.
export function touch(paths) {
  for (const p of paths) get(p).then((d) => cache.set(p, d)).catch(() => {});
}

// The refresh button of a page: read these paths now (the server runs the scripts, whatever it holds), keep the answers, and let every poll show them.
export const sync = $state({ n: 0, busy: false });
export async function refresh(paths) {
  sync.busy = true;
  try {
    await Promise.all(paths.map((p) => get(p, true).then((d) => cache.set(p, d)).catch(() => {})));
  } finally {
    sync.busy = false;
    sync.n++;
  }
}

export function poll(path, ms) {
  const st = $state({ data: null, error: null, loaded: false });
  $effect(() => {
    sync.n;   // a refresh re-runs this effect: the new answer is in the cache
    const p = typeof path === 'function' ? path() : path;
    if (!p) return;
    if (cache.has(p)) { st.data = cache.get(p); st.error = null; st.loaded = true; }
    let alive = true;
    let timer;
    const run = async () => {
      try {
        const d = await get(p);
        cache.set(p, d);
        if (alive) { st.data = d; st.error = null; }
      } catch (e) {
        if (alive) st.error = e;
      }
      if (alive) {
        st.loaded = true;
        timer = setTimeout(run, ms);
      }
    };
    run();
    return () => { alive = false; clearTimeout(timer); };
  });
  return st;
}

// the rows of a tsv answer, [] before the first answer
export const rows = (st) => st.data?.rows ?? [];
