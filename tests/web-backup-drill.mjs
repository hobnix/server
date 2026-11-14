// Drill rows of the Backup page (web/src/pages/backup-drill.js): drill_ok and drill_ct_ok are epochs, not 'ok'/'failed'.
import assert from 'node:assert/strict';
import { restoreDrill, instanceDrill } from '../web/src/pages/backup-drill.js';

const age = (v) => `age${v}`;
assert.deepEqual(restoreDrill({ drill_ok: '100', last_drill: '100' }, age), ['passed · age100', 'ok']);
assert.deepEqual(restoreDrill({ drill_ok: '100' }, age), ['passed · age100', 'ok']);
assert.deepEqual(restoreDrill({ drill_ok: '100', last_drill: '200' }, age), ['failed · age200', 'bad']);
assert.deepEqual(restoreDrill({ last_drill: '200' }, age), ['failed · age200', 'bad']);
assert.deepEqual(restoreDrill({}, age), ['never', 'off']);
assert.deepEqual(restoreDrill({ drill_ok: '', last_drill: '' }, age), ['never', 'off']);
// old strings
assert.deepEqual(restoreDrill({ drill_ok: 'ok', last_drill: '100' }, age), ['passed · age100', 'ok']);
assert.deepEqual(restoreDrill({ drill_ok: 'failed', last_drill: '100' }, age), ['failed · age100', 'bad']);

assert.equal(instanceDrill({}, age), null);
assert.equal(instanceDrill({ drill_ct_ok: '5' }, age), null);
assert.deepEqual(instanceDrill({ drill_ct_name: 'uptime-kuma', drill_ct_ok: '300' }, age), ['uptime-kuma · passed · age300', 'ok']);
assert.deepEqual(instanceDrill({ drill_ct_name: 'x', drill_ct_ok: 'ok' }, age), ['x · passed', 'ok']);
assert.deepEqual(instanceDrill({ drill_ct_name: 'x', drill_ct_ok: 'failed' }, age), ['x · failed', 'bad']);
assert.deepEqual(instanceDrill({ drill_ct_name: 'x' }, age), ['x · never passed', 'off']);
console.log('ok');
