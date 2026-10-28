<script>
  // The one line a card shows for what the status document does not carry today.
  let { children } = $props();
</script>

<div class="ny"><i class="ph ph-hourglass-simple-low"></i><span><b>Not available yet.</b> {@render children()}</span></div>

<style>
  .ny { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; color: var(--color-neutral-400); }
  .ny i { margin-top: 2px; color: var(--color-neutral-500); }
  b { font-weight: 500; color: var(--color-neutral-300); }
</style>
