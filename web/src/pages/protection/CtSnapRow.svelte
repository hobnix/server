<script>
  import { tip } from '../../ui/tooltip.svelte.js';
  import { poll, rows } from '../../data.svelte.js';
  import { openPlan } from '../../ui.svelte.js';

  let { name } = $props();
  // name, created
  const csn = poll(() => `/api/sys/ct/snapshots/${encodeURIComponent(name)}`, 15000);
  // oldest first, whatever the order of the answer ("YYYY-MM-DD HH:MM" sorts as text)
  const snaps = $derived([...rows(csn)].sort((a, b) => (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0)));
  const newestName = $derived(snaps.length ? snaps[snaps.length - 1][0] : '');
  const ok = $derived(csn.loaded && !csn.error);
</script>

<tr>
  <td style="padding:4px 8px"><span class="row7"><i class="ph ph-cube"></i>{name}</span></td>
  <td style="padding:4px 8px">{ok ? snaps.length : ''}</td>
  <td class="n300" style="padding:4px 8px">{ok ? (snaps.length ? snaps[snaps.length - 1][1] : '—') : ''}</td>
  <td class="n400" style="padding:4px 8px">{ok ? (snaps.length ? snaps[0][1] : '—') : ''}</td>
  <td style="padding:2px 8px">
    <span class="acts">
      <button class="btn btn-ghost btn-icon" aria-label="Snapshot now" use:tip={'Snapshot now'} onclick={() => openPlan('ct', [name, 'snapshot'], `Snapshot ${name}`)}><i class="ph ph-camera"></i></button>
      <button class="btn btn-ghost btn-icon" disabled={!newestName} aria-label="Restore newest" use:tip={newestName ? `Restore ${newestName}` : 'No snapshot to restore'} onclick={() => openPlan('ct', [name, 'restore', '--snapshot', newestName], `Restore ${name}`)}><i class="ph ph-arrow-u-up-left"></i></button>
    </span>
  </td>
</tr>

<style>
  .row7 { display: flex; align-items: center; gap: 7px; }
  .row7 i { color: var(--color-neutral-400); }
  .n300 { color: var(--color-neutral-300); }
  .n400 { color: var(--color-neutral-400); }
  .acts { display: flex; justify-content: flex-end; gap: 2px; }
  .acts .btn { width: 26px; height: 26px; color: var(--color-neutral-300); }
</style>
