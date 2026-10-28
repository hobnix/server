<script>
  // proxyserver Settings (design screen 20): the VPS's machine.nix keys are not in the status document, so there is nothing to list.
  import { useProxy } from './proxy/proxy.svelte.js';
  import ProxyHead from './proxy/ProxyHead.svelte';
  import ProxyGate from './proxy/ProxyGate.svelte';

  import { settingsOf } from './proxy/status.js';
  import { brief } from './proxy/proxy.svelte.js';

  const px = useProxy();
  const items = $derived(settingsOf(px.doc));
</script>

<div class="page">
  <ProxyHead {px} title="Settings" sub="machine.nix on the VPS · not in git" />
  <ProxyGate {px}>
    <div class="card elev-sm c">
      <i class="ph ph-lock-simple"></i>
      <div>
        The settings of the proxyserver live in its own <code>machine.nix</code> on the VPS and are read-only here. Change them there and run <code>vps update</code>.
        <div class="n">Secrets are files under /var/lib/proxyserver/, never values in the interface.</div>
      </div>
    </div>
    {#if items.length}
      <div class="card elev-sm list">
        {#each items as [k, v]}<div class="row"><span class="k">{k}</span><span class="v">{brief(v)}</span></div>{/each}
      </div>
    {/if}
  </ProxyGate>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .c { flex-direction: row; gap: 10px; align-items: flex-start; padding: 14px 16px; max-width: 620px; color: var(--color-neutral-300); font-size: 13px; }
  .c i { font-size: 18px; color: var(--color-neutral-400); margin-top: 1px; }
  .list { padding: 8px 16px; max-width: 620px; }
  .row { display: flex; gap: 12px; padding: 6px 0; font-size: 12.5px; box-shadow: inset 0 -1px 0 color-mix(in srgb, var(--color-text) 6%, transparent); }
  .k { width: 200px; flex: none; font-family: ui-monospace, Menlo, monospace; color: var(--color-neutral-400); }
  .v { min-width: 0; overflow: hidden; text-overflow: ellipsis; font-family: ui-monospace, Menlo, monospace; }
  .n { margin-top: 6px; font-size: 11.5px; color: var(--color-neutral-500); }
</style>
