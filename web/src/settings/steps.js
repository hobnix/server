// The guided steps of a capability page ([[settings.steps]] in its manifest, copied into layout.gen.json). Pure functions, no Svelte, so plain
// node can test them. A draft is { key: value } for every key of the steps; the guided view and the Advanced view edit the SAME draft.
// opts = the rows of `hs sys config list` as the page has them ({ key, cur, ... }).

// every key the steps name, once, in step order
export const stepKeys = (steps) => [...new Set((steps || []).flatMap((s) => s.keys || []))];

// the draft starts at the current values
export function draftFrom(opts, steps) {
  const cur = new Map((opts || []).map((o) => [o.key, o.cur ?? '']));
  return Object.fromEntries(stepKeys(steps).map((k) => [k, cur.get(k) ?? '']));
}

// a preset sets some keys; the others stay as they are (returns a new draft)
export const applyPreset = (draft, preset) => ({ ...draft, ...(preset?.set || {}) });

// the preset whose values all equal the draft, or undefined
export const presetOf = (draft, presets) => (presets || []).find((p) => Object.entries(p.set).every(([k, v]) => draft[k] === v));

// the keys whose value differs from the current one: [{ key, from, to }]
export function diff(draft, opts) {
  // a key that is not set applies its schema default: a value equal to it changes nothing (and "from" shows the default, not "(empty)")
  const raw = new Map((opts || []).map((o) => [o.key, o.cur ?? '']));
  const base = new Map((opts || []).map((o) => [o.key, o.cur || o.dflt || '']));
  return Object.entries(draft)
    .filter(([k, v]) => { const t = String(v).trim(); return t !== (base.get(k) ?? '') && !(t === '' && (raw.get(k) ?? '') === ''); })
    .map(([k, v]) => ({ key: k, from: base.get(k) ?? '', to: String(v).trim() }));
}

// "gateway setup" -> { area: 'gateway', verb: 'setup' }
export const applyParts = (apply) => {
  const [area, ...rest] = String(apply || '').split(/\s+/).filter(Boolean);
  return { area, verb: rest.join(' ') };
};

// the arguments of the plan: ['setup', '--set', 'k=v', ...]; [] when nothing changed
export function changed(draft, opts, verb = 'setup') {
  const d = diff(draft, opts);
  return d.length ? [verb, ...d.flatMap((c) => ['--set', `${c.key}=${c.to}`])] : [];
}

// the arguments of a first setup: every key of the steps is sent, also when it equals the current value (nothing exists yet that could differ)
export function changedAll(draft, steps, verb = 'setup') {
  const set = stepKeys(steps).filter((k) => String(draft[k] ?? '').trim() !== '');
  return set.length ? [verb, ...set.flatMap((k) => ['--set', `${k}=${String(draft[k]).trim()}`])] : [];
}

// the value of a key in the rows of a key<TAB>value read ('' when missing or '-')
export function kvGet(rows, key) {
  const r = (rows || []).find((x) => x[0] === key);
  return r && r[1] !== '-' ? String(r[1]) : '';
}

// Is the setup of a capability done? The docker setup is done when its container exists and hobnix owns it (`owned` of `hs sys docker status`),
// not when the capability is listed as on; every other capability keeps `on`. `status` = rows of the docker status read, or null while unread.
export function setupDone(apply, on, status) {
  if (apply === 'docker setup') return kvGet(status, 'owned') === 'yes';
  return !!on;
}

// ---- the wizard (one question per screen): steps with `options` instead of `presets` ----

// the rows with the schema default filled in where the layout knows it (core pages: `defaults` of layout.gen.json); returns new rows
export const withDefaults = (opts, defaults) => (opts || []).map((o) => (defaults && o.key in defaults ? { ...o, dflt: defaults[o.key] } : o));

// the option whose values all equal the draft, or undefined. With `defaults`, an empty draft value (key not set) equals the default's value
export const optionOf = (draft, step, defaults = null) => (step?.options || []).find((o) => Object.entries(o.set || {}).every(([k, v]) => {
  const d = draft[k];
  return d === v || (defaults && (d === '' || d === undefined) && v === (defaults[k] ?? ''));
}));

// the steps to show: a step with `when` shows only when every key's current value (or its default when unset) equals the wanted one
export function visibleSteps(steps, opts, defaults = null) {
  const row = new Map((opts || []).map((o) => [o.key, o]));
  const val = (k) => { const o = row.get(k); return o?.cur || o?.dflt || defaults?.[k] || ''; };
  return (steps || []).filter((s) => Object.entries(s.when || {}).every(([k, v]) => val(k) === v));
}
// the keys of a step that no option sets: shown as fields under the choices
export const freeKeys = (step) => { const set = new Set((step?.options || []).flatMap((o) => Object.keys(o.set || {}))); return (step?.keys || []).filter((k) => !set.has(k)); };

// every step with options that has no matching option yet gets its recommended one (returns a new draft)
export function withRecommended(draft, steps, defaults = null) {
  let out = { ...draft };
  for (const s of steps || []) {
    if (!s.options?.length || optionOf(out, s, defaults)) continue;
    const rec = s.options.find((o) => o.recommended);
    if (rec) out = applyPreset(out, rec);
  }
  return out;
}

// the screens: every step id, then 'review'; `only` = one step id shows just that step and the review
export function screens(steps, only = '') {
  const ids = (steps || []).map((s) => s.id);
  return ids.includes(only) ? [only, 'review'] : [...ids, 'review'];
}

// "Step 2 of 3" and the width of the bar in percent
export const progress = (i, n) => ({ text: `Step ${i + 1} of ${n}`, pct: Math.round(((i + 1) / n) * 100) });

// a page is guided (wizard) when a step has options
export const isGuided = (steps) => (steps || []).some((s) => s.options?.length);
