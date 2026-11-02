import { appOf, childrenOf } from '../web/src/pages/docker/apps.js';

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

console.log(`-- ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);