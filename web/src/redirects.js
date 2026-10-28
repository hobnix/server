// Old address -> new address (pure, no Svelte: tests/web-routes.mjs runs it in node). routes.js re-exports it, route.svelte.js applies it with replaceState.
//
// Phase 1 of the redesign put every page under a node: /node/<name>/<inner path>. The INNER paths did not change yet, so an address without a node
// ("/storage/bulk/disks", "/proxy/ports", a bookmark, a guide link) only gets the node in front. Phase 2 moves pages to the inner paths of
//  every move is ONE line in `innerMoves` (old inner path -> new inner path, a query string is allowed on the right),
// and the redirect then also fixes the addresses that already carry a node. The commented lines are that table, ready for phase 2.
export const innerMoves = {
  '/hardware': '/monitoring/hardware', '/operations/data': '/monitoring/diagnostics',
  '/games': '/extensions/games', '/operations/posters': '/extensions/posters',
  '/storage': '/storage/pools',
  '/storage/bulk': '/storage/pools/bulk', '/storage/fast': '/storage/pools/fast',
  '/storage/bulk/disks': '/storage/disks?pool=bulk', '/storage/fast/disks': '/storage/disks?pool=fast', '/storage/unassigned': '/storage/disks?pool=none',
  '/storage/bulk/shares': '/storage/shares?pool=bulk', '/storage/fast/shares': '/storage/shares?pool=fast',
  '/protection/snapshots': '/storage/shares?view=snapshots',
  '/operations/apps': '/instances/apps', '/operations/services': '/instances/services',
  '/proxy': '/', '/proxy/mail': '/mail', '/proxy/ports': '/ports', '/proxy/game-ports': '/ports', '/proxy/watcher': '/watcher',
  '/proxy/certificate': '/certificate', '/proxy/tailscale': '/tailscale', '/proxy/settings': '/settings',
  // '/operations/notifications': '/monitoring/notifications',
};

// the node the VPS pages belong to (kind vps); its pages are the /proxy/... inner paths until phase 2 renames them
export const VPS_NODE = 'proxyserver';

// Split "/path?query#hash" into [path, rest]
const cut = (a) => { const i = a.search(/[?#]/); return i < 0 ? [a, ''] : [a.slice(0, i), a.slice(i)]; };

// The new address for `addr` (path + search), or null when it is fine as it is. `local` = the local node's name.
export function redirect(addr, local) {
  if (!local) return null;
  let [path, rest] = cut(addr);
  let node, inner;
  const m = path.match(/^\/node\/([^/]+)(\/.*)?$/);
  if (m) { node = decodeURIComponent(m[1]); inner = m[2] || '/'; }
  else {
    inner = path || '/';
    node = inner === '/proxy' || inner.startsWith('/proxy/') ? VPS_NODE : local;
  }
  const moved = innerMoves[inner.length > 1 ? inner.replace(/\/$/, '') : inner];
  if (moved) {
    const [p2, r2] = cut(moved);
    inner = p2;
    rest = r2 ? (rest ? r2 + '&' + rest.replace(/^[?#]/, '') : r2) : rest;
  }
  const out = `/node/${encodeURIComponent(node)}${inner === '/' ? '' : inner}${rest}`;
  return out === addr ? null : out;
}
