import { appOf, childrenOf, filesChip, applyOf, isActionable, revOf, diskChanged, UNMANAGED_TIP } from '../web/src/pages/docker/apps.js';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };

const row = ['app1', 'docker', 'app1', 'running', '2/3', '80,443', '10.0.0.5', 'img:1, img:2', 'web', '-'];
const a = appOf(row);
check('appOf maps every field', a && a.name === 'app1' && a.parent === 'docker' && a.project === 'app1' && a.state === 'running' && a.running === '2/3' && a.ports === '80,443' && a.address === '10.0.0.5' && a.images === 'img:1, img:2' && a.managed === 'web' && a.update === '-');
check('appOf keeps running as a string', typeof a.running === 'string');
check('appOf returns null for a short row', appOf(['x']) === null);
check('appOf returns null for non-array', appOf(null) === null);

const before = [['arr', 'docker', 'arr', 'running', '8989'], ['notes', 'docker', 'notes', 'exited', '-'], ['foreign', 'other', 'foreign', 'running', '80']];
const snap = before.map((r) => r.slice());
const m = childrenOf(before);
check('childrenOf groups by parent', m.get('docker') && m.get('docker').length === 2);
check('childrenOf keeps input order', m.get('docker')[0][0] === 'arr' && m.get('docker')[1][0] === 'notes');
check('childrenOf groups foreign parents too (filtering is the page job)', m.has('other'));
check('childrenOf does not mutate input', JSON.stringify(before) === JSON.stringify(snap));
check('childrenOf skips malformed rows', childrenOf([['short']]).size === 0);
check('childrenOf returns a Map', m instanceof Map);
check('childrenOf handles non-array', childrenOf(null).size === 0);

// field 11 (files) and unmanaged rows
const r11 = (files, managed = 'web') => appOf(['x', 'docker', 'x', 'running', '1/1', '-', '-', '-', managed, '-', files]);
check('appOf: 10 fields -> files is -', a.files === '-');
check('appOf: field 11 is files', r11('changed').files === 'changed' && r11('new').files === 'new');
check('appOf: empty field 11 -> -', r11('').files === '-');
check('chip: changed', filesChip(r11('changed')).text === 'Changed, not applied');
check('chip: new', filesChip(r11('new')).text === 'New, not started');
check('chip: invalid', filesChip(r11('invalid')).tone === 'bad');
check('chip: same and - have none', filesChip(r11('same')) === null && filesChip(r11('-')) === null && filesChip(null) === null);
const un = r11('-', 'unmanaged');
check('chip: unmanaged with tooltip', filesChip(un).text === 'Unmanaged' && filesChip(un).tip === UNMANAGED_TIP);
check('unmanaged is not actionable, others are', !isActionable(un) && isActionable(r11('same')) && !isActionable(null));
check('apply: changed/new on a web app is allowed', applyOf(r11('changed')).ok && applyOf(r11('new')).ok);
check('apply: invalid is shown but refused with a reason', applyOf(r11('invalid')).show && !applyOf(r11('invalid')).ok && applyOf(r11('invalid')).reason.length > 0);
check('apply: not shown for same, - and unmanaged', !applyOf(r11('same')).show && !applyOf(r11('-')).show && !applyOf(un).show);
check('apply: allowed for recipe apps, refused for others', applyOf(r11('changed', 'recipe')).ok && applyOf(r11('changed', 'other')).show && !applyOf(r11('changed', 'other')).ok);
check('revOf reads the text answer', revOf({ text: 'abc\n' }) === 'abc' && revOf(null) === '' && revOf({}) === '');
check('diskChanged: differs', diskChanged('aaa', 'bbb'));
check('diskChanged: same, unknown, new', !diskChanged('aaa', 'aaa') && !diskChanged('aaa', '') && !diskChanged('new', 'bbb') && !diskChanged('', 'bbb'));

console.log(`-- ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);