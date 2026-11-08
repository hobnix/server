<script>
  import Button from '../ui/Button.svelte';
  import { onMount } from 'svelte';
  import { plan as askPlan, start as doStart } from '../api.js';
  import { ui, track, trackDone, showTab, openPlan } from '../ui.svelte.js';
  import { offersRebuild, effectOf } from './effect.js';
  import { jobKey } from '../jobkey.js';
  import PlanSteps from './PlanSteps.svelte';
  import Halftone from './Halftone.svelte';
  import Chip from '../ui/Chip.svelte';
  import Skeleton from '../ui/Skeleton.svelte';

  let { dialog } = $props();            // { area, args, title }

  let p = $state(null);                 // the plan, as the backend parsed it
  let loadError = $state('');
  let confirm = $state('');
  let busy = $state(false);
  let startError = $state('');
  let saved = $state(!!dialog.saved);   // a change was written and waits for a rebuild: say so, offer "Rebuild now" (no plan is asked)

  const savedText = $derived(effectOf(p?.steps)?.text ?? 'This takes effect with hs rebuild.');
  const danger = $derived(!!p?.steps.some((s) => s[0] === 'danger'));
  const allowed = $derived(p?.status === 'ok');
  const canStart = $derived(allowed && !busy && (!p.confirm_name || confirm === p.confirm_name));
  const kicker = $derived(p && !allowed ? 'Plan · refused' : danger ? 'Plan · danger' : 'Plan');

  onMount(() => {
    if (saved) return;
    let open = true;       // the answer may be one a button already asked for (prefetchPlan): it is not cancelled with the dialog
    askPlan(dialog.area, dialog.args, undefined, undefined, undefined, dialog.document)
      .then((r) => { if (open) p = r; }, (e) => { if (open) loadError = e.message; });
    return () => { open = false; };
  });

  function close() { ui.dialog = null; }

  async function go() {
    busy = true;
    startError = '';
    try {
      const r = await doStart(dialog.area, dialog.args, p.confirm_name ? confirm : '', undefined, undefined, dialog.document);
      if (r.status === 'started' && r.unit) {
        track(r.unit, dialog.title || p.heading, jobKey(dialog.area, dialog.args));
        showTab('tasks');
        close();
      } else if (r.status === 'done') {
        trackDone(dialog.title || p.heading, p.steps ?? []);
        showTab('tasks');
        if (dialog.area !== 'system' && offersRebuild(p.steps)) saved = true; else close();
      } else {
        startError = r.reason || 'The server did not start it.';
      }
    } catch (e) {
      startError = e.message;
    } finally {
      busy = false;
    }
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && close()} />

<div class="dialog-backdrop" role="presentation">
  <div class="pdlg" class:danger role="dialog" aria-modal="true" aria-labelledby="pdt">
    {#if danger}<div class="stripe"></div>{/if}
    <div class="dh">
      <!-- halftone slot: the dialog header (not for a danger plan, whose header is tinted red) -->
      {#if !danger}<Halftone cell={3} focus={[1, 0]} reach={0.9} opacity={0.75} />{/if}
      <div class="dtop">
        <span class="eyebrow" class:bad={danger}>{kicker}</span>
        <span class="grow"></span>
        <Chip kind="strong">{ui.host}</Chip>
      </div>
      <h3 id="pdt">{saved ? 'Saved' : p?.heading || dialog.title || 'Plan'}</h3>
    </div>
    <div class="dbody">
      {#if saved}
        <PlanSteps steps={[['note', savedText]]} />
        <div class="lede">The server runs as before until it is rebuilt.</div>
      {:else if loadError}
        <div class="refused"><i class="ph ph-warning-circle"></i>{loadError}</div>
      {:else if !p}
        <Skeleton lines={3} />
        <div class="lede">Asking the server what would happen…</div>
      {:else if !allowed}
        <div class="refused"><i class="ph ph-prohibit"></i>{p.reason || 'The server refused this.'}</div>
        {#each p.fixes ?? [] as f}<div class="lede">To make it possible, run <code class="cmd">{f}</code></div>{/each}
        <div class="lede">Nothing has run.</div>
      {:else}
        <PlanSteps steps={p.steps} long={p.long} />
        {#if p.command}<code class="cmd">{p.command}</code>{/if}
      {/if}
      {#if startError}<div class="refused"><i class="ph ph-warning-circle"></i>{startError}</div>{/if}
    </div>
    {#if !saved && allowed && p.confirm_name}
      <div class="confirm">
        <label for="cf">Type <code>{p.confirm_name}</code> to confirm</label>
        <input id="cf" class="input" bind:value={confirm} placeholder={p.confirm_name} autocomplete="off" spellcheck="false" />
      </div>
    {/if}
    {#if saved}
    <div class="dfoot">
      <span class="note"></span>
      <Button onclick={close}>Later</Button>
      <Button variant="primary" onclick={() => { close(); openPlan('system', ['rebuild'], 'Rebuild now'); }}><i class="ph ph-hammer"></i>Rebuild now…</Button>
    </div>
    {:else}
    <div class="dfoot">
      <span class="note">{allowed ? 'Nothing has run yet. The result appears under Jobs.' : ''}</span>
      <Button onclick={close}>{allowed ? 'Cancel' : 'Close'}</Button>
      {#if !allowed && (p?.reason?.includes('changed meanwhile') || startError.includes('changed meanwhile')) && dialog.onReload}
        <Button variant="primary" onclick={() => { const cb = dialog.onReload; close(); cb(); }}>Reload</Button>
      {/if}
      {#if allowed}
        <Button variant={danger ? 'danger' : 'primary'} tooltip={canStart ? '' : p.confirm_name && confirm !== p.confirm_name ? 'Type the name to confirm first' : busy ? 'Starting' : 'This change cannot be started now'} disabled={!canStart} onclick={() => { go(); }}>
          <i class="ph ph-play"></i>{busy ? 'Starting…' : 'Start job'}
        </Button>
      {/if}
    </div>
    {/if}
  </div>
</div>

<style>
  .pdlg { position: relative; width: min(540px, 100%); max-height: calc(100dvh - 32px); display: flex; flex-direction: column; overflow: hidden; background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: 0 24px 64px oklch(0 0 0 / 0.5); }
  .stripe { position: absolute; left: 0; right: 0; top: 0; height: 3px; background: var(--bad); z-index: 2; }
  .dh { position: relative; flex: none; padding: 20px 22px 14px; border-bottom: 1px solid var(--line); overflow: hidden; }
  .pdlg.danger .dh { background: color-mix(in oklch, var(--bad) 10%, var(--panel)); }
  .dtop { position: relative; display: flex; align-items: center; gap: 8px; }
  .eyebrow.bad { color: var(--bad-ink); }
  h3 { position: relative; margin: 6px 0 0; font-size: 18px; font-weight: 600; letter-spacing: -0.02em; }
  .dbody { padding: 8px 22px 14px; overflow: auto; min-height: 0; display: flex; flex-direction: column; gap: 10px; }
  .lede { font-size: 12.5px; color: var(--fg-3); }
  .cmd { display: block; font-size: 12px; padding: 10px 12px; border: 1px solid var(--line); background: var(--panel-2); color: var(--fg-2); white-space: pre-wrap; overflow-wrap: anywhere; }
  .refused { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; color: var(--bad-ink); padding-top: 8px; }
  .confirm { padding: 14px 22px; border-top: 1px solid var(--line); }
  .confirm label { display: block; margin-bottom: 6px; font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-3); }
  .confirm code { color: var(--fg); text-transform: none; letter-spacing: 0; }
  .confirm .input { border-color: color-mix(in oklch, var(--bad) 55%, var(--line-2)); font-family: var(--mono); }
  .dfoot { flex: none; display: flex; align-items: center; gap: 8px; justify-content: flex-end; flex-wrap: wrap; padding: 14px 22px; background: var(--panel-2); border-top: 1px solid var(--line); }
  .note { flex: 1; min-width: 180px; color: var(--fg-3); font-size: 12.5px; }
</style>
