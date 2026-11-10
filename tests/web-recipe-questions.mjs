// The question dialog logic of an interactive recipe run (web/src/forms/ops/recipeQuestions.js, ADR 0018 stage 3; contract: docs/PLAN-recipe-orchestrator.md).
import * as q from '../web/src/forms/ops/recipeQuestions.js';
import { questionTexts } from '../web/src/forms/ops/recipeQuestionTexts.js';
let bad = 0;
const check = (n, c, x = '') => { if (c) console.log(`  ok    ${n}`); else { bad++; console.log(`  FAIL  ${n} ${x}`); } };
const rec = (over = {}) => ({ id: '20261109-120000-recipe-unifi-abcd', slug: 'recipe-unifi', state: 'waiting', step: { n: 1, of: 1, text: 'run' },
  waiting: { seq: 3, key: 'FIXED_IP', label: "Fixed address for 'unifi'", kind: 'text', default: '10.10.95.25', pattern: '([0-9]{1,3}\\.){3}[0-9]{1,3}', choices: null, error: null, attempt: 1, asked: 'x' }, ...over });

const p = q.pending(rec());
check('pending: the question of a waiting record', p && p.seq === 3 && p.key === 'FIXED_IP' && p.kind === 'text' && p.def === '10.10.95.25' && p.attempt === 1);
check('pending: not waiting, no question', q.pending(rec({ state: 'running' })) === null && q.pending(rec({ waiting: null })) === null && q.pending(null) === null);
check('pending: a record without a number is no question', q.pending(rec({ waiting: { key: 'X', kind: 'text' } })) === null);
const sec = q.pending(rec({ waiting: { seq: 1, key: 'PASSWORD', label: 'Admin password', kind: 'secret', default: 'leak', choices: null } }));
check('a secret never shows a default, even if the record had one', sec.kind === 'secret' && sec.def === '');
check('an unknown kind is treated as text', q.pending(rec({ waiting: { seq: 1, key: 'K', label: 'L', kind: 'weird' } })).kind === 'text');
check('choices are strings', q.pending(rec({ waiting: { seq: 1, key: 'M', label: 'Mode', kind: 'choice', choices: ['fast', 'slow'] } })).choices.join() === 'fast,slow');

// translation by key, English fallback
check('label: de by key', q.questionLabel(questionTexts, 'de', 'unifi', p).startsWith('Feste Adresse'));
check('label: English stays English', q.questionLabel(questionTexts, 'en', 'unifi', p) === "Fixed address for 'unifi'");
check('label: recipe.KEY wins over KEY', q.questionLabel({ de: { 'unifi.FIXED_IP': 'A', FIXED_IP: 'B' } }, 'de', 'unifi', p) === 'A');
check('label: an unknown key falls back to the record text', q.questionLabel(questionTexts, 'de', 'unifi', { key: 'NOPE', label: 'Plain English' }) === 'Plain English');
check('error: translated by its English text, else shown as is', q.errorLabel(questionTexts, 'de', { error: 'That value does not fit here.' }) === 'Dieser Wert passt hier nicht.' && q.errorLabel(questionTexts, 'de', { error: 'Odd.' }) === 'Odd.' && q.errorLabel(questionTexts, 'de', { error: null }) === '');

// the shape check of an answer
const t = { kind: 'text', pattern: '[0-9]+', choices: [] };
check('text: a fitting value, an empty one (the default) and a bad one', q.answerError(t, '8080') === '' && q.answerError(t, '') === '' && q.answerError(t, 'ab') === 'pattern');
check('text: a control character is refused', q.answerError({ kind: 'text', pattern: '', choices: [] }, 'a\u0001b') === 'control');
check('secret: empty is refused, a value passes', q.answerError({ kind: 'secret' }, '') === 'required' && q.answerError({ kind: 'secret' }, 'x y z') === '');
check('choice: only one of the choices', q.answerError({ kind: 'choice', choices: ['a', 'b'] }, 'a') === '' && q.answerError({ kind: 'choice', choices: ['a', 'b'] }, 'c') === 'choice');
check('a pattern JS cannot read is left to the step', q.answerError({ kind: 'text', pattern: '(?<x', choices: [] }, 'abc') === '');

// the request: the value is only ever stdin
const r = q.answerRequest('JOB-1', p, 'S3cret');
check('request: area jobs, args name job, seq and key', r.area === 'jobs' && r.args.join(' ') === 'answer JOB-1 --seq 3 --key FIXED_IP');
check('request: the value is stdin and in no argument', r.stdin === 'S3cret' && !r.args.some((a) => a.includes('S3cret')));

// what the dialog says about the record
check('phase: waiting, running (queued counts), ok', q.phase(rec()) === 'waiting' && q.phase(rec({ state: 'queued' })) === 'running' && q.phase(rec({ state: 'ok' })) === 'ok');
check('phase: a timeout is told apart from a stop', q.phase(rec({ state: 'cancelled', error: { category: 'input_timeout' } })) === 'timeout' && q.phase(rec({ state: 'cancelled', error: null })) === 'cancelled');
check('phase: too many refusals, failed, interrupted', q.phase(rec({ state: 'failed', error: { category: 'input_rejected' } })) === 'rejected' && q.phase(rec({ state: 'failed', error: { category: 'exit' } })) === 'failed' && q.phase(rec({ state: 'interrupted' })) === 'interrupted');
check('phase: no record, a state we do not know', q.phase(null) === 'unknown' && q.phase(rec({ state: 'brand-new' })) === 'unknown');
check('isActive', q.isActive(rec()) && q.isActive(rec({ state: 'running' })) && !q.isActive(rec({ state: 'ok' })) && !q.isActive(null));
check('recipeOf: record slugs', q.recipeOf({ slug: 'recipe-unifi' }) === 'unifi' && q.recipeOf({ slug: 'recipe-unifi-run' }) === 'unifi' && q.recipeOf(null) === '');
check('replyKind', q.replyKind({ status: 'done' }) === 'done' && q.replyKind({ status: 'stale' }) === 'stale' && q.replyKind({ status: 'refused' }) === 'refused' && q.replyKind(null) === 'refused');

// the texts of the table are plain text: nothing that could become markup
const all = Object.values(questionTexts).flatMap((o) => Object.values(o));
check('the translations contain no HTML', all.every((s) => !/[<>]/.test(s)));
process.exit(bad ? 1 : 0);
