// The logic of the question dialog of an interactive recipe run (RunQuestions.svelte), as plain functions so node can test it
// (tests/web-recipe-questions.mjs). ADR 0018 stage 3; the contract is docs/PLAN-recipe-orchestrator.md.
//
// The job record (`GET /api/sys/jobs/record/<id>`) carries `waiting` while the run waits for an answer:
//   { seq, key, label, kind: 'text'|'secret'|'choice', default, pattern, choices, error, attempt, asked }
// The browser translates by KEY (`<recipe>.<KEY>`, then `<KEY>`); the English `label` and `error` of the record are the fallback. Plain text only:
// nothing here is ever put into the page as HTML.

export const ACTIVE = ['queued', 'running', 'waiting'];
export const isActive = (rec) => !!rec && ACTIVE.includes(rec.state);

// the pending question of a record, or null
export function pending(rec) {
  const w = rec?.waiting;
  if (!w || rec.state !== 'waiting' || !Number.isInteger(w.seq) || typeof w.key !== 'string') return null;
  const kind = ['text', 'secret', 'choice'].includes(w.kind) ? w.kind : 'text';
  return {
    seq: w.seq, key: w.key, kind, label: String(w.label ?? w.key), def: kind === 'secret' ? '' : String(w.default ?? ''),
    pattern: w.pattern ?? '', choices: Array.isArray(w.choices) ? w.choices.map(String) : [], error: w.error ?? '', attempt: w.attempt ?? 1,
  };
}

// translated texts by key: { de: { 'unifi.FIXED_IP': '...', FIXED_IP: '...' } }; a missing entry gives the English text of the record
export function questionLabel(table, code, recipe, q) {
  const t = table?.[code] ?? {};
  return t[`${recipe}.${q.key}`] ?? t[q.key] ?? q.label;
}
export const errorLabel = (table, code, q) => (q.error ? (table?.[code]?.[q.error] ?? q.error) : '');

const CONTROL = /[\u0000-\u001f\u007f]/;

// '' when the value may be sent, else a short code for the field. The server and the step have the last word (a refusal comes back as a new question).
export function answerError(q, value) {
  if (q.kind === 'secret') return value === '' ? 'required' : CONTROL.test(value) || value.length > 4000 ? 'control' : '';
  if (CONTROL.test(value) || value.length > 4000) return 'control';
  if (q.kind === 'choice') return q.choices.includes(value) ? '' : 'choice';
  if (value === '') return '';   // an empty text means "take the default" (ADR 0018 rule 7)
  if (q.pattern) { try { if (!new RegExp(`^(?:${q.pattern})$`).test(value)) return 'pattern'; } catch { /* a pattern JS cannot read: the step decides */ } }
  return '';
}

// the request body of an answer: the area, the argument list and the ONE line for stdin (never in the arguments)
export function answerRequest(jobId, q, value) {
  return { area: 'jobs', args: ['answer', jobId, '--seq', String(q.seq), '--key', q.key], stdin: value };
}

// What the dialog says about a record: 'waiting' | 'running' | 'ok' | 'failed' | 'timeout' | 'cancelled' | 'interrupted' | 'unknown'
export function phase(rec) {
  if (!rec) return 'unknown';
  if (rec.state === 'cancelled') return rec.error?.category === 'input_timeout' ? 'timeout' : 'cancelled';
  if (rec.state === 'failed' && rec.error?.category === 'input_rejected') return 'rejected';
  return ['waiting', 'running', 'queued', 'ok', 'failed', 'interrupted'].includes(rec.state) ? (rec.state === 'queued' ? 'running' : rec.state) : 'unknown';
}

// the recipe name of a record (slug recipe-<name>[-<container>] or a sub-job recipe-<name>-run): only for the translation lookup
export const recipeOf = (rec) => String(rec?.slug ?? '').replace(/^recipe-/, '').replace(/-(run|install|configure|start)$/, '');

// the reply of `jobs answer` -> 'done' | 'stale' | 'refused'
export const replyKind = (r) => (r?.status === 'done' ? 'done' : r?.status === 'stale' ? 'stale' : 'refused');
