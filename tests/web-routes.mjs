// The node addresses and the redirect table (web/src/redirects.js, pure) and the inner-path handling of readsFor, run with node.
import { redirect, innerMoves } from '../web/src/redirects.js';
import { readsFor, innerPath } from '../web/src/readsfor.js';
import { readFileSync } from 'node:fs';

let ok = 0, bad = 0;
const eq = (name, got, want) => { if (JSON.stringify(got) === JSON.stringify(want)) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); } };

const L = 'homeserver';
eq('/ goes to the local node', redirect('/', L), '/node/homeserver');
eq('an old inner path gets the node', redirect('/instances', L), '/node/homeserver/instances');
eq('a moved storage page is redirected', redirect('/storage/bulk/disks', L), '/node/homeserver/storage/disks?pool=bulk');
eq('also with the node already in front', redirect('/node/homeserver/storage/unassigned', L), '/node/homeserver/storage/disks?pool=none');
eq('the pools move', [redirect('/storage', L), redirect('/storage/fast', L)], ['/node/homeserver/storage/pools', '/node/homeserver/storage/pools/fast']);
eq('the shares move', [redirect('/storage/fast/shares', L), redirect('/protection/snapshots', L)], ['/node/homeserver/storage/shares?pool=fast', '/node/homeserver/storage/shares?view=snapshots']);
eq('a query is joined to the new one', redirect('/storage/bulk/disks?x=1', L), '/node/homeserver/storage/disks?pool=bulk&x=1');
eq('the query is kept', redirect('/instances?x=1', L), '/node/homeserver/instances?x=1');
eq('the vps pages belong to the proxyserver node, one level up', redirect('/proxy/ports', L), '/node/proxyserver/ports');
eq('/proxy is the node summary', redirect('/proxy', L), '/node/proxyserver');
eq('the old alias is the Ports page', redirect('/proxy/game-ports', L), '/node/proxyserver/ports');
eq('every other proxy page', ['mail', 'watcher', 'certificate', 'tailscale', 'settings'].map((p) => redirect(`/proxy/${p}`, L)), ['mail', 'watcher', 'certificate', 'tailscale', 'settings'].map((p) => `/node/proxyserver/${p}`));
eq('an address that already carries the node is moved too', redirect('/node/proxyserver/proxy/mail', L), '/node/proxyserver/mail');
eq('a moved address is left alone afterwards', redirect('/node/proxyserver/mail', L), null);
eq('the settings page of another node is its own', redirect('/node/edge1/settings', L), null);
eq('the query survives a move', redirect('/proxy/ports?x=1', L), '/node/proxyserver/ports?x=1');
eq('a guide address', redirect('/docs/en/setup', L), '/node/homeserver/docs/en/setup');
eq('a node address is left alone', redirect('/node/homeserver/instances', L), null);
eq('the node root is left alone', redirect('/node/other', L), null);
eq('without a local name nothing happens', redirect('/storage', ''), null);
eq('hardware, diagnostics and the extension pages moved', [redirect('/hardware', L), redirect('/node/homeserver/operations/data', L), redirect('/games', L), redirect('/operations/posters', L)],
  ['/node/homeserver/monitoring/hardware', '/node/homeserver/monitoring/diagnostics', '/node/homeserver/extensions/games', '/node/homeserver/extensions/posters']);
eq('the storage moves are in the table', ['/storage/bulk', '/storage/unassigned', '/storage/bulk/shares', '/protection/snapshots'].every((k) => k in innerMoves), true);
eq('every move is an inner path to an inner path', Object.entries(innerMoves).filter(([a, b]) => !a.startsWith('/') || !b.startsWith('/')), []);
eq('Apps moved under Instances', redirect('/operations/apps', L), '/node/homeserver/instances/apps');
eq('Services moved under Instances', redirect('/node/homeserver/operations/services', L), '/node/homeserver/instances/services');
eq('the new Apps page prefetches the recipes', readsFor('/node/homeserver/instances/apps').includes('/api/sys/recipes/list'), true);
eq('the old Apps address prefetches the same', readsFor('/operations/apps'), readsFor('/instances/apps'));
eq('the moves of phase 2D are in the table', ['/proxy', '/proxy/mail', '/proxy/ports', '/proxy/settings'].every((k) => k in innerMoves), true);

eq('inner path strips node and query', innerPath('/node/homeserver/storage/bulk/disks?pool=bulk'), '/storage/bulk/disks');
eq('inner path of a node root', innerPath('/node/homeserver'), '/');
eq('inner path of a plain path', innerPath('/instances'), '/instances');
eq('readsFor takes a node address', readsFor('/node/homeserver/instances'), readsFor('/instances'));
eq('readsFor takes a pool address', readsFor('/node/hs/storage/fast').some((p) => p.endsWith('pool=fast')), true);

// every tree path has a route (the routes table is keyed by inner path), and the nav lines the shell relies on are there
const nav = readFileSync(new URL('../web/src/nav.js', import.meta.url), 'utf8');
const routes = readFileSync(new URL('../web/src/routes.js', import.meta.url), 'utf8');
const paths = [...nav.matchAll(/path: '(\/[^']*)'/g)].map((m) => m[1]);
const missing = paths.filter((p) => !routes.includes(`'${p}':`) && p !== '/');
eq('every tree path has a route', missing, []);

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
