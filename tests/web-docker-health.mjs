// The Docker health rows turned into tree notes and a banner (web/src/pages/docker/health.js, nav.js).
import { problems, treeMeta, dockerChildren } from '../web/src/pages/docker/health.js';
import { tree } from '../web/src/nav.js';

let ok = 0, bad = 0;
const check = (name, cond) => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}`); } };

const fine = [['container', 'ok', '-', '-', 'runs'], ['share', 'ok', '-', '-', 'there'], ['mount', 'ok', '-', '-', 'mounted']];
const broken = [['container', 'ok', '-', '-', 'runs'], ['share', 'ok', '-', '-', 'there'], ['mount', 'fail', '-', '-', 'not mounted. Fix: hs docker enable']];
const off = [['container', 'off', '-', '-', 'off'], ['share', 'off', '-', '-', 'x'], ['mount', 'off', '-', '-', 'x']];

check('nothing is wrong when every check is ok', problems(fine).length === 0);
check('a failing check is a problem', problems(broken).length === 1 && problems(broken)[0].id === 'mount');
check('an off check is no problem', problems(off).length === 0);
check('a short or empty answer is no problem and does not throw', problems([['a']]).length === 0 && problems(undefined).length === 0);
check('the children of Docker are found in the tree', dockerChildren(tree).includes('/instances/docker/registries'));
check('Docker itself is not one of its children', !dockerChildren(tree).includes('/instances/docker'));
check('no notes while everything is fine', Object.keys(treeMeta(fine, ['/x'])).length === 0);
const m = treeMeta(broken, dockerChildren(tree));
check('Docker gets a red dot with the reason', m['/instances/docker']?.dot === 'bad' && /hs docker enable/.test(m['/instances/docker'].title));
check('Registries is dimmed', m['/instances/docker/registries']?.dim === true);
check('a warn gives an amber dot', treeMeta([['share', 'warn', '-', '-', 'w']], [])['/instances/docker'].dot === 'warn');

console.log(`${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
