<script>
  // One subpage of Settings, chosen by the address (/settings/<page>): General, Network and DNS, Storage, Backups, Users and access, Updates,
  // Advanced. The fields come from layout.gen.json (generated from `page` in config/schema.toml); Advanced lists every key. General also holds
  // Appearance and the Nodes card, Updates the version and the update actions, Advanced the Check button.
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import { get } from '../api.js';
  import { route, go } from '../route.svelte.js';
  import { openPlan } from '../ui.svelte.js';
  import { changes, load } from '../changes.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import Fields from './Fields.svelte';
  import layout from './layout.gen.json';
  import { fieldsFor } from './layout.js';
  import { useConfig } from './config.svelte.js';

  let { deck } = $props();    // the shared status document (Shell polls it)

  // The look of the interface (settings/Appearance.svelte): mounted when the file exists. A glob import may find nothing, so a build without the file works.
  const appearance = import.meta.glob('./Appearance.svelte', { eager: true });
  const Appearance = Object.values(appearance)[0]?.default ?? null;

  const TITLES = {
    general: ['General', 'The name, language and look of this server and its web interface.'],
    network: ['Network and DNS', 'The network card, address ranges and names.'],
    storage: ['Storage', 'Pools, snapshots and disk behaviour.'],
    backups: ['Backups', 'What gets backed up and how.'],
    access: ['Users and access', 'Who can sign in and from where.'],
    updates: ['Updates', 'The installed version, new changes upstream and the update actions.'],
    advanced: ['Advanced', '/etc/nixos/machine.toml and the settings that need no rebuild: every key.'],
  };
  const page = $derived(route.path.split('/')[2] || 'general');
  const title = $derived(TITLES[page] ?? TITLES.general);

  const { list, opts: getOpts } = useConfig();
  const fields = $derived(fieldsFor(layout, page, getOpts()));

  // General: the Nodes card
  const nodeList = poll(() => (page === 'general' ? '/api/sys/node/list' : ''), 30000);

  // Updates: `hs sys system updates` rows behind, ahead, upstream, fetched; the installed revision is the changelog head (changes.svelte.js)
  const updates = poll(() => (page === 'updates' && !deck?.data?.locked ? '/api/sys/system/updates' : ''), 60000);
  const upd = $derived(Object.fromEntries(rows(updates).map((r) => [r[0], r[1]])));
  const behind = $derived(Number(upd.behind) || 0);
  const fetched = $derived(upd.fetched && upd.fetched !== '-' ? new Date(Number(upd.fetched) * 1000).toLocaleString() : 'never');
  $effect(() => { if (page === 'updates' && !changes.loaded) load(); });

  // Advanced: check machine.toml
  let chk = $state(null);          // { text, rc } of the last check
  let chkBusy = $state(false);
  let chkError = $state('');
  async function runCheck() {
    chkBusy = true; chkError = '';
    try { chk = await get('/api/sys/config/check'); }
    catch (e) { chkError = e.message; }
    finally { chkBusy = false; }
  }
</script>

<div class="page">
  <PageHeader title={title[0]} crumb="Settings" sub={title[1]}>
    {#snippet actions()}
      {#if page === 'advanced'}
        <button use:tip={chkBusy ? 'A check is running' : 'Look for typos and missing values in machine.toml'} class="btn b13" onclick={runCheck} disabled={chkBusy}><i class="ph ph-check-square"></i>Check</button>
      {/if}
    {/snippet}
  </PageHeader>

  {#if page === 'advanced' && (chk || chkError)}
    <div class="card elev-sm res" class:bad={chk && chk.rc !== 0} role="status">
      <div class="rh">
        <i class="ph ph-{chkError || chk.rc !== 0 ? 'warning-circle' : 'check-circle'}" style="color:{chkError || chk.rc !== 0 ? 'var(--st-bad)' : 'var(--st-ok)'}"></i>
        <span>{chkError ? 'The check could not run.' : chk.rc === 0 ? 'machine.toml is fine' : 'machine.toml has problems'}</span>
        <span style="flex:1"></span>
        <button use:tip={'Close the result'} class="btn btn-ghost btn-icon x" aria-label="Close" onclick={() => { chk = null; chkError = ''; }}><i class="ph ph-x"></i></button>
      </div>
      <pre>{chkError || chk.text.trim()}</pre>
    </div>
  {/if}

  {#if page === 'general'}
    {#if Appearance}<Appearance />{/if}
    <div class="cols">
      <div class="card sec" id="nodes">
        <div class="st">Nodes</div>
        <p class="hp2">The other servers this one looks at: {rows(nodeList).length} on the list. Adding, removing and the keys are on the Nodes page.</p>
        <button use:tip={'Open the list of servers'} class="btn sm" style="align-self:flex-start" onclick={() => go('/nodes')}><i class="ph ph-hard-drives"></i>Open Nodes</button>
      </div>
    </div>
  {/if}

  {#if page === 'updates'}
    <div class="cols">
      <div class="card sec">
        <div class="st">This server</div>
        <div class="kv"><span>Installed revision</span><code>{changes.head ? changes.head.slice(0, 7) : '-'}</code></div>
        <div class="kv"><span>Upstream</span><code>{upd.upstream && upd.upstream !== '-' ? upd.upstream : 'none'}</code></div>
        <div class="kv"><span>Last looked</span><span>{fetched}</span></div>
        <p class="hp2">{updates.loaded ? (behind > 0 ? `${behind} new change${behind === 1 ? '' : 's'} upstream.` : 'Up to date as of the last look.') : 'Loading…'}</p>
        <div class="acts">
          <button use:tip={'Update the server (snapshots first; shows the plan)'} class="btn btn-primary b13" disabled={!!deck?.data?.locked} onclick={() => openPlan('system', ['update'], 'Update')}><i class="ph ph-arrow-circle-up"></i>Update…</button>
          <button use:tip={'Read what is new, change by change'} class="btn b13" onclick={() => go('/operations/whats-new')}><i class="ph ph-sparkle"></i>What's new</button>
        </div>
      </div>
      <div class="card sec">
        <div class="st">New options</div>
        <p class="hp2">After an update machine.toml may lack options that were added. Syncing puts them in their place with their defaults; your values stay. It shows the plan first.</p>
        <button use:tip={'Put machine.toml in the layout of the example (shows the plan)'} class="btn sm" style="align-self:flex-start" onclick={() => openPlan('config', ['sync'], 'Sync machine.toml')}><i class="ph ph-arrows-clockwise"></i>Sync new options…</button>
      </div>
    </div>
  {:else if fields.length}
    <Fields opts={fields} />
  {:else}
    <div class="muted">{list.loaded ? (list.error ? `The settings could not be read${list.error?.message ? `: ${list.error.message}` : '.'}` : 'No settings on this page.') : 'Loading…'}</div>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .b13 { font-size: 13px; }
  .hp2 { margin: 0; font-size: 12.5px; color: var(--color-neutral-500); }
  .cols { column-width: 400px; column-gap: 14px; }
  .sec { padding: 14px 16px; gap: 10px; break-inside: avoid; margin-bottom: 14px; }
  .st { font-size: 14px; font-weight: 500; }
  .kv { display: flex; justify-content: space-between; gap: 12px; font-size: 13px; }
  .kv span:first-child { color: var(--color-neutral-500); }
  .acts { display: flex; gap: 8px; flex-wrap: wrap; }
  .res { padding: 12px 14px; gap: 8px; }
  .res.bad { box-shadow: inset 0 0 0 1px var(--st-bad); }
  .rh { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 500; }
  .x { width: 26px; height: 26px; color: var(--color-neutral-400); }
  pre { margin: 0; font-size: 12px; white-space: pre-wrap; color: var(--color-neutral-300); font-family: var(--font-mono, ui-monospace, monospace); }
  .muted { font-size: 12px; color: var(--fg-3); }
</style>
