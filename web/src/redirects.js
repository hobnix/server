// Address without a node -> address with the local node (pure, no Svelte: tests/web-routes.mjs runs it in node). routes.js re-exports it, route.svelte.js applies it with replaceState.
//
// Every page lives under a node: /node/<name>/<inner path>. An address without a node ("/storage/pools", an entry address, `go('/x')`)
// only gets the local node in front. Old inner paths are not moved any more; they are plain unknown pages.

// the node the VPS pages belong to (kind vps)
export const VPS_NODE = 'proxyserver';

// Split "/path?query#hash" into [path, rest]
const cut = (a) => { const i = a.search(/[?#]/); return i < 0 ? [a, ''] : [a.slice(0, i), a.slice(i)]; };

// The new address for `addr` (path + search), or null when it is fine as it is. `local` = the local node's name.
export function redirect(addr, local) {
  if (!local) return null;
  const [path, rest] = cut(addr);
  let node, inner;
  const m = path.match(/^\/node\/([^/]+)(\/.*)?$/);
  if (m) { node = decodeURIComponent(m[1]); inner = m[2] || '/'; }
  else { inner = path || '/'; node = local; }
  const out = `/node/${encodeURIComponent(node)}${inner === '/' ? '' : inner}${rest}`;
  return out === addr ? null : out;
}
