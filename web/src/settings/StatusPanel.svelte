<script>
  // The status block of a capability page: the rows of a `sys` read named by [settings] status in the capability manifest. One line per check:
  // id, state, detail, reason. A row is `id state fix detail reason` (a `-` is empty). Nothing here names a capability.
  import StatusDot from '../ui/StatusDot.svelte';
  import Chip from '../ui/Chip.svelte';
  import { poll, rows } from '../data.svelte.js';

  // read: the words of the sys read ("gateway health"), polled as /api/sys/gateway/health
  let { read = '' } = $props();
  const st = poll(() => (read ? `/api/sys/${read.split(/\s+/).join('/')}` : ''), 60000);
  const dot = { ok: 'ok', warn: 'warn', fail: 'bad', off: 'off' };
  const list = $derived(rows(st).filter((r) => r.length >= 5).map((r) => ({ id: r[0], state: r[1], fix: r[2], detail: r[3], reason: r[4] })));
</script>

<div class="card panel">
  <div class="title">Status</div>
  {#if list.length}
    {#each list as r (r.id)}
      <div class="row">
        <StatusDot state={dot[r.state] ?? 'off'} label={r.state} />
        <span class="id mono">{r.id}</span>
        <span class="reason">{r.reason}</span>
        {#if r.detail !== '-'}<Chip>{r.detail}</Chip>{/if}
      </div>
    {/each}
  {:else if st.error}
    <div class="muted">The checks could not be read.</div>
  {:else}
    <div class="muted">Checking…</div>
  {/if}
</div>

<style>
  .panel { display: flex; flex-direction: column; gap: 8px; padding: 14px 16px; }
  .title { font-weight: 600; }
  .row { display: grid; grid-template-columns: 90px 80px 1fr auto; align-items: center; gap: 12px; }
  .id { color: var(--fg-2); }
  .reason { color: var(--fg-1); min-width: 0; overflow-wrap: anywhere; }
  .muted { font-size: 12px; color: var(--fg-3); }
  @media (max-width: 860px) { .row { grid-template-columns: 1fr; gap: 2px; } }
</style>
