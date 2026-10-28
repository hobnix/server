<script>
  // The one usage display of a list: a SEGMENTED bar (4 px segments, 2 px gaps) of a FIXED width (so every row lines up, whatever the column or the
  // text) and "2.00 / 4.00 TB" (used / size) after it. `free` in bytes; "-" or empty = unknown: an empty bar and only the size. `used` (bytes) can
  // be given instead of `free`. Green by default, amber over 90 % (the design has no red here; over 97 % the amber turns orange-red).
  // `width` is the length of the bar in px (default 120); `block` makes the bar fill its container (cards) and puts the text under it as a row.
  //   <UsageBar used={p.used} size={p.size} />   <UsageBar free={d.free} size={d.size} width={96} />
  import { spaceTxt } from '../pages/storage/pool.js';
  let { free = null, used = null, size, width = 120, block = false } = $props();
  const isNum = (v) => v != null && v !== '' && v !== '-' && !isNaN(Number(v));
  const freeB = $derived(isNum(free) ? Number(free) : isNum(used) && size > 0 ? size - Number(used) : null);
  const known = $derived(freeB !== null && size > 0);
  const pct = $derived(known ? Math.max(0, Math.min(100, Math.round((1 - freeB / size) * 100))) : 0);
  const hot = $derived(pct >= 90);
</script>

<div class="ub" class:hot class:block>
  <div class="ub-track" class:unknown={!known} style={block ? undefined : `width:${width}px`} role="meter" aria-valuemin="0" aria-valuemax="100" aria-valuenow={known ? pct : undefined} aria-label="Used space">
    {#if known}<div class="ub-fill" style="width:{pct}%"></div>{/if}
  </div>
  <span class="ub-txt">{spaceTxt(freeB, size)}</span>
</div>

<style>
  .ub { display: flex; align-items: center; gap: 10px; }
  .ub.block { flex-direction: column; align-items: stretch; gap: 6px; }
  .ub-track { position: relative; flex: none; height: 10px; background: var(--panel-3); overflow: hidden;
    -webkit-mask-image: repeating-linear-gradient(90deg, #000 0 4px, transparent 4px 6px); mask-image: repeating-linear-gradient(90deg, #000 0 4px, transparent 4px 6px); }
  .block .ub-track { width: 100%; }
  /* a phone: the text goes under the bar, so a list row with a usage bar stays narrow */
  @media (max-width: 860px) { .ub:not(.block) { flex-direction: column; align-items: flex-start; gap: 4px; } .ub-track { max-width: 100%; } .ub-txt { min-width: 0; } }
  .ub-track.unknown { opacity: 0.5; }
  .ub-fill { position: absolute; left: 0; top: 0; bottom: 0; background: linear-gradient(90deg, color-mix(in oklch, var(--ok) 70%, var(--panel-3)), var(--ok)); }
  .hot .ub-fill { background: linear-gradient(90deg, var(--warn), oklch(0.74 0.17 52)); }
  .ub-txt { font: 12px var(--mono); color: var(--fg-2); white-space: nowrap; font-variant-numeric: tabular-nums; min-width: 9.5em; }
  .block .ub-txt { min-width: 0; }
  .hot .ub-txt { color: var(--warn-ink); }
  /* a selected table row: the track switches to a neutral overlay so the bar stays readable on the tinted row */
  :global(tr.selected) .ub-track { background: color-mix(in oklch, var(--fg) 24%, transparent); }
</style>
