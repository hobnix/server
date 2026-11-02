<script>
  // The guided setup of a capability page as a wizard: one question per screen (steps with `options`, [[settings.steps]] in the manifest), then a
  // review that opens the plan of `apply`. `advanced` (set by the page) shows the step keys as plain key/value fields over the SAME draft. Nothing here names a
  // capability; the logic is steps.js.
  import { tip } from '../ui/tooltip.svelte.js';
  import Wizard from '../ui/Wizard.svelte';
  import ChoiceList from '../ui/ChoiceList.svelte';
  import { tr } from '../i18n.js';
  import { openPlan } from '../ui.svelte.js';
  import { stepKeys, draftFrom, applyPreset, optionOf, freeKeys, withDefaults, visibleSteps, withRecommended, screens, diff, changed, changedAll, applyParts, readPath, withReadOptions } from './steps.js';
  import { poll, rows as rowsOf } from '../data.svelte.js';

  // steps: the layout list; apply: "<area> <verb>"; opts: rows of `hs sys config list`; off: a reason the setup is off. on: the part is on already (the page then starts at the review, the summary). known: `on` is settled (parts list / docker status arrived); the draft waits for it, else a set-up part would get the recommended preset
  // first: nothing exists yet (the docker container): Apply is always possible and sends every step key
  // advanced: the page's Advanced view is on (it replaces the tabs): the step keys as plain fields over the same draft
  // defaults: { key: value } of the schema; the rows then carry them and an unset key matches its default's option. Only a setup that is not on yet gets the recommended option of a step that still has no match
  // steps with a `when` that does not hold are left out of the screens, the review and the wizard (Advanced keeps every key)
  let { steps: allSteps = [], apply = '', opts: rows = [], off = '', on = false, known = true, first = false, advanced = false, defaults = null } = $props();
  const opts = $derived(defaults ? withDefaults(rows, defaults) : rows);
  const steps = $derived(visibleSteps(allSteps, opts, defaults));
  let draft = $state({});
  let ready = $state(false);
  let only = $state('');
  let at = $state(0);
  let moved = $state(false);
  const keys = $derived(stepKeys(allSteps));
  const help = $derived(Object.fromEntries(opts.map((o) => [o.key, o.help])));
  const dflt = $derived(Object.fromEntries(opts.map((o) => [o.key, o.dflt])));
  const list = $derived(screens(steps, only));

  $effect(() => {
    if (!ready && known && opts.length) { draft = on ? draftFrom(opts, allSteps) : withRecommended(draftFrom(opts, allSteps), allSteps, defaults); ready = true; }
  });
  // a part that is on shows the summary first, unless the person has moved already
  $effect(() => {
    if (ready && on && !moved) at = list.length - 1;
  });

  const id = $derived(list[Math.min(at, list.length - 1)]);
  const plain = $derived(steps.find((s) => s.id === id));
  // a step with `options_from` offers the rows of its read as choices (a free field while the read has not arrived, failed or is empty)
  const fromRead = poll(() => readPath(plain), 15000);
  const step = $derived(withReadOptions(plain, rowsOf(fromRead)));
  const isReview = $derived(id === 'review');
  const changes = $derived(diff(draft, opts));
  const go = (n) => { moved = true; at = Math.max(0, Math.min(n, list.length - 1)); };
  const pick = (o) => { draft = applyPreset(draft, o); };
  const edit = (s) => { moved = true; only = s.id; at = 0; };
  // what a step shows in the review: the label of the chosen option, else the raw values
  const shown = (s) => optionOf(draft, s, defaults)?.label ?? s.keys.map((k) => `${k} = ${draft[k] || '(empty)'}`).join(', ');
  const review = () => {
    const { area, verb } = applyParts(apply);
    openPlan(area, first ? changedAll(draft, allSteps, verb) : changed(draft, opts, verb), 'Apply the setup');
  };
</script>

<div class="card sec">
  {#if off}
    <div class="muted">{off}</div>
  {:else if !ready}
    <div class="muted">Reading the current values…</div>
  {:else if advanced}
    <div class="q">{tr('Advanced')}</div>
    <div class="muted">The same values as the questions, as plain fields.</div>
    {#each keys as k (k)}
      <div class="fld">
        <div class="k"><code>{k}</code></div>
        <div class="v">
          <input class="input in" bind:value={draft[k]} placeholder={dflt[k]} aria-label={k} />
          <span class="hp" use:tip={help[k]}>{help[k]}</span>
        </div>
      </div>
    {/each}
    {#if changes.length}
      <div class="diff">
        {#each changes as c (c.key)}
          <code>{c.key}</code><span class="mono">{c.from || '(empty)'} → {c.to || '(empty)'}</span>
        {/each}
      </div>
    {/if}
    <div class="foot"><button type="button" class="btn btn-primary" disabled={!first && !changes.length} onclick={review}>{tr('Apply…')}</button></div>
  {:else if isReview}
    <Wizard index={at} total={list.length} question={tr('Review')} help="" primary={tr('Apply…')} canNext={first || !!changes.length} onnext={review} onback={() => go(at - 1)}>
      {#each steps as s (s.id)}
        <div class="rv">
          <span class="rt">{s.title}</span>
          <span class="rs mono">{shown(s)}</span>
          <button type="button" class="link" onclick={() => edit(s)}>{tr('Change')}</button>
        </div>
      {/each}
      {#if changes.length}
        <div class="diff">
          {#each changes as c (c.key)}
            <code>{c.key}</code><span class="mono">{c.from || '(empty)'} → {c.to || '(empty)'}</span>
          {/each}
        </div>
      {:else if first}
        <div class="muted">Nothing is set up yet: Apply creates it with these values.</div>
      {:else}
        <div class="muted">Nothing changed yet.</div>
      {/if}
    </Wizard>
  {:else if step}
    <Wizard index={at} total={list.length} question={step.question || step.title} help={step.text} primary={tr('Next')} onnext={() => go(at + 1)} onback={() => go(at - 1)}>
      {#if step.options?.length}
        <ChoiceList options={step.options} value={optionOf(draft, step, defaults)?.id ?? ''} onpick={(oid) => pick(step.options.find((o) => o.id === oid))} label={step.question || step.title} />
      {/if}
      {#each freeKeys(step) as k (k)}
        <div class="fld">
          <div class="k"><code>{k}</code></div>
          <div class="v">
            <input class="input in" bind:value={draft[k]} placeholder={dflt[k]} aria-label={k} />
            <span class="hp" use:tip={help[k]}>{help[k]}</span>
          </div>
        </div>
      {/each}
    </Wizard>
  {/if}
</div>

<style>
  .sec { display: flex; flex-direction: column; gap: 14px; padding: 16px 18px; }
  .rv { display: grid; grid-template-columns: 120px minmax(0, 1fr) auto; gap: 12px; align-items: baseline; padding: 8px 0; border-bottom: 1px solid var(--line); }
  .rt { font-size: 14px; font-weight: 500; }
  .rs { font-size: 13px; color: var(--fg-2); overflow-wrap: anywhere; }
  .link { border: 0; background: none; padding: 0; color: var(--fg-2); font-size: 13px; text-decoration: underline; cursor: pointer; }
  .link:hover { color: var(--fg); }
  .fld { display: grid; grid-template-columns: 190px minmax(0, 1fr); gap: 12px; align-items: start; }
  .k { padding-top: 7px; overflow-wrap: anywhere; }
  .k code { font-size: 12px; }
  .v { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .in { min-height: 32px; font-size: 13px; font-family: var(--font-mono, ui-monospace, monospace); }
  .hp { font-size: 11.5px; color: var(--fg-3); display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  .q { font-size: 20px; font-weight: 600; }
  .foot { display: flex; justify-content: flex-end; }
  .diff { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; font-size: 13px; margin-top: 8px; }
  .muted { font-size: 12px; color: var(--fg-3); }
  @media (max-width: 860px) { .fld { grid-template-columns: 1fr; gap: 2px; } .rv { grid-template-columns: 1fr; gap: 2px; } }
</style>
