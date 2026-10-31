<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { takeSelection } from '../select.svelte.js';
  import { openCreate, ui } from '../ui.svelte.js';
  import { start, get } from '../api.js';
  import RunRecipe from '../forms/ops/RunRecipe.svelte';
  import AppServices from '../forms/ops/AppServices.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import { link } from './instances/ct.js';

  const list = poll('/api/sys/recipes/list', 30000);
  // services app: name, container, ... the containers that have a described service
  const svc = poll('/api/sys/services/app', 30000);
  const withService = $derived(new Set(rows(svc).map((r) => r[1])));
  const hasService = (a) => !!a.cts && a.cts.split(',').some((c) => withService.has(c));

  // name, description, containers (comma separated, - for none), state: installed | partly | not installed | parked | unknown
  const apps = $derived(rows(list).map((r) => ({ name: r[0], desc: r[1], cts: r[2] === '-' ? '' : r[2], state: r[3] })));
  const installed = $derived(apps.filter((a) => a.state === 'installed').length);

  // the icons the design gives the known recipes; anything else is a package
  const icons = {
    arr: 'film-slate', authentik: 'key', bulwark: 'envelope-open', cloudflared: 'cloud', docker: 'shipping-container', docs: 'book-open',
    homeassistant: 'house-line', domain: 'identification-badge', immich: 'images', jellyfin: 'film-strip', 'matrix-hook': 'chat-circle-text',
    monitoring: 'chart-line', ntfy: 'bell', paperclip: 'robot', pelican: 'game-controller', qbittorrent: 'download-simple', sabnzbd: 'download', seerr: 'magnifying-glass',
    stalwart: 'envelope-simple', sunshine: 'television', synapse: 'chat-circle', tdarr: 'swap', 'upload-storage': 'cloud-arrow-up', 'uptime-kuma': 'heartbeat', zoraxy: 'arrows-split',
  };
  const tag = (a) => (a.state === 'installed' ? (a.cts ? `in ${a.cts.split(',').join(', ')}` : 'installed') : a.state);

  const run = (a) => openCreate(RunRecipe, { recipe: a.name });
  const services = (a) => openCreate(AppServices, { app: a.name, cts: a.cts ? a.cts.split(',') : [] });

  let q = $state('');
  let show = $state('all');
  const shown = $derived(apps.filter((a) => (show === 'all' || (show === 'installed' ? a.state === 'installed' : a.state !== 'installed'))
    && (!q.trim() || (a.name + ' ' + a.desc).toLowerCase().includes(q.trim().toLowerCase()))));
  const columns = [
    { key: 'sel', label: '', sort: false, width: '44px' },
    { key: 'go', label: '', sort: false }, { key: 'name', label: 'App' }, { key: 'desc', label: 'What it does' },
    { key: 'state', label: 'State' }, { key: 'tools', label: '', sort: false, align: 'right' },
  ];

  let copied = $state('');
  let hl = $state('');
  $effect(() => { const n = takeSelection('recipes'); if (n) hl = n; });
  $effect(() => { if (hl && apps.length) document.getElementById('app-' + hl)?.scrollIntoView({ block: 'center' }); });
  async function copy(name) {
    const text = `hs recipe ${name}`;
    try { await navigator.clipboard.writeText(text); }
    catch {
      // a page served over plain HTTP has no clipboard API: select the text in a hidden field instead
      const t = document.createElement('textarea');
      t.value = text; t.style.position = 'fixed'; t.style.opacity = '0';
      document.body.appendChild(t); t.select();
      try { document.execCommand('copy'); } catch { /* nothing more to try */ }
      t.remove();
    }
    copied = name;
    setTimeout(() => { if (copied === name) copied = ''; }, 1500);
  }

  // ═══ bulk selection ═══
  const selected = $state(new Set());
  const toggle = (name, checked) => { if (checked) selected.add(name); else selected.delete(name); };
  const selectedApps = $derived(apps.filter((a) => selected.has(a.name)));
  const canInstall = $derived(selectedApps.some((a) => a.state !== 'installed'));
  const canUpdate = $derived(selectedApps.some((a) => a.state === 'installed'));
  const bulkBusy = $state(false);
  let bulkOpen = null;           // { action, items } while the confirmation dialog is open
  let bulkSummary = [];          // { name, ok, state, reason }
  let showSummary = $state(false);

  // wait until a job unit reaches a terminal state, then return it ('ok' | 'failed' | 'unknown' | 'running' on timeout)
  async function awaitJob(unit) {
    let from = 0;
    for (let i = 0; i < 600; i++) {   // up to about ten minutes
      try {
        const r = await get(`/api/sys/jobs/tail/${encodeURIComponent(unit)}?from=${from}`);
        let state = 'running';
        for (const row of r.rows ?? []) {
          if (row[0] === 'next') from = Number(row[1]) || from;
          else if (row[0] === 'state') state = row[1];
        }
        if (state !== 'running') return state;
      } catch { /* the stream broke once: try again */ }
      await new Promise((ok) => setTimeout(ok, 1000));
    }
    return 'running';
  }

  // start one recipe as its own background job (install and update are both `hs sys recipes start <name> run`)
  const startOne = async (name) => {
    try {
      const r = await start('recipes', [name, 'run']);
      if (r.status === 'started' && r.unit) return { unit: r.unit };
      return { ok: false, reason: r.reason || `could not start (${r.status})`, status: r.status };
    } catch (e) {
      return { ok: false, reason: e.message, status: 'error' };
    }
  };

  // run the selected items one job after another, then refresh and report
  const runBulk = async (action) => {
    const items = selectedApps.filter((a) => action === 'install' ? a.state !== 'installed' : a.state === 'installed');
    if (!items.length) return;
    bulkOpen = { action, items };
  };

  const confirmBulk = async () => {
    const { action, items } = bulkOpen;
    bulkOpen = null;
    bulkBusy = true;
    bulkSummary = [];
    try {
      for (const a of items) {
        const r = await startOne(a.name);
        if (r.unit) {
          const state = await awaitJob(r.unit);
          bulkSummary.push({ name: a.name, ok: state === 'ok', state });
        } else {
          bulkSummary.push({ name: a.name, ok: false, reason: r.reason, status: r.status });
        }
      }
      selected = new Set();
      await refresh(['/api/sys/recipes/list', '/api/sys/services/app']);
      showSummary = true;
    } finally {
      bulkBusy = false;
    }
  };

  const cancelBulk = () => { bulkOpen = null; };
  const dismissSummary = () => { showSummary = false; bulkSummary = []; };
  const failedCount = $derived(bulkSummary.filter((r) => !r.ok).length);
</script>

<PageHeader title="Apps" crumb="{ui.host} › Instances" sub={list.loaded && !list.error ? `${installed} of ${apps.length} installed · safe to run again` : 'One-command installers, safe to run again.'} />

<PageState loading={!list.loaded} error={list.error?.message} hasData={list.data != null} empty={list.loaded && !list.error && !apps.length}
           emptyIcon="package" emptyTitle="No recipes" emptyText="This server has no app recipes." retry={() => refresh(['/api/sys/recipes/list'])}>
  <div class="bar">
    {#each [['all', 'All'], ['installed', 'Installed'], ['todo', 'Not installed']] as [k, l]}
      <button class="btn sm {show === k ? 'btn-primary' : 'btn-ghost'}" onclick={() => (show = k)}>{l}</button>
    {/each}
    <input class="input find" bind:value={q} placeholder="Search apps" aria-label="Search apps" autocomplete="off" />
  </div>

  {#if selected.size}
    <div class="bulk">
      <span class="bulk-count">{selected.size} selected</span>
      <button class="btn sm {canInstall ? 'btn-primary' : 'btn-ghost'}" disabled={!canInstall || bulkBusy} onclick={() => runBulk('install')}>Install selected</button>
      <button class="btn sm {canUpdate ? 'btn-primary' : 'btn-ghost'}" disabled={!canUpdate || bulkBusy} onclick={() => runBulk('update')}>Update selected</button>
      <button class="btn btn-ghost sm" disabled={bulkBusy} onclick={() => (selected = new Set())}>Clear selection</button>
    </div>
  {/if}

  <div class="card tc">
    <Table id="apps" {columns} rows={shown} key="name" loading={!list.loaded} empty="No app matches.">
      {#snippet cell(a, col)}
        {@const on = a.state === 'installed'}
        {#if col.key === 'sel'}
          <input type="checkbox" checked={selected.has(a.name)} onchange={(e) => toggle(a.name, e.target.checked)} aria-label="Select {a.name}" />
        {:else if col.key === 'go'}
          <button class="btn sm {on ? '' : 'btn-primary'}" disabled={a.state === 'parked'} use:tip={a.state === 'parked' ? 'This recipe is parked' : on ? 'Run again: repairs or updates the setup' : 'Set this app up'} onclick={() => run(a)}><i class="ph ph-{on ? 'arrows-clockwise' : 'download-simple'}"></i>{on ? 'Update' : 'Install'}</button>
        {:else if col.key === 'name'}
          <span id="app-{a.name}" class="nm" class:hl={hl === a.name}><i class="ph ph-{icons[a.name] ?? 'package'}" style="color:{on ? 'var(--accent-ink)' : 'var(--fg-3)'}"></i>{a.name}</span>
        {:else if col.key === 'desc'}
          <span class="ds">{a.desc}</span>{#if a.cts}<div class="in">In {#each a.cts.split(',') as c, i}{i ? ', ' : ''}<a {...link('/instances', 'instances', c)}>{c}</a>{/each}</div>{/if}
        {:else if col.key === 'state'}
          <StatusDot state={on ? 'ok' : a.state === 'partly' ? 'warn' : 'off'} label={a.state} />
        {:else}
          <button class="btn btn-ghost btn-icon" disabled={!hasService(a)} use:tip={hasService(a) ? 'Services: local and public access' : a.cts ? 'No service is described yet: Update the app to describe it' : 'Install the app first'} aria-label="Services of {a.name}" onclick={() => services(a)}><i class="ph ph-globe-hemisphere-west"></i></button>
          <button class="btn btn-ghost btn-icon" use:tip={copied === a.name ? 'Copied' : 'Copy the terminal command: hs recipe ' + a.name} aria-label="Copy hs recipe {a.name}" onclick={() => copy(a.name)}><i class="ph ph-{copied === a.name ? 'check' : 'terminal-window'}"></i></button>
        {/if}
      {/snippet}
    </Table>
  </div>
</PageState>

{#if bulkOpen}
  <div class="dialog-backdrop" onclick={cancelBulk}>
    <div class="bulk-dialog" onclick={(e) => e.stopPropagation()}>
      <h3>{bulkOpen.action === 'install' ? 'Install the selected apps' : 'Update the selected apps'}</h3>
      <p>Each app gets its own background job and the jobs run one after another. The result appears under Jobs.</p>
      <ul class="bulk-list">
        {#each bulkOpen.items as a}<li>{a.name} <span class="bulk-note">({a.state})</span></li>{/each}
      </ul>
      <div class="bulk-foot">
        <button class="btn" onclick={cancelBulk}>Cancel</button>
        <button class="btn btn-primary" disabled={bulkBusy} onclick={confirmBulk}>Start {bulkOpen.items.length} job{bulkOpen.items.length === 1 ? '' : 's'}</button>
      </div>
    </div>
  </div>
{/if}

{#if showSummary}
  <div class="dialog-backdrop" onclick={dismissSummary}>
    <div class="bulk-dialog" onclick={(e) => e.stopPropagation()}>
      <h3 class:{bad}={failedCount > 0}>{failedCount > 0 ? 'Some jobs failed' : 'All jobs finished'}</h3>
      <ul class="bulk-list">
        {#each bulkSummary as r}
          <li class:{bad}={!r.ok}>{r.name} <span class="bulk-note">{r.ok ? 'finished' : (r.reason ?? ('state: ' + (r.state ?? 'failed')))}</span></li>
        {/each}
      </ul>
      <div class="bulk-foot">
        <button class="btn btn-primary" onclick={dismissSummary}>Done</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .bar { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
  .find { margin-left: auto; max-width: 240px; }
  .nm { display: inline-flex; align-items: center; gap: 8px; font-weight: 600; font-size: 13.5px; }
  .nm i { font-size: 18px; }
  .nm.hl { outline: 2px solid var(--accent); outline-offset: 3px; }
  .ds { font-size: 12.5px; color: var(--fg-3); }
  .in { font-size: 12px; color: var(--fg-2); }
  .bulk { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin: 10px 0 6px; }
  .bulk-count { font: 500 12.5px var(--mono); color: var(--fg-2); }
  .bulk-dialog { background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: 0 24px 64px oklch(0 0 0 / 0.5); width: min(460px, 92vw); max-height: 82vh; overflow: auto; margin: 2vh auto; padding: 22px; display: flex; flex-direction: column; gap: 12px; }
  .bulk-dialog h3 { margin: 0 0 2px; font-size: 17px; font-weight: 600; letter-spacing: -0.02em; }
  .bulk-dialog h3.bad { color: var(--bad-ink); }
  .bulk-dialog p { margin: 0; font-size: 12.5px; color: var(--fg-3); }
  .bulk-list { margin: 0; padding: 0 0 0 20px; font-size: 13px; color: var(--fg); gap: 6px; display: flex; flex-direction: column; }
  .bulk-list li { display: flex; justify-content: space-between; gap: 10px; }
  .bulk-list li.bad { color: var(--bad-ink); }
  .bulk-note { color: var(--fg-2); font-size: 12px; }
  .bulk-foot { display: flex; gap: 8px; justify-content: flex-end; padding-top: 8px; border-top: 1px solid var(--line); }
  .dialog-backdrop { position: fixed; inset: 0; background: oklch(0 0 0 / 0.45); display: grid; place-items: center; z-index: 60; }
  .bad { color: var(--bad-ink); }
</style>
