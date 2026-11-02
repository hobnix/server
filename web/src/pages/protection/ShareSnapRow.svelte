<script>
  import { tip } from '../../ui/tooltip.svelte.js';
  import { poll, rows } from '../../data.svelte.js';
  import { openPlan, jobRunning } from '../../ui.svelte.js';
  import Button from '../../ui/Button.svelte';

  let { name, pool } = $props();
  // name, created, auto|manual, used
  const hist = poll(() => `/api/sys/shares/history/${encodeURIComponent(name)}`, 30000);
  // oldest first, whatever the order of the answer ("YYYY-MM-DD HH:MM" sorts as text)
  const snaps = $derived([...rows(hist)].sort((a, b) => (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0)));
  const auto = $derived(snaps.some((r) => r[2] === 'auto'));
  const newest = $derived(snaps.length ? snaps[snaps.length - 1][1] : '—');
  const newestName = $derived(snaps.length ? snaps[snaps.length - 1][0] : '');
</script>

<tr>
  <td style="padding:4px 8px">{name}</td>
  <td class="n400" style="padding:4px 8px">{pool}</td>
  <td style="padding:4px 8px">{#if hist.loaded && !hist.error}<button class="tagbtn tag {auto ? 'tag-accent' : 'tag-neutral'}" use:tip={auto ? 'Turn automatic snapshots off' : 'Turn automatic snapshots on'} onclick={() => openPlan('shares', [name, 'auto', '--to', auto ? 'off' : 'on'], `Automatic snapshots of ${name} ${auto ? 'off' : 'on'}`)}>{auto ? 'on' : 'off'}</button>{/if}</td>
  <td style="padding:4px 8px">{hist.loaded && !hist.error ? snaps.length : ''}</td>
  <td class="n300" style="padding:4px 8px">{hist.loaded && !hist.error ? newest : ''}</td>
  <td style="padding:2px 8px">
    <span class="acts">
      <Button variant="ghost" class="btn-icon" icon="camera" busy={jobRunning('shares', [name, 'snapshot'])} aria-label="Snapshot now" tooltip={'Snapshot now'} onclick={() => openPlan('shares', [name, 'snapshot'], `Snapshot ${name}`)} />
      <Button variant="ghost" class="btn-icon" icon="arrow-u-up-left" disabled={!newestName} busy={jobRunning('shares', [name, 'rollback', '--snapshot', newestName])} aria-label="Roll back to newest" tooltip={newestName ? `Roll back to ${newestName}` : 'No snapshot to roll back to'} onclick={() => openPlan('shares', [name, 'rollback', '--snapshot', newestName], `Roll back ${name}`)} />
    </span>
  </td>
</tr>

<style>
  td :global(.tag) { padding: 1px 8px; }
  .tagbtn { border: 0; cursor: pointer; font: inherit; }
  .n300 { color: var(--color-neutral-300); }
  .n400 { color: var(--color-neutral-400); }
  .acts { display: flex; justify-content: flex-end; gap: 2px; }
  .acts .btn { width: 26px; height: 26px; color: var(--color-neutral-300); }
</style>
