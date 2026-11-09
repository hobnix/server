// The Events page logic (web/src/pages/events.js), run with node.
import { parseRow, eventText, merge, filterRows, sinceFrom } from '../web/src/pages/events.js';
import { readFileSync } from 'node:fs';
let bad = 0;
const eq = (n, g, w) => { if (JSON.stringify(g) === JSON.stringify(w)) console.log(`  ok    ${n}`); else { bad++; console.log(`  FAIL  ${n}: got ${JSON.stringify(g)}, want ${JSON.stringify(w)}`); } };

const failed = parseRow(['7', '1700000000', 'job', 'failed', 'hs-x', 'error', 'job failed (exit 3)', '{"exit":3}']);
eq('a tsv row is parsed', [failed.id, failed.level, failed.payload.exit], [7, 'error', 3]);
eq('- is empty', parseRow(['1', '5', 'a', 'b', '-', 'info', '-', '-']).subject, '');
eq('a bad level is info', parseRow(['1', '5', 'a', 'b', '-', 'loud', '-', '-']).level, 'info');
eq('job.failed en', eventText(failed, 'en'), 'Job hs-x failed (exit 3)');
eq('job.failed de', eventText(failed, 'de'), 'Auftrag hs-x ist fehlgeschlagen (Exit 3)');
const aud = parseRow({ id: 8, time: 1, source: 'audit', kind: 'ok', subject: 'pool add', level: 'info', text: '', payload: { actor: 'admin', exit: 0 } });
eq('audit de', eventText(aud, 'de'), 'admin hat „pool add“ ausgeführt');
eq('notify.failed keeps the reason', eventText(parseRow(['9', '1', 'notify', 'failed', 'phone', 'warn', 'Alarm: no answer', '-']), 'en'), 'Message to phone could not be sent: Alarm: no answer');
eq('disk de', eventText(parseRow(['9', '1', 'disk', 'plugged', 'sdb', 'info', '-', '-']), 'de'), 'Festplatte sdb wurde angesteckt');
eq('an unknown kind shows its text', eventText(parseRow(['1', '1', 'pkg.x', 'done', 's', 'info', 'all good', '-'])), 'all good');
eq('an unknown kind without text shows the raw name', eventText(parseRow(['1', '1', 'pkg.x', 'done', 's', 'info', '-', '-'])), 'pkg.x.done');
eq('text stays plain (no HTML turned into anything)', eventText(parseRow(['1', '1', 'x', 'y', 's', 'info', '<b>hi</b>', '-'])), '<b>hi</b>');

const a = parseRow(['1', '100', 'job', 'ok', 'j', 'info', '-', '-']), b = parseRow(['2', '200', 'disk', 'removed', 'sdb', 'warn', '-', '-']), c = parseRow(['3', '300', 'job', 'failed', 'j', 'error', '-', '-']);
eq('merge is newest first without duplicates', merge([a, b], [c, b]).map((e) => e.id), [3, 2, 1]);
eq('merge keeps at most max', merge([a, b, c], [], 2).map((e) => e.id), [3, 2]);
eq('level filter', filterRows([a, b, c], { level: 'warn' }).map((e) => e.id), [2]);
eq('kind filter', filterRows([a, b, c], { kind: 'JOB.' }).map((e) => e.id), [1, 3]);
eq('time filter', filterRows([a, b, c], { since: 250 }).map((e) => e.id), [3]);
eq('sinceFrom', [sinceFrom('1h', 10_000_000), sinceFrom('')], [10000 - 3600, 0]);

const routes = readFileSync(new URL('../web/src/routes.js', import.meta.url), 'utf8');
eq('route', routes.includes("'/operations/events': Events"), true);
eq('nav entry', readFileSync(new URL('../web/src/nav.js', import.meta.url), 'utf8').includes("path: '/operations/events'"), true);
eq('page has no raw HTML', /\{@html/.test(readFileSync(new URL('../web/src/pages/Events.svelte', import.meta.url), 'utf8')), false);
process.exit(bad ? 1 : 0);
