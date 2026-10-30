// The settings keys as the pages show them: ONE poll of `hs sys config list` shared by every Settings subpage, and the values a person typed.
// What the person typed, per key. The server keeps a read for up to 30 s, so after a change the list still shows the old value for a
// moment: the typed value stays on screen (marked "applying") until the list agrees or 40 s have passed.
import { poll, rows } from '../data.svelte.js';
import { ui, openPlan } from '../ui.svelte.js';

export const drafts = $state({});

// section, key, current, default, type, help, settable
export const optsOf = (l) => rows(l).map((r) => ({ section: r[0], key: r[1], cur: r[2], dflt: r[3], type: r[4], help: r[5], settable: r[6] === 'yes' }));

export const shown = (o) => (o.key in drafts ? drafts[o.key].value : o.cur);

// Call once from a component's script (it starts effects): polls the list and ages the drafts out. Returns { list, opts() }.
export function useConfig() {
  const list = poll('/api/sys/config/list', 8000);
  const opts = () => optsOf(list);
  $effect(() => {
    for (const o of opts()) {
      const d = drafts[o.key];
      if (d && d.sent && (o.cur === d.value || Date.now() - d.sent > 40000)) delete drafts[o.key];
    }
  });
  $effect(() => {
    // when the plan dialog goes away, the drafts that were sent to it are waiting for the list; the others were not asked for
    if (!ui.dialog) for (const k of Object.keys(drafts)) { if (drafts[k].asked && !drafts[k].sent) drafts[k].sent = Date.now(); }
  });
  $effect(() => {
    // a cancelled dialog changed nothing: after the grace time the field is back to the file's value
    const t = setInterval(() => {
      for (const k of Object.keys(drafts)) if (drafts[k].sent && Date.now() - drafts[k].sent > 40000) delete drafts[k];
    }, 5000);
    return () => clearInterval(t);
  });
  return { list, opts };
}

export function commit(o, value) {
  value = value.trim();
  if (value === o.cur) { delete drafts[o.key]; return; }
  drafts[o.key] = { value, asked: true, sent: 0 };
  openPlan('config', ['set', o.key, value], `Set ${o.key}`);
}
export const onKey = (e, o) => { if (e.key === 'Enter') commit(o, e.currentTarget.value); };
