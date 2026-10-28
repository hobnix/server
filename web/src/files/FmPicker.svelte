<script>
  // The location picker of a pane: a hard-edged popover in the look of the Combobox, grouped (Pools with their disks, Cache, Shares, Temporary disks).
  // A location that may not be the other side of the other pane's location stays visible and greyed with its reason (fm/pair), a read-only one is
  // marked (it can be a source, never a target).
  import { onMount } from 'svelte';
  import { tip } from '../ui/tooltip.svelte.js';
  import Chip from '../ui/Chip.svelte';
  import { sizeTxt } from '../pages/storage/pool.js';

  let { fm, side } = $props();
  let root;
  onMount(() => root?.focus({ preventScroll: true }));

  const cur = $derived(fm.panes[side].loc);
  const pools = $derived(fm.locs.filter((l) => l.kind === 'pool'));
  const diskOf = (p) => fm.locs.filter((l) => l.kind === 'disk' && l.pool === p.id.replace(/^pool:/, ''));
  const loose = $derived(fm.locs.filter((l) => l.kind === 'disk' && !pools.some((p) => p.id.replace(/^pool:/, '') === l.pool)));
  const groups = $derived([
    { title: 'Pools', rows: pools.flatMap((p) => [{ l: p, child: false }, ...diskOf(p).map((d) => ({ l: d, child: true }))]) },
    { title: 'Disks', rows: loose.map((l) => ({ l, child: false })) },
    { title: 'Bulk cache', rows: fm.locs.filter((l) => l.kind === 'cache').map((l) => ({ l, child: false })) },
    { title: 'Shares', rows: fm.locs.filter((l) => l.kind === 'share').map((l) => ({ l, child: false })) },
    { title: 'Temporary disks', rows: fm.locs.filter((l) => l.kind === 'temp').map((l) => ({ l, child: false })) },
    { title: 'Other', rows: fm.locs.filter((l) => !['pool', 'disk', 'cache', 'share', 'temp'].includes(l.kind)).map((l) => ({ l, child: false })) },
  ].filter((g) => g.rows.length));

  const pct = (l) => (l.size > 0 && Number.isFinite(l.free) ? Math.round((1 - l.free / l.size) * 100) : 0);
  const why = (l) => { const pr = fm.pairOf(side, l.id); return pr.ok ? '' : pr.reason || 'Not possible together with the other pane'; };
  function pick(l) { if (!why(l)) fm.pickLocation(side, l.id); }
  function key(e) {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); fm.picker = null; }
    else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const all = [...root.querySelectorAll('button.fmpr:not(.locked)')];
      const i = all.indexOf(document.activeElement);
      all[Math.max(0, Math.min(all.length - 1, i + (e.key === 'ArrowDown' ? 1 : -1)))]?.focus();
    }
  }
</script>

<button type="button" class="ddscrim" aria-label="Close location picker" tabindex="-1" onclick={() => (fm.picker = null)}></button>
<div class="fmpick" role="listbox" aria-label="Locations" tabindex="-1" bind:this={root} onkeydown={key}>
  {#each groups as g (g.title)}
    <div class="fmpg">
      <div class="eyebrow">{g.title}</div>
      {#each g.rows as { l, child } (l.id)}
        {@const no = why(l)}
        <button type="button" class="fmpr" class:cur={l.id === cur} class:child class:locked={!!no} role="option" aria-selected={l.id === cur} aria-disabled={!!no} use:tip={no} onclick={() => pick(l)}>
          <span class="pl"><b class="mono">{l.label}</b><Chip>{l.kind}</Chip>{#if l.fs}<span class="fsx">{l.fs}</span>{/if}{#if !l.writable}<Chip>read only</Chip>{/if}</span>
          <span class="pm">{l.size > 0 ? `${sizeTxt(l.size)}${Number.isFinite(l.free) ? `, ${sizeTxt(l.free)} free` : ''}` : ''}{#if !l.writable && l.reason} · {l.reason}{/if}</span>
          {#if no}
            <span class="pr2"><i class="ph ph-lock"></i>{no}</span>
          {:else if l.size > 0 && Number.isFinite(l.free)}
            <span class="pb"><span class="bar" class:hot={pct(l) >= 90}><span style="width:{pct(l)}%"></span></span><span class="pc">{pct(l)} %</span></span>
          {/if}
        </button>
      {/each}
    </div>
  {:else}
    <div class="fmpg"><div class="eyebrow">No locations</div></div>
  {/each}
</div>

<style>
  .ddscrim { position: fixed; inset: 0; z-index: 60; padding: 0; border: 0; background: transparent; cursor: default; }
  .fmpick { position: absolute; z-index: 61; left: 12px; right: 12px; top: 48px; max-height: min(420px, 70vh); overflow: auto; padding: 6px; background: var(--panel); border: 1px solid var(--line-2); box-shadow: var(--shadow); outline: none; }
  .fmpg + .fmpg { margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--line); }
  .fmpg > .eyebrow { padding: 4px 8px; }
  .fmpr { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 2px 12px; width: 100%; padding: 7px 8px; border: 0; background: none; color: var(--fg-2); font: inherit; text-align: left; cursor: pointer; }
  .fmpr:hover, .fmpr:focus-visible { background: var(--panel-2); }
  .fmpr.cur { background: color-mix(in oklch, var(--accent) 14%, transparent); }
  .fmpr.child { padding-left: 28px; }
  .fmpr.locked { opacity: 0.55; cursor: not-allowed; }
  .pl { display: flex; align-items: center; gap: 8px; color: var(--fg); min-width: 0; flex-wrap: wrap; }
  .fsx { font-size: 12px; color: var(--fg-3); }
  .pm { grid-column: 1; font-size: 12px; color: var(--fg-3); }
  .pb { grid-column: 2; grid-row: 1 / span 2; display: flex; align-items: center; gap: 8px; align-self: center; }
  .bar { position: relative; width: 70px; height: 8px; background: var(--panel-3); overflow: hidden; -webkit-mask-image: repeating-linear-gradient(90deg, #000 0 4px, transparent 4px 6px); mask-image: repeating-linear-gradient(90deg, #000 0 4px, transparent 4px 6px); }
  .bar span { position: absolute; left: 0; top: 0; bottom: 0; background: var(--ok); }
  .bar.hot span { background: var(--warn); }
  .pc { font: 12px var(--mono); color: var(--fg-2); min-width: 3em; text-align: right; }
  .pr2 { grid-column: 2; grid-row: 1 / span 2; display: flex; align-items: center; gap: 6px; color: var(--warn-ink); font-size: 12px; align-self: center; max-width: 220px; }
  @media (max-width: 860px) { .fmpick { position: fixed; left: 8px; right: 8px; top: 70px; } }
</style>
