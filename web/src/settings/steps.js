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

// ---- the wizard (one question per screen): steps with `options` instead of `presets` ----

// the option whose values all equal the draft, or undefined
export const optionOf = (draft, step) => presetOf(draft, step?.options);
// the keys of a step that no option sets: shown as fields under the choices
export const freeKeys = (step) => { const set = new Set((step?.options || []).flatMap((o) => Object.keys(o.set || {}))); return (step?.keys || []).filter((k) => !set.has(k)); };

// every step with options that has no matching option yet gets its recommended one (returns a new draft)
export function withRecommended(draft, steps) {
  let out = { ...draft };
  for (const s of steps || []) {
    if (!s.options?.length || optionOf(out, s)) continue;
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
