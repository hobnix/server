<script>
  import { poll, rows, refresh } from '../data.svelte.js';
  import { takeSelection } from '../select.svelte.js';
  import { openCreate, ui } from '../ui.svelte.js';
  import RunRecipe from '../forms/ops/RunRecipe.svelte';
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

<PageHeader title="Apps" crumb="{ui.host} › Instances" sub={list.loaded && !list.error ? `${installed} installed · one-command installers, safe to run again` : 'One-command installers, safe to run again.'} />

<div class="note"><i class="ph ph-terminal-window"></i>Run shows the plan first, then sets an app up with the answers you give in the form (a token, a VPN account ...), the answers stored last time and the defaults; it shows up under Tasks. Only the domain recipe needs a terminal: the Administrator password is typed into Samba.</div>

<PageState loading={!list.loaded} error={list.error?.message} hasData={list.data != null} empty={list.loaded && !list.error && !apps.length}
           emptyIcon="package" emptyTitle="No recipes" emptyText="This server has no app recipes." retry={() => refresh(['/api/sys/recipes/list'])}>
  <div class="grid">
    {#each apps as a (a.name)}
      {@const on = a.state === 'installed'}
      <div class="card app" id="app-{a.name}" class:hl={hl === a.name}>
        <div class="top">
          <i class="ph ph-{icons[a.name] ?? 'package'}" style="font-size:18px;color:{on ? 'var(--accent-ink)' : 'var(--fg-3)'}"></i>
          <span class="nm">{a.name}</span>
          <span class="st"><StatusDot state={on ? 'ok' : a.state === 'partly' ? 'warn' : 'off'} label={a.state} /></span>
        </div>
        <div class="ds">{a.desc}</div>
        {#if a.cts}
          <div class="in">In {#each a.cts.split(',') as c, i}{i ? ', ' : ''}<a {...link('/instances', 'instances', c)}>{c}</a>{/each}</div>
        {/if}
        <div class="act"><button class="btn sm" disabled={a.state === 'parked'} title={a.state === 'parked' ? 'This recipe is parked' : on ? 'Run again: repairs or updates the setup' : 'Set this app up'} onclick={() => run(a)}><i class="ph ph-play"></i>{on ? 'Run again…' : 'Run…'}</button></div>
        <div class="cmd">
          <code>hs recipe {a.name}</code>
          <button class="btn btn-ghost btn-icon cp" title={copied === a.name ? 'Copied' : 'Copy'} aria-label="Copy hs recipe {a.name}" onclick={() => copy(a.name)}><i class="ph ph-{copied === a.name ? 'check' : 'copy'}"></i></button>
        </div>
      </div>
    {/each}
  </div>
</PageState>

<style>
  .note { display: flex; gap: 10px; align-items: center; padding: 10px 12px; border: 1px solid var(--line); background: var(--panel); font-size: 12.5px; color: var(--fg-2); }
  .note i { font-size: 16px; color: var(--accent-ink); }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 12px; }
  .app { padding: 14px 16px; gap: 8px; }
  .app.hl { outline: 2px solid var(--accent); }
  .top { display: flex; align-items: center; gap: 8px; }
  .nm { font-weight: 600; }
  .st { margin-left: auto; font-size: 12px; }
  .ds { font-size: 12.5px; color: var(--fg-3); flex: 1; }
  .in { font-size: 12.5px; color: var(--fg-2); }
  .cmd { display: flex; align-items: center; gap: 6px; }
  code { flex: 1; font-size: 11.5px; padding: 4px 8px; background: var(--bg); color: var(--fg-2); overflow: hidden; text-overflow: ellipsis; }
  .cp { width: 28px; min-height: 28px; color: var(--fg-3); }
  .act { display: flex; }
</style>
