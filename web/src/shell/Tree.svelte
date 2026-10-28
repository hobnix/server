<script>
  // The resource tree: servers (nodes) are the roots. This server is expanded; remote nodes are collapsed and show a status dot. The page list under a node
  // depends on its kind (nav.js nodeItems). A node's Summary is its root row. Node data: Shell builds `nodes` = [{ name, kind, local, dot: {state,title} }].
  import TreeNode from './TreeNode.svelte';
  import TreeRow from './TreeRow.svelte';
  import { route, go } from '../route.svelte.js';
  import { nodeItems } from '../nav.js';
  import { ui } from '../ui.svelte.js';

  let { nodes = [], locked = false, meta = {} } = $props();

  // open state per node name; a node stays open while the page on screen belongs to it
  let open = $state({});
  const isOpen = (n) => (open[n.name] ?? n.local) || route.node === n.name;
  const addr = (n) => `/node/${encodeURIComponent(n.name)}`;
  const kindChip = { main: '', vps: 'vps', edge: 'edge', peer: 'peer' };
</script>

<div class="tree" role="tree" aria-label="Servers and pages">
  <div class="thead"><span>Servers</span><span class="cnt">{nodes.length}</span></div>
  <div class="tscroll">
    {#each nodes as n (n.name)}
      {@const items = nodeItems(n.kind, n.local ? ui.features.capabilities : n.caps, n.local ? ui.features.extensions : null).filter((i) => i.path !== '/')}
      <TreeRow icon={n.kind === 'main' ? 'hard-drives' : n.kind === 'peer' ? 'house-line' : 'globe-hemisphere-west'} label={n.name} strong gap={n !== nodes[0]}
               href={addr(n)} active={route.node === n.name && route.path === '/'}
               caret={items.length ? (isOpen(n) ? 'open' : 'closed') : null} ontoggle={() => (open[n.name] = !isOpen(n))}
               onclick={() => { open[n.name] = true; go(addr(n)); }}
               chip={n.local ? 'this server' : kindChip[n.kind] ?? n.kind} dot={n.dot ?? { state: 'off', title: 'no data' }} />
      {#if isOpen(n)}
        {#each items as it (it.label + (it.path ?? ''))}
          <TreeNode item={it} node={n.name} local={n.local} depth={1} locked={locked && n.local} {meta} />
        {/each}
      {/if}
    {/each}
  </div>
</div>

<style>
  .tree { display: flex; flex-direction: column; min-height: 0; flex: 1; }
  .thead { display: flex; align-items: center; justify-content: space-between; padding: 10px 14px 4px 16px; font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-3); }
  .cnt { font: 500 11px var(--mono); color: var(--fg-2); background: var(--panel-3); padding: 0 6px; }
  .tscroll { flex: 1; min-height: 0; overflow-y: auto; scrollbar-gutter: stable; padding: 4px 8px 10px; }
</style>
