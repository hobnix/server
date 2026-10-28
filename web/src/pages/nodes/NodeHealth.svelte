<script>
  // Health of a REMOTE node: what its status document carries (the number of open problems, failed units, Tailscale). The list of the problems
  // themselves is not in the document yet (the word `health` of ); until then this page says how many and where to look.
  import { poll } from '../../data.svelte.js';
  import StatusDot from '../../ui/StatusDot.svelte';
  import Kv from '../../ui/Kv.svelte';
  import PageHeader from '../../shell/PageHeader.svelte';
  import PageState from '../../shell/PageState.svelte';
  import { since } from './nodes.js';

  let { node } = $props();
  const st = poll(() => `/api/sys/node/status/${encodeURIComponent(node.name)}`, 30000);
  const d = $derived(st.data);
  const n = $derived(d?.problems);
</script>

<PageHeader title="Health" crumb={node.name} sub="The state of {node.name} as it reports it.">
  {#snippet actions()}
    {#if d}<StatusDot state={n > 0 ? 'warn' : n === 0 ? 'ok' : 'off'} label={n == null ? 'unknown' : n === 0 ? 'no problems' : `${n} problem${n === 1 ? '' : 's'}`} />{/if}
  {/snippet}
</PageHeader>
<PageState loading={!st.loaded} error={st.error?.message} hasData={d != null} empty={false}>
  <div class="card" style="padding:0">
    <Kv items={[
      { k: 'Open problems', v: n }, { k: 'Failed units', v: d?.failed_units }, { k: 'Tailscale', v: typeof d?.tailscale === 'string' ? d.tailscale : '' },
      { k: 'Disk health', v: d?.smart ? `${d.smart.disks} disks, ${d.smart.findings?.length ? d.smart.findings.join(', ') : 'no findings'}` : '' },
      { k: 'Last answer', v: d ? since(d.time) : '' }, { k: 'Storage', v: d?.locked ? 'locked' : d ? 'open' : '' },
    ]} />
  </div>
  <p class="muted">The problems themselves are listed on {node.name} (<code>hs health</code> there). This server does not change anything on it.</p>
</PageState>

<style>
  .muted { color: var(--fg-3); font-size: 12.5px; margin: 0; }
</style>
