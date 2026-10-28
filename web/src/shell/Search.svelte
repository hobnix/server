<script>
  // Jump-to search of the top bar. Client side only: the lists are the reads the pages already use, fetched when the box gets focus.
  import { mainTree, vpsTree, visible } from '../nav.js';
  import { ui } from '../ui.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import { go } from '../route.svelte.js';
  import { VPS_NODE } from '../redirects.js';
  import { tick } from 'svelte';
  import { setSelection } from '../select.svelte.js';

  let q = $state('');
  let focused = $state(false);   // the lists are read from the first focus on
  let open = $state(false);      // the dropdown
  let expanded = $state(false);  // narrow screens: the input is shown instead of the icon
  let active = $state(0);
  let input = $state();

  const cts = poll(() => (focused ? '/api/sys/ct/list' : ''), 30000);
  const shares = poll(() => (focused ? '/api/sys/shares/overview' : ''), 30000);
  const users = poll(() => (focused ? '/api/sys/users/list' : ''), 60000);
  const groups = poll(() => (focused ? '/api/sys/users/groups' : ''), 60000);
  const disks = poll(() => (focused ? '/api/sys/monitor/disks' : ''), 30000);
  const recipes = poll(() => (focused ? '/api/sys/recipes/list' : ''), 60000);

  const GROUPS = [
    { kind: 'pages', title: 'Pages', icon: 'compass' },
    { kind: 'instances', title: 'Instances', icon: 'cube' },
    { kind: 'shares', title: 'Shares', icon: 'folders' },
    { kind: 'users', title: 'Users', icon: 'user' },
    { kind: 'groups', title: 'Groups', icon: 'users-four' },
    { kind: 'disks', title: 'Disks', icon: 'hard-drive' },
    { kind: 'recipes', title: 'Recipes', icon: 'package' },
  ];

  // every entry of the resource tree with a path, with the labels above it as the hint
  const pages = $derived.by(() => {
    const out = [];
    // the address names its node: the pages of this server under its own name, the proxyserver pages under theirs (route.svelte.js)
    const walk = (items, trail, node) => {
      for (const it of visible(items, ui.features.capabilities)) {
        if (it.path) out.push({ name: it.label, hint: trail.join(' › '), icon: it.icon, path: `/node/${encodeURIComponent(node)}${it.path === '/' ? '' : it.path}` });
        if (it.children) walk(it.children, [...trail, it.label], node);
      }
    };
    walk(mainTree, [], ui.host);
    if ((ui.features.capabilities ?? ['vps']).includes('vps')) walk(vpsTree, [VPS_NODE], VPS_NODE);
    return out;
  });

  // monitor disks column 4: "bulk ..." = bulk pool, free/mounted = not in a pool, anything else = fast
  const local = (p) => `/node/${encodeURIComponent(ui.host)}${p}`;
  const diskPath = (role) => (/^bulk/.test(role) ? '/storage/disks?pool=bulk' : role === 'free' || role === 'mounted' ? '/storage/disks?pool=none' : '/storage/disks?pool=fast');

  // lists: [searchable strings, the shown item]; the first string is the name
  const sources = $derived({
    pages: pages.map((p) => ({ ...p, kind: 'pages', keys: [p.name, p.hint] })),
    instances: rows(cts).map((r) => ({ kind: 'instances', name: r[0], hint: r[2] ?? '', path: local('/instances'), keys: [r[0]] })),
    shares: rows(shares).map((r) => ({ kind: 'shares', name: r[0], hint: r[2] ?? '', path: local('/storage/shares'), keys: [r[0]] })),
    users: rows(users).map((r) => ({ kind: 'users', name: r[0], hint: r[1] && r[1] !== '-' ? r[1] : '', path: local('/identity/users'), keys: [r[0], r[1] ?? ''] })),
    groups: rows(groups).map((r) => ({ kind: 'groups', name: r[0], hint: '', path: local('/identity/groups'), keys: [r[0]] })),
    disks: rows(disks).map((r) => ({ kind: 'disks', name: r[0], hint: [r[10], r[3]].filter(Boolean).join(' · '), path: local(diskPath(r[3] ?? '')), keys: [r[0], r[10] ?? ''] })),
    recipes: rows(recipes).map((r) => ({ kind: 'recipes', name: r[0], hint: r[3] ?? '', path: local('/instances/apps'), keys: [r[0]] })),
  });

  // 0 = starts with the text, 1 = a word starts with it, 2 = contains it, -1 = no match; the best of the item's strings counts
  function rank(keys, t) {
    let best = -1;
    for (const k of keys) {
      const s = (k ?? '').toLowerCase();
      const i = s.indexOf(t);
      if (i < 0) continue;
      const r = i === 0 ? 0 : /[\s\-_.\/]/.test(s[i - 1]) ? 1 : 2;
      if (best < 0 || r < best) best = r;
    }
    return best;
  }

  const result = $derived.by(() => {
    const t = q.trim().toLowerCase();
    if (!t) return [];
    const out = [];
    for (const g of GROUPS) {
      const hits = [];
      for (const it of sources[g.kind]) {
        const r = rank(it.keys, t);
        if (r >= 0) hits.push({ it, r });
      }
      hits.sort((a, b) => a.r - b.r || a.it.name.localeCompare(b.it.name));
      if (hits.length) out.push({ ...g, items: hits.slice(0, 8).map((h) => h.it) });
    }
    return out;
  });
  // the same items in one row, numbered for the arrow keys
  const flat = $derived(result.flatMap((g) => g.items));
  const idOf = (it) => `sr-${flat.indexOf(it)}`;
  const searching = $derived(q.trim() !== '');
  $effect(() => { flat; active = 0; });
  // keep the highlighted row in view when the list scrolls
  $effect(() => { if (open && flat.length) document.getElementById(`sr-${active}`)?.scrollIntoView({ block: 'nearest' }); });

  function choose(it) {
    if (!it) return;
    if (it.kind !== 'pages') setSelection(it.kind, it.name);
    go(it.path);
    close();
    input?.blur();
  }
  function close() { open = false; q = ''; expanded = false; }

  function onkey(e) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      open = true;
      if (flat.length) active = (active + (e.key === 'ArrowDown' ? 1 : flat.length - 1)) % flat.length;
    } else if (e.key === 'Enter') {
      if (open && flat[active]) { e.preventDefault(); choose(flat[active]); }
    } else if (e.key === 'Escape') {
      e.stopPropagation();
      if (open || q) { close(); }
      else input?.blur();
    }
  }

  // "/" focuses the box from anywhere except while typing in a field
  function slash(e) {
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return;
    const t = e.target;
    if (t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
    e.preventDefault();
    expanded = true;
    // the input is only displayed after the state change on narrow screens
    tick().then(() => input?.focus());
  }
  function showInput() {
    expanded = true;
    tick().then(() => input?.focus());
  }
  function blur() {
    open = false;
    if (!q) expanded = false;
  }
</script>

<svelte:window onkeydown={slash} />

<div class="search" class:expanded>
  <button class="btn btn-ghost icon" aria-label="Search" title="Search" onclick={showInput}><i class="ph ph-magnifying-glass" style="font-size:16px"></i></button>
  <div class="field">
    <i class="ph ph-magnifying-glass"></i>
    <input class="input" bind:this={input} bind:value={q} type="text" placeholder="Search shares, instances, users…" aria-label="Search" autocomplete="off" spellcheck="false"
      role="combobox" aria-expanded={open && searching} aria-controls="search-list" aria-autocomplete="list" aria-activedescendant={open && flat.length ? `sr-${active}` : undefined}
      onfocus={() => { focused = true; open = true; }} onblur={blur} oninput={() => (open = true)} onkeydown={onkey} />
    {#if open && searching}
      <div class="drop card elev-md" id="search-list" role="listbox" aria-label="Search results" tabindex="-1" onmousedown={(e) => e.preventDefault()}>
        {#each result as g (g.kind)}
          <div class="gh" role="presentation">{g.title}</div>
          {#each g.items as it (it.kind + it.path + it.name)}
            <div class="opt" id={idOf(it)} role="option" tabindex="-1" aria-selected={flat[active] === it} class:on={flat[active] === it}
              onmouseenter={() => (active = flat.indexOf(it))} onclick={() => choose(it)} onkeydown={() => {}}>
              <i class="ph ph-{it.kind === 'pages' ? it.icon : g.icon}"></i>
              <span class="nm">{it.name}</span>
              {#if it.hint}<span class="ht">{it.hint}</span>{/if}
            </div>
          {/each}
        {/each}
        {#if !flat.length}<div class="none">No match</div>{/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .search { position: relative; width: min(340px, 30vw); }
  .field { position: relative; }
  .field > i { position: absolute; left: 10px; top: 9px; color: var(--color-neutral-500); pointer-events: none; }
  .field .input { min-height: 30px; padding: 4px 10px 4px 30px; font-size: 13px; background: var(--color-bg); }
  .icon { display: none; padding: 5px 6px; }
  .drop { position: absolute; top: calc(100% + 6px); left: 0; width: max(100%, 320px); max-height: 60vh; overflow: auto; padding: 4px; background: var(--color-surface); display: flex; flex-direction: column; z-index: 50; }
  .gh { padding: 8px 8px 3px; font-size: 11px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.04em; color: var(--color-neutral-500); }
  .opt { display: flex; align-items: center; gap: 8px; padding: 5px 8px; border-radius: var(--r); font-size: 12.5px; cursor: pointer; min-width: 0; }
  .opt > i { flex: none; color: var(--color-neutral-400); font-size: 14px; }
  .opt.on { background: var(--color-accent-900); }
  .opt.on > i { color: var(--color-accent); }
  .nm { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ht { margin-left: auto; padding-left: 8px; font-size: 11.5px; color: var(--color-neutral-500); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .none { padding: 10px 8px; font-size: 12.5px; color: var(--color-neutral-500); }
  /* narrow: an icon; a tap spreads the input over the whole bar */
  @media (max-width: 900px) {
    .search { width: auto; }
    .icon { display: inline-flex; }
    .field { display: none; }
    .search.expanded .icon { display: none; }
    .search.expanded .field { display: block; position: fixed; z-index: 55; top: 8px; left: 10px; right: 10px; }
    .search.expanded .drop { width: 100%; }
  }
</style>
