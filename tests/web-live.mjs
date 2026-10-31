// The poll timing of the live stream (web/src/polldelay.js): no timer while a topic read follows the stream, the plain interval otherwise.
import { nextDelay } from '../web/src/polldelay.js';
import { parseLiveRows } from '../web/src/livestatus.js';

let ok = 0, bad = 0;
const check = (name, cond) => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}`); } };

check('topic and live open: no timer', nextDelay('status', true, 15000) === null);
check('topic, live closed: the interval', nextDelay('status', false, 15000) === 15000);
check('no topic, live open: the interval', nextDelay(undefined, true, 15000) === 15000);
check('503 with retry_after: that many seconds', nextDelay('status', true, 15000, { status: 503, retryAfter: 2 }) === 2000);
check('503 without retry_after: the interval', nextDelay('status', false, 15000, { status: 503 }) === 15000);
check('other error, live open: the interval', nextDelay('status', true, 15000, { status: 500 }) === 15000);
check('live topic and live open: no timer', nextDelay('live', true, 5000) === null);
check('live topic, live closed: the interval', nextDelay('live', false, 5000) === 5000);

const now = 1000;
const rows = [
  ['status', '15', '7', '1', '0', '-', '-'],
  ['a', '5', '-1', '2', '0', '-', '-'],
  ['b', '5', '-1', '3', '1', 'boom', '995'],
  ['c', '5', '20', '4', '0', '-', '-'],
  ['d', '5', '10', '5', '2', 'boom', '995'],
  ['e', '5', '10', '6', '0', 'boom', '995'],
  ['f', '5', '10', '7', '0', 'boom', '980'],
];
const parsed = parseLiveRows(rows, now);
check('live rows: all seven fields parsed', parsed.length === 7 && parsed[0].topic === 'status' && parsed[0].every === 15 && parsed[0].age === 7 && parsed[0].gen === 1 && parsed[0].rc === 0 && parsed[0].err === null && parsed[0].tsErr === null);
check('live state pending vs never', parsed[1].state === 'pending' && parsed[2].state === 'never');
check('live state stale at boundary', parseLiveRows([['x', '5', '16', '1', '0', '-', '-']], now)[0].state === 'stale' && parseLiveRows([['x', '5', '15', '1', '0', '-', '-']], now)[0].state === 'fresh');
check('live state stale row', parsed[3].state === 'stale');
check('live state nonzero rc is failing', parsed[4].state === 'failing');
check('live state newer ts_err is failing', parsed[5].state === 'failing');
check('live state older ts_err is fresh', parsed[6].state === 'fresh');
check('live rows: malformed rows are dropped', parseLiveRows([['only', 'five', 'fields', 'here', 'x']], now).length === 0);
console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
