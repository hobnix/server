// The "when does it take effect" sentence in the web interface (web/src/shell/effect.js and the two dialogs that show a plan).
import { readFileSync } from 'node:fs';
import { effectOf, offersRebuild } from '../web/src/shell/effect.js';

let bad = 0;
const check = (name, cond) => { if (cond) console.log(`  ok    ${name}`); else { bad++; console.log(`  FAIL  ${name}`); } };

const rb = [['step', 'x'], ['note', 'This takes effect with hs rebuild. The last rebuild took about 3 min.']];
check('a rebuild sentence is found with its index', effectOf(rb)?.kind === 'rebuild' && effectOf(rb).index === 1);
check('the at-once sentence is found', effectOf([['note', 'This takes effect at once; no rebuild is needed.']])?.kind === 'now');
check('a plan without one has none', effectOf([['step', 'a'], ['note', 'b']]) === null);
check('only notes count (a step is not the sentence)', effectOf([['step', 'takes effect at once']]) === null);
check('empty / missing steps', effectOf([]) === null && effectOf(undefined) === null);
check('Rebuild now is offered for a rebuild plan only', offersRebuild(rb) && !offersRebuild([['note', 'This takes effect at once; no rebuild is needed.']]));

const read = (p) => readFileSync(new URL(`../web/src/${p}`, import.meta.url), 'utf8');
check('PlanSteps shows the sentence (both dialogs render plans through it)', read('shell/PlanSteps.svelte').includes('effectOf'));
check('PlanDialog renders PlanSteps', read('shell/PlanDialog.svelte').includes('<PlanSteps'));
check('CreateDialog renders PlanSteps', read('shell/CreateDialog.svelte').includes('<PlanSteps'));
check('both dialogs offer Rebuild now after a rebuild-class change', read('shell/PlanDialog.svelte').includes("openPlan('system', ['rebuild']") && read('shell/CreateDialog.svelte').includes('openSaved'));

// no page starts a change on its own: only the dialogs (and the file manager, which changes no configuration) call start()
import { readdirSync, statSync } from 'node:fs';
const walk = (d) => readdirSync(d).flatMap((n) => { const p = `${d}/${n}`; return statSync(p).isDirectory() ? (n === 'node_modules' ? [] : walk(p)) : [p]; });
const root = new URL('../web/src', import.meta.url).pathname;
const starters = walk(root).filter((p) => /\.(svelte|js)$/.test(p) && /\bstart as doStart\b|\bdoStart\(/.test(readFileSync(p, 'utf8'))).map((p) => p.slice(root.length + 1)).sort();
console.log('  starters: ' + starters.join(', '));
const allowed = ['files/api.js', 'shell/CreateDialog.svelte', 'shell/PlanDialog.svelte', 'files/FmPlan.svelte'];
check('only the plan dialogs start a change (found: ' + starters.join(', ') + ')', starters.every((s) => allowed.includes(s)));
process.exit(bad ? 1 : 0);
