// The guided steps of a capability page (web/src/settings/steps.js) and what the layout JSON declares. Plain node.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stepKeys, draftFrom, applyPreset, presetOf, diff, changed, applyParts, optionOf, withRecommended, screens, progress, isGuided, freeKeys, changedAll, kvGet, setupDone } from '../web/src/settings/steps.js';

const layout = JSON.parse(readFileSync(new URL('../web/src/settings/layout.gen.json', import.meta.url), 'utf8'));
const gw = layout.caps.gateway;
assert.equal(gw.apply, 'gateway setup');
assert.deepEqual(gw.steps.map((s) => s.id), ['connect', 'domain', 'certs', 'auth', 'unknown']);
assert.deepEqual(stepKeys(gw.steps), ['reverseProxy', 'gatewayTunnelPort', 'gatewayPublicHttps', 'gatewayPublicHttp', 'proxyDomains', 'gatewayDirectDomains', 'gatewayAcmeEmail', 'gatewayAcmeStaging', 'gatewayAcmeChallenge', 'gatewayAcmeDnsProvider', 'gatewayUnknownHostLocal', 'gatewayUnknownHostPublic']);
assert.ok(Object.values(layout.caps).every((c) => c.steps === undefined || (c.apply && c.steps.every((s) => /^[a-z][a-z0-9-]*$/.test(s.id)))));

assert.ok(isGuided(gw.steps));
assert.ok(gw.steps.every((s) => !s.presets && s.question));
assert.deepEqual(gw.steps.find((s) => s.id === 'connect').options.map((o) => o.id), ['tunnel', 'router']);
assert.deepEqual(gw.steps.find((s) => s.id === 'certs').options.map((o) => o.id), ['cloudflare']);
assert.ok(gw.steps.every((s) => (s.options || []).every((o) => !o.recommended)));
assert.deepEqual(freeKeys(gw.steps.find((s) => s.id === 'certs')), ['gatewayAcmeEmail', 'gatewayAcmeStaging']);
assert.deepEqual(freeKeys(gw.steps.find((s) => s.id === 'connect')), []);
assert.deepEqual(freeKeys({ keys: ['a'] }), ['a']);

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
// the wizard: docker declares two questions with options, each with one recommended
const dk = layout.caps.docker;
assert.equal(dk.apply, 'docker setup');
assert.deepEqual(dk.steps.map((s) => s.id), ['manager', 'size']);
for (const s of dk.steps) {
  assert.equal(s.options.filter((o) => o.recommended).length, 1, s.id);
  assert.ok(s.question);
}
assert.equal(isGuided(dk.steps), true);
assert.equal(isGuided(gw.steps), true);
assert.equal(isGuided(undefined), false);
const dOpts = [{ key: 'dockerManager', cur: '' }, { key: 'dockerSize', cur: '', dflt: 'm' }];
const w0 = withRecommended(draftFrom(dOpts, dk.steps), dk.steps);
assert.deepEqual(w0, { dockerManager: 'webui', dockerSize: 'm' });
assert.equal(optionOf(w0, dk.steps[0]).id, 'webui');
assert.deepEqual(changed(w0, dOpts, 'setup'), ['setup', '--set', 'dockerManager=webui'], 'size m is the default: no diff');
assert.deepEqual(withRecommended({ dockerManager: 'arcane', dockerSize: '' }, dk.steps), { dockerManager: 'arcane', dockerSize: 'm' });
assert.deepEqual(screens(dk.steps), ['manager', 'size', 'review']);
assert.deepEqual(screens(dk.steps, 'size'), ['size', 'review']);
assert.deepEqual(screens(dk.steps, 'nope'), ['manager', 'size', 'review']);
assert.deepEqual(progress(1, 3), { text: 'Step 2 of 3', pct: 67 });
console.log('  ok    settings steps');

// the docker wizard counts the container, not the capability list
const dkSteps = layout.caps.docker.steps;
const dkDraft = withRecommended(draftFrom([], dkSteps), dkSteps);
assert.deepEqual(changedAll(dkDraft, dkSteps, 'setup'), ['setup', '--set', 'dockerManager=webui', '--set', 'dockerSize=m']);
assert.deepEqual(changedAll({}, dkSteps, 'setup'), []);
const owned = [['state', 'on'], ['owned', 'yes']];
const notOwned = [['state', 'off'], ['owned', 'no'], ['instance', '-']];
assert.equal(kvGet(notOwned, 'instance'), '');
assert.equal(setupDone('docker setup', true, notOwned), false);
assert.equal(setupDone('docker setup', true, null), false);
assert.equal(setupDone('docker setup', false, owned), true);
assert.equal(setupDone('gateway setup', true, notOwned), true);
assert.equal(setupDone('gateway setup', false, owned), false);

