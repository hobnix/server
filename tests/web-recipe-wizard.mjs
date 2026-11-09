// The recipe wizard logic (web/src/forms/ops/recipeSteps.js, ADR 0018 stage 1).
import * as w from '../web/src/forms/ops/recipeSteps.js';
let bad = 0;
const check = (n, c, x = '') => { if (c) console.log(`  ok    ${n}`); else { bad++; console.log(`  FAIL  ${n} ${x}`); } };
const asksRows = [
  ['PROVIDER', 'Provider', 'text', 'proton', '-', '-'], ['KIND', 'Kind', 'choice:wg,ovpn', 'wg', '-', '-'],
  ['KEY', 'Private key', 'secret', '-', '-', 'KIND=wg'], ['ADDR', 'Address', 'text', '-', '[0-9./]+', '-'], ['RUNS', 'Runtime', 'choice:lxc,vm', 'lxc', '-', '-'],
  ['input', 'form'],
];
const { asks, input } = w.parseAsks(asksRows);
check('parse: input row and dashes', input === 'form' && asks.length === 5 && asks[0].pattern === '' && asks[2].when === 'KIND=wg');
const flat = w.buildSteps(asks, []);
check('no step rows: one page with everything', flat.length === 1 && flat[0].id === 'settings' && flat[0].asks.length === 5);
check('no questions, no rows: no pages', w.buildSteps([], []).length === 0);
const steps = w.buildSteps(asks, [['account', 'Account', 'Who you are', 'PROVIDER,KIND,KEY'], ['intro', 'Welcome', '-', '-'], ['bogus', '-', '-', 'NOPE,PROVIDER']]);
check('declared pages keep header order', steps.map((s) => s.id).join() === 'account,intro,bogus,settings', steps.map((s) => s.id).join());
check('a key stays on its first page, unknown keys are ignored', steps[2].asks.length === 0 && steps[0].asks.length === 3);
check('unplaced questions go to the last page', steps[3].asks.map((a) => a.key).join() === 'ADDR,RUNS');
check('help and a dash label', steps[0].help === 'Who you are' && steps[2].label === 'bogus' && steps[1].help === '');
const v = { PROVIDER: 'proton', KIND: 'ovpn', ADDR: '', RUNS: 'lxc' };
check('when: the secret is off for ovpn', w.activeAsks(steps[0], v).map((a) => a.key).join() === 'PROVIDER,KIND');
check('a text-only page stays visible', w.visibleSteps(steps, v).some((s) => s.id === 'intro'));
const only = w.buildSteps(asks.filter((a) => a.key === 'KEY'), []);
check('a page with only switched-off questions is skipped', w.visibleSteps(only, v).length === 0);
check('errors: required / pattern / choice / secret', w.askError(asks[3], v, '') === 'required' && w.askError(asks[3], { ADDR: 'x' }, '') === 'pattern' && w.askError(asks[1], { KIND: 'zz' }, '') === 'choice' && w.askError(asks[2], {}, '') === 'required' && w.askError(asks[2], {}, 'pw') === '');
check('an empty text without a pattern is fine', w.askError(asks[0], { PROVIDER: '' }, '') === '');
check('control characters are refused', w.askError(asks[0], { PROVIDER: 'a\nb' }, '') === 'control');
check('name check', w.nameError('') === '' && w.nameError('jelly2') === '' && w.nameError('Bad') === 'name');
const ok = { PROVIDER: 'proton', KIND: 'wg', ADDR: '10.0.0.2/32', RUNS: 'lxc' };
check('args: --set only for non-secret answers', w.answerArgs(steps, ok, '', false).join(' ') === '--set PROVIDER=proton --set KIND=wg --set ADDR=10.0.0.2/32 --set RUNS=lxc');
check('args: RUNS dropped for a named container until chosen', !w.answerArgs(steps, ok, 'two', false).includes('RUNS=lxc') && w.answerArgs(steps, ok, 'two', true).includes('--set') );
const a = w.answerArgs(steps, ok, '', false).join(' ');
check('the secret is never in the arguments', !a.includes('KEY') && !a.includes('hunter2'));
check('secret goes to stdin only while its question counts', w.secretOf(steps, ok, 'hunter2') === 'hunter2' && w.secretOf(steps, { ...ok, KIND: 'ovpn' }, 'hunter2') === undefined);
const rows = w.reviewRows(steps, ok, 'hunter2', '', 'vpn');
check('review hides the secret', !JSON.stringify(rows).includes('hunter2') && rows.find((r) => r.secret).value === 'set');
check('review ends with the container name', rows.at(-1).value === 'vpn');
const extra = [...steps, { id: 'q1', label: 'Free address?', help: '', asks: [{ key: 'ADDR2', label: 'x', kind: 'text', def: '', pattern: '', when: '' }] }];
check('stage 3 seam: a question appended as a step is handled like any other', w.stepMissing(extra[4], { ADDR2: '' }, '') === false && w.answerArgs(extra, { ...ok, ADDR2: 'z' }, '', false).includes('ADDR2=z'));
process.exit(bad ? 1 : 0);
