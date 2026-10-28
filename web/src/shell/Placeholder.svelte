<script>
  import { route } from '../route.svelte.js';
  import { titleOf } from '../nav.js';

  const trail = $derived(titleOf(route.path));
</script>

<div class="page">
  <div class="crumb">{trail ? trail.slice(0, -1).join(' / ') : ''}</div>
  <h3 style="margin:0">{trail ? trail[trail.length - 1] : 'Page not found'}</h3>
  <div class="card elev-sm" style="max-width:520px">
    <div style="display:flex;gap:10px;align-items:flex-start">
      <i class="ph ph-hammer" style="font-size:18px;color:var(--color-neutral-400);margin-top:1px"></i>
      <div style="color:var(--color-neutral-300)">
        {trail ? 'This page is not built yet. Everything it will show can be read on the server with the hs command in the meantime.' : 'There is no such page.'}
      </div>
    </div>
  </div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .crumb { font-size: 11px; color: var(--color-neutral-500); min-height: 14px; }
  h3 { font-size: 20px; }
</style>
