<script>
  // The Marketplace: every package of every repository (recipes and extensions are both just packages), and the repositories they come from.
  // Reads: hs sys pkg market / repos. Changes: hs sys pkg plan|start (install, update, remove, fetch, repo-add, repo-remove); a package or repository
  // that came from a repository somebody added is red (the typed word is its name).
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { openPlan, openCreate, ui } from '../ui.svelte.js';
  import { route, go } from '../route.svelte.js';
  import { start } from '../api.js';
  import RepoAdd from '../forms/ops/RepoAdd.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import PageTabs from '../ui/PageTabs.svelte';
  import StatusDot from '../ui/StatusDot.svelte';

  const market = poll('/api/sys/pkg/market', 30000);
  const repoList = poll('/api/sys/pkg/repos', 30000);
  const PATHS = ['/api/sys/pkg/market', '/api/sys/pkg/repos'];

  // name, kind, repository, available version, installed version (- = none), state (new|current|update|orphan), core, audience, title
  const pkgs = $derived(rows(market).map((r) => ({ name: r[0], kind: r[1], repo: r[2], avail: r[3], inst: r[4] === '-' ? '' : r[4], state: r[5], core: r[6] === 'yes', title: r[8] === '-' ? '' : r[8] })));
  // name, address, signed|unsigned, default|added
  const repos = $derived(rows(repoList).map((r) => ({ name: r[0], url: r[1], signed: r[2] === 'signed', from: r[3] })));
  const updates = $derived(pkgs.filter((p) => p.state === 'update').length);

  const tabs = [{ id: 'packages', label: 'Packages' }, { id: 'repos', label: 'Repositories' }];
  const tab = $derived(tabs.some((t) => t.id === route.query.tab) ? route.query.tab : 'packages');
  const pick = (id) => go(id === 'packages' ? '/marketplace' : `/marketplace?tab=${id}`);

  let q = $state('');
  let kind = $state('all');
  let show = $state('all');
  const shown = $derived(pkgs.filter((p) => (kind === 'all' || p.kind === kind)
    && (show === 'all' || (show === 'installed' ? p.state !== 'new' : show === 'updates' ? p.state === 'update' : p.state === 'new'))
    && (!q.trim() || (p.name + ' ' + p.title).toLowerCase().includes(q.trim().toLowerCase()))));

  const kindLabel = (k) => (k === 'recipe' ? 'App' : k === 'extension' ? 'Extension' : 'Package');
  const kindIcon = (k) => (k === 'extension' ? 'puzzle-piece' : 'package');
  const stateDot = (p) => (p.state === 'current' ? 'ok' : p.state === 'update' || p.state === 'orphan' ? 'warn' : 'off');
  const stateText = (p) => (p.state === 'new' ? 'not installed' : p.state === 'current' ? `installed ${p.inst}` : p.state === 'update' ? `${p.inst} → ${p.avail}` : 'repository gone');
  const columns = [
    { key: 'sel', label: '', sort: false, width: '44px' },
    { key: 'go', label: '', sort: false }, { key: 'name', label: 'Package' }, { key: 'title', label: 'What it is' },
    { key: 'repo', label: 'Repository' }, { key: 'state', label: 'State' }, { key: 'tools', label: '', sort: false, align: 'right' },
  ];
  const repoColumns = [
    { key: 'name', label: 'Repository' }, { key: 'url', label: 'Address' }, { key: 'signed', label: 'Releases' }, { key: 'from', label: 'From' },
    { key: 'tools', label: '', sort: false, align: 'right' },
  ];

  const install = (p) => openPlan('pkg', ['install', p.name], `Install ${p.name}`);
  const update = (p) => openPlan('pkg', ['update', p.name], `Update ${p.name}`);
  const remove = (p) => openPlan('pkg', ['remove', p.name], `Remove ${p.name}`);
  const fetchAll = () => openPlan('pkg', ['fetch'], 'Read the repositories again');
  const addRepo = () => openCreate(RepoAdd, {});
  const dropRepo = (r) => openPlan('pkg', ['repo-remove', r.name], `Remove the repository ${r.name}`);

  // a package that came from an added repository is red: installing it needs the name typed, which a bulk run cannot do per item
  const red = (p) => repos.find((r) => r.name === p.repo)?.from === 'added';

  // what a change did shows after its dialog closes
  let was = false;
  $effect(() => {
    const open = !!ui.dialog || !!ui.create;
    if (was && !open) setTimeout(() => refresh(PATHS), 400);
    was = open;
  });

  // ═══ bulk selection ═══
  const selected = $state(new Set());
  const toggle = (name, checked) => { if (checked) selected.add(name); else selected.delete(name); };
  const selectedPkgs = $derived(pkgs.filter((p) => selected.has(p.name)));
  const canInstall = $derived(selectedPkgs.some((p) => p.state === 'new' && !red(p)));
  const canUpdate = $derived(selectedPkgs.some((p) => p.state === 'update'));
  const canRemove = $derived(selectedPkgs.some((p) => p.state !== 'new' && !p.core));
  const bulkBusy = $state(false);
  let bulkOpen = null;           // { action, items } while the confirmation dialog is open
  let bulkSummary = [];
  let showSummary = $state(false);

  // start one package (synchronous: status done / refused); each call blocks until the package change is finished
  const startOne = async (action, name) => {
    try {
      const r = await start('pkg', [action, name]);
      return { ok: r.status === 'done', reason: r.reason, status: r.status };
    } catch (e) {
      return { ok: false, reason: e.message, status: 'error' };
    }
  };

  const runBulk = (action) => {
    let items;
    if (action === 'install') items = selectedPkgs.filter((p) => p.state === 'new');
    else if (action === 'update') items = selectedPkgs.filter((p) => p.state === 'update');
    else items = selectedPkgs.filter((p) => p.state !== 'new' && !p.core);
    if (!items.length) return;
    bulkOpen = { action, items };
  };

  const confirmBulk = async () => {
    const { action, items } = bulkOpen;
    bulkOpen = null;
    bulkBusy = true;
    bulkSummary = [];
    try {
      for (const p of items) {
        const r = await startOne(action, p.name);
        bulkSummary.push({ name: p.name, ok: r.ok, reason: r.reason, status: r.status });
      }
      selected = new Set();
      await refresh(PATHS);
      showSummary = true;
    } finally {
      bulkBusy = false;
    }
  };

  const cancelBulk = () => { bulkOpen = null; };
  const dismissSummary = () => { showSummary = false; bulkSummary = []; };
  const failedCount = $derived(bulkSummary.filter((r) => !r.ok).length);
</script>

<PageHeader title="Marketplace" crumb={ui.host}
            sub={market.loaded && !market.error ? `${pkgs.length} packages from ${repos.length} repositories${updates ? ` · ${updates} update${updates > 1 ? 's' : ''}` : ''}` : 'Apps and extensions from the repositories you trust.'}>
  {#snippet actions()}
    <button class="btn" use:tip={'Read the repositories again and find the newest releases'} onclick={fetchAll}><i class="ph ph-arrows-clockwise"></i>Check for updates</button>
    <button class="btn btn-primary" use:tip={'Add a repository of packages'} onclick={addRepo}><i class="ph ph-plus"></i>Add repository</button>
  {/snippet}
</PageHeader>

<PageTabs {tabs} {tab} onpick={pick} />

{#if tab === 'packages'}
  <PageState loading={!market.loaded} error={market.error?.message} hasData={market.data != null} empty={market.loaded && !market.error && !pkgs.length}
             emptyIcon="storefront" emptyTitle="Nothing to install yet" emptyText="No release of any repository has been read. Use Check for updates." retry={() => refresh(PATHS)}>
    <div class="bar">
      {#each [['all', 'All'], ['recipe', 'Apps'], ['extension', 'Extensions']] as [k, l]}
        <button class="btn sm {kind === k ? 'btn-primary' : 'btn-ghost'}" onclick={() => (kind = k)}>{l}</button>
      {/each}
      <span class="sep"></span>
      {#each [['all', 'Any'], ['installed', 'Installed'], ['updates', 'Updates'], ['new', 'Not installed']] as [k, l]}
        <button class="btn sm {show === k ? 'btn-primary' : 'btn-ghost'}" onclick={() => (show = k)}>{l}</button>
      {/each}
      <input class="input find" bind:value={q} placeholder="Search packages" aria-label="Search packages" autocomplete="off" />
    </div>

    {#if selected.size}
      <div class="bulk">
        <span class="bulk-count">{selected.size} selected</span>
        <button class="btn sm {canInstall ? 'btn-primary' : 'btn-ghost'}" disabled={!canInstall || bulkBusy} onclick={() => runBulk('install')}>Install selected</button>
        <button class="btn sm {canUpdate ? 'btn-primary' : 'btn-ghost'}" disabled={!canUpdate || bulkBusy} onclick={() => runBulk('update')}>Update selected</button>
        <button class="btn sm {canRemove ? 'btn-danger' : 'btn-ghost'}" disabled={!canRemove || bulkBusy} onclick={() => runBulk('remove')}>Remove selected</button>
        <button class="btn btn-ghost sm" disabled={bulkBusy} onclick={() => (selected = new Set())}>Clear selection</button>
      </div>
    {/if}

    <div class="card tc">
      <Table id="market" {columns} rows={shown} key="name" loading={!market.loaded} empty="No package matches.">
        {#snippet cell(p, col)}
          {@const on = p.state !== 'new'}
          {#if col.key === 'sel'}
            <input type="checkbox" checked={selected.has(p.name)} onchange={(e) => toggle(p.name, e.target.checked)} aria-label="Select {p.name}" />
          {:else if col.key === 'go'}
            {#if p.state === 'new'}
              <button class="btn sm btn-primary" use:tip={`Install ${p.name} from ${p.repo}`} onclick={() => install(p)}>Install</button>
            {:else if p.state === 'update'}
              <button class="btn sm btn-primary" use:tip={`Update to ${p.avail}: shows what changed first`} onclick={() => update(p)}>Update</button>
            {/if}
          {:else if col.key === 'name'}
            <span class="nm"><i class="ph ph-{kindIcon(p.kind)}" style="color:{p.state === 'new' ? 'var(--fg-3)' : 'var(--accent-ink)'}"></i>{p.name}</span>
            <div class="in">{kindLabel(p.kind)}{p.core ? ' · the server needs it' : ''}</div>
          {:else if col.key === 'title'}
            <span class="ds">{p.title}</span>
          {:else if col.key === 'repo'}
            {p.repo}
          {:else if col.key === 'state'}
            <StatusDot state={stateDot(p)} label={stateText(p)} />
          {:else if p.state !== 'new'}
            <button class="btn btn-ghost btn-icon" disabled={p.core} use:tip={p.core ? 'The server refers to this package by name: it stays' : 'Remove the installed copy (data and containers stay)'} aria-label="Remove {p.name}" onclick={() => remove(p)}><i class="ph ph-trash"></i></button>
          {/if}
        {/snippet}
      </Table>
    </div>
  </PageState>
{:else}
  <PageState loading={!repoList.loaded} error={repoList.error?.message} hasData={repoList.data != null} empty={repoList.loaded && !repoList.error && !repos.length}
             emptyIcon="database" emptyTitle="No repositories" emptyText="Add a repository to see its packages." retry={() => refresh(PATHS)}>
    <div class="card tc">
      <Table id="repos" columns={repoColumns} rows={repos} key="name" loading={!repoList.loaded} empty="No repository.">
        {#snippet cell(r, col)}
          {#if col.key === 'name'}
            <span class="nm"><i class="ph ph-database"></i>{r.name}</span>
          {:else if col.key === 'url'}
            <span class="ds">{r.url}</span>
          {:else if col.key === 'signed'}
            <StatusDot state={r.signed ? 'ok' : 'bad'} label={r.signed ? 'signed releases only' : 'unsigned'} />
          {:else if col.key === 'from'}
            {r.from === 'default' ? 'this project' : 'added by you'}
          {:else if r.from === 'added'}
            <button class="btn btn-ghost btn-icon" use:tip={'Take this repository out (installed packages stay)'} aria-label="Remove {r.name}" onclick={() => dropRepo(r)}><i class="ph ph-trash"></i></button>
          {/if}
        {/snippet}
      </Table>
    </div>
    <div class="note">Packages run as root on this server. A release is used only when its signature verifies against the key the repository was added with.</div>
  </PageState>
{/if}

{#if bulkOpen}
  <div class="dialog-backdrop" onclick={cancelBulk}>
    <div class="bulk-dialog" onclick={(e) => e.stopPropagation()}>
      <h3 class:{bad}={bulkOpen.action === 'remove'}>
        {bulkOpen.action === 'install' ? 'Install the selected packages'
         : bulkOpen.action === 'update' ? 'Update the selected packages'
         : 'Remove the selected packages'}
      </h3>
      <p class={bulkOpen.action === 'remove' ? 'bulk-warn' : ''}>
        {bulkOpen.action === 'remove' ? 'This removes the installed copy of each package. Data and containers made by a recipe stay.'
         : 'Each package gets its own change and they run one after another.'}
      </p>
      <ul class="bulk-list">
        {#each bulkOpen.items as p}<li>{p.name} <span class="bulk-note">({stateText(p)})</span></li>{/each}
      </ul>
      <div class="bulk-foot">
        <button class="btn" onclick={cancelBulk}>Cancel</button>
        <button class="btn {bulkOpen.action === 'remove' ? 'btn-danger' : 'btn-primary'}" disabled={bulkBusy} onclick={confirmBulk}>
          {bulkOpen.action === 'remove' ? 'Remove' : 'Start'}{bulkOpen.items.length === 1 ? '' : ' ' + bulkOpen.items.length + (bulkOpen.action === 'remove' ? '' : ' jobs')}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if showSummary}
  <div class="dialog-backdrop" onclick={dismissSummary}>
    <div class="bulk-dialog" onclick={(e) => e.stopPropagation()}>
      <h3 class:{bad}={failedCount > 0}>{failedCount > 0 ? 'Some changes failed' : 'All changes finished'}</h3>
      <ul class="bulk-list">
        {#each bulkSummary as r}
          <li class:{bad}={!r.ok}>{r.name} <span class="bulk-note">{r.ok ? 'finished' : (r.reason ?? ('status: ' + (r.status ?? 'failed')))}</span></li>
        {/each}
      </ul>
      <div class="bulk-foot">
        <button class="btn btn-primary" onclick={dismissSummary}>Done</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .bar { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin-top: 12px; }
  .sep { width: 1px; height: 18px; background: var(--line); margin: 0 4px; }
  .find { margin-left: auto; max-width: 240px; }
  .nm { display: inline-flex; align-items: center; gap: 8px; font-weight: 600; font-size: 13.5px; }
  .nm i { font-size: 18px; }
  .ds { font-size: 12.5px; color: var(--fg-3); }
  .in { font-size: 12px; color: var(--fg-3); margin-left: 26px; }
  .note { font-size: 12.5px; color: var(--fg-3); margin-top: 10px; }
  .bulk { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin: 10px 0 6px; }
  .bulk-count { font: 500 12.5px var(--mono); color: var(--fg-2); }
  .bulk-dialog { background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: 0 24px 64px oklch(0 0 0 / 0.5); width: min(460px, 92vw); max-height: 82vh; overflow: auto; margin: 2vh auto; padding: 22px; display: flex; flex-direction: column; gap: 12px; }
  .bulk-dialog h3 { margin: 0 0 2px; font-size: 17px; font-weight: 600; letter-spacing: -0.02em; }
  .bulk-dialog h3.bad { color: var(--bad-ink); }
  .bulk-dialog p { margin: 0; font-size: 12.5px; color: var(--fg-3); }
  .bulk-warn { color: var(--bad-ink); }
  .bulk-list { margin: 0; padding: 0 0 0 20px; font-size: 13px; color: var(--fg); gap: 6px; display: flex; flex-direction: column; }
  .bulk-list li { display: flex; justify-content: space-between; gap: 10px; }
  .bulk-list li.bad { color: var(--bad-ink); }
  .bulk-note { color: var(--fg-2); font-size: 12px; }
  .bulk-foot { display: flex; gap: 8px; justify-content: flex-end; padding-top: 8px; border-top: 1px solid var(--line); }
  .dialog-backdrop { position: fixed; inset: 0; background: oklch(0 0 0 / 0.45); display: grid; place-items: center; z-index: 60; }
  .bad { color: var(--bad-ink); }
</style>
