// The job record helpers of the Jobs panel (web/src/jobrecords.js), run with node.
import { parseRecord, stateDot, stateKnown, stepText, percent, progressText, duration, isJobEvent, lastJobEvent, latestOnly } from '../web/src/jobrecords.js';
let bad = 0;
const check = (n, ok) => { if (!ok) { bad++; console.log('FAIL: ' + n); } };
const run = parseRecord(['20261109-101010-update-abcd', 'update', 'Update', 'running', '-', '2026-11-09T10:10:10Z', '-', '-', '2', '5', 'Fetching', '30', '120', 'files']);
check('running record: step', stepText(run.step) === '2/5 Fetching');
check('running record: progress', run.progress.done === 30 && run.progress.total === 120 && percent(run.progress) === 25);
check('running record: no end, no exit', run.ended === null && run.exit === null);
const bare = parseRecord(['id', '-', '-', 'ok', '-', '-', '-', '0', '-', '-', '-', '-', '-', '-']);
check('record without step and progress', bare.step === null && bare.progress === null && bare.exit === 0 && bare.description === 'id');
check('state dots', stateDot('ok') === 'ok' && stateDot('failed') === 'bad' && stateDot('interrupted') === 'warn' && stateDot('running') === 'info');
check('unknown state is neutral text, not an error', stateDot('brand-new') === 'off' && !stateKnown('brand-new') && stateDot('waiting') === 'warn' && stateKnown('waiting') && stateKnown('cancelled'));
check('percent: no total', percent({ done: 3, total: null }) === null && percent(null) === null);
check('percent: capped', percent({ done: 9, total: 3 }) === 100);
check('progress text with unit', progressText({ done: 1, total: 4, unit: 'files' }) === '1 / 4 files');
check('progress text bytes', progressText({ done: 5, total: 10, unit: 'bytes' }, (n) => n + 'B') === '5B / 10B');
check('duration of an ended job', duration('2026-11-09T10:00:00Z', '2026-11-09T10:02:00Z') === '2 min');
check('duration of a running job', duration('2026-11-09T10:00:00Z', null, Date.parse('2026-11-09T10:00:30Z')) === '30 s');
check('job events', isJobEvent({ kind: 'job.failed' }) && !isJobEvent({ kind: 'disk.removed' }) && !isJobEvent(null));
check('step of an ok job is empty, of a running and a failed job shown', stepText({ n: 3, of: 3, text: 'Done' }, 'ok') === '' && stepText({ n: 3, of: 3, text: 'x' }, 'running') === '3/3 x' && stepText({ n: 2, of: 3, text: 'x' }, 'failed') === '2/3 x');
// a slow read of the running state that comes back after the read of the final state must not win
{
  let shown = null;
  const delays = [50, 5];
  let i = 0;
  const load = latestOnly(() => { const k = i++; return new Promise((r) => setTimeout(() => r(k === 0 ? 'running' : 'ok'), delays[k])); }, (v) => { shown = v; });
  await Promise.all([load(), load()]);
  check('an older read that returns late is dropped', shown === 'ok');
}
// the newest job event is the one the panel acts on; none before the first job of a page (the panel's baseline is then 0, so the first event reads)
{
  const evs = [{ id: 4, kind: 'audit.ok' }, { id: 5, kind: 'job.queued' }, { id: 6, kind: 'job.running' }, { id: 7, kind: 'backup.ok' }];
  check('lastJobEvent: the newest job.* row', lastJobEvent(evs)?.id === 6);
  check('lastJobEvent: none without a job row, and for an empty or missing log', lastJobEvent([{ id: 1, kind: 'audit.ok' }]) === null && lastJobEvent([]) === null && lastJobEvent(undefined) === null);
  check('lastJobEvent: a first job row on a page without any is found (id 5 differs from the baseline 0)', lastJobEvent([{ id: 5, kind: 'job.queued' }])?.id === 5);
}
if (bad) process.exit(1);
