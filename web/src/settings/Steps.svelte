<script>
  // The guided setup of a capability page: the steps declared by [[settings.steps]] in its manifest (layout.gen.json caps[name].steps), numbered,
  // presets as radio cards, the keys of a step as fields, and at the end a review. The Advanced toggle shows all step keys as plain key/value
  // fields over the SAME draft. Review = the keys that differ + a button that opens the plan of `apply` (the area and verb of the change); the
  // plan dialog asks for the typed confirmation. Nothing here names a capability. The logic is steps.js.
  import { tip } from '../ui/tooltip.svelte.js';
  import { openPlan } from '../ui.svelte.js';
  import { stepKeys, draftFrom, applyPreset, presetOf, diff, changed, applyParts } from './steps.js';

  // steps: the layout list; apply: "<area> <verb>"; opts: the rows of `hs sys config list` (key, cur, help, ...)
  // off: a reason (the status row `setup` is off); the setup block then shows it instead of the steps
  let { steps = [], apply = '', opts = [], off = '' } = $props();
  let draft = $state({});
  let ready = $state(false);
  let advanced = $state(false);
  const keys = $derived(stepKeys(steps));
  const help = $derived(Object.fromEntries(opts.map((o) => [o.key, o.help])));
  const dflt = $derived(Object.fromEntries(opts.map((o) => [o.key, o.dflt])));

  // the draft starts at the current values as soon as the list is read; "Start over" goes back to them
  $effect(() => {
    if (!ready && opts.length) { draft = draftFrom(opts, steps); ready = true; }
  });
  const reset = () => { draft = draftFrom(opts, steps); };
  const pick = (p) => { draft = applyPreset(draft, p); };

  const changes = $derived(diff(draft, opts));
  const review = () => {
    const { area, verb } = applyParts(apply);
    openPlan(area, changed(draft, opts, verb), 'Apply the setup');
  };
</script>

<div class="card sec">
  <div class="head">
    <div class="title">Setup</div>
    <label class="adv"><input type="checkbox" bind:checked={advanced} /> Advanced</label>
  </div>

  {#if off}
    <div class="muted">{off}</div>
  {:else if !ready}
    <div class="muted">Reading the current values…</div>
  {:else if advanced}
    <div class="muted">The same values as the steps, as plain fields.</div>
    {#each keys as k (k)}
      <div class="fld">
        <div class="k"><code>{k}</code></div>
        <div class="v">
          <input class="input in" bind:value={draft[k]} placeholder={dflt[k]} aria-label={k} />
          <span class="hp" use:tip={help[k]}>{help[k]}</span>
        </div>
      </div>
    {/each}
  {:else}
    {#each steps as s, i (s.id)}
      <div class="step" id={`step-${s.id}`}>
        <div class="sh"><span class="num mono">{i + 1}</span><span class="st">{s.title}</span></div>
        <div class="muted">{s.text}</div>
        {#if s.presets?.length}
          <div class="cards" role="radiogroup" aria-label={s.title}>
            {#each s.presets as p (p.id)}
              <button type="button" class="pc" class:on={presetOf(draft, [p])} role="radio" aria-checked={!!presetOf(draft, [p])} onclick={() => pick(p)}>{p.label}</button>
            {/each}
          </div>
        {/if}
        {#each s.keys as k (k)}
          <div class="fld">
            <div class="k"><code>{k}</code></div>
            <div class="v">
              <input class="input in" bind:value={draft[k]} placeholder={dflt[k]} aria-label={k} />
              <span class="hp" use:tip={help[k]}>{help[k]}</span>
            </div>
          </div>
        {/each}
      </div>
    {/each}
  {/if}

  {#if ready && !off}
    <div class="step" id="step-review">
      <div class="sh"><span class="num mono">{steps.length + 1}</span><span class="st">Review</span></div>
      {#if changes.length}
        <div class="diff">
          {#each changes as c (c.key)}
            <code>{c.key}</code><span class="mono">{c.from || '(empty)'} → {c.to || '(empty)'}</span>
          {/each}
        </div>
      {:else}
        <div class="muted">Nothing changed yet.</div>
      {/if}
      <div class="btns">
        <button class="btn" disabled={!changes.length} onclick={review}>Review…</button>
        <button class="btn" disabled={!changes.length} onclick={reset}>Start over</button>
      </div>
    </div>
  {/if}
</div>

<style>
  .sec { display: flex; flex-direction: column; gap: 14px; padding: 14px 16px; }
  .head { display: flex; justify-content: space-between; align-items: center; }
  .title { font-weight: 600; }
  .adv { font-size: 12px; color: var(--fg-2); display: flex; gap: 6px; align-items: center; }
  .step { display: flex; flex-direction: column; gap: 8px; }
  .sh { display: flex; gap: 10px; align-items: center; }
  .num { display: inline-grid; place-items: center; width: 22px; height: 22px; border: 1px solid var(--line); font-size: 12px; color: var(--fg-2); }
  .st { font-size: 14px; font-weight: 500; }
  .cards { display: flex; gap: 8px; flex-wrap: wrap; }
  .pc { padding: 10px 14px; border: 1px solid var(--line); background: var(--panel); color: var(--fg-1); cursor: pointer; }
  .pc.on { border-color: var(--accent); }
  .fld { display: grid; grid-template-columns: 190px minmax(0, 1fr); gap: 12px; align-items: start; }
  .k { padding-top: 7px; overflow-wrap: anywhere; }
  .k code { font-size: 12px; }
  .v { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .in { min-height: 32px; font-size: 13px; font-family: var(--font-mono, ui-monospace, monospace); }
  .hp { font-size: 11.5px; color: var(--fg-3); display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  .diff { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; font-size: 13px; }
  .btns { display: flex; gap: 8px; }
  .muted { font-size: 12px; color: var(--fg-3); }
  @media (max-width: 860px) { .fld { grid-template-columns: 1fr; gap: 2px; } }
</style>
