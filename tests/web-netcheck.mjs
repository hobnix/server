// The Network step logic of the first-run wizard (web/src/wizard/netcheck.js, issue #179).
import * as n from '../web/src/wizard/netcheck.js';
let bad = 0;
const check = (name, c, x = '') => { if (c) console.log(`  ok    ${name}`); else { bad++; console.log(`  FAIL  ${name} ${x}`); } };
const good = [
  ['link', 'ok', 'eth0', '-'], ['wireless', 'ok', '-', '-'], ['address', 'ok', '192.168.1.5/24 on eth0', 'reserve this address on your router'],
  ['route', 'ok', '192.168.1.1 on eth0', '-'], ['dns', 'ok', 'github.com is 1.2.3.4', '-'], ['clock', 'ok', '2026-11-13 10:00 UTC', '-'],
];
const v = n.viewRows(good);
check('six view rows with labels', v.length === 6 && v[0].label === 'Cable' && v[4].label === 'Names (DNS)');
check('a dash is no value', v[1].value === '' && v[1].fix === '' && v[0].value === 'eth0');
check('ok maps to the ok dot', v.every((r) => r.tone === 'ok'));
check('a passed check', n.passed(good) && n.firstFailure(good) === null);
check('the advice names the address', n.adviceFor(good) === '192.168.1.5/24 on eth0');
const nolink = [['link', 'fail', '-', 'Connect a network cable.'], ['wireless', 'ok', '-', '-'], ['address', 'fail', '-', 'Fix the link first.'], ['route', 'fail', '-', 'Fix the link first.'], ['dns', 'fail', '-', 'Fix the link first.'], ['clock', 'ok', 'x', '-']];
check('a failure maps to bad', n.viewRows(nolink)[0].tone === 'bad');
check('the first failure is the link', n.firstFailure(nolink).item === 'link' && n.firstFailure(nolink).fix === 'Connect a network cable.');
check('failed: not passed, no advice', !n.passed(nolink) && n.adviceFor(nolink) === '');
const warn = good.map((r) => (r[0] === 'wireless' ? ['wireless', 'warn', 'wlan0', 'a server needs a cable'] : r));
check('a warning alone passes', n.passed(warn) && n.viewRows(warn)[1].tone === 'warn');
check('no rows is not passed', !n.passed([]) && !n.passed(undefined) && n.viewRows(null).length === 0);
check('an unknown state is a failure', n.viewRows([['link', 'weird', '-', '-']])[0].tone === 'bad');
const nics = [['eth1', 'down', '-', 'no'], ['eth0', 'up', 'aa:bb', 'no'], ['eth2', 'up', 'cc:dd', 'yes']];
check('cards: current first, then by name', n.cards(nics).map((c) => c.name).join() === 'eth2,eth0,eth1');
check('cards: link and mac', n.cards(nics)[1].up && n.cards(nics)[1].mac === 'aa:bb' && n.cards(nics)[2].mac === '');
check('options carry the link state', n.nicOptions(nics)[2].label === 'eth1 (no cable)' && n.nicOptions(nics)[0].value === 'eth2');
check('default card: the current one', n.defaultNic(nics) === 'eth2');
check('default card: else one with a cable', n.defaultNic([['eth1', 'down', '-', 'no'], ['eth0', 'up', '-', 'no']]) === 'eth0');
check('default card: else the first, else empty', n.defaultNic([['eth1', 'down', '-', 'no']]) === 'eth1' && n.defaultNic([]) === '');
process.exit(bad ? 1 : 0);
