<script>
  // Shows the page only when the proxyserver's document is there; otherwise the one calm card that says why.
  let { px, children } = $props();
</script>

{#if px.state === 'ok'}
  {@render children()}
{:else}
  <div class="card elev-sm gate">
    <i class="ph {px.state === 'off' ? 'ph-plugs' : px.state === 'down' ? 'ph-plugs' : 'ph-circle-notch'}" style="font-size:18px;color:var(--color-neutral-400);margin-top:1px"></i>
    <div>
      {#if px.state === 'off'}
        <div class="t">proxyserver is not configured</div>
        <div class="n">Set <code>proxyStatusUrl</code> in machine.toml (the address of its status document, for example <code>http://proxyserver:9740/status.json</code>), then run <code>hs rebuild</code>.</div>
      {:else if px.state === 'down'}
        <div class="t">proxyserver is not reachable</div>
        <div class="n">{px.error || 'No answer'}. The status document is read over Tailscale (deckApi on the VPS).</div>
      {:else}
        <div class="t">Loading…</div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .gate { flex-direction: row; gap: 10px; align-items: flex-start; padding: 14px 16px; max-width: 560px; }
  .t { font-size: 14px; font-weight: 500; }
  .n { margin-top: 3px; font-size: 12.5px; color: var(--color-neutral-400); }
</style>
