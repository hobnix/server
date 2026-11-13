// The first-run wizard steps (web/src/setup/steps.js). Plain node.
import assert from 'node:assert/strict';
import { FIRST_RUN_STEPS, active, clampIndex } from '../web/src/setup/steps.js';

assert.deepEqual(FIRST_RUN_STEPS.map((s) => s.id), ['account', 'network', 'storage', 'preset', 'done']);
assert.deepEqual(active(FIRST_RUN_STEPS, ['account', 'preset', 'done']).map((s) => s.id), ['account', 'preset', 'done']);
assert.deepEqual(active(FIRST_RUN_STEPS, ['account', 'network', 'preset', 'done']).map((s) => s.id), ['account', 'network', 'preset', 'done']);
assert.ok(FIRST_RUN_STEPS.every((s) => s.question && s.primary));
for (const s of FIRST_RUN_STEPS.filter((x) => x.slot)) assert.match(s.slot, /^#\d+$/);
assert.deepEqual(FIRST_RUN_STEPS.filter((s) => s.slot).map((s) => s.id), ['network', 'storage']);
assert.equal(clampIndex(-1, 3), 0);
assert.equal(clampIndex(9, 3), 2);
assert.equal(clampIndex(1, 3), 1);
