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
