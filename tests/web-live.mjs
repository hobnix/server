// The poll timing of the live stream (web/src/polldelay.js): no timer while a topic read follows the stream, the plain interval otherwise.
import { nextDelay } from '../web/src/polldelay.js';

let ok = 0, bad = 0;
const check = (name, cond) => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}`); } };

check('topic and live open: no timer', nextDelay('status', true, 15000) === null);
check('topic, live closed: the interval', nextDelay('status', false, 15000) === 15000);
check('no topic, live open: the interval', nextDelay(undefined, true, 15000) === 15000);
check('503 with retry_after: that many seconds', nextDelay('status', true, 15000, { status: 503, retryAfter: 2 }) === 2000);
check('503 without retry_after: the interval', nextDelay('status', false, 15000, { status: 503 }) === 15000);
check('other error, live open: the interval', nextDelay('status', true, 15000, { status: 500 }) === 15000);
console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
