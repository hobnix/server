<script>
  // The list-and-drawer layout: the list on the left, the Drawer on the right while something is selected. Under 1100 px the drawer drops below the
  // list, under 860 px it covers the page (Drawer.svelte). Optional list columns hide while a drawer is open on a mid-size screen.
  //   <Split open={!!sel}>{#snippet list()}<Table .../>{/snippet}{#snippet side()}<Drawer ...>...</Drawer>{/snippet}</Split>
  let { open = false, list, side } = $props();
</script>

<div class="split" class:hasd={open}>
  <div class="listc">{@render list?.()}</div>
  {#if open}{@render side?.()}{/if}
</div>

<style>
  .split { display: flex; gap: 16px; align-items: flex-start; }
  .listc { flex: 1; min-width: 0; }
  @media (max-width: 1100px) { .split { flex-direction: column; align-items: stretch; } }
  @media (min-width: 861px) and (max-width: 1400px) { .hasd :global(.opt) { display: none; } }
</style>
