<script>
  // proxyserver Tailscale (design screen 20): the parts the status document supports.
  import { bytes } from '../format.js';
  import { useProxy } from './proxy/proxy.svelte.js';
  import { tailscaleInfo } from './proxy/status.js';
  import ProxyHead from './proxy/ProxyHead.svelte';
  import ProxyGate from './proxy/ProxyGate.svelte';
  import NotYet from './proxy/NotYet.svelte';

  const px = useProxy();
  const d = $derived(px.doc);
  const ts = $derived(d?.tailscale);
  const info = $derived(tailscaleInfo(d));
  const facts = $derived([
    { label: 'State', value: ts ?? '–', sub: ts ? 'BackendState' : 'not available' },
    ...(info.address ? [{ label: 'Address', value: info.address, sub: info.tag ?? 'no tag' }] : []),
    ...(info.latency != null ? [{ label: 'Latency', value: `${Math.round(info.latency)} ms`, sub: 'to the homeserver' }] : []),
    { label: 'Received', value: d?.net_tailscale ? bytes(d.net_tailscale.rx_bytes) : '–', sub: d?.net_tailscale ? `${d.net_tailscale.iface}, since boot` : 'not available' },
    { label: 'Sent', value: d?.net_tailscale ? bytes(d.net_tailscale.tx_bytes) : '–', sub: d?.net_tailscale ? `${d.net_tailscale.iface}, since boot` : 'not available' },
  ]);
</script>

<div class="page">
  <ProxyHead {px} title="Tailscale" sub="the ACL lives in the Tailscale admin console, not in the repo" />
  <ProxyGate {px}>
    <div class="facts">
      {#each facts as f}
        <div class="card elev-sm f"><div class="fl">{f.label}</div><div class="fv">{f.value}</div><div class="fs">{f.sub}</div></div>
      {/each}
    </div>
    <div class="card elev-sm c">
      <div class="ct">proxyserver may reach</div>
      {#if info.mayReach.length}
        {#each info.mayReach as r}<div class="row"><span class="mono">{r.target}</span><span class="fs">{r.ports ?? ''}</span></div>{/each}
      {:else}
        <NotYet>The access list is not in the status document. Read it in the Tailscale admin console.</NotYet>
      {/if}
    </div>
    <div class="card elev-sm c">
      <div class="ct">Never reachable from proxyserver</div>
      {#if info.neverReach.length}
        {#each info.neverReach as r}<div class="row"><span class="mono">{r.target}</span><span class="fs">{r.why ?? ''}</span></div>{/each}
      {:else}
        <NotYet>Same: the status document does not carry the list of targets that are blocked.</NotYet>
      {/if}
    </div>
  </ProxyGate>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
  .f { padding: 12px 14px; gap: 2px; }
  .fl { font-size: 12px; color: var(--color-neutral-400); }
  .fv { font-size: 16px; font-weight: 500; }
  .fs { font-size: 12px; color: var(--color-neutral-500); }
  .c { padding: 12px 14px; gap: 8px; }
  .ct { font-size: 14px; font-weight: 500; }
  .row { display: flex; gap: 12px; align-items: baseline; padding: 4px 0; box-shadow: inset 0 -1px 0 color-mix(in srgb, var(--color-text) 6%, transparent); }
  .mono { font-family: ui-monospace, Menlo, monospace; font-size: 12px; }
</style>
