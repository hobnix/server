// The Settings subpages: every key lands on exactly one page besides Advanced, Advanced lists all, the tree has a child per page, and only
// capabilities that are on and have a page show in the tree. Plain node. The key lists come from the .sh (HS_KEYS, HS_SETTABLE).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fieldsFor, capEntries, pageOf } from '../web/src/settings/layout.js';
import { mainTree, nodeItems } from '../web/src/nav.js';

const layout = JSON.parse(readFileSync(new URL('../web/src/settings/layout.gen.json', import.meta.url), 'utf8'));
const keys = (process.env.HS_KEYS || '').trim().split(/\s+/).filter(Boolean);
const settable = new Set((process.env.HS_SETTABLE || '').trim().split(/\s+/).filter(Boolean));
assert.ok(keys.length > 50, 'the key list was passed in');
const opts = keys.map((key) => ({ key, settable: settable.has(key) }));
const pages = [...layout.pages.filter((p) => p !== 'advanced'), ...Object.keys(layout.caps).map((n) => `cap:${n}`)];

// (1) the JSON has exactly the keys of the schema
assert.deepEqual(Object.keys(layout.keys).sort(), [...keys].sort());
// (2) every settable key is on exactly one page other than advanced
for (const k of settable) assert.equal(pages.filter((p) => fieldsFor(layout, p, opts).some((o) => o.key === k)).length, 1, k);
for (const k of keys) assert.ok(pageOf(layout, k), k);
// (3) every key is on advanced
assert.deepEqual(fieldsFor(layout, 'advanced', opts).map((o) => o.key), keys);
// (4) the tree lists only capabilities that are on and have a page
const names = Object.entries(layout.caps).filter(([, c]) => c.entry).map(([n]) => n);
assert.ok(names.includes('gateway'));
assert.deepEqual(capEntries(layout, []), []);
assert.deepEqual(capEntries(layout, null), []);
assert.deepEqual(capEntries(layout, ['gateway', 'docs']).map((e) => e.path), ['/settings/capabilities/gateway']);
const all = capEntries(layout, Object.keys(layout.caps));
assert.deepEqual(all.map((e) => e.label), all.map((e) => e.label).sort((a, b) => a.localeCompare(b)));
// (5) every page id has a tree child under /settings; the capability children land under Capabilities
const settings = mainTree.find((i) => i.path === '/settings');
for (const p of layout.pages) assert.ok(settings.children.some((c) => c.path === `/settings/${p}`), p);
const withCap = nodeItems('main', null, [], capEntries(layout, ['gateway'])).find((i) => i.path === '/settings');
assert.deepEqual(withCap.children.find((c) => c.path === '/settings/capabilities').children.map((c) => c.path), ['/settings/capabilities/gateway']);
assert.equal(settings.children.find((c) => c.path === '/settings/capabilities').children, undefined, 'the static tree is not changed');
console.log('  ok    settings layout');
