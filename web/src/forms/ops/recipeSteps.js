// The logic of the recipe wizard (RunRecipe.svelte), as plain functions so node can test it (tests/web-recipe-wizard.mjs). ADR 0018, stage 1.
//
// A STEP is { id, label, help, asks: [ask] } and an ASK is { key, label, kind, def, pattern, when } (the rows of `hs sys recipes asks`).
// Stage 1 builds the steps from the header lines of the recipe (`hs sys recipes steps`: id, label, help, keys). Stage 3 (the orchestrator) will
// feed the same shape: a question that appears while a job runs is one more step { id, label, help, asks: [ask] }, so the page that renders a
// step, checks it (stepMissing / askError) and collects the answers (answerArgs, secretOf) does not care where the step came from.

export const IMPLICIT = 'settings';   // the page for questions that name no step (and for every question of a recipe with no steps at all)

const dash = (v) => (v === '-' || v === undefined ? '' : v);

// rows of `hs sys recipes asks` -> { asks, input }
export function parseAsks(rows) {
  const r = rows ?? [];
  return {
    asks: r.filter((x) => x[0] !== 'input').map((x) => ({ key: x[0], label: x[1], kind: x[2], def: dash(x[3]), pattern: dash(x[4]), when: dash(x[5]) })),
    input: r.find((x) => x[0] === 'input')?.[1] ?? 'none',
  };
}

// asks + rows of `hs sys recipes steps` (id, label, help, keys) -> steps. A step row with no question stays (a page of text). A question that no
// row names goes on the implicit last page; with no rows at all that page holds everything. A key named twice stays on its first page.
export function buildSteps(asks, rows, implicit = { label: 'Settings', help: '' }) {
  const byKey = new Map(asks.map((a) => [a.key, a]));
  const placed = new Set();
  const steps = [];
  for (const x of rows ?? []) {
    if (!x[0] || x[0] === 'input') continue;
    const mine = [];
    for (const k of dash(x[3]).split(',').filter(Boolean)) {
      if (byKey.has(k) && !placed.has(k)) { placed.add(k); mine.push(byKey.get(k)); }
    }
    steps.push({ id: x[0], label: dash(x[1]) || x[0], help: dash(x[2]), asks: mine });
  }
  const rest = asks.filter((a) => !placed.has(a.key));
  if (rest.length) steps.push({ id: IMPLICIT, label: implicit.label, help: implicit.help, asks: rest });
  return steps;
}

// a question counts while its `when` (KEY=value) holds
export const askActive = (a, values) => !a.when || (values[a.when.split('=')[0]] ?? '') === a.when.slice(a.when.indexOf('=') + 1);
export const activeAsks = (step, values) => step.asks.filter((a) => askActive(a, values));
// a step whose every question is switched off is skipped; one that never had a question is a page of text and stays
export const visibleSteps = (steps, values) => steps.filter((s) => s.asks.length === 0 || activeAsks(s, values).length > 0);

export const choicesOf = (a) => a.kind.slice('choice:'.length).split(',');

// '' when the answer is fine, else a short reason for the field. An empty text without a pattern is fine (the countries of a VPN).
export function askError(a, values, secret) {
  if (a.kind === 'secret') return secret ? (/[\u0000-\u001f\u007f]/.test(secret) ? 'control' : '') : 'required';
  const v = values[a.key] ?? '';
  if (v === '') return a.kind === 'text' && !a.pattern ? '' : 'required';
  if (/[\u0000-\u001f\u007f]/.test(v)) return 'control';
  if (a.kind.startsWith('choice:')) return choicesOf(a).includes(v) ? '' : 'choice';
  if (a.pattern) { try { if (!new RegExp(`^(?:${a.pattern})$`).test(v)) return 'pattern'; } catch { /* a pattern JS cannot read: the server decides */ } }
  return '';
}
export const stepMissing = (step, values, secret) => activeAsks(step, values).some((a) => askError(a, values, secret) !== '');
// the name of the second container is checked as the server does
export const nameError = (n) => (n === '' || /^[a-z0-9][a-z0-9-]{0,40}$/.test(n) ? '' : 'name');

// the --set arguments: every active text/choice answer that is not empty (RUNS follows the container name unless the person chose it)
export function answerArgs(steps, values, own, runsTouched) {
  const out = [];
  for (const s of steps) for (const q of activeAsks(s, values)) {
    if (q.kind === 'secret' || (values[q.key] ?? '') === '') continue;
    if (q.key === 'RUNS' && own && !runsTouched) continue;
    out.push('--set', `${q.key}=${values[q.key]}`);
  }
  return out;
}
// the one secret that counts goes on standard input, never in an argument
export const secretAsk = (steps, values) => steps.flatMap((s) => activeAsks(s, values)).find((a) => a.kind === 'secret');
export const secretOf = (steps, values, secret) => (secretAsk(steps, values) && secret ? secret : undefined);

// the review page: [{ stepId, label, value }] (a secret shows as set, never as its value)
export function reviewRows(steps, values, secret, own, recipe) {
  const rows = [];
  for (const s of steps) for (const q of activeAsks(s, values)) {
    rows.push({ stepId: s.id, label: q.label, secret: q.kind === 'secret', value: q.kind === 'secret' ? (secret ? 'set' : '') : (values[q.key] ?? '') });
  }
  rows.push({ stepId: 'name', label: 'Container name', secret: false, value: own || recipe });
  return rows;
}
