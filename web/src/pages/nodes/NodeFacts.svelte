<script>
  // The read only pages of a peer: Storage, Instances and Backup, each a summary of the node's status document.
  // One component, the address says which. No button: what the other server allows is its owner's decision.
  import { route } from '../../route.svelte.js';
  import { poll } from '../../data.svelte.js';
  import { duration } from '../../format.js';
  import StatusDot from '../../ui/StatusDot.svelte';
  import Banner from '../../ui/Banner.svelte';
  import PageHeader from '../../shell/PageHeader.svelte';
  import PageState from '../../shell/PageState.svelte';
  import UsageBar from '../../shell/UsageBar.svelte';
  import { facts, since } from './nodes.js';

  let { node } = $props();
  const st = poll(() => `/api/sys/node/status/${encodeURIComponent(node.name)}`, 30000);
  const d = $derived(st.data);
  const f = $derived(facts(d));
  const which = $derived(route.path.startsWith('/protection') ? 'backup' : route.path === '/instances' ? 'instances' : 'storage');
  const title = $derived({ backup: 'Backup', instances: 'Instances', storage: 'Storage' }[which]);
  const empty = $derived(d != null && !f.locked && (which === 'storage' ? !f.pools.length : which === 'instances' ? !f.instances : !f.backup));
</script>

<PageHeader {title} crumb={node.name} sub="A summary from the status document of {node.name}, read only. Last answer: {d ? since(d.time) : 'never'}." />
{#if f.locked}<Banner tone="warn" icon="lock">The storage on {node.name} is locked; its pools and instances are not available until it is unlocked there.</Banner>{/if}
<PageState loading={!st.loaded} error={st.error?.message} hasData={d != null} {empty} emptyIcon="tray" emptyTitle="The document has nothing about this" emptyText="{node.name} does not report it (yet).">
  <div class="card pad">
    {#if which === 'storage'}
      {#each f.pools as p (p.name)}
        <div class="r"><b>{p.name}</b>{#if p.health}<StatusDot state={p.health === 'ONLINE' ? 'ok' : 'warn'} label={p.health.toLowerCase()} />{/if}<UsageBar used={p.used} size={p.size} /></div>
      {/each}
    {:else if which === 'instances'}
      <div class="r"><b>{f.instances?.running}</b> of {f.instances?.total} instances are running</div>
    {:else}
      <div class="r"><StatusDot state={f.backup?.status === 'ok' ? 'ok' : 'warn'} label={f.backup?.status || 'unknown'} />{#if f.backup?.age_s != null}<span class="muted">last backup {duration(f.backup.age_s)} ago</span>{/if}</div>
    {/if}
  </div>
</PageState>

<style>
  .pad { padding: 14px 16px; display: flex; flex-direction: column; gap: 12px; }
  .r { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
  .muted { color: var(--fg-3); font-size: 12.5px; }
</style>
