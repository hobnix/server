<script>
  // The key of one node and the line its owner has to put on that server (hs sys node keyline <name>: only the PUBLIC half). Shows what is missing
  // when there is no key yet, with the button that makes it. `name` is the node. Used in the Nodes drawer and on the Summary of a node that never answered.
  import { poll, rows } from '../../data.svelte.js';
  import { openPlan } from '../../ui.svelte.js';
  import { keyInfo } from './nodes.js';
  import Banner from '../../ui/Banner.svelte';

  let { name, canChange = true } = $props();
  const kl = poll(() => `/api/sys/node/keyline/${encodeURIComponent(name)}`, 8000);
  const info = $derived(keyInfo(rows(kl)));
  let copied = $state(false);
  async function copy() {
    try { await navigator.clipboard.writeText(info.line); copied = true; setTimeout(() => (copied = false), 2000); } catch { /* the line is selectable */ }
  }
</script>

{#if !kl.loaded}
  <div class="muted">Reading the key…</div>
{:else if kl.error && !kl.data}
  <Banner tone="bad">The key could not be read: {kl.error.message}</Banner>
{:else if info.key === 'locked'}
  <Banner tone="warn">The key lives in the closed vault. Unlock the storage first (<code>hs unlock</code>).</Banner>
{:else if info.key !== 'ok'}
  <div class="stack">
    <div class="muted">There is no key for {name} yet. The key lets this server ask for the status of {name}, and nothing else.</div>
    {#if canChange}<button class="btn btn-primary sm" onclick={() => openPlan('node', ['key', name], `Make the key for ${name}`)}><i class="ph ph-key"></i>Make the key</button>{/if}
  </div>
{:else}
  <div class="stack">
    <div class="muted">The owner of {name} puts this line into: <b>{info.file}</b>. Then {name} answers status requests from this server, and nothing else.</div>
    <pre class="line">{info.line}</pre>
    <div class="row">
      <button class="btn sm" onclick={copy}><i class="ph ph-{copied ? 'check' : 'copy'}"></i>{copied ? 'Copied' : 'Copy the line'}</button>
      {#if canChange}<button class="btn btn-ghost sm" onclick={() => openPlan('node', ['key', name, '--new'], `New key for ${name}`)}><i class="ph ph-arrows-clockwise"></i>New key…</button>{/if}
    </div>
  </div>
{/if}

<style>
  .stack { display: flex; flex-direction: column; gap: 10px; }
  .muted { color: var(--fg-2); font-size: 13px; }
  .line { margin: 0; padding: 10px 12px; border: 1px solid var(--line); border-radius: var(--r); background: var(--panel-2, var(--panel)); font: 12px var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; user-select: all; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; }
</style>
