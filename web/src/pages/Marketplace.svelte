<script>
  // The Marketplace: every package of every repository (recipes and extensions are both just packages), and the repositories they come from.
  // Reads: hs sys pkg market / repos. Changes: hs sys pkg plan|start (install, update, remove, fetch, repo-add, repo-remove); a package or repository
  // that came from a repository somebody added is red (the typed word is its name).
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { openPlan, openCreate, ui } from '../ui.svelte.js';
  import { route, go } from '../route.svelte.js';
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

  // what a change did shows after its dialog closes
  let was = false;
  $effect(() => {
    const open = !!ui.dialog || !!ui.create;
    if (was && !open) setTimeout(() => refresh(PATHS), 400);
    was = open;
  });
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
    <div class="card tc">
      <Table id="market" {columns} rows={shown} key="name" loading={!market.loaded} empty="No package matches.">
        {#snippet cell(p, col)}
          {#if col.key === 'go'}
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

<style>
  .bar { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin-top: 12px; }
  .sep { width: 1px; height: 18px; background: var(--line); margin: 0 4px; }
  .find { margin-left: auto; max-width: 240px; }
  .nm { display: inline-flex; align-items: center; gap: 8px; font-weight: 600; font-size: 13.5px; }
  .nm i { font-size: 18px; }
  .ds { font-size: 12.5px; color: var(--fg-3); }
  .in { font-size: 12px; color: var(--fg-3); margin-left: 26px; }
  .note { font-size: 12.5px; color: var(--fg-3); margin-top: 10px; }
</style>
