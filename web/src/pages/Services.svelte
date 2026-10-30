<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import { openPlan, openCreate, ui } from '../ui.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Banner from '../ui/Banner.svelte';
  import Kv from '../ui/Kv.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import { ctOf, link, servicesOf } from './instances/ct.js';
  import Table from '../shell/Table.svelte';
  import ServiceForm from '../forms/ops/ServiceForm.svelte';
  import Board from '../dashboard/Board.svelte';
  import { boardPoll } from '../dashboard/board.svelte.js';
  import { onDestroy } from 'svelte';

  // the tile dashboard (dashboard variant web); polled only while it is on
  const boardOn = ui.features.dashboard === 'web';
  const board = boardOn ? boardPoll() : null;
  onDestroy(() => board?.stop?.());

  const svc = poll('/api/sys/services/list', 15000);
  const plan = poll('/api/sys/services/routes', 15000);
  // the gateway proxy (capability gateway): read only while the capability is on
  const gateway = $derived(Array.isArray(ui.features.capabilities) && ui.features.capabilities.includes('gateway'));
  const local = poll(() => (gateway ? '/api/sys/services/local-routes' : ''), 15000);
  const gw = poll(() => (gateway ? '/api/sys/gateway/status' : ''), 30000);
  const ctl = poll('/api/sys/ct/list', 30000);
  // the instance a service points at (its name or address in the target), for the link
  const cts = $derived(rows(ctl).map(ctOf));
  const ctOfTarget = (s) => cts.find((c) => servicesOf(c, [s]).length)?.name ?? '';

  // services list: name, title, target, exposure, names, wants
  const services = $derived(rows(svc).map((r) => ({ name: r[0], title: r[1], target: r[2], exposure: r[3], names: r[4], wants: r[5] })));
  // services routes: act, host, path, target, service, note; a lone "status none" row = no reverse proxy
  const noProxy = $derived(rows(plan).some((r) => r[0] === 'status' && r[1] === 'none'));
  const routes = $derived(rows(plan).filter((r) => r[0] !== 'status' && r[0] !== 'warn').map((r) => ({ act: r[0], host: r[1], path: r[2], target: r[3], service: r[4], note: r[5] ?? '' })));
  const warns = $derived(rows(plan).filter((r) => r[0] === 'warn').map((r) => r[5] ?? ''));
  const todo = $derived(routes.filter((r) => ['add', 'confirm', 'change', 'remove'].includes(r.act)).length);
  const handmade = $derived(routes.filter((r) => r.act === 'ok' && r.note.startsWith('not adopted')).length);

  // local routes: the same columns as the routes; gateway status is key, value
  const localRoutes = $derived(rows(local).filter((r) => r[0] !== 'status' && r[0] !== 'warn').map((r) => ({ act: r[0], host: r[1], path: r[2], target: r[3], service: r[4], note: r[5] ?? '' })));
  const localTodo = $derived(localRoutes.filter((r) => ['add', 'change', 'remove'].includes(r.act)).length);
  const gwv = $derived(Object.fromEntries(rows(gw).map((r) => [r[0], r[1]])));
  const tone = (a) => (['violation', 'blocked', 'conflict', 'invalid'].includes(a) ? 'bad' : ['confirm', 'change', 'remove', 'unresolved', 'manual'].includes(a) ? 'warn' : a === 'add' ? 'info' : a === 'ok' ? 'ok' : 'off');
  const dash = (v) => (v === '-' || v === undefined ? '' : v);

  const columns = [
    { key: 'name', label: 'Name' }, { key: 'title', label: 'Title' }, { key: 'target', label: 'Target' }, { key: 'exposure', label: 'Exposure' },
    { key: 'names', label: 'Names' }, { key: 'wants', label: 'Wants' }, { key: 'rm', label: '', sort: false, align: 'right' },
  ];
  const routeCols = [
    { key: 'act', label: 'State' }, { key: 'host', label: 'Host' }, { key: 'path', label: 'Path' }, { key: 'target', label: 'Target' }, { key: 'service', label: 'Service' }, { key: 'note', label: 'Note' },
  ];
</script>

<PageHeader title="Services" crumb="{ui.host} › Instances" sub="What the reverse proxy publishes, and what each service wants. Public means reachable from the internet; admin pages never are.">
  {#snippet actions()}
    <button use:tip={'Describe a service so the proxy can route it'} class="btn btn-primary" onclick={() => openCreate(ServiceForm)}><i class="ph ph-plus"></i>Describe a service…</button>
    <button class="btn" disabled={noProxy || !todo} use:tip={todo ? 'Make the routes the services want' : 'The proxy already matches the services'} onclick={() => openPlan('routes', ['apply'], 'Apply the routes')}><i class="ph ph-check-circle"></i>Apply{todo ? ` (${todo})` : ''}…</button>
    <button class="btn btn-ghost" disabled={noProxy || !handmade} use:tip={'Let hs manage routes that were made by hand'} onclick={() => openPlan('routes', ['adopt'], 'Adopt routes')}><i class="ph ph-hand-grabbing"></i>Adopt…</button>
    <button class="btn btn-ghost" disabled={noProxy} use:tip={'Describe the routes of the proxy as services'} onclick={() => openPlan('routes', ['import'], 'Import services')}><i class="ph ph-download-simple"></i>Import…</button>
  {/snippet}
</PageHeader>

{#if boardOn}
  <div class="card tc">
    <div class="sh dh">
      <span>Dashboard</span>
      <a class="btn btn-ghost" href="/dashboard" target="_blank" rel="noopener noreferrer"><i class="ph ph-arrows-out"></i>Open full screen</a>
    </div>
    {#if board.error && !board.doc}<Banner tone="warn">{board.error}</Banner>
    {:else if board.doc}<Board doc={board.doc} host={location.hostname} />{/if}
  </div>
{:else}
  <div class="muted">The dashboard is off: <code>hs config set dashboard web</code></div>
{/if}

{#if noProxy}
  <Banner tone="info">No reverse proxy is set up. Run <code>hs recipe zoraxy</code>, then <code>hs config set reverseProxy zoraxy</code>.</Banner>
{/if}
{#each warns as w}<Banner tone="warn">{w}</Banner>{/each}

<PageState loading={!svc.loaded} error={svc.error?.message} hasData={svc.data != null} empty={svc.loaded && !svc.error && !services.length}
           emptyIcon="arrows-split" emptyTitle="No services yet" emptyText="Import the routes of the proxy, or run a recipe: it describes its own service.">
  {#snippet emptyAction()}<button use:tip={'Describe a service so the proxy can route it'} class="btn btn-primary" onclick={() => openCreate(ServiceForm)}><i class="ph ph-plus"></i>Describe a service…</button>{/snippet}
  <div class="card tc">
    <div class="sh">Services</div>
    <Table id="services" {columns} rows={services} key="name" loading={!svc.loaded} empty="No services.">
      {#snippet cell(s, col)}
        {#if col.key === 'name'}<code>{s.name}</code>
        {:else if col.key === 'title'}<span class="c">{dash(s.title)}</span>
        {:else if col.key === 'target'}
          {@const ct = ctOfTarget(s)}
          <span class="c">{#if ct}<a {...link('/instances', 'instances', ct)} use:tip={`Open the instance ${ct}`}>{s.target}</a>{:else}{s.target}{/if}</span>
        {:else if col.key === 'exposure'}<span class="tag {s.exposure === 'public-ok' ? 'tag-accent' : 'tag-neutral'}">{s.exposure}</span>
        {:else if col.key === 'names'}<span class="c">{dash(s.names)}</span>
        {:else if col.key === 'wants'}<span class="c">{dash(s.wants)}</span>
        {:else}<button class="btn btn-ghost btn-icon rm" use:tip={`Change ${s.name}`} aria-label="Change {s.name}" onclick={() => openCreate(ServiceForm, { edit: s.name })}><i class="ph ph-pencil-simple"></i></button><button class="btn btn-ghost btn-icon rm" use:tip={`Forget the description of ${s.name} (its routes stay)`} aria-label="Forget {s.name}" onclick={() => openPlan('routes', ['remove', s.name], 'Forget ' + s.name)}><i class="ph ph-x"></i></button>{/if}
      {/snippet}
    </Table>
  </div>

  {#if !noProxy}
    <div class="card tc">
      <div class="sh">Routes on the proxy against the services</div>
      <Table id="service-routes" columns={routeCols} rows={routes} loading={!plan.loaded}
             empty={plan.error ? 'The routes could not be read.' : 'No services want a route and the proxy has none.'}>
        {#snippet cell(r, col)}
          {#if col.key === 'act'}<StatusDot state={tone(r.act)} label={r.act} />
          {:else}<span class="c">{col.key === 'note' ? r.note : dash(r[col.key])}</span>{/if}
        {/snippet}
      </Table>
    </div>
  {/if}
</PageState>
{#if gateway}
  <div class="card tc">
    <div class="sh">Local names (gateway proxy)</div>
    {#if gw.loaded && gwv.wildcard && gwv.wildcard !== 'ok'}<Banner tone="warn">The wildcard DNS record is {gwv.wildcard}. Run <code>hs gateway check</code> in a terminal.</Banner>{/if}
    <Kv items={[{ k: 'Service', v: gwv.service ?? '' }, { k: 'Web interface', v: gwv.webui ?? '' }, { k: 'Domain', v: gwv.domain ?? '' }, { k: 'Wildcard', v: gwv.wildcard ?? '' }, { k: 'Port 80', v: gwv.port80 ?? '' }]} />
    <div class="acts">
      <button class="btn" disabled={!localTodo} use:tip={localTodo ? 'Make the local names the services want' : 'The gateway proxy already matches the services'} onclick={() => openPlan('routes', ['apply', '--proxy', 'local'], 'Apply the local names')}><i class="ph ph-check-circle"></i>Apply local{localTodo ? ` (${localTodo})` : ''}…</button>
      <button class="btn btn-ghost" use:tip={'Let every service without a choice get a local name'} onclick={() => openPlan('routes', ['import', '--proxy', 'local'], 'Import local names')}><i class="ph ph-download-simple"></i>Import local…</button>
    </div>
    <Table id="service-local-routes" columns={routeCols} rows={localRoutes} loading={!local.loaded}
           empty={local.error ? 'The local names could not be read.' : 'No services want a local name.'}>
      {#snippet cell(r, col)}
        {#if col.key === 'act'}<StatusDot state={tone(r.act)} label={r.act} />
        {:else}<span class="c">{col.key === 'note' ? r.note : dash(r[col.key])}</span>{/if}
      {/snippet}
    </Table>
  </div>
{/if}
<div class="muted">The proxy login (<code>hs services proxy login</code>) stays in the terminal: it carries a password.</div>

<style>
  .tc { padding: 12px 14px; }
  .sh { font-size: 12px; color: var(--fg-3); margin-bottom: 6px; }
  .dh { display: flex; align-items: center; justify-content: space-between; }
  .acts { display: flex; gap: 8px; margin: 8px 0; }
  .muted { font-size: 12px; color: var(--fg-3); }
  .c { color: var(--fg-2); }
  .rm { width: 28px; min-height: 28px; color: var(--fg-3); }
</style>
