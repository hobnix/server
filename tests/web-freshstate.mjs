import assert from 'node:assert/strict';
import { worst } from '../web/src/freshstate.js';

assert.deepEqual(worst([]), { status: 'fresh', topics: [], error: '', lastOk: null });
assert.equal(worst([{ status: 'fresh' }, null, undefined]).status, 'fresh');
assert.equal(worst([{ status: 'fresh' }, { status: 'stale', topic: 'a' }]).status, 'stale');
assert.equal(worst([{ status: 'expired', topic: 'a' }, { status: 'stale', topic: 'b' }]).status, 'expired');
const w = worst([{ status: 'error', topic: 'x', error: 'boom', lastOk: 5000 }, { status: 'error', topic: 'y', lastOk: 3000 }, { status: 'fresh', topic: 'z' }]);
assert.deepEqual(w, { status: 'error', topics: ['x', 'y'], error: 'boom', lastOk: 3000 });
console.log('ok');
