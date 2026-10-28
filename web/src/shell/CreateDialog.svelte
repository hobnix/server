<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // The create dialog (design: "Create dialog", 960 px, form on the left, live plan on the right). A form component renders it with its own fields:
  //
  //   <CreateDialog title="New share" area="shares" args={() => [...] | null} stdin={() => password} onclose={...} ondone={...}>
  //     {#snippet form(plan)} ...fields bound to the form component's own state... {/snippet}   (`plan`: the last answer, null before the first)
  //   </CreateDialog>
  //
  // `args` is a function of the form state that returns the argument list of `hs sys <area> plan|start` (or null while the form cannot name a command yet).
  // The dialog asks the server for a plan whenever it changes (debounced) and shows what comes back: allowed / needs input / refused. A password or a
  // passphrase is returned by `stdin` (one line): it is sent in the request body for the server to put on the command's standard input, never in `args`.
  import { plan as askPlan, start as doStart } from '../api.js';
  import { ui, track, showTab } from '../ui.svelte.js';
  import PlanSteps from './PlanSteps.svelte';

  let { title, kicker = 'New', area, args, stdin = () => undefined, form, onclose = () => { ui.create = null; }, ondone = () => {} } = $props();

  let p = $state(null);
  let asking = $state(false);
  let loadError = $state('');
  let confirm = $state('');
  let busy = $state(false);
  let startError = $state('');
  let seq = 0;

  const danger = $derived(!!p?.steps.some((s) => s[0] === 'danger'));
  const status = $derived(!p ? 'waiting' : p.status);
  const allowed = $derived(p?.status === 'ok');
  const canStart = $derived(allowed && !busy && !asking && (!p.confirm_name || confirm === p.confirm_name));

  // a new plan whenever the form changes (300 ms after the last change); the answer of an older question is dropped
  $effect(() => {
    const a = args();
    const s = stdin();
    clearTimeout(timer);
    if (!a) { p = null; asking = false; loadError = ''; return; }
    asking = true;
    const my = ++seq;
    timer = setTimeout(async () => {
      try {
        const r = await askPlan(area, a, s);
        if (my === seq) { p = r; loadError = ''; if (r.confirm_name !== p?.confirm_name) confirm = ''; }
      } catch (e) {
        if (my === seq) { loadError = e.message; p = null; }
      } finally {
        if (my === seq) asking = false;
      }
    }, 300);
  });
  let timer;

  async function go() {
    const a = args();
    if (!a) return;
    busy = true;
    startError = '';
    try {
      const r = await doStart(area, a, p.confirm_name ? confirm : '', stdin());
      if (r.status === 'started' && r.unit) {
        track(r.unit, title);
        showTab('tasks');
        onclose();
        ondone(r);
      } else if (r.status === 'done') {
        onclose();
        ondone(r);
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

<svelte:window onkeydown={(e) => e.key === 'Escape' && onclose()} />

<div class="dialog-backdrop" role="presentation" style="z-index:50" onclick={(e) => e.target === e.currentTarget && onclose()}>
  <div class="dialog wide" role="dialog" aria-modal="true" aria-labelledby="cdt">
    <div class="left">
      <div>
        <div class="kicker">{kicker} <span class="tag tag-neutral" style="padding:1px 8px;margin-left:6px">{ui.host}</span></div>
        <div id="cdt" class="dialog-title">{title}</div>
      </div>
      {@render form?.(p)}
    </div>

    <div class="right">
      <div class="pill {status}">
        <span class="dot {allowed ? 'ok' : status === 'refused' ? 'bad' : 'off'}"></span>
        {#if asking}checking…{:else if allowed}allowed{:else if status === 'needs'}needs input{:else if status === 'refused'}refused{:else}fill in the form{/if}
      </div>

      <div class="scroll">
        {#if loadError}
          <div class="refused"><i class="ph ph-warning-circle"></i>{loadError}</div>
        {:else if p?.status === 'needs'}
          <div class="lede">Still missing</div>
          <ul class="needs">{#each p.needs as n}<li>{n}</li>{/each}</ul>
        {:else if p?.status === 'refused'}
          <div class="lede">Refused</div>
          <div class="refused"><i class="ph ph-prohibit"></i>{p.reason || 'The server refused this.'}</div>
        {/if}
        {#if p && p.heading && p.status === 'ok'}<div style="font-size:14px;font-weight:500;margin-bottom:2px">{p.heading}</div>{/if}
        {#if p}<PlanSteps steps={p.steps} long={p.long && allowed} dim={!allowed} />{/if}
        {#if p?.command && allowed}<code class="cmd">{p.command}</code>{/if}
        {#if p?.confirm_name && allowed}
          <div class="field" style="margin-top:10px">
            <label for="cf2">Type <code style="color:var(--color-text)">{p.confirm_name}</code> to confirm</label>
            <input id="cf2" class="input" bind:value={confirm} placeholder={p.confirm_name} autocomplete="off" spellcheck="false" />
          </div>
        {/if}
        {#if startError}<div class="refused" style="margin-top:8px"><i class="ph ph-warning-circle"></i>{startError}</div>{/if}
      </div>

      <div class="dialog-actions" style="margin-top:0">
        <button class="btn btn-secondary" onclick={onclose}>Cancel</button>
        <button use:tip={canStart ? '' : p.confirm_name && confirm !== p.confirm_name ? 'Type the name to confirm first' : busy ? 'Starting' : 'Fill in the form first'} class="btn btn-primary" disabled={!canStart} onclick={go} style={danger ? 'color:var(--st-bad);border-color:var(--st-bad)' : ''}>
          <i class="ph ph-play"></i>{busy ? 'Starting…' : 'Start'}
        </button>
      </div>
    </div>
  </div>
</div>

<style>
  .dialog.wide { width: min(960px, 100%); height: min(720px, calc(100vh - 40px)); padding: 0; gap: 0; display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr); grid-template-rows: minmax(0, 1fr); overflow: hidden; }
  .left { padding: 20px 22px; overflow: auto; display: flex; flex-direction: column; gap: 16px; min-height: 0; }
  .right { background: var(--color-bg); box-shadow: inset 1px 0 0 var(--color-neutral-800); padding: 20px 20px 16px; display: flex; flex-direction: column; gap: 12px; min-height: 0; }
  .scroll { flex: 1; min-height: 0; overflow: auto; }
  .kicker { font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--color-accent-300); display: flex; align-items: center; margin-bottom: 4px; }
  .pill { align-self: flex-start; display: inline-flex; align-items: center; gap: 7px; font-size: 12px; padding: 3px 11px; border-radius: 999px; background: var(--color-neutral-900); color: var(--color-neutral-300); }
  .lede { font-size: 12px; color: var(--color-neutral-400); margin-bottom: 4px; }
  .needs { margin: 0 0 8px; padding-left: 18px; font-size: 13px; color: var(--color-neutral-200); }
  .refused { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; color: var(--st-bad); }
  .cmd { display: block; font-size: 12px; padding: 10px 12px; margin-top: 10px; border-radius: var(--r); background: var(--color-surface); color: var(--color-neutral-300); overflow-x: auto; white-space: nowrap; }
  .btn:disabled { opacity: 0.45; cursor: default; }
  @media (max-width: 800px) { .dialog.wide { grid-template-columns: minmax(0, 1fr); grid-template-rows: minmax(0, 1fr) minmax(0, 1fr); } }
</style>
