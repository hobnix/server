// The tree of a REMOTE node built from the capabilities its status document reports (web/src/nav.js nodeItems) and the helpers of the node pages
// (web/src/pages/nodes/nodes.js). Plain node, no dependencies.
import assert from 'node:assert/strict';
import { nodeItems } from '../web/src/nav.js';
import { since, keyInfo, capList, facts } from '../web/src/pages/nodes/nodes.js';

const paths = (kind, caps) => nodeItems(kind, caps).map((i) => i.path);

// a peer: Health always; Storage, Instances, Backup only for the capabilities it names
assert.deepEqual(paths('peer', null), ['/health']);
assert.deepEqual(paths('peer', []), ['/health']);
assert.deepEqual(paths('peer', ['storage', 'incus', 'backup', 'samba']), ['/health', '/storage', '/instances', '/protection/backup']);
assert.deepEqual(paths('peer', ['incus']), ['/health', '/instances']);

// an edge node: the pages follow its edge capabilities; Tailscale and Settings are always there
assert.deepEqual(paths('edge', ['edge-ports']), ['/health', '/ports', '/tailscale', '/settings']);
assert.deepEqual(paths('edge', ['edge-mail', 'edge-ports', 'edge-watcher', 'edge-status']), ['/health', '/mail', '/ports', '/watcher', '/certificate', '/tailscale', '/settings']);
// a vps node (the old proxyserver) does not report a list: every page
assert.deepEqual(paths('vps', null), ['/health', '/mail', '/ports', '/watcher', '/certificate', '/tailscale', '/settings']);
// the main node keeps its long tree and the Nodes page
assert.ok(paths('main', ['docs']).includes('/nodes'));
assert.ok(paths('main', null).includes('/settings'));
// nothing of a remote tree is a local page by accident: a peer never gets Settings, Network or Identity
for (const p of ['/settings', '/network', '/identity', '/nodes', '/setup']) assert.ok(!paths('peer', ['storage', 'incus', 'backup']).includes(p), p);

// the capability pages go under Settings > Capabilities (a copy: without the 4th argument nothing changes)
const gw = [{ label: 'Gateway proxy', icon: 'puzzle-piece', path: '/settings/capabilities/gateway' }];
const capKids = (items) => items.find((i) => i.path === '/settings').children.find((c) => c.path === '/settings/capabilities').children;
assert.deepEqual(capKids(nodeItems('main', null, [], gw)), gw);
assert.equal(capKids(nodeItems('main', null, [])), undefined);
assert.equal(capKids(nodeItems('main', null, [], gw)) === gw, true);
assert.equal(capKids(nodeItems('main', null)), undefined);

// helpers
const now = 1_000_000;
assert.equal(since(null, now), 'never');
assert.equal(since(now - 10, now), 'just now');
assert.equal(since(now - 14 * 60, now), '14 min ago');
assert.equal(since(now - 3 * 3600, now), '3 h ago');
assert.equal(since(now - 5 * 86400, now), '5 d ago');
assert.deepEqual(keyInfo([['key', 'ok'], ['line', 'restrict,command="x" ssh-ed25519 AAA hs-node']]), { key: 'ok', line: 'restrict,command="x" ssh-ed25519 AAA hs-node' });
assert.deepEqual(capList(['a', 'b', 'c', 'd', 'e', 'f']), { shown: ['a', 'b', 'c', 'd'], more: 2 });
assert.deepEqual(capList(null), { shown: [], more: 0 });
const f = facts({ pools: { fast: { size: 100, used: 40, health: 'ONLINE' }, bulk: null }, instances: { running: 2, total: 3 }, backup: { status: 'ok', age_s: 60 }, locked: true });
assert.deepEqual(f, { pools: [{ name: 'fast', used: 40, size: 100, health: 'ONLINE' }], instances: { running: 2, total: 3 }, backup: { status: 'ok', age_s: 60 }, locked: true });
assert.deepEqual(facts(null), { pools: [], instances: null, backup: null, locked: false });

console.log('ok');
