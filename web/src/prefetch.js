// What a page reads first, by address, so the answers can be fetched while the pointer is still on the way to the tree entry (TreeNode: pointerenter).
// The server keeps these reads warm (Warmer in scripts/web-serve.py), so the fetch is cheap; it only moves the answer into the browser's cache
// (data.svelte.js) before the page asks. A page that is not listed just loads as it always did.
import { touch } from './data.svelte.js';
import { readsFor } from './readsfor.js';
import { ui } from './ui.svelte.js';

export { readsFor };


// at most once every few seconds per address, however often the pointer crosses the entry
const last = new Map();
export function prefetchRoute(path) {
  const now = Date.now();
  if (!path || now - (last.get(path) ?? 0) < 5000) return;
  last.set(path, now);
  const paths = readsFor(path, ui.features.extensions);
  if (paths.length) touch(paths);
}
