// The page is the URL path (the backend answers every unknown path with the app, so a reload keeps the page).
//
// Every address lives under a node: /node/<name>/<inner path>, the local node too (name = its host name).
//   route.full  the address as it is in the bar            /node/homeserver/storage/bulk/disks
//   route.node  the node's name                            homeserver        ('' = an address without a node: not yet redirected)
//   route.path  the INNER path, which pages and tests use  /storage/bulk/disks   ('/' = the node's Summary)
//   route.query the search part as an object               { pool: 'bulk' }
// go('/instances') on a page means "this page of the CURRENT node"; go('/node/other/health') names a node. url(path) gives the address for an <a href>.
import { redirect } from './redirects.js';

const state = { local: '' };          // the local node's name, set once by the shell (setLocalNode)

function parse(pathname, search = '') {
  const m = pathname.match(/^\/node\/([^/]+)(\/.*)?$/);
  const query = Object.fromEntries(new URLSearchParams(search));
  return m ? { full: pathname, node: decodeURIComponent(m[1]), path: m[2] || '/', query } : { full: pathname, node: '', path: pathname, query };
}

export const route = $state(parse(location.pathname, location.search));

function set(p) { route.full = p.full; route.node = p.node; route.path = p.path; route.query = p.query; }

addEventListener('popstate', () => { set(parse(location.pathname, location.search)); fix(); });

// the address for a path: already a node address stays; an inner path gets the current node (or the local one)
export function url(path) {
  if (path.startsWith('/node/')) return path;
  const node = route.node || state.local;
  return node ? `/node/${encodeURIComponent(node)}${path === '/' ? '' : path}` : path;
}

export function go(path) {
  const to = url(path);
  if (to === location.pathname + location.search) return;
  history.pushState({}, '', to);
  set(parse(to.split('?')[0], to.includes('?') ? to.slice(to.indexOf('?')) : ''));
  fix();
}

// An address without a node, or an old one (routes.js `redirects`), is replaced by the new one; Back keeps working because it is replaceState.
function fix() {
  if (!state.local || new URLSearchParams(location.search).has('terminal')) return;   // a popped-out terminal keeps its address
  const cur = route.full + (location.search || '');
  const to = redirect(route.node ? `/node/${encodeURIComponent(route.node)}${route.path === '/' ? '' : route.path}` + (location.search || '') : cur, state.local);
  if (to && to !== cur) {
    history.replaceState({}, '', to);
    set(parse(to.split('?')[0], to.includes('?') ? to.slice(to.indexOf('?')) : ''));
  }
}

// The shell calls this once it knows the local node's name (the session answer); an old address is replaced right away.
export function setLocalNode(name) {
  if (!name || state.local === name) return;
  state.local = name;
  fix();
}
