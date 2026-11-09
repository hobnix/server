<script>
  // The questions of an interactive recipe run (ADR 0018 stage 3, docs/PLAN-recipe-orchestrator.md). The run is an orchestration job; while a step needs an
  // answer its record says `waiting` and carries the question. This dialog follows the record (a job.* event, else every 3 s) and shows that question:
  // a text, a choice or a secret, with the refusal text of the last try under it. The answer goes to `hs sys jobs answer` as ONE line of standard input
  // (never in an argument, never stored here). Closing the dialog changes nothing: the run waits on the server (the Jobs page opens it again).
  // The texts of a question are translated by its key (translations.js), the English text of the record is the fallback; everything is shown as plain text.
  import { onDestroy } from 'svelte';
  import Button from '../../ui/Button.svelte';
  import { get, start } from '../../api.js';
  import { live } from '../../live.svelte.js';
  import { lang } from '../../lang.svelte.js';
  import { tr } from '../../i18n.js';
  import { ui } from '../../ui.svelte.js';
  import { isJobEvent, stepText } from '../../jobrecords.js';
  import { pending, phase, isActive, answerError, answerRequest, replyKind, questionLabel, errorLabel, recipeOf } from './recipeQuestions.js';
  import { questionTexts } from './recipeQuestionTexts.js';

  let { job, recipe = '', onclose = () => { ui.create = null; } } = $props();

  let rec = $state(null);
  let loadError = $state('');
  let value = $state('');
  let tried = $state(false);
  let sendError = $state('');
  let answeredSeq = $state(0);   // the question this dialog sent an answer to: it is not asked again while the record still shows it
  let lastSeq = 0;

  async function load() {
    try {
      rec = await get(`/api/sys/jobs/record/${encodeURIComponent(job)}`);
      loadError = '';
    } catch (e) { loadError = e.message || 'The job could not be read.'; }
  }
  $effect(() => { load(); });
  let lastEv = 0;
  $effect(() => {
    const ev = live.events.findLast?.(isJobEvent) ?? [...live.events].reverse().find(isJobEvent);
    if (ev && ev.id !== lastEv) { lastEv = ev.id; load(); }
  });
  const timer = setInterval(() => { if (!rec || isActive(rec)) load(); }, 3000);
  onDestroy(() => clearInterval(timer));

  const q = $derived(pending(rec));
  const ph = $derived(phase(rec));
  const name = $derived(recipe || recipeOf(rec));
  const label = $derived(q ? questionLabel(questionTexts, lang.code, name, q) : '');
  const errText = $derived(q ? errorLabel(questionTexts, lang.code, q) : '');
  // a new question starts with its default (a secret with nothing)
  $effect(() => { if (q && q.seq !== lastSeq) { lastSeq = q.seq; value = q.kind === 'choice' ? (q.choices.includes(q.def) ? q.def : (q.choices[0] ?? '')) : q.def; tried = false; sendError = ''; } });

  const why = { required: 'Needed', control: 'No control characters', choice: 'Pick one of the choices', pattern: 'This does not look right' };
  const bad = $derived(q ? answerError(q, value) : '');
  const waiting = $derived(!!q && q.seq !== answeredSeq);

  async function send() {
    if (!q) return;
    if (bad) { tried = true; return; }
    const r = answerRequest(job, q, value);
    sendError = '';
    try {
      const reply = await start(r.area, r.args, '', r.stdin);
      const k = replyKind(reply);
      if (k === 'done') { answeredSeq = q.seq; value = ''; }
      else if (k === 'refused') sendError = reply.reason || 'The answer was not accepted.';
    } catch (e) { sendError = e.message || 'The answer could not be sent.'; }
    await load();
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onclose()} />

<div class="dialog-backdrop" role="presentation" style="z-index:50">
  <div class="dialog" role="dialog" aria-modal="true" aria-labelledby="rqt" style="width:min(520px,100%)">
    <div class="rq">
      <div>
        <div class="kicker">{tr('Apps')}</div>
        <div id="rqt" class="dialog-title">{tr('Run')} {name}</div>
      </div>

      {#if loadError && !rec}
        <div class="hint">{tr('The job could not be read.')} {loadError}</div>
      {:else if !rec}
        <div class="hint">{tr('Loading…')}</div>
      {:else if waiting && q}
        <div class="wait"><i class="ph ph-hourglass-medium" aria-hidden="true"></i> {tr('Waiting for your answer')}</div>
        <div class="field">
          <label for="rq-answer">{label}</label>
          {#if q.kind === 'secret'}
            <input id="rq-answer" class="input" type="password" bind:value autocomplete="new-password" spellcheck="false" />
          {:else if q.kind === 'choice'}
            <select id="rq-answer" class="input" bind:value>
              {#each q.choices as c}<option value={c}>{c}</option>{/each}
            </select>
          {:else}
            <input id="rq-answer" class="input" bind:value autocomplete="off" spellcheck="false" placeholder={q.def} />
          {/if}
          {#if errText && !tried}<div class="err">{errText}</div>{/if}
          {#if tried && bad}<div class="err">{tr(why[bad] ?? '')}</div>{/if}
          {#if sendError}<div class="err">{sendError}</div>{/if}
        </div>
        <div class="hint">
          {#if q.kind === 'secret'}{tr('The secret goes only into the container, never into the log.')}{:else if q.def}{tr('Leave it empty to use')} <code>{q.def}</code>.{/if}
          {tr('Closing this window does not stop the run: it waits for your answer on the Jobs page.')}
        </div>
        <div class="nav">
          <Button type="button" onclick={onclose}>{tr('Close')}</Button>
          <Button variant="primary" type="button" onclick={send}>{tr('Send')}</Button>
        </div>
      {:else if ph === 'ok'}
        <div class="done"><i class="ph ph-check-circle" aria-hidden="true"></i> {tr('Done')}</div>
        <div class="nav"><span></span><Button variant="primary" type="button" onclick={onclose}>{tr('Close')}</Button></div>
      {:else if ph === 'timeout'}
        <div class="err">{tr('Nobody answered in time, so the run was cancelled. Run it again.')}</div>
        <div class="nav"><span></span><Button type="button" onclick={onclose}>{tr('Close')}</Button></div>
      {:else if ph === 'cancelled' || ph === 'failed' || ph === 'interrupted' || ph === 'rejected'}
        <div class="err">{ph === 'cancelled' ? tr('The run was stopped.') : ph === 'interrupted' ? tr('The run was interrupted (the server restarted). Run it again.') : ph === 'rejected' ? tr('The answers were refused too often. Run it again.') : tr('The run failed. The Jobs page and the log show why.')}</div>
        <div class="nav"><span></span><Button type="button" onclick={onclose}>{tr('Close')}</Button></div>
      {:else}
        <div class="wait"><i class="ph ph-circle-notch spin" aria-hidden="true"></i> {tr('Running…')} {stepText(rec.step)}</div>
        <div class="hint">{tr('A question appears here when the setup needs an answer. You can close this window; the run goes on.')}</div>
        <div class="nav"><span></span><Button type="button" onclick={onclose}>{tr('Close')}</Button></div>
      {/if}
    </div>
  </div>
</div>

<style>
  .rq { display: flex; flex-direction: column; gap: 14px; padding: 20px; }
  .hint { font-size: 12px; color: var(--color-neutral-500); }
  .wait, .done { font-size: 15px; font-weight: 600; display: flex; align-items: center; gap: 8px; }
  .err { font-size: 12px; color: var(--st-bad); margin-top: 3px; }
  .nav { display: flex; justify-content: space-between; gap: 8px; }
</style>
