<script>
  // The pages of one node, as tree rows (recursive). `node` is the node's name (the address is /node/<node><item.path>), `local` says whether it is this
  // server (its pages prefetch their reads, its rows know the storage lock). Items with a `capability` that is off are left out (nav.js visible()).
  // meta: path -> { text, warn } or { dot, title } (the right-hand note of a row, only where the data exists).
  import TreeNode from './TreeNode.svelte';
  import TreeRow from './TreeRow.svelte';
  import { route, go } from '../route.svelte.js';
  import { prefetchRoute } from '../prefetch.js';
  import { visible } from '../nav.js';
  import { ui } from '../ui.svelte.js';

  let { item, node, local = true, depth = 0, locked = false, meta = {} } = $props();

  const addr = $derived(`/node/${encodeURIComponent(node)}${item.path === '/' ? '' : item.path ?? ''}`);
  const kids = $derived(item.children ? visible(item.children, local ? ui.features.capabilities : null) : []);
  const hasKids = $derived(kids.length > 0);
  const here = $derived(route.node === node);
  const selected = $derived(!!item.path && here && (route.path === item.path || (item.prefix && route.path.startsWith(item.path + '/'))));
  const dim = $derived(local && locked && !!item.storage);
  const m = $derived(item.path && !dim && local ? meta[item.path] : (item.path && !local ? meta[`${node}:${item.path}`] : null));

  // open state: a group stays open while the page on screen is inside it
  const inside = (it) => (it.path && route.node === node && (route.path === it.path || route.path.startsWith(it.path + '/'))) || (it.children ?? []).some(inside);
  let open = $state(true);
  $effect(() => { if (inside(item)) open = true; });

  function click() {
    if (item.path) go(addr);
    else if (hasKids) open = !open;
  }
</script>

<TreeRow {depth} icon={item.icon} label={item.label} href={addr} active={selected} {dim} gap={!!item.gap}
         caret={hasKids ? (open ? 'open' : 'closed') : null} ontoggle={() => (open = !open)} onclick={click}
         onhover={() => local && prefetchRoute(item.path)}
         lock={dim} count={m?.text ?? ''} warn={!!m?.warn} dot={m?.dot ? { state: m.dot, title: m.title || m.dot } : null} />
{#if hasKids && open}
  {#each kids as c (c.label + (c.path ?? ''))}
    <TreeNode item={c} {node} {local} depth={depth + 1} {locked} {meta} />
  {/each}
{/if}
