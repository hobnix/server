<script>
  // Key-value cells for a drawer or a card: two per row, thin lines between. `items`: [{ k, v }] (v may be a number or a string; empty/null shows a dash).
  //   <Kv items={[{ k: 'Layout', v: 'raidz1' }, { k: 'Size', v: '4 TB' }]} />
  let { items = [], cols = 2 } = $props();
</script>

<div class="kv" style:--cols={cols}>
  {#each items as it (it.k)}
    <div class="c"><div class="k">{it.k}</div><div class="v">{it.v === null || it.v === undefined || it.v === '' ? '–' : it.v}</div></div>
  {/each}
</div>

<style>
  .kv { display: flex; flex-wrap: wrap; border-bottom: 1px solid var(--line); }
  .c { flex: 0 0 calc(100% / var(--cols)); padding: 10px 16px; min-width: 0; border-bottom: 1px solid var(--line); }
  .k { font: 500 11px var(--mono); letter-spacing: 0.06em; text-transform: uppercase; color: var(--fg-3); }
  .v { margin-top: 2px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; }
</style>
