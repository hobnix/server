<script>
  import { tip } from '../../ui/tooltip.svelte.js';
  // A list of free disks to pick from: checkboxes, or radio buttons with `single`. `picked` is a list of by-id names.
  import { shortId } from './disks.js';

  let { disks, loaded = true, picked = $bindable([]), single = false, empty = 'No free disks.' } = $props();

  const warnNote = (n) => /encrypt|old ZFS/.test(n);

  function toggle(id) {
    if (single) picked = [id];
    else picked = picked.includes(id) ? picked.filter((x) => x !== id) : [...picked, id];
  }
</script>

<div class="list" role="group" aria-label="Free disks">
  {#each disks as d (d.id)}
    <label class="row" class:on={picked.includes(d.id)}>
      <input type={single ? 'radio' : 'checkbox'} name="free-disk" checked={picked.includes(d.id)} onchange={() => toggle(d.id)} />
      <span class="main">
        <code use:tip={d.id}>{shortId(d.id)}</code>
        <span class="meta">{d.space ?? d.size} · {d.type}</span>
      </span>
      {#each d.notes as n}<span class="tag {warnNote(n) ? 'tag-accent-2' : 'tag-neutral'}" style="padding:1px 7px;white-space:nowrap">{n}</span>{/each}
    </label>
  {:else}
    <div class="empty">{loaded ? empty : 'Loading…'}</div>
  {/each}
</div>

<style>
  .list { display: flex; flex-direction: column; border: 1px solid var(--color-divider); border-radius: var(--r); overflow: hidden; max-height: 240px; overflow-y: auto; }
  .row { display: flex; align-items: center; gap: 10px; padding: 8px 10px; cursor: pointer; font-size: 13px; flex-wrap: wrap; }
  .row + .row { border-top: 1px solid var(--color-divider); }
  .row:hover { background: color-mix(in srgb, var(--color-text) 6%, transparent); }
  .row.on { background: var(--color-accent-900); }
  .row input { accent-color: var(--color-accent); }
  .main { display: flex; flex-direction: column; gap: 1px; min-width: 0; flex: 1; }
  code { font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta { font-size: 11.5px; color: var(--color-neutral-400); }
  .empty { padding: 12px; font-size: 12.5px; color: var(--color-neutral-500); }
</style>
