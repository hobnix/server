// The job records (ADR 0004) as the Jobs panel shows them. Plain JS so tests/web-jobrecords.mjs can load it in node.
// Columns of `hs sys jobs records` (docs/api/sys.toml): id slug description state queued started ended exit step_n step_of step_text
// progress_done progress_total progress_unit. An empty field is "-".

const KNOWN = { queued: 'off', running: 'info', waiting: 'warn', ok: 'ok', failed: 'bad', cancelled: 'off', interrupted: 'warn' };

const val = (s) => (s === undefined || s === null || s === '-' || s === '' ? null : s);
const num = (s) => { const v = val(s); if (v === null) return null; const n = Number(v); return Number.isFinite(n) ? n : null; };

export function parseRecord(r) {
  return {
    id: r[0], slug: val(r[1]), description: val(r[2]) ?? val(r[1]) ?? r[0], state: val(r[3]) ?? '',
    queued: val(r[4]), started: val(r[5]), ended: val(r[6]), exit: num(r[7]),
    step: num(r[9]) === null && !val(r[10]) ? null : { n: num(r[8]), of: num(r[9]), text: val(r[10]) },
    progress: num(r[11]) === null && num(r[12]) === null ? null : { done: num(r[11]), total: num(r[12]), unit: val(r[13]) },
  };
}

// The dot of a state. A state this page does not know is plain text with a neutral dot, never an error.
export const stateDot = (s) => KNOWN[s] ?? 'off';
export const stateKnown = (s) => Object.prototype.hasOwnProperty.call(KNOWN, s);

export function stepText(step, state = '') {
  if (!step || state === 'ok') return '';   // a finished job has no current step; a failed one keeps the step it stopped at
  const head = step.n !== null && step.of !== null ? `${step.n}/${step.of}` : step.n !== null ? String(step.n) : '';
  return [head, step.text].filter(Boolean).join(' ');
}

// Percent done, or null when the total is not known.
export function percent(p) {
  if (!p || p.done === null || !p.total || p.total <= 0) return null;
  return Math.max(0, Math.min(100, Math.round((p.done / p.total) * 100)));
}

export function progressText(p, human = (n) => String(n)) {
  if (!p) return '';
  const u = p.unit === 'bytes' ? human : (n) => String(n);
  const unit = p.unit && p.unit !== 'bytes' ? ` ${p.unit}` : '';
  if (p.done === null) return '';
  return p.total ? `${u(p.done)} / ${u(p.total)}${unit}` : `${u(p.done)}${unit}`;
}

// A record file is ISO 8601 UTC; "-" and garbage give ''.
export function clock(iso, locale) {
  const d = new Date(val(iso) ?? NaN);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleString(locale, { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
}

export function duration(a, b, now = Date.now()) {
  const s0 = Date.parse(val(a) ?? ''); if (Number.isNaN(s0)) return '';
  const e0 = val(b) ? Date.parse(b) : now;
  const s = Math.max(0, Math.round((e0 - s0) / 1000));
  return s < 60 ? `${s} s` : s < 3600 ? `${Math.round(s / 60)} min` : `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min`;
}

// Does a row of the event log (live.events) change the record list? A row has `source` ("job") and `kind` ("queued", "running", "ok", ...);
// the page shows them as "job.queued". (This used to test `kind.startsWith('job.')`, which no real row matches: the panel never heard an event.)
export const isJobEvent = (ev) => !!ev && (ev.source === 'job' || (typeof ev.kind === 'string' && ev.kind.startsWith('job.')));

// The newest job.* row of the event log, or null. The Jobs panel reads again whenever its id differs from the one it last acted on.
export function lastJobEvent(events) {
  for (let i = (events?.length ?? 0) - 1; i >= 0; i--) if (isJobEvent(events[i])) return events[i];
  return null;
}

// Reads that may overlap (a job.running read still running when job.ok arrives): only the answer of the newest started read is applied, an older one
// that comes back late is dropped. Without this a slow read of the running state overwrote the final state until a reload.
export function latestOnly(read, apply) {
  let started = 0, applied = 0;
  return async (...a) => {
    const mine = ++started;
    const v = await read(...a);
    if (mine < applied) return false;
    applied = mine;
    apply(v);
    return true;
  };
}
