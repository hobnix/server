// State that several parts of the shell share: the open plan dialog, the bottom panel, and the tasks started from this browser.
import { get } from './api.js';

export const ui = $state({
  dialog: null,                       // { area, args, title } while a plan dialog is open
  create: null,                       // { component, props } while a create dialog (a form with a live plan) is open
  features: { terminal: false, vps: false, capabilities: null },      // what the server switched on, from the session answer; capabilities = names of the parts that are on (null = not told: show everything)
  host: 'homeserver',                 // this node's name (the dialogs name the node they act on)
  panel: { open: true, tab: 'tasks', height: 214 },   // height in px while open; the grip drags it
});

export function openPlan(area, args, title) {
  ui.dialog = { area, args, title };
}

// a form component (it renders a CreateDialog) is shown on top of the page; props go to it
export function openCreate(component, props = {}) {
  ui.create = { component, props };
}

export function showTab(tab) {
  ui.panel.tab = tab;
  ui.panel.open = true;
}

// Tasks: jobs started here, newest first. A job runs on the server whether or not this page is open; the page only follows its journal.
export const tasks = $state({ list: [], selected: '' });

export function track(unit, title) {
  let t = tasks.list.find((x) => x.unit === unit);
  if (t && t.state === 'running') return t;
  t = { unit, title, started: new Date(), ended: null, state: 'running', exit: null, lines: [], next: 0, gone: 0 };
  tasks.list = [t, ...tasks.list.filter((x) => x.unit !== unit)];
  tasks.selected = unit;
  follow(unit);
  return tasks.list[0];
}

// a change that finished at once (no background job): it still leaves a line in Tasks, so there is a trace of what was done
let doneSeq = 0;
export function trackDone(title, steps = []) {
  const unit = `done-${++doneSeq}`;
  const now = new Date();
  const t = { unit, title, started: now, ended: now, state: 'ok', exit: '0', lines: steps.map((s) => (typeof s === 'string' ? s : s.text ?? s[1] ?? '')).filter(Boolean), next: 0, gone: 0 };
  tasks.list = [t, ...tasks.list];
  tasks.selected = unit;
}

// Apply the rows of one `sys jobs tail` answer to a task (the stream pushes the same rows the read returns).
function apply(t, rows) {
  for (const row of rows) {
    if (row[0] === 'state') t.state = row[1];
    else if (row[0] === 'exit') t.exit = row[1];
    else if (row[0] === 'line') t.lines.push(row.slice(1).join('\t'));
    else if (row[0] === 'next') t.next = Number(row[1]) || t.next;
  }
}

// Follow a job: a server-sent-events stream (GET /api/sys/jobs/stream/<unit>) while it works, polling the same journal every 2 s when
// the stream cannot be opened or breaks off before the unit ended.
async function follow(unit) {
  if (typeof EventSource !== 'undefined' && (await stream(unit))) return;
  await poll(unit);
}

// resolves true when the job ended (or the session did), false when the caller should fall back to polling
function stream(unit) {
  return new Promise((resolve) => {
    const t0 = tasks.list.find((x) => x.unit === unit);
    if (!t0) return resolve(true);
    let es;
    try { es = new EventSource(`/api/sys/jobs/stream/${encodeURIComponent(unit)}?from=${t0.next}`); } catch { return resolve(false); }
    let gone = 0;
    const done = (v) => { es.close(); resolve(v); };
    es.onmessage = (ev) => {
      const t = tasks.list.find((x) => x.unit === unit);
      if (!t) return done(true);
      let rows = [];
      try { rows = JSON.parse(ev.data).rows ?? []; } catch { return; }
      apply(t, rows);
      // a unit that was just started may not exist for a moment: not "gone" yet
      if (t.state === 'unknown' && ++gone < 4) t.state = 'running';
      if (t.state !== 'running') { t.ended = new Date(); done(true); }
    };
    // the stream ends on its own (event: end) when the unit ended; if the task still runs then (session ended, stream time limit), poll
    es.addEventListener('end', () => {
      const t = tasks.list.find((x) => x.unit === unit);
      done(!t || t.state !== 'running');
    });
    // EventSource would reconnect by itself, but from the old offset: stop and continue by polling from the right one
    es.onerror = () => done(false);
  });
}

async function poll(unit) {
  for (;;) {
    const t = tasks.list.find((x) => x.unit === unit);
    if (!t) return;
    try {
      const r = await get(`/api/sys/jobs/tail/${encodeURIComponent(unit)}?from=${t.next}`);
      apply(t, r.rows);
      // a unit that was just started may not exist for a moment: give it a few tries before calling it gone
      if (t.state === 'unknown' && ++t.gone < 4) t.state = 'running';
      if (t.state !== 'running') { t.ended = new Date(); return; }
    } catch (e) {
      if (e.status === 401) return;
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
}
