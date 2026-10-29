<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { takeSelection } from '../select.svelte.js';
  import { openCreate, ui } from '../ui.svelte.js';
  import RunRecipe from '../forms/ops/RunRecipe.svelte';
  import AppServices from '../forms/ops/AppServices.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import { link } from './instances/ct.js';

  const list = poll('/api/sys/recipes/list', 30000);

  // name, description, containers (comma separated, - for none), state: installed | partly | not installed | parked | unknown
  const apps = $derived(rows(list).map((r) => ({ name: r[0], desc: r[1], cts: r[2] === '-' ? '' : r[2], state: r[3] })));
  const installed = $derived(apps.filter((a) => a.state === 'installed').length);

  // the icons the design gives the known recipes; anything else is a package
  const icons = {
    arr: 'film-slate', authentik: 'key', bulwark: 'envelope-open', cloudflared: 'cloud', docker: 'shipping-container', docs: 'book-open',
    homeassistant: 'house-line', domain: 'identification-badge', homepage: 'house', immich: 'images', jellyfin: 'film-strip', 'matrix-hook': 'chat-circle-text',
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
  <div class="card tc">
    <Table id="apps" {columns} rows={shown} key="name" loading={!list.loaded} empty="No app matches.">
      {#snippet cell(a, col)}
        {@const on = a.state === 'installed'}
        {#if col.key === 'go'}
          <button class="btn sm {on ? '' : 'btn-primary'}" disabled={a.state === 'parked'} use:tip={a.state === 'parked' ? 'This recipe is parked' : on ? 'Run again: repairs or updates the setup' : 'Set this app up'} onclick={() => run(a)}><i class="ph ph-{on ? 'arrows-clockwise' : 'download-simple'}"></i>{on ? 'Update' : 'Install'}</button>
        {:else if col.key === 'name'}
          <span id="app-{a.name}" class="nm" class:hl={hl === a.name}><i class="ph ph-{icons[a.name] ?? 'package'}" style="color:{on ? 'var(--accent-ink)' : 'var(--fg-3)'}"></i>{a.name}</span>
        {:else if col.key === 'desc'}
          <span class="ds">{a.desc}</span>{#if a.cts}<div class="in">In {#each a.cts.split(',') as c, i}{i ? ', ' : ''}<a {...link('/instances', 'instances', c)}>{c}</a>{/each}</div>{/if}
        {:else if col.key === 'state'}
          <StatusDot state={on ? 'ok' : a.state === 'partly' ? 'warn' : 'off'} label={a.state} />
        {:else}
          <button class="btn btn-ghost btn-icon" disabled={!a.cts} use:tip={a.cts ? 'Services: local and public access' : 'Install the app first'} aria-label="Services of {a.name}" onclick={() => services(a)}><i class="ph ph-globe-hemisphere-west"></i></button>
          <button class="btn btn-ghost btn-icon" use:tip={copied === a.name ? 'Copied' : 'Copy the terminal command: hs recipe ' + a.name} aria-label="Copy hs recipe {a.name}" onclick={() => copy(a.name)}><i class="ph ph-{copied === a.name ? 'check' : 'terminal-window'}"></i></button>
        {/if}
      {/snippet}
    </Table>
  </div>
</PageState>

<style>
  .bar { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
  .find { margin-left: auto; max-width: 240px; }
  .nm { display: inline-flex; align-items: center; gap: 8px; font-weight: 600; font-size: 13.5px; }
  .nm i { font-size: 18px; }
  .nm.hl { outline: 2px solid var(--accent); outline-offset: 3px; }
  .ds { font-size: 12.5px; color: var(--fg-3); }
  .in { font-size: 12px; color: var(--fg-2); }
</style>
