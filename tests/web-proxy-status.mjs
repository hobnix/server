// web/src/pages/proxy/status.js (the dots of the proxyserver tree rows) and the nav/routes pairing. Plain node, no dependencies.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'src');
const st = await import(pathToFileURL(join(root, 'pages', 'proxy', 'status.js')).href);

// a document without the optional sections: grey dots, no throw
const bare = { schema: 1, kind: 'proxyserver', time: Date.now() / 1000, problems: 0, mail_queue: 2, tailscale: 'Running' };
let m = st.treeMeta('ok', bare);
assert.equal(m['/'].dot, 'ok');
assert.equal(m['/mail'].dot, 'ok');           // the old key mail_queue alone still counts
assert.equal(m['/ports'].dot, 'off');
assert.equal(m['/watcher'].dot, 'off');
assert.equal(m['/certificate'].dot, 'off');
assert.equal(m['/tailscale'].dot, 'ok');

// full document
const full = { ...bare, mail: { queue: 0, oldest_s: null, stalwart: true, spf: 'pass' },
  watcher: { state: 'ok', heartbeat_age_s: 30, sites: [{ name: 'status', code: 200, since: 1 }] },
  ports: { groups: [
    { id: 'games', name: 'Games', target: 'pelican-wings', probe: { ok: true, ms: 40 }, rows: [{ name: 'game 1', proto: 'tcp+udp', ports: '25565-25579', count: 15, forwarded: true }] },
    { id: 'rtc', name: 'Matrix calls (LiveKit)', target: 'livekit', probe: { ok: true, ms: 30 }, rows: [{ name: 'rtc 1', proto: 'tcp', ports: '7881', count: 1, forwarded: true }] },
    { id: 'mail', name: 'Mail', target: 'stalwart', probe: null, rows: [{ name: 'SMTP', proto: 'tcp', ports: '25', count: 1, forwarded: true }] },
    { id: 'own', name: 'own', target: null, probe: null, rows: [{ name: 'ACME', proto: 'tcp', ports: '80', count: 1, forwarded: true }, { name: 'Tailscale', proto: 'udp', ports: '41641', count: 1, forwarded: true }] }] },
  certificate: { days_left: 60, domain: 'x.cloud' } };
m = st.treeMeta('ok', full);
for (const p of ['mail', 'ports', 'watcher', 'certificate']) assert.equal(m[`/${p}`].dot, 'ok', p);

// trouble
assert.equal(st.mail({ mail: { queue: 3, stalwart: false } }).dot, 'bad');
assert.equal(st.mail({ mail: { queue: 3, oldest_s: 7200, stalwart: true } }).dot, 'warn');
assert.equal(st.mail({ mail: { queue: 0, spf: 'fail' } }).dot, 'warn');
assert.equal(st.watcher({ watcher: { state: 'ok', sites: [{ code: 502 }] } }).dot, 'bad');
assert.equal(st.watcher({ watcher: { state: 'stale', sites: [] } }).dot, 'warn');
const grp = (id, probe, rows, target = 'x') => ({ id, name: id, target, probe, rows: rows.map((f) => ({ name: 'r', proto: 'tcp', ports: '1', count: 1, forwarded: f })) });
assert.equal(st.ports({ ports: { groups: [grp('games', null, [true, false])] } }).dot, 'warn');
assert.equal(st.ports({ ports: { groups: [grp('games', { ok: false, ms: null }, [true]), grp('own', null, [false])] } }).dot, 'bad');
assert.equal(st.ports({ ports: { groups: [grp('mail', null, [false])] } }).dot, 'warn');
assert.equal(st.ports({ ports: { groups: [grp('games', null, [null])] } }).dot, 'off');
assert.equal(st.ports({ ports: { groups: [] } }).dot, 'off');
assert.equal(st.ports({ game_ports: { blocks: [{ forwarded: false }] } }).dot, 'off');   // the old key alone is not the new list
{
  const t = st.ports(full);   // totals: 15 + 1 ports forwarded to 2 targets, 3 open on the VPS itself
  assert.deepEqual([t.forwardedPorts, t.targets, t.openPorts, t.groups.length], [16, 2, 3, 4]);
  assert.equal(t.groups[0].total, 15);
}
assert.equal(st.certificate({ certificate: { days_left: 5 } }).dot, 'bad');
assert.equal(st.certificate({ certificate: { days_left: 14 } }).dot, 'warn');
assert.equal(st.treeMeta('down', null)['/'].dot, 'bad');
assert.deepEqual(st.treeMeta('off', null), {});
assert.equal(st.treeMeta('ok', { ...bare, time: 1 })['/'].dot, 'warn');   // an old document
assert.equal(st.treeMeta('ok', { ...bare, problems: 2 })['/'].dot, 'warn');

// wrong shapes never throw
for (const bad of [null, {}, { mail: 'x', watcher: [], game_ports: 3, ports: { groups: [3, { rows: 'x' }] }, certificate: { days_left: 'x' } }]) {
  assert.doesNotThrow(() => st.treeMeta('ok', bad));
}
assert.equal(st.nodeCount('ok'), 2);
assert.equal(st.nodeCount('off'), 1);
assert.equal(st.nodeCount('down'), 1);

// every proxyserver row has its own path (inner paths of the node: /mail, /ports, ...), and every path has a page in the table of edge nodes
const nav = readFileSync(join(root, 'nav.js'), 'utf8');
const routes = readFileSync(join(root, 'routes.js'), 'utf8');
const edgeBlock = nav.slice(nav.indexOf("label: 'proxyserver'"), nav.indexOf('];', nav.indexOf("label: 'proxyserver'")));
const edgePaths = [...edgeBlock.matchAll(/path: '(\/[^']*)'/g)].map((x) => x[1]).filter((p) => p !== '/');
assert.equal(new Set(edgePaths).size, edgePaths.length, 'proxy rows share a path');
assert.ok(edgePaths.length >= 6);
const edgeRoutes = routes.slice(routes.indexOf('const edgeRoutes'), routes.indexOf('const peerRoutes'));
for (const p of [...edgePaths, '/', '/health']) assert.ok(edgeRoutes.includes(`'${p}':`), `no edge route for ${p}`);
for (const p of Object.keys(m)) assert.ok(p === '/' || edgePaths.includes(p), `the tree has no row for ${p}`);
// the old addresses are moved by redirects.js (tests/web-routes.mjs checks the table itself)
const red = readFileSync(join(root, 'redirects.js'), 'utf8');
for (const old of ['/proxy', ...edgePaths.map((p) => '/proxy' + p), '/proxy/game-ports']) assert.ok(red.includes(`'${old}':`), `no redirect for ${old}`);
console.log('ok');
