<script>
  // The "pending rebuild" banner above every page of this node: the machine.toml changes that were saved and wait for a rebuild, listed, with one
  // button that applies them all (staged apply, docs/adr/0002 rule 4). Nothing shows while the queue is empty.
  import Button from '../ui/Button.svelte';
  import Banner from '../ui/Banner.svelte';
  import { poll } from '../data.svelte.js';
  import { openPlan, jobRunning } from '../ui.svelte.js';
  import { pendingItems, describe, headline } from './pending.js';

  const list = poll('/api/sys/rebuild/pending', 15000);
  const items = $derived(pendingItems(list.data?.rows));
  let open = $state(false);
</script>

{#if items.length}
  <Banner tone="warn" icon="hammer">
    <b>{headline(items.length)}.</b> They are saved in machine.toml; the server runs as before until it is rebuilt.
    <button class="lnk" onclick={() => (open = !open)}>{open ? 'Hide the list' : 'Show the list'}</button>
    {#if open}
      <ul class="pend">{#each items as it}<li><code>{describe(it)}</code></li>{/each}</ul>
    {/if}
    {#snippet action()}
      <Button size="sm" variant="primary" icon="hammer" busy={jobRunning('system', ['rebuild'])} busyLabel="Rebuilding…" tooltip={'Apply all of them with one rebuild (shows the plan)'} onclick={() => openPlan('system', ['rebuild'], 'Rebuild now')}>Rebuild now…</Button>
    {/snippet}
  </Banner>
{/if}

<style>
  .lnk { background: none; border: 0; padding: 0 0 0 6px; color: var(--accent-ink); cursor: pointer; font: inherit; text-decoration: underline; }
  .pend { margin: 6px 0 0; padding-left: 18px; font-size: 12.5px; }
</style>
