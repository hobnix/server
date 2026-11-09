<script>
  // Run an app recipe as a step wizard (ADR 0018, stage 1). hs sys recipes plan|start <recipe> run [--name <container>] [--set KEY=value]...
  // The questions come from the `# ask:` header lines (`hs sys recipes asks <recipe>`), the pages from the `# step:` / `# help:` lines and the
  // 7th field of an ask (`hs sys recipes steps <recipe>`); a recipe without step lines gets one page. One page per group of questions, then the
  // container name, then the review: the plan the server would run (the right-hand side of the dialog) and Start. Text and choices go as --set, the
  // one secret on standard input (never in an argument or a log, and the review never shows it). Everything else a recipe asks (memory, port, share ...)
  // takes the answer stored last time or its default. A recipe with `# input: terminal` only shows the command to run on the server.
  // Stage 3 (the orchestrator) feeds more steps of the same shape into `steps`; see recipeSteps.js.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import Button from '../../ui/Button.svelte';
  import { get } from '../../api.js';
  import { tr } from '../../i18n.js';
  import { progress } from '../../settings/steps.js';
  import { parseAsks, buildSteps, visibleSteps, activeAsks, choicesOf, askError, stepMissing, nameError, answerArgs, secretOf, secretAsk, reviewRows } from './recipeSteps.js';

  let { recipe, onclose, ondone } = $props();

  let own = $state('');
  let loaded = $state(false);
  let loadError = $state('');
  let all = $state([]);       // every step the recipe declares (from the server)
  let input = $state('none');
  let values = $state({});    // key -> text/choice answers
  let secret = $state('');
  let runsTouched = $state(false);   // the default of RUNS depends on the container name; the server picks it again unless the user chose
  let at = $state(0);
  let tried = $state(false);  // "Next" was pressed on a page with a missing answer: the fields show what is wrong

  $effect(() => {
    Promise.all([
      get(`/api/sys/recipes/asks/${encodeURIComponent(recipe)}`),
      get(`/api/sys/recipes/steps/${encodeURIComponent(recipe)}`).catch(() => null),   // an older server has no steps row: one page
    ])
      .then(([a, s]) => {
        const p = parseAsks(a?.rows);
        input = p.input;
        all = buildSteps(p.asks, s?.rows ?? [], { label: tr('Settings'), help: '' });
        const v = {};
        for (const q of p.asks) if (q.kind !== 'secret') v[q.key] = q.def;
        values = v;
        loaded = true;
      })
      .catch((e) => { loadError = e.message; loaded = true; });
  });

  // the pages: the visible steps, the container name, the review
  const steps = $derived(visibleSteps(all, values));
  const total = $derived(steps.length + 2);
  const nameAt = $derived(steps.length);
  const reviewAt = $derived(steps.length + 1);
  const cur = $derived(at < steps.length ? steps[at] : null);
  const isReview = $derived(at === reviewAt);
  const hasSecret = $derived(!!secretAsk(all, values));

  const why = { required: 'Needed', control: 'No control characters', choice: 'Pick one of the choices', pattern: 'This does not look right', name: 'Lower-case letters, digits and dashes' };
  const errOf = (a) => (tried ? tr(why[askError(a, values, secret)] ?? '') : '');
  const pageMissing = $derived(cur ? stepMissing(cur, values, secret) : at === nameAt ? nameError(own.trim()) !== '' : false);
  const allMissing = $derived(steps.some((s) => stepMissing(s, values, secret)) || nameError(own.trim()) !== '');

  const next = () => { if (pageMissing) { tried = true; return; } tried = false; at = Math.min(at + 1, reviewAt); };
  const back = () => { tried = false; at = Math.max(at - 1, 0); };
  $effect(() => { if (at > reviewAt) at = reviewAt; });   // a switched-off page can leave `at` past the end

  // The plan is asked only on the review page: args() is null (no plan yet) while a person is still answering.
  const args = () => {
    if (!loaded || loadError || input === 'terminal' || !isReview || allMissing) return null;
    const n = own.trim();
    const a = [recipe, 'run'];
    if (n) a.push('--name', n);
    return a.concat(answerArgs(steps, values, n, runsTouched));
  };
  const stdin = () => (isReview ? secretOf(steps, values, secret) : undefined);
  const rows = $derived(reviewRows(steps, values, secret, own.trim(), recipe));
  const pageOf = (id) => { const i = steps.findIndex((s) => s.id === id); return i >= 0 ? i : nameAt; };
  const prog = $derived(progress(at, total));
</script>

<CreateDialog title={tr('Run') + ' ' + recipe} kicker="Apps" area="recipes" {args} {stdin} {onclose} {ondone}>
  {#snippet form()}
    {#if loadError}
      <div class="hint">{tr('The questions of this recipe could not be read:')} {loadError}</div>
    {:else if !loaded}
      <div class="hint">{tr('Loading…')}</div>
    {:else if input === 'terminal'}
      <div class="hint">{tr('This recipe needs a person at a terminal (a password is typed into the setup). Run')} <code>hs recipe {recipe}</code> {tr('on the server.')}</div>
    {:else}
      <div class="prog">
        <span class="pt">{prog.text}</span>
        <div class="bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow={prog.pct} aria-label={prog.text}><div class="fill" style:width="{prog.pct}%"></div></div>
      </div>

      {#if cur}
        <div class="q">{cur.label}</div>
        {#if cur.help}<div class="hint">{cur.help}</div>{/if}
        {#each activeAsks(cur, values) as q (q.key)}
          <div class="field">
            <label for="rr-{q.key}">{q.label}</label>
            {#if q.kind === 'secret'}
              <input id="rr-{q.key}" class="input" type="password" bind:value={secret} autocomplete="new-password" spellcheck="false" />
            {:else if q.kind.startsWith('choice:')}
              <select id="rr-{q.key}" class="input" bind:value={values[q.key]} onchange={() => { if (q.key === 'RUNS') runsTouched = true; }}>
                {#each choicesOf(q) as c}<option value={c}>{c}</option>{/each}
              </select>
            {:else}
              <input id="rr-{q.key}" class="input" bind:value={values[q.key]} autocomplete="off" spellcheck="false" />
            {/if}
            {#if errOf(q)}<div class="err">{errOf(q)}</div>{/if}
          </div>
        {/each}
      {:else if at === nameAt}
        <div class="q">{tr('Container name')}</div>
        <div class="field">
          <label for="rr-name">{tr('Container name (optional)')}</label>
          <input id="rr-name" class="input" bind:value={own} placeholder={recipe} maxlength="41" autocomplete="off" spellcheck="false" />
          {#if tried && nameError(own.trim())}<div class="err">{tr(why.name)}</div>{/if}
        </div>
        <div class="hint">{tr('Leave the name empty for the usual container. A name of your own runs the recipe a second time, for example a second Jellyfin.')}</div>
      {:else}
        <div class="q">{tr('Review')}</div>
        <div class="hint">{tr('Check your answers. The plan on the right is what the server would do; Start runs it.')}</div>
        <dl class="rev">
          {#each rows as r (r.label + r.stepId)}
            <dt>{r.label}</dt>
            <dd>{#if r.secret}{r.value ? tr('set (not shown)') : tr('Needed')}{:else}{r.value === '' ? '—' : r.value}{/if} <Button variant="ghost" size="sm" onclick={() => { tried = false; at = pageOf(r.stepId); }}>{tr('Change')}</Button></dd>
          {/each}
        </dl>
        <div class="hint">
          {#if hasSecret}{tr('The secret goes only into the container, never into the log.')}{/if}
          {tr('Preferences the recipe does not ask here (memory, port, share ...) use the answers stored last time, or the defaults; to choose them yourself run')} <code>hs recipe {recipe}</code> {tr('in the terminal.')}
        </div>
      {/if}

      <div class="nav">
        <Button type="button" disabled={at === 0} onclick={back}><i class="ph ph-arrow-left"></i>{tr('Back')}</Button>
        {#if !isReview}<Button variant="primary" type="button" onclick={next}>{at === reviewAt - 1 ? tr('Review') : tr('Next')}</Button>{/if}
      </div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
  .prog { display: flex; flex-direction: column; gap: 6px; }
  .pt { font-size: 12px; color: var(--fg-3); }
  .bar { height: 4px; background: var(--line); }
  .fill { height: 100%; background: var(--accent); }
  .q { font-size: 18px; font-weight: 600; }
  .err { font-size: 12px; color: var(--st-bad); margin-top: 3px; }
  .nav { display: flex; justify-content: space-between; gap: 8px; margin-top: auto; }
  .rev { display: grid; grid-template-columns: max-content 1fr; gap: 6px 14px; margin: 0; font-size: 13px; }
  .rev dt { color: var(--fg-3); }
  .rev dd { margin: 0; overflow-wrap: anywhere; }
</style>
