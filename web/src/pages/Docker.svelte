<script>
  // The Docker page: the apps (compose projects) that run in the locked docker container.
  import { poll, rows, refresh } from '../data.svelte.js';
  import { takeSelection } from '../select.svelte.js';
  import { openPlan, jobRunning, ui } from '../ui.svelte.js';
  import { url } from '../route.svelte.js';
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
  import AppLogs from './docker/AppLogs.svelte';
  import AppEditor from '../forms/docker/AppEditor.svelte';
  import { appOf } from './docker/apps.js';

  const appsPoll = poll('/api/sys/docker/apps', 30000);
  const statusPoll = poll('/api/sys/docker/status', 15000);

  let selName = $state('');
  let tab = $state('overview');
  let creating = $state(false);
  $effect(() => { const n = takeSelection('docker'); if (n) selName = n; });
  $effect(() => { if (sel) tab = 'overview'; });

  const apps = $derived(rows(appsPoll).map(appOf).filter(Boolean));
  const status = $derived(Object.fromEntries(rows(statusPoll).map((r) => [r[0], r[1]])));
  const sel = $derived(apps.find((a) => a.name === selName) ?? null);
  const runningCount = $derived(apps.filter((a) => a.state === 'running').length);

  const dot = (s) => (s === 'running' ? 'ok' : s === 'partial' ? 'warn' : 'off');
  const portHref = (app, port) => (app.address && app.address !== '-' ? `http://${app.address}:${port}` : null);
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
  const tabs = $derived(sel?.managed === 'web'
    ? [{ id: 'overview', label: 'Overview' }, { id: 'compose', label: 'Compose' }, { id: 'logs', label: 'Logs' }]
    : [{ id: 'overview', label: 'Overview' }, { id: 'logs', label: 'Logs' }]);
</script>

<PageHeader title="Docker" crumb="Instances" sub={apps.length ? `${runningCount} of ${apps.length} apps running${status.address && status.address !== '-' ? ` · ${status.address}` : ''}` : 'Apps that run in the Docker container.'} />

<PageState loading={!appsPoll.loaded} error={appsPoll.error?.message} hasData={appsPoll.data != null}
           empty={appsPoll.loaded && !apps.length && !appsPoll.error} emptyIcon="shipping-container" emptyTitle="No apps yet" emptyText="No apps run in Docker yet."
           retry={() => refresh(['/api/sys/docker/apps'])}>
  {#if status.state !== 'on'}
    <EmptyState icon="shipping-container" title="Docker is off" tone="info" text="Turn Docker on under Settings, Capabilities, Docker.">
      {#snippet action()}<a class="btn" href={url('/settings/capabilities/docker')}>Open Docker settings</a>{/snippet}
    </EmptyState>
  {:else}
    <div class="toolbar"><Button size="sm" icon="plus" onclick={() => { creating = true; }}>New app</Button></div>
    <Split open={!!sel || creating}>
      {#snippet list()}
        <div class="card" style="padding:0">
          <Table id="docker-apps" {columns} rows={apps} key="name" selected={sel?.name} onrow={(a) => { selName = a.name; }} loading={!appsPoll.loaded} empty="No apps.">
            {#snippet cell(a, col)}
              {#if col.key === 'name'}{a.name}
              {:else if col.key === 'state'}<StatusDot state={dot(a.state)} label={a.state} />
              {:else if col.key === 'running'}{a.running}
              {:else if col.key === 'ports'}
                {@const ports = a.ports === '-' ? [] : a.ports.split(',').filter(Boolean)}
                {#if ports.length}
                  {#each ports as p, i}{#if i > 0}, {/if}{#if portHref(a, p)}<a href={portHref(a, p)} target="_blank" rel="noopener" onclick={(e) => e.stopPropagation()}>{p}</a>{:else}{p}{/if}{/each}
                {:else}–{/if}
              {:else if col.key === 'images'}<span class="images" title={a.images}>{a.images}</span>
              {:else if col.key === 'managed'}<Chip>{a.managed}</Chip>
              {:else}
                <span class="acts">
                  {#if a.state === 'exited' || a.state === 'created'}
                    <Button variant="ghost" class="btn-icon ib" icon="play" busy={jobRunning('docker-app', [a.name, 'start'])} tooltip="Start" aria-label="Start {a.name}" onclick={(e) => plan(e, a, 'start')} />
                  {:else if a.state === 'running' || a.state === 'partial'}
                    <Button variant="ghost" class="btn-icon ib" icon="stop" busy={jobRunning('docker-app', [a.name, 'stop'])} tooltip="Stop" aria-label="Stop {a.name}" onclick={(e) => plan(e, a, 'stop')} />
                  {/if}
                  <Button variant="ghost" class="btn-icon ib" icon="arrow-clockwise" busy={jobRunning('docker-app', [a.name, 'restart'])} tooltip="Restart" aria-label="Restart {a.name}" onclick={(e) => plan(e, a, 'restart')} />
                  <Button variant="ghost" class="btn-icon ib" icon="download-simple" busy={jobRunning('docker-app', [a.name, 'pull'])} tooltip="Pull" aria-label="Pull {a.name}" onclick={(e) => plan(e, a, 'pull')}>Pull</Button>
                </span>
              {/if}
            {/snippet}
          </Table>
        </div>
      {/snippet}
      {#snippet side()}
        {#if creating}
          <div class="sdr-wrap">
            <AppEditor app="" rev="new" onclose={() => { creating = false; }} />
          </div>
        {:else if sel}
          <Drawer title={sel.name} chip={sel.managed} state={dot(sel.state)} stateLabel={sel.state} {tabs} bind:tab onclose={() => { selName = ''; }}>
            {#snippet children(t)}
              {#if t === 'overview'}
                <Kv items={[...]} />
              {:else if t === 'compose'}
                <AppEditor app={sel.name} />
              {:else}
                {#key sel.name}<AppLogs app={sel.name} />{/key}
              {/if}
            {/snippet}
            {#snippet actions()}
              {#if sel.state === 'exited' || sel.state === 'created'}
                <Button size="sm" icon="play" busy={jobRunning('docker-app', [sel.name, 'start'])} busyLabel="Starting…" tooltip="Start this app" onclick={(e) => plan(e, sel, 'start')}>Start</Button>
              {:else if sel.state === 'running' || sel.state === 'partial'}
                <Button size="sm" icon="stop" busy={jobRunning('docker-app', [sel.name, 'stop'])} busyLabel="Stopping…" tooltip="Stop this app" onclick={(e) => plan(e, sel, 'stop')}>Stop</Button>
              {/if}
              <Button size="sm" icon="arrow-clockwise" busy={jobRunning('docker-app', [sel.name, 'restart'])} busyLabel="Restarting…" tooltip="Restart this app" onclick={(e) => plan(e, sel, 'restart')}>Restart</Button>
              <Button size="sm" icon="download-simple" busy={jobRunning('docker-app', [sel.name, 'pull'])} busyLabel="Pulling…" tooltip="Pull images and recreate" onclick={(e) => plan(e, sel, 'pull')}>Pull</Button>
              {#if sel.managed === 'web'}
                <Button size="sm" icon="arrow-clockwise" busy={jobRunning('docker-app', [sel.name, 'rebuild'])} busyLabel="Rebuilding…" tooltip="Rebuild" onclick={(e) => openPlan('docker-app', [sel.name, 'rebuild'], `rebuild ${sel.name}`)}>Rebuild</Button>
                <Button size="sm" variant="danger" busy={jobRunning('docker-app', [sel.name, 'delete'])} busyLabel="Deleting…" tooltip="Delete" onclick={(e) => openPlan('docker-app', [sel.name, 'delete'], `delete ${sel.name}`)}>Delete</Button>
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
  .ib { width: 28px; min-height: 28px; color: var(--fg-2); }
</style>
