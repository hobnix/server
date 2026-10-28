<script>
  // The overview of a group in the tree (Storage, Identity, Protection, Operations): one card per child page with the note the tree shows,
  // and for Storage the capacity of the two pools on top. Nothing is read here that the tree does not read already.
  import { route, go } from '../route.svelte.js';
  import { tree } from '../nav.js';
  import { bytes } from '../format.js';

  let { deck, meta = {} } = $props();

  const find = (items, path) => {
    for (const it of items) {
      if (it.path === path) return it;
      const r = it.children && find(it.children, path);
      if (r) return r;
    }
    return null;
  };
  const node = $derived(find(tree, route.path));
  const locked = $derived(!!deck?.data?.locked);

  // a child may be a group itself (bulk and fast hold Disks and Shares): its pages are listed under it
  const cards = $derived((node?.children ?? []).map((c) => ({ ...c, kids: c.children ?? [] })));
  const dim = (c) => locked && c.storage;
  const note = (it) => (dim(it) ? { text: 'locked', warn: true } : meta[it.path] ?? null);
  const shown = (n) => n.text ?? '●';

  const pools = $derived(['bulk', 'fast'].map((n) => ({ name: n, ...(deck?.data?.pools?.[n] ?? {}) })).filter((p) => p.size > 0));
  const pct = (p) => Math.round((p.used / p.size) * 100);
  const isStorage = $derived(route.path === '/storage');
</script>

<div class="page">
  <div class="crumb">homeserver</div>
  <h3 style="margin:0">{node?.label ?? 'Overview'}</h3>

  {#if isStorage && pools.length && !locked}
    <div class="two">
      {#each pools as p}
        <button class="card elev-sm pool" onclick={() => go(`/storage/${p.name}`)}>
          <div class="row"><i class="ph ph-{p.name === 'fast' ? 'lightning' : 'cylinder'}" style="color:var(--color-accent)"></i><span class="nm">{p.name}</span><span class="sub" style="margin-left:auto">{pct(p)} % used</span></div>
          <div class="bar"><div style="width:{pct(p)}%"></div></div>
          <div class="sub">{bytes(p.used)} of {bytes(p.size)}</div>
        </button>
      {/each}
    </div>
  {/if}
  {#if isStorage && locked}
    <div class="card elev-sm sub" style="padding:12px 14px">The storage is locked: unlock it under Encryption to see the pools.</div>
  {/if}

  <div class="grid">
    {#each cards as c}
      {@const n = note(c)}
      <div class="card elev-sm item" class:dim={dim(c)}>
        <button class="head" onclick={() => c.path && go(c.path)}>
          <i class="ph ph-{c.icon}"></i><span class="nm">{c.label}</span>
          {#if n}<span class="meta" class:warn={n.warn}>{shown(n)}</span>{/if}
          {#if dim(c)}<i class="ph ph-lock-simple" style="color:var(--color-neutral-600)"></i>{/if}
        </button>
        {#each c.kids as k}
          {@const kn = note(k)}
          <button class="kid" onclick={() => go(k.path)}>
            <i class="ph ph-{k.icon}"></i><span>{k.label}</span>
            {#if kn}<span class="meta" class:warn={kn.warn}>{shown(kn)}</span>{/if}
          </button>
        {/each}
      </div>
    {/each}
  </div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .crumb { font-size: 11px; color: var(--color-neutral-500); }
  h3 { font-size: 20px; }
  .two { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
  .pool { text-align: left; padding: 14px 16px; gap: 8px; cursor: pointer; color: inherit; font: inherit; border: 0; }
  .item { padding: 6px; gap: 0; }
  .item.dim { opacity: 0.6; }
  .row { display: flex; align-items: center; gap: 8px; }
  .nm { font-size: 14px; font-weight: 500; }
  .sub { font-size: 12px; color: var(--color-neutral-500); }
  .bar { height: 8px; border-radius: var(--r); background: var(--color-neutral-800); }
  .bar div { height: 8px; border-radius: var(--r); background: linear-gradient(90deg, var(--color-accent-700), var(--color-accent-500)); }
  .head, .kid { display: flex; align-items: center; gap: 8px; width: 100%; padding: 8px 10px; border: 0; background: none; color: inherit; font: inherit; text-align: left; border-radius: var(--r); cursor: pointer; }
  .head:hover, .kid:hover { background: var(--color-neutral-900); }
  .head i, .kid i { font-size: 16px; color: var(--color-neutral-400); }
  .kid { padding-left: 30px; font-size: 13px; color: var(--color-neutral-300); }
  .meta { margin-left: auto; font-size: 11px; color: var(--color-neutral-500); }
  .meta.warn { color: var(--st-warn); }
</style>
