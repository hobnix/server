<script>
  // The last step: what is still open (it stays on the Setup page). The page's Finish calls save().
  import { poll, rows } from '../data.svelte.js';
  import { openPlan } from '../ui.svelte.js';
  let { save = $bindable(null) } = $props();
  const list = poll('/api/sys/setup/list', 30000);
  // id, state, label
  const open = $derived(rows(list).filter((r) => r[0] !== 'finished' && r[1] === 'open').map((r) => ({ id: r[0], label: r[2] })));
  save = () => { openPlan('setup', ['wizard-done'], 'Finish the first setup'); return false; };
</script>

{#if open.length}
  <p class="muted">Still open:</p>
  <ul>{#each open as o (o.id)}<li>{o.label}</li>{/each}</ul>
{:else}
  <p class="muted">Nothing is open.</p>
{/if}
