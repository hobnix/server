<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { openPlan, openCreate, jobRunning, ui } from '../ui.svelte.js';
  import { prefetchPlan } from '../api.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Banner from '../ui/Banner.svelte';
  import Button from '../ui/Button.svelte';
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

  // the form only writes the description: read the list and the plans again now, so Apply knows what is new without waiting for the next poll
  const readAgain = () => refresh(['/api/sys/services/list', '/api/sys/services/routes', ...(gateway ? ['/api/sys/services/local-routes'] : [])]);
  const describe = (props = {}) => openCreate(ServiceForm, { ...props, ondone: readAgain });

  // a routes job (Apply, Adopt, Import, Forget) started from here: its buttons stay busy until it ends, then the plans are read again
  // (the next poll could be 15 s away and Apply would still show the old count)
  const routesJob = $derived(jobRunning('routes'));
  let wasRunning = false;
  $effect(() => {
    if (wasRunning && !routesJob) readAgain();
    wasRunning = routesJob;
  });

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
    <Button variant="primary" tooltip={'Describe a service so the proxy can route it'} onclick={() => describe()}><i class="ph ph-plus"></i>Describe a service…</Button>
    <Button icon="check-circle" disabled={noProxy || !todo || (routesJob && !jobRunning('routes', ['apply']))} busy={jobRunning('routes', ['apply'])} busyLabel="Applying…" tooltip={todo ? 'Make the routes the services want' : 'The proxy already matches the services'} onpointerenter={() => prefetchPlan('routes', ['apply'])} onfocus={() => prefetchPlan('routes', ['apply'])} onclick={() => openPlan('routes', ['apply'], 'Apply the routes')}>Apply{todo ? ` (${todo})` : ''}…</Button>
    <Button variant="ghost" icon="hand-grabbing" disabled={noProxy || !handmade || (routesJob && !jobRunning('routes', ['adopt']))} busy={jobRunning('routes', ['adopt'])} busyLabel="Adopting…" tooltip={'Let hs manage routes that were made by hand'} onclick={() => openPlan('routes', ['adopt'], 'Adopt routes')}>Adopt…</Button>
    <Button variant="ghost" icon="download-simple" disabled={noProxy || (routesJob && !jobRunning('routes', ['import']))} busy={jobRunning('routes', ['import'])} busyLabel="Importing…" tooltip={'Describe the routes of the proxy as services'} onclick={() => openPlan('routes', ['import'], 'Import services')}>Import…</Button>
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
  {#snippet emptyAction()}<Button variant="primary" tooltip={'Describe a service so the proxy can route it'} onclick={() => describe()}><i class="ph ph-plus"></i>Describe a service…</Button>{/snippet}
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
        {:else}<Button variant="ghost" class="btn-icon services-rm" tooltip={`Change ${s.name}`} aria-label="Change {s.name}" onclick={() => describe({ edit: s.name })}><i class="ph ph-pencil-simple"></i></Button><Button variant="ghost" class="btn-icon services-rm" tooltip={`Forget the description of ${s.name} (its routes stay)`} aria-label="Forget {s.name}" onclick={() => openPlan('routes', ['remove', s.name], 'Forget ' + s.name)}><i class="ph ph-x"></i></Button>{/if}
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
      <Button icon="check-circle" disabled={!localTodo || (routesJob && !jobRunning('routes', ['apply', '--proxy', 'local']))} busy={jobRunning('routes', ['apply', '--proxy', 'local'])} busyLabel="Applying…" tooltip={localTodo ? 'Make the local names the services want' : 'The gateway proxy already matches the services'} onclick={() => openPlan('routes', ['apply', '--proxy', 'local'], 'Apply the local names')}>Apply local{localTodo ? ` (${localTodo})` : ''}…</Button>
      <Button variant="ghost" icon="download-simple" disabled={routesJob && !jobRunning('routes', ['import', '--proxy', 'local'])} busy={jobRunning('routes', ['import', '--proxy', 'local'])} busyLabel="Importing…" tooltip={'Let every service without a choice get a local name'} onclick={() => openPlan('routes', ['import', '--proxy', 'local'], 'Import local names')}>Import local…</Button>
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
  :global(.btn.services-rm) { width: 28px; min-height: 28px; color: var(--fg-3); }
</style>
