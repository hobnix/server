<script>
  // The guided setup of a capability page as a wizard: one question per screen (steps with `options`, [[settings.steps]] in the manifest), then a
  // review that opens the plan of `apply`. Advanced shows the step keys as plain key/value fields over the SAME draft. Nothing here names a
  // capability; the logic is steps.js. Steps.svelte is the older view (presets, all steps on one card).
  import { tip } from '../ui/tooltip.svelte.js';
  import Wizard from '../ui/Wizard.svelte';
  import ChoiceList from '../ui/ChoiceList.svelte';
  import { tr } from '../i18n.js';
  import { openPlan } from '../ui.svelte.js';
  import { stepKeys, draftFrom, applyPreset, optionOf, withRecommended, screens, diff, changed, applyParts } from './steps.js';

  // steps, apply, opts, off: as Steps.svelte. on: the part is on already (the page then starts at the review, the summary)
  let { steps = [], apply = '', opts = [], off = '', on = false } = $props();
  let draft = $state({});
  let ready = $state(false);
  let advanced = $state(false);
  let only = $state('');
  let at = $state(0);
  let moved = $state(false);
  const keys = $derived(stepKeys(steps));
  const help = $derived(Object.fromEntries(opts.map((o) => [o.key, o.help])));
  const dflt = $derived(Object.fromEntries(opts.map((o) => [o.key, o.dflt])));
  const list = $derived(screens(steps, only));

  $effect(() => {
    if (!ready && opts.length) { draft = withRecommended(draftFrom(opts, steps), steps); ready = true; }
  });
  // a part that is on shows the summary first, unless the person has moved already
  $effect(() => {
    if (ready && on && !moved) at = list.length - 1;
  });

  const id = $derived(list[Math.min(at, list.length - 1)]);
  const step = $derived(steps.find((s) => s.id === id));
  const isReview = $derived(id === 'review');
  const changes = $derived(diff(draft, opts));
  const go = (n) => { moved = true; at = Math.max(0, Math.min(n, list.length - 1)); };
  const pick = (o) => { draft = applyPreset(draft, o); };
  const edit = (s) => { moved = true; only = s.id; at = 0; };
  // what a step shows in the review: the label of the chosen option, else the raw values
  const shown = (s) => optionOf(draft, s)?.label ?? s.keys.map((k) => `${k} = ${draft[k] || '(empty)'}`).join(', ');
  const review = () => {
    const { area, verb } = applyParts(apply);
    openPlan(area, changed(draft, opts, verb), 'Apply the setup');
  };
</script>

<div class="card sec">
  {#if off}
    <div class="muted">{off}</div>
  {:else if !ready}
    <div class="muted">Reading the current values…</div>
  {:else if advanced}
    <Wizard index={at} total={list.length} question={tr('Advanced')} help="The same values as the questions, as plain fields." primary={tr('Review')} onnext={() => { advanced = false; go(list.length - 1); }} bind:advanced>
      {#each keys as k (k)}
        <div class="fld">
          <div class="k"><code>{k}</code></div>
          <div class="v">
            <input class="input in" bind:value={draft[k]} placeholder={dflt[k]} aria-label={k} />
            <span class="hp" use:tip={help[k]}>{help[k]}</span>
          </div>
        </div>
      {/each}
    </Wizard>
  {:else if isReview}
    <Wizard index={at} total={list.length} question={tr('Review')} help="" primary={tr('Apply…')} canNext={!!changes.length} onnext={review} onback={() => go(at - 1)} bind:advanced>
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
      {:else}
        <div class="muted">Nothing changed yet.</div>
      {/if}
    </Wizard>
  {:else if step}
    <Wizard index={at} total={list.length} question={step.question || step.title} help={step.text} primary={tr('Next')} onnext={() => go(at + 1)} onback={() => go(at - 1)} bind:advanced>
      {#if step.options?.length}
        <ChoiceList options={step.options} value={optionOf(draft, step)?.id ?? ''} onpick={(oid) => pick(step.options.find((o) => o.id === oid))} label={step.question || step.title} />
      {:else}
        {#each step.keys as k (k)}
          <div class="fld">
            <div class="k"><code>{k}</code></div>
            <div class="v">
              <input class="input in" bind:value={draft[k]} placeholder={dflt[k]} aria-label={k} />
              <span class="hp" use:tip={help[k]}>{help[k]}</span>
            </div>
          </div>
        {/each}
      {/if}
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
  .diff { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; font-size: 13px; margin-top: 8px; }
  .muted { font-size: 12px; color: var(--fg-3); }
  @media (max-width: 860px) { .fld { grid-template-columns: 1fr; gap: 2px; } .rv { grid-template-columns: 1fr; gap: 2px; } }
</style>
