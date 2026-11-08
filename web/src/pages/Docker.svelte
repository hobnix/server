<script>
  // The Docker page: the apps (compose projects) that run in the locked docker container.
  import { poll, rows, refresh } from '../data.svelte.js';
  import { takeSelection } from '../select.svelte.js';
  import { tip } from '../ui/tooltip.svelte.js';
  import { openPlan, jobRunning, ui } from '../ui.svelte.js';
  import { url, go } from '../route.svelte.js';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Button from '../ui/Button.svelte';
  import Split from '../ui/Split.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import Kv from '../ui/Kv.svelte';
  import Chip from '../ui/Chip.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Banner from '../ui/Banner.svelte';
  import AppLogs from './docker/AppLogs.svelte';
  import { appOf, filesChip, applyOf, isActionable } from './docker/apps.js';
  import { problems } from './docker/health.js';

  const appsPoll = poll('/api/sys/docker/apps', 30000);
  const statusPoll = poll('/api/sys/docker/status', 15000);
  const healthPoll = poll('/api/sys/docker/health', 30000);

  let selName = $state('');
  let tab = $state('overview');
  $effect(() => { const n = takeSelection('docker'); if (n) selName = n; });
  $effect(() => { if (sel) tab = 'overview'; });

  const apps = $derived(rows(appsPoll).map(appOf).filter(Boolean));
  const status = $derived(Object.fromEntries(rows(statusPoll).map((r) => [r[0], r[1]])));
  // Docker is on, but something it needs is missing (the share apps, its mount): said once at the top, with the command that fixes it
  const broken = $derived(status.state === 'on' ? problems(rows(healthPoll)) : []);
  const sel = $derived(apps.find((a) => a.name === selName) ?? null);
  const runningCount = $derived(apps.filter((a) => a.state === 'running').length);

  const dot = (s) => (s === 'running' ? 'ok' : s === 'partial' ? 'warn' : 'off');
  const portHref = (app, port) => (app.address && app.address !== '-' ? `http://${app.address}:${port}` : null);
  const applyPlan = (e, app) => { e.stopPropagation(); openPlan('docker-app', [app.name, 'recreate'], `apply ${app.name}`); };
  const plan = (e, app, action) => { e.stopPropagation(); openPlan('docker-app', [app.name, action], `${action} ${app.name}`); };

  const columns = [
    { key: 'name', label: 'Name' },
    { key: 'state', label: 'State' },
    { key: 'running', label: 'Running' },
    { key: 'ports', label: 'Ports' },
    { key: 'images', label: 'Images', optional: true },
    { key: 'managed', label: 'Managed' },
    { key: 'actions', label: '', sort: false, align: 'right' },
  ];
  const tabs = $derived(sel?.managed === 'unmanaged'
    ? [{ id: 'overview', label: 'Overview' }]
    : sel?.managed === 'web'
    ? [{ id: 'overview', label: 'Overview' }, { id: 'compose', label: 'Compose' }, { id: 'logs', label: 'Logs' }]
    : [{ id: 'overview', label: 'Overview' }, { id: 'logs', label: 'Logs' }]);
</script>

<PageHeader title="Docker" crumb="Instances" sub={apps.length ? `${runningCount} of ${apps.length} apps running${status.address && status.address !== '-' ? ` · ${status.address}` : ''}` : 'Apps that run in the Docker container.'} />

{#if broken.length}
  <Banner tone="bad">
    Docker is on, but not complete: {broken.map((b) => b.reason).join(' ')}
    {#snippet action()}<a class="btn" href={url('/settings/capabilities/docker')}>Open Docker settings</a>{/snippet}
  </Banner>
{/if}

<PageState loading={!appsPoll.loaded} error={appsPoll.error?.message} hasData={appsPoll.data != null}
           empty={appsPoll.loaded && !apps.length && !appsPoll.error} emptyIcon="shipping-container" emptyTitle="No apps yet" emptyText="No apps run in Docker yet."
           retry={() => refresh(['/api/sys/docker/apps'])}>
  {#if status.state !== 'on'}
    <EmptyState icon="shipping-container" title="Docker is off" tone="info" text="Turn Docker on under Settings, Capabilities, Docker.">
      {#snippet action()}<a class="btn" href={url('/settings/capabilities/docker')}>Open Docker settings</a>{/snippet}
    </EmptyState>
  {:else}
    <div class="toolbar"><Button size="sm" icon="plus" onclick={() => go('/instances/docker/new')}>New app</Button> <Button size="sm" icon="magic-wand" onclick={() => go('/instances/docker/wizard')}>Guided</Button></div>
    <Split open={!!sel}>
      {#snippet list()}
        <div class="card" style="padding:0">
          <Table id="docker-apps" {columns} rows={apps} key="name" selected={sel?.name} onrow={(a) => { selName = a.name; }} loading={!appsPoll.loaded} empty="No apps.">
            {#snippet cell(a, col)}
              {#if col.key === 'name'}{a.name}
                {#if filesChip(a)}{@const c = filesChip(a)} <Chip tone={c.tone} title={c.tip}>{c.text}</Chip>{/if}
              {:else if col.key === 'state'}<StatusDot state={dot(a.state)} label={a.state} />
              {:else if col.key === 'running'}{#if a.running === '0/0'}<span use:tip={"No containers yet: save applies when the app is started or pulled"}>–</span>{:else}{a.running}{/if}
              {:else if col.key === 'ports'}
                {@const ports = a.ports === '-' ? [] : a.ports.split(',').filter(Boolean)}
                {#if ports.length}
                  {#each ports as p, i}{#if i > 0}, {/if}{#if portHref(a, p)}<a href={portHref(a, p)} target="_blank" rel="noopener" onclick={(e) => e.stopPropagation()}>{p}</a>{:else}{p}{/if}{/each}
                {:else}–{/if}
              {:else if col.key === 'images'}<span class="images" use:tip={a.images}>{a.images}</span>
              {:else if col.key === 'managed'}<Chip>{a.managed}</Chip>
              {:else if !isActionable(a)}
                <span class="acts"></span>
              {:else}
                <span class="acts">
                  {#if applyOf(a).show}
                    <Button variant="ghost" size="sm" icon="check-circle" disabled={!applyOf(a).ok} busy={jobRunning('docker-app', [a.name, 'recreate'])} tooltip={applyOf(a).ok ? 'Apply: docker compose up -d from the files on disk (no pull, no build)' : applyOf(a).reason} aria-label="Apply {a.name}" onclick={(e) => applyPlan(e, a)}>Apply</Button>
                  {/if}
                  {#if a.state === 'exited' || a.state === 'created' || a.state === 'stopped'}
                    <Button variant="ghost" class="btn-icon ib" icon="play" busy={jobRunning('docker-app', [a.name, 'start'])} tooltip="Start" aria-label="Start {a.name}" onclick={(e) => plan(e, a, 'start')} />
                  {:else if a.state === 'running' || a.state === 'partial'}
                    <Button variant="ghost" class="btn-icon ib" icon="stop" busy={jobRunning('docker-app', [a.name, 'stop'])} tooltip="Stop" aria-label="Stop {a.name}" onclick={(e) => plan(e, a, 'stop')} />
                  {/if}
                  <Button variant="ghost" class="btn-icon ib" icon="arrow-clockwise" busy={jobRunning('docker-app', [a.name, 'restart'])} tooltip="Restart" aria-label="Restart {a.name}" onclick={(e) => plan(e, a, 'restart')} />
                  <Button variant="ghost" class="btn-icon ib" icon="download-simple" busy={jobRunning('docker-app', [a.name, 'pull'])} tooltip="Pull" aria-label="Pull {a.name}" onclick={(e) => plan(e, a, 'pull')} />
                </span>
              {/if}
            {/snippet}
          </Table>
        </div>
      {/snippet}
      {#snippet side()}
        {#if sel}
          <Drawer title={sel.name} chip={sel.managed} state={dot(sel.state)} stateLabel={sel.state} {tabs} bind:tab onclose={() => { selName = ''; }}>
            {#snippet children(t)}
              {#if t === 'overview'}
                <Kv items={[{ k: 'State', v: sel.state }, { k: 'Running', v: sel.running }, { k: 'Project', v: sel.project }, { k: 'Address', v: sel.address }, { k: 'Ports', v: sel.ports }, { k: 'Images', v: sel.images }, { k: 'Managed', v: sel.managed }, { k: 'Update', v: sel.update }, ...(sel.files !== '-' ? [{ k: 'Files', v: sel.files }] : [])]} />
              {:else if t === 'compose'}
                <Button icon="pencil-simple" onclick={() => go(`/instances/docker/app/${encodeURIComponent(sel.name)}`)}>Open editor</Button>
              {:else}
                {#key sel.name}<AppLogs app={sel.name} />{/key}
              {/if}
            {/snippet}
            {#snippet actions()}
              {#if !isActionable(sel)}
                <Chip title={filesChip(sel).tip}>{filesChip(sel).text}</Chip>
              {:else}
              {#if applyOf(sel).show}
                <Button size="sm" variant="primary" icon="check-circle" disabled={!applyOf(sel).ok} busy={jobRunning('docker-app', [sel.name, 'recreate'])} busyLabel="Applying…" tooltip={applyOf(sel).ok ? 'Recreate the app from the files on disk' : applyOf(sel).reason} onclick={(e) => applyPlan(e, sel)}>Apply</Button>
              {/if}
              {#if sel.state === 'exited' || sel.state === 'created' || sel.state === 'stopped'}
                <Button size="sm" icon="play" busy={jobRunning('docker-app', [sel.name, 'start'])} busyLabel="Starting…" tooltip="Start this app" onclick={(e) => plan(e, sel, 'start')}>Start</Button>
              {:else if sel.state === 'running' || sel.state === 'partial'}
                <Button size="sm" icon="stop" busy={jobRunning('docker-app', [sel.name, 'stop'])} busyLabel="Stopping…" tooltip="Stop this app" onclick={(e) => plan(e, sel, 'stop')}>Stop</Button>
              {/if}
              <Button size="sm" icon="arrow-clockwise" busy={jobRunning('docker-app', [sel.name, 'restart'])} busyLabel="Restarting…" tooltip="Restart this app" onclick={(e) => plan(e, sel, 'restart')}>Restart</Button>
              <Button size="sm" icon="download-simple" busy={jobRunning('docker-app', [sel.name, 'pull'])} busyLabel="Pulling…" tooltip="Pull images and recreate" onclick={(e) => plan(e, sel, 'pull')}>Pull</Button>
              {#if sel.managed === 'web'}
                <Button size="sm" icon="arrow-clockwise" busy={jobRunning('docker-app', [sel.name, 'rebuild'])} busyLabel="Rebuilding…" tooltip="Rebuild" onclick={(e) => openPlan('docker-app', [sel.name, 'rebuild'], `rebuild ${sel.name}`)}>Rebuild</Button>
                <Button size="sm" variant="danger" busy={jobRunning('docker-app', [sel.name, 'delete'])} busyLabel="Deleting…" tooltip="Remove the containers; the folder in /opt/apps stays, so the app can be started again" onclick={(e) => openPlan('docker-app', [sel.name, 'delete'], `delete ${sel.name}`)}>Delete</Button>
                <Button size="sm" variant="danger" busy={jobRunning('docker-app', [sel.name, 'delete', '--delete-data'])} busyLabel="Deleting…" tooltip="Also delete the config and data (/opt/apps)" onclick={(e) => openPlan('docker-app', [sel.name, 'delete', '--delete-data'], `delete ${sel.name} and its data`)}>Delete with data</Button>
              {/if}
              {/if}
            {/snippet}
          </Drawer>
        {/if}
      {/snippet}
    </Split>
  {/if}
</PageState>

<style>
  .images { font-size: 12px; color: var(--fg-3); max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: inline-block; }
  .acts { display: flex; justify-content: flex-end; gap: 2px; }
  .acts :global(.ib) { width: 28px; min-height: 28px; height: 28px; padding: 0; color: var(--fg-2); }
</style>
