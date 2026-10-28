<script>
  // Summary of a REMOTE node (peer, or any node without a page of its own): what its status document says (read over SSH, the word status only) and what
  // `hs node show` knows. A node that never answered shows how to get it to (the key and the line its owner has to allow). Read only: no button changes it.
  import { poll, rows } from '../data.svelte.js';
  import { duration } from '../format.js';
  import StatusDot from '../ui/StatusDot.svelte';
  import Chip from '../ui/Chip.svelte';
  import Kv from '../ui/Kv.svelte';
  import Banner from '../ui/Banner.svelte';
  import PageHeader from './PageHeader.svelte';
  import PageState from './PageState.svelte';
  import UsageBar from './UsageBar.svelte';
  import NodeKey from '../pages/nodes/NodeKey.svelte';
  import { since, facts } from '../pages/nodes/nodes.js';

  let { node } = $props();
  const url = (w) => `/api/sys/node/${w}/${encodeURIComponent(node.name)}`;
  const show = poll(() => url('show'), 30000);
  const st = poll(() => url('status'), 30000);
  const d = $derived(st.data);
  const info = $derived(Object.fromEntries(rows(show).filter((r) => r[0] !== 'command').map((r) => [r[0], r[1]])));
  const f = $derived(facts(d));
  const noKey = $derived(info.key === 'missing' || info.key === 'locked' || /^(no key yet|key locked)/.test(node.dot?.title ?? ''));
  const items = $derived([
    { k: 'Host', v: info.host ? `${info.host}${info.port ? `:${info.port}` : ''}` : '' },
    { k: 'Last answer', v: d ? since(d.time) : 'never' },
    { k: 'Up for', v: d?.uptime_s != null ? duration(d.uptime_s) : '' },
    { k: 'Load', v: Array.isArray(d?.load) ? d.load.join(' ') : '' },
    { k: 'Problems', v: d?.problems ?? '' },
    { k: 'Parts', v: Array.isArray(d?.capabilities) ? d.capabilities.join(', ') : '' },
  ]);
</script>

<PageHeader title={node.name} crumb="Servers" sub="Read only: this server only asks for the status of {node.name}.">
  {#snippet actions()}<Chip>{node.kind}</Chip><StatusDot state={node.dot?.state ?? 'off'} label={node.dot?.title ?? 'no data'} />{/snippet}
</PageHeader>

{#if f.locked}<Banner tone="warn" icon="lock">The storage on {node.name} is locked, so its pools and instances are not available until it is unlocked there.</Banner>{/if}

{#if noKey && !d}
  <div class="card pad"><h3>Not connected yet</h3><NodeKey name={node.name} /></div>
{:else}
  <PageState loading={!st.loaded} error={st.error?.message} hasData={d != null} empty={false}>
    <div class="card" style="padding:0"><Kv {items} /></div>
    {#if f.pools.length || f.instances || f.backup}
      <div class="card pad grid">
        {#each f.pools as p (p.name)}
          <div><div class="k">Pool {p.name}</div><UsageBar used={p.used} size={p.size} /></div>
        {/each}
        {#if f.instances}<div><div class="k">Instances</div><b>{f.instances.running}</b> of {f.instances.total} running</div>{/if}
        {#if f.backup}<div><div class="k">Backup</div><StatusDot state={f.backup.status === 'ok' ? 'ok' : 'warn'} label={f.backup.status || 'unknown'} />{#if f.backup.age_s != null} <span class="muted">{duration(f.backup.age_s)} ago</span>{/if}</div>{/if}
      </div>
    {/if}
  </PageState>
{/if}

<style>
  .pad { padding: 14px 16px; display: flex; flex-direction: column; gap: 10px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
  .k { font: 500 11px var(--mono); letter-spacing: 0.06em; text-transform: uppercase; color: var(--fg-3); margin-bottom: 4px; }
  .muted { color: var(--fg-3); font-size: 12.5px; }
  h3 { margin: 0; font-size: 15px; font-weight: 600; }
</style>
