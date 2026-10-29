<script>
  // The result of a finished or cancelled job: what was done, what was skipped, what failed (with the reason). Only Close.
  import Chip from '../ui/Chip.svelte';
  import * as S from './selection.js';

  let { fm } = $props();
  const j = $derived(fm.job);
  const p = $derived(j?.p);
  const close = () => (fm.result = false);
  const title = $derived(j.state === 'done' ? 'Finished' : j.state === 'cancelled' ? 'Cancelled' : 'Failed');
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && close()} />

{#if j && p}
  <div class="dialog-backdrop" role="presentation">
    <div class="rdlg" role="dialog" aria-modal="true" aria-labelledby="fmrt">
      <div class="dh"><div class="dtop"><span class="eyebrow">Result</span><span class="grow"></span><Chip>{j.op}</Chip></div><h3 id="fmrt">{title}: {j.title}</h3></div>
      <div class="dbody">
        <div class="step"><span class="mk p">+</span><div class="h">{S.plural(p.filesDone || 0, 'file')} {j.op === 'move' ? 'moved and verified' : j.op === 'delete' ? 'deleted' : 'done'}{Number.isFinite(p.bytesDone) ? ` · ${S.bytesTxt(p.bytesDone)}` : ''}
          {#if j.op === 'move'}<div class="sm">Removed from the source after verification.</div>{/if}</div></div>
        {#if p.skipped.n}
          <div class="step"><span class="mk t">~</span><div class="h">{S.plural(p.skipped.n, 'item')} skipped<div class="sm">Already on the target (policy: skip existing), or locked.</div>
            {#if p.skipped.items.length}<ul>{#each p.skipped.items as it}<li><span class="mono">{it.path}</span>{#if it.why} <span class="sm">{it.why}</span>{/if}</li>{/each}</ul>{/if}</div></div>
        {/if}
        {#if p.failed.n}
          <div class="step"><span class="mk m">−</span><div class="h">{S.plural(p.failed.n, 'item')} failed<div class="sm">They are left where they were.</div>
            {#if p.failed.items.length}<ul>{#each p.failed.items as it}<li><span class="mono">{it.path}</span>{#if it.why} <span class="bad">{it.why}</span>{/if}</li>{/each}</ul>{/if}</div></div>
        {/if}
        {#if j.state === 'cancelled'}<div class="sm">Cancelled: what was copied stays, nothing unverified was removed.</div>{/if}
        <div class="sm">Skipped and failed items are kept in the job log under Tasks.</div>
      </div>
      <div class="dfoot"><button class="btn btn-primary" onclick={close}>Close</button></div>
    </div>
  </div>
{/if}

<style>
  .rdlg { width: min(560px, 100%); max-height: calc(100dvh - 32px); display: flex; flex-direction: column; overflow: hidden; background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: 0 24px 64px oklch(0 0 0 / 0.5); }
  .dh { padding: 20px 22px 14px; border-bottom: 1px solid var(--line); }
  .dtop { display: flex; align-items: center; gap: 8px; }
  h3 { margin: 6px 0 0; font-size: 18px; font-weight: 600; letter-spacing: -0.02em; overflow-wrap: anywhere; }
  .dbody { padding: 8px 22px 14px; overflow: auto; min-height: 0; }
  .step { display: flex; gap: 12px; padding: 9px 0; border-bottom: 1px solid var(--line); }
  .mk { flex: none; width: 22px; height: 22px; display: grid; place-items: center; border: 1px solid var(--line-2); font: 600 13px var(--mono); background: var(--panel-2); color: var(--accent-ink); }
  .mk.m { color: var(--bad-ink); } .mk.t { color: var(--info-ink); }
  .h { flex: 1; min-width: 0; font-size: 13px; }
  .sm { font-size: 12px; color: var(--fg-3); padding-top: 4px; }
  .bad { color: var(--bad-ink); font-size: 12px; }
  ul { margin: 6px 0 0; padding: 0; list-style: none; max-height: 200px; overflow: auto; font-size: 12px; display: flex; flex-direction: column; gap: 3px; }
  li { display: flex; gap: 8px; flex-wrap: wrap; align-items: baseline; }
  .dfoot { display: flex; justify-content: flex-end; padding: 14px 22px; background: var(--panel-2); border-top: 1px solid var(--line); }
  @media (max-width: 860px) { .rdlg { width: calc(100% + 32px); margin: -16px; height: 100dvh; max-height: none; } }
</style>
