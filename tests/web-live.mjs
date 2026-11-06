// The poll timing of the live stream (web/src/polldelay.js): no timer while a topic read follows the stream, the plain interval otherwise.
import { nextDelay } from '../web/src/polldelay.js';
import { parseLiveRows, parseInspect } from '../web/src/livestatus.js';
import { poolTopic } from '../web/src/pages/storage/pool.js';

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

// poll(): the explicit topic wins, else live.topics[path] (source check: poll needs Svelte runes, so the line is checked as text)
import { readFileSync } from 'node:fs';
const src = readFileSync(new URL('../web/src/data.svelte.js', import.meta.url), 'utf8');
check('poll: explicit topic first, then live.topics[path]', /\(typeof topic === 'function' \? topic\(\) : topic\) \?\? live\.topics\[p\]/.test(src));

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
const ins = (o) => ({ topic: 't', words: ['a'], interval: 5, lock: 'run', origin: 'core', cap: null, cap_on: true, groups: [], age: 1, gen: 1, rc: 0, err: null, ts_err: null, bytes: 1, ...o });
const pi = (o, now = 1000) => parseInspect({ now, topics: [ins(o)] });
check('inspect: fresh', pi({}).rows[0].state === 'fresh');
check('inspect: never and pending', pi({ age: null, err: 'x' }).rows[0].state === 'never' && pi({ age: null }).rows[0].state === 'pending');
check('inspect: stale', pi({ age: 16 }).rows[0].state === 'stale');
check('inspect: failing by exit code and by newer error', pi({ rc: 2 }).rows[0].state === 'failing' && pi({ age: 10, err: 'x', ts_err: 995 }).rows[0].state === 'failing');
check('inspect: capability off wins', pi({ cap_on: false, age: null }).rows[0].state === 'off');
check('inspect: doc status wins', pi({ status: 'error', cap_on: true }).rows[0].state === 'error');
check('inspect: has.needs only with the key', !pi({}).has.needs && pi({ needs: ['a', 'b'] }).has.needs && pi({ needs: ['a', 'b'] }).rows[0].needs.join(', ') === 'a, b');
check('inspect: has.status and has.ttl', pi({ status: 'ok', ttl: 45 }).has.status && pi({ ttl: 45 }).has.ttl && !pi({}).has.ttl && !pi({ ttl: null }).has.ttl);
check('inspect: garbage gives no rows', parseInspect(null).rows.length === 0 && parseInspect({ topics: 5 }).rows.length === 0 && parseInspect({ topics: [null, {}, { topic: 3 }] }).rows.length === 0);
check('inspect: unknown keys are kept', pi({ extra: 1 }).rows[0].extra === 1);
check('poolTopic kinds', poolTopic('info', 'bulk') === 'pool-info-bulk' && poolTopic('members', 'fast') === 'pool-members-fast' && poolTopic('state', 'bulk') === 'pool-state-bulk');
check('poolTopic rejects bad args', poolTopic('info', 'other') === undefined && poolTopic('disks', 'bulk') === undefined && poolTopic('info', 'fast') === 'pool-info-fast');
check('storage topic, live open: no timer', nextDelay('shares-overview', true, 30000) === null);
check('storage topic, live closed: the interval', nextDelay('shares-overview', false, 30000) === 30000);
check('fixed-pool topic, live open: no timer', nextDelay(poolTopic('info', 'bulk'), true, 15000) === null);
check('fixed-pool topic, live closed: the interval', nextDelay(poolTopic('state', 'fast'), false, 10000) === 10000);
check('direct pool read (no topic), live open: the interval', nextDelay(poolTopic('info', 'archive'), true, 15000) === 15000);
console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
