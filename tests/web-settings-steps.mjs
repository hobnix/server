// The guided steps of a capability page (web/src/settings/steps.js) and what the layout JSON declares. Plain node.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stepKeys, draftFrom, applyPreset, presetOf, diff, changed, applyParts } from '../web/src/settings/steps.js';

const layout = JSON.parse(readFileSync(new URL('../web/src/settings/layout.gen.json', import.meta.url), 'utf8'));
const gw = layout.caps.gateway;
assert.equal(gw.apply, 'gateway setup');
assert.deepEqual(gw.steps.map((s) => s.id), ['connect', 'domain', 'certs', 'auth', 'unknown']);
assert.deepEqual(stepKeys(gw.steps), ['reverseProxy', 'gatewayTunnelPort', 'gatewayPublicHttps', 'gatewayPublicHttp', 'proxyDomains', 'gatewayDirectDomains', 'gatewayAcmeEmail', 'gatewayAcmeStaging', 'gatewayAcmeChallenge', 'gatewayAcmeDnsProvider', 'gatewayUnknownHostLocal', 'gatewayUnknownHostPublic']);
assert.ok(Object.values(layout.caps).every((c) => c.steps === undefined || (c.apply && c.steps.every((s) => /^[a-z][a-z0-9-]*$/.test(s.id)))));

const steps = [
  { id: 'a', keys: ['x', 'y'], presets: [{ id: 'p', label: 'P', set: { x: '1', y: '2' } }, { id: 'q', label: 'Q', set: { x: '3' } }] },
  { id: 'b', keys: ['y', 'z'] },
  { id: 'c', keys: [] },
];
const opts = [{ key: 'x', cur: '0' }, { key: 'y', cur: '' }, { key: 'z', cur: 'keep' }, { key: 'other', cur: 'o' }];
assert.deepEqual(stepKeys(steps), ['x', 'y', 'z']);
const d0 = draftFrom(opts, steps);
assert.deepEqual(d0, { x: '0', y: '', z: 'keep' });
assert.deepEqual(changed(d0, opts), [], 'nothing changed, no plan');
// a preset sets only its keys and does not touch the old draft
const d1 = applyPreset(d0, steps[0].presets[0]);
assert.deepEqual(d0, { x: '0', y: '', z: 'keep' });
assert.deepEqual(d1, { x: '1', y: '2', z: 'keep' });
assert.equal(presetOf(d1, steps[0].presets).id, 'p');
assert.equal(presetOf(d0, steps[0].presets), undefined);
assert.deepEqual(diff(d1, opts), [{ key: 'x', from: '0', to: '1' }, { key: 'y', from: '', to: '2' }]);
assert.deepEqual(changed(d1, opts), ['setup', '--set', 'x=1', '--set', 'y=2']);
// Advanced edits the same draft: a typed value gives the same list as the preset
assert.deepEqual(changed({ ...d0, x: ' 1 ', y: '2' }, opts), changed(d1, opts));
// a value set back to the current one drops out
assert.deepEqual(changed({ ...d1, x: '0' }, opts), ['setup', '--set', 'y=2']);
assert.deepEqual(changed(d1, opts, 'other'), ['other', '--set', 'x=1', '--set', 'y=2']);
// an unset key applies its default: a preset equal to the default sends nothing and Review shows the default as the old value
const optsD = [{ key: 'p', cur: '', dflt: '0' }, { key: 'q', cur: '', dflt: '' }];
assert.deepEqual(changed({ p: '0', q: '' }, optsD), []);
assert.deepEqual(diff({ p: '8081', q: '' }, optsD), [{ key: 'p', from: '0', to: '8081' }]);
assert.deepEqual(applyParts('gateway setup'), { area: 'gateway', verb: 'setup' });
assert.deepEqual(draftFrom([], steps), { x: '', y: '', z: '' });
console.log('  ok    settings steps');
