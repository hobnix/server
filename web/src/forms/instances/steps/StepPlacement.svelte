<script>
  // Step "Where the disk lives": the Incus storage pools with their free space (`hs sys ct pools`). The default pool is the fast one (SSD);
  // a bulk pool is one whose folder is on the data disks and only exists when an Incus pool was created there.
  import ChoiceList from '../../../ui/ChoiceList.svelte';
  import UsageBar from '../../../shell/UsageBar.svelte';
  import { poll, rows } from '../../../data.svelte.js';

  let { pool = $bindable('') } = $props();
  const pl = poll('/api/sys/ct/pools', 30000, 'ct-pools');
  // name, driver, kind (fast|bulk|other), free, total, source
  const pools = $derived(rows(pl).map((r) => ({ name: r[0], driver: r[1], kind: r[2], free: r[3], total: Number(r[4]), source: r[5] })));
  const word = { fast: 'Fast pool', bulk: 'Bulk pool', other: 'Pool' };
  const options = $derived(pools.map((p) => ({
    id: p.name === 'default' ? '' : p.name,
    label: `${word[p.kind] ?? 'Pool'} "${p.name}"`,
    text: p.name === 'default' ? 'The default: fast storage, snapshots like the other instances.' : `${p.driver}${p.source && p.source !== '-' ? ' on ' + p.source : ''}`,
    recommended: p.name === 'default',
  })));
</script>

{#if pl.loaded && !pools.length}
  <div class="hint">The pools could not be read; the disk goes on the default (fast) pool.</div>
{:else}
  <ChoiceList {options} value={pool} onpick={(id) => (pool = id)} label="Where the disk lives" />
  <div class="free">
    {#each pools as p (p.name)}
      <div class="fr"><span>{p.name}</span><UsageBar free={p.free} size={p.total} width={160} /></div>
    {/each}
  </div>
  {#if !pools.some((p) => p.kind === 'bulk')}<div class="hint">No pool on the bulk disks exists. A bulk pool has to be created in Incus first; the share folders can still be bound in the last step.</div>{/if}
{/if}

<style>
  .free { display: flex; flex-direction: column; gap: 6px; margin-top: 8px; font-size: 12.5px; }
  .fr { display: flex; align-items: center; gap: 12px; }
  .fr > span { min-width: 90px; color: var(--fg-2); }
  .hint { font-size: 12px; color: var(--fg-3); }
</style>
