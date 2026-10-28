<script>
  // The tab row of a page (not of a drawer: that is Drawer.svelte's own): Network uses it for Overview, DNS, Ports, Router, Remote shares.
  //   <PageTabs tabs={[{ id: 'dns', label: 'DNS' }]} {tab} onpick={(id) => go('/network?tab=' + id)} />  (or bind:tab)
  import { tr } from "../i18n.js";
  let { tabs = [], tab = $bindable(''), onpick = null } = $props();
  const active = $derived(tab || tabs[0]?.id || '');
</script>

<div class="ptabs" role="tablist">
  {#each tabs as t (t.id)}
    <button class="pt" class:on={active === t.id} role="tab" aria-selected={active === t.id} onclick={() => { tab = t.id; onpick?.(t.id); }}>{tr(t.label)}</button>
  {/each}
</div>

<style>
  .ptabs { display: flex; gap: 2px; border-bottom: 1px solid var(--line); overflow-x: auto; overflow-y: hidden; }
  .pt { position: relative; flex: none; height: 38px; padding: 0 14px; border: 0; background: none; color: var(--fg-2); font-weight: 500; }
  .pt:hover, .pt.on { color: var(--fg); }
  .pt.on::after { content: ''; position: absolute; left: 8px; right: 8px; bottom: 0; height: 2px; background: linear-gradient(90deg, var(--h2), var(--h1), var(--h4)); }
</style>
