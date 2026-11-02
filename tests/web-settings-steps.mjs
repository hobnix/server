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
// real defaults (layout.defaults): an unset key whose default equals an option keeps that option; a set-up draft is not touched
assert.equal(layout.defaults.dockerSize, 'm');
const unset = withRecommended({ dockerManager: '', dockerSize: '' }, dk.steps, layout.defaults);
assert.equal(unset.dockerSize, '', 'size is unset and its default m matches an option: not preset');
assert.equal(optionOf(unset, dk.steps[1], layout.defaults).id, dk.steps[1].options.find((o) => o.set.dockerSize === 'm').id);
assert.equal(layout.defaults.gatewayAcmeStaging, 'true', 'gateway step keys carry their real defaults');
const gwSet = Object.fromEntries(gw.steps.flatMap((s) => s.keys).map((k) => [k, layout.defaults[k] ?? '']));
assert.deepEqual(withRecommended(gwSet, gw.steps, layout.defaults), gwSet, 'a draft that matches the defaults is not changed');
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


// core pages: schema defaults, tolerant optionOf, the `when` rule
import { withDefaults, visibleSteps } from '../web/src/settings/steps.js';
const wo = withDefaults([{ key: 'a', cur: '', dflt: '' }, { key: 'b', cur: 'x', dflt: 'y' }], { a: 'true' });
assert.deepEqual(wo.map((o) => o.dflt), ['true', 'y']);
assert.deepEqual(withDefaults([{ key: 'a' }], null), [{ key: 'a' }]);
const stp = { options: [{ id: 'on', set: { a: 'true' } }, { id: 'off', set: { a: 'false' } }] };
assert.equal(optionOf({ a: '' }, stp), undefined);
assert.equal(optionOf({ a: '' }, stp, { a: 'true' }).id, 'on');
assert.equal(optionOf({ a: '' }, stp, { a: 'false' }).id, 'off');
assert.equal(optionOf({ a: 'false' }, stp, { a: 'true' }).id, 'off');
assert.equal(optionOf({ a: '' }, stp, {}), undefined);
assert.equal(optionOf({ a: '' }, { options: [{ id: 'never', set: { a: '' } }] }, {}).id, 'never');
const ws = [{ id: 'p', when: { bulkType: 'snapraid' } }, { id: 'z', when: { bulkType: 'zfs' } }, { id: 'all' }];
const ids = (o, d) => visibleSteps(ws, o, d).map((s) => s.id);
assert.deepEqual(ids([{ key: 'bulkType', cur: 'snapraid' }]), ['p', 'all']);
assert.deepEqual(ids([{ key: 'bulkType', cur: '', dflt: 'zfs' }]), ['z', 'all']);
assert.deepEqual(ids([{ key: 'bulkType', cur: '' }], { bulkType: 'zfs' }), ['z', 'all']);
assert.deepEqual(ids([], null), ['all']);
assert.deepEqual(visibleSteps(ws.slice(2), null).map((s) => s.id), ['all']);
assert.deepEqual(changed({ a: 'false' }, withDefaults([{ key: 'a', cur: '' }], { a: 'true' }), 'apply'), ['apply', '--set', 'a=false']);
assert.deepEqual(changed({ a: 'true' }, withDefaults([{ key: 'a', cur: '' }], { a: 'true' }), 'apply'), []);

// tag.js: the tag of a part and of the Updates header
import { partTag, updatesTag } from '../web/src/settings/tag.js';
assert.deepEqual(partTag(undefined, ''), { state: 'off', label: 'off' });
assert.deepEqual(partTag({ on: false, nix: true }, 'ok'), { state: 'off', label: 'off' });
assert.deepEqual(partTag({ on: true, nix: true }, 'fail'), { state: 'warn', label: 'rebuild needed' });
assert.deepEqual(partTag({ on: true, nix: false }, 'fail'), { state: 'ok', label: 'on' });
assert.deepEqual(partTag({ on: false, nix: true, pending: true }, ''), { state: 'warn', label: 'rebuild needed' });
assert.deepEqual(partTag({ on: true, nix: true }, 'ok'), { state: 'ok', label: 'running' });
assert.deepEqual(partTag({ on: true, nix: true }, ''), { state: 'ok', label: 'on' });
assert.equal(updatesTag([]), null);
assert.equal(updatesTag(undefined), null);
assert.deepEqual(updatesTag([['behind', '0'], ['ahead', '0']]), { state: 'ok', label: 'up to date' });
assert.deepEqual(updatesTag([['behind', '1']]), { state: 'warn', label: '1 update available' });
assert.deepEqual(updatesTag([['behind', '3']]), { state: 'warn', label: '3 updates available' });

// steps with options_from: the rows of a read become the choices (current first); no rows leave a free field
import { readPath, withReadOptions } from '../web/src/settings/steps.js';
const nicStep = { id: 'card', keys: ['nic'], options_from: 'net nics' };
assert.equal(readPath(nicStep), '/api/sys/net/nics');
assert.equal(readPath({ id: 'x', keys: ['a'] }), '');
assert.equal(withReadOptions(nicStep, []), nicStep);
const nicOpts = withReadOptions(nicStep, [['eth1', 'down', '-', 'no'], ['eth0', 'up', 'aa:bb', 'yes']]).options;
assert.deepEqual(nicOpts.map((o) => o.id), ['eth0', 'eth1']);
assert.deepEqual(nicOpts[0].set, { nic: 'eth0' });
assert.equal(nicOpts[0].text, 'up · aa:bb');
assert.equal(nicOpts[1].text, 'down');
