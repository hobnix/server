// The Releases page of Settings (web/src/settings/releases.js, the tree entry, the route, the German words). Plain node: the .svelte files and
// i18n.js (runes) cannot be imported, so the route and the German dictionary are checked in their source text.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CHANNELS, WHO, releaseModel, nextUpdate, planArgs } from '../web/src/settings/releases.js';
import { mainTree } from '../web/src/nav.js';

const src = (p) => readFileSync(new URL(`../web/src/${p}`, import.meta.url), 'utf8');

assert.deepEqual(CHANNELS, ['stable', 'beta', 'edge']);
assert.equal(releaseModel([]), null);
assert.equal(releaseModel(null), null);

const m = releaseModel([['channel', 'beta'], ['installed', 'v1.1.0-beta.1'], ['offer', 'stable', 'v1.0.0', 'kept'], ['offer', 'beta', 'v1.1.0-beta.1', 'current'],
  ['offer', 'edge', 'origin/develop', 'update'], ['ref', 'v1.1.0-beta.1'], ['state', 'current'], ['signed', 'yes']]);
assert.equal(m.channel, 'beta');
assert.equal(m.installed, 'v1.1.0-beta.1');
assert.deepEqual(m.offers.stable, { ref: 'v1.0.0', state: 'kept' });
assert.equal(m.offers.edge.ref, 'origin/develop');
assert.equal(m.signed, 'yes');
assert.equal(nextUpdate(m).state, 'ok');
assert.deepEqual(['current', 'kept', 'update', 'unknown', 'none'].map((s) => nextUpdate({ state: s }).state), ['ok', 'info', 'warn', 'info', 'off']);
assert.match(nextUpdate({ state: 'kept' }).text, /no downgrade/);
assert.deepEqual(planArgs('edge'), ['channel', 'edge']);

// the page is in the tree under Settings and has a route
const settings = mainTree.find((i) => i.path === '/settings');
assert.ok(settings.children.some((c) => c.path === '/settings/releases' && c.label === 'Releases'));
assert.match(src('routes.js'), /'\/settings\/releases': Releases,/);

// German: every sentence of the page is in the dictionary of i18n.js
const i18n = src('i18n.js');
const words = [...Object.values(WHO), ...['current', 'kept', 'update', 'unknown', 'none'].map((s) => nextUpdate({ state: s }).text),
  'Releases', 'Installed version', 'Next update', 'Signature', 'Would install', 'Switch to'];
for (const w of words) assert.ok(i18n.includes(`'${w}':`) || i18n.includes(` ${w}:`) || i18n.includes(`{ ${w}:`), `no German for: ${w}`);
console.log('  ok    web releases');
