// The row button of the Apps page (web/src/pages/apps.js).
import { appAction } from '../web/src/pages/apps.js';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };

const parked = appAction({ state: 'parked', vstate: 'unknown', applied: '-', avail: '-' });
check('parked: Install, tip parked, not primary', parked.label === 'Install' && parked.tip === 'This recipe is parked' && !parked.primary);
const fresh = appAction({ state: 'not installed', vstate: 'unknown', applied: '-', avail: '1.0.0' });
check('not installed: Install, primary', fresh.label === 'Install' && fresh.primary && fresh.tip === 'Set this app up');
const partly = appAction({ state: 'partly', vstate: 'current', applied: '1.0.0', avail: '1.0.0' });
check('partly: Install', partly.label === 'Install' && partly.primary);
const cur = appAction({ state: 'installed', vstate: 'current', applied: '1.2.0', avail: '1.2.0' });
check('installed and current: Repair', cur.label === 'Repair' && cur.icon === 'wrench' && !cur.primary);
check('current tip says Up to date and the version', cur.tip.includes('Up to date') && cur.tip.includes('1.2.0'));
const upd = appAction({ state: 'installed', vstate: 'update', applied: '1.0.0', avail: '1.2.0' });
check('installed and update: Update', upd.label === 'Update' && upd.icon === 'arrows-clockwise' && !upd.primary);
check('update tip names both versions', upd.tip.includes('1.0.0') && upd.tip.includes('1.2.0'));
const unk = appAction({ state: 'installed', vstate: 'unknown', applied: '-', avail: '1.2.0' });
check('installed and unknown: Update with the old tip', unk.label === 'Update' && unk.tip === 'Run again: repairs or updates the setup');
check('never a disabled field', [parked, fresh, partly, cur, upd, unk].every((x) => !('disabled' in x)));

console.log(`${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
