<script>
  // Instances: containers and VMs. Table, then a drawer (Storage, Snapshots, Logs, Route); every action opens a plan.
  // Snapshots of an instance live HERE (the Snapshots page is gone); the "in the backup" switch lives on Backup, this page only shows the badge.
  import { poll, rows, refresh } from '../data.svelte.js';
  import { takeSelection } from '../select.svelte.js';
  import { openPlan, openCreate, ui } from '../ui.svelte.js';
  import { route } from '../route.svelte.js';
  import Terminal from '../shell/Terminal.svelte';
  import CreateInstance from '../forms/instances/CreateInstance.svelte';
  import InstanceSettings from '../forms/instances/InstanceSettings.svelte';
  import BindStorage from '../forms/instances/BindStorage.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Split from '../ui/Split.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import Kv from '../ui/Kv.svelte';
  import Chip from '../ui/Chip.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import LogsTab from './instances/LogsTab.svelte';
  import { sizeToBytes } from '../format.js';
  import { ctOf, ctIcon, isVm, isRunning, link, servicesOf } from './instances/ct.js';

  const ctl = poll('/api/sys/ct/list', 5000);
  const bk = poll('/api/sys/backup/overview', 60000);
  const svc = poll('/api/sys/services/list', 30000);
  const rec = poll('/api/sys/recipes/list', 60000);

  let selName = $state('');
  let tab = $state('storage');
  $effect(() => { const n = takeSelection('instances'); if (n) selName = n; });
  // /instances?view=snapshots (the old Snapshots page) opens the Snapshots tab of the first instance
  $effect(() => { if (route.query.view === 'snapshots') tab = 'snap'; });

  const cts = $derived(rows(ctl).map(ctOf));
  const sel = $derived(cts.find((c) => c.name === selName) ?? (route.query.view === 'snapshots' ? cts[0] : null) ?? null);
  const running = $derived(cts.filter(isRunning).length);

  // backup overview: kind, name, on|off, bytes. Read only here; empty while the backup disk or the storage is not there
  const backupOf = $derived(Object.fromEntries(rows(bk).filter((r) => r[0] === 'ct').map((r) => [r[1], r[2] === 'on'])));
  const backupKnown = $derived(bk.loaded && !bk.error);
  // services list: name, title, target, exposure, names, wants
  const services = $derived(rows(svc).map((r) => ({ name: r[0], title: r[1], target: r[2], exposure: r[3], names: r[4], wants: r[5] })));
  // recipes list: name, description, containers (comma separated, - for none), state
  const recipes = $derived(rows(rec).map((r) => ({ name: r[0], cts: r[2] === '-' ? [] : r[2].split(',') })));

  const bind = poll(() => (sel ? `/api/sys/ct/bindings/${encodeURIComponent(sel.name)}` : ''), 15000);
  // binding, kind, pool, source, inside, mode, cache, backup, share, used_bytes, disks, also_used_by
  const bindings = $derived(rows(bind).map((r) => ({ device: r[0], kind: r[1], pool: r[2], source: r[3], inside: r[4], mode: r[5], backup: r[7], share: r[8], also: r[11] })));
  const snap = poll(() => (sel ? `/api/sys/ct/snapshots/${encodeURIComponent(sel.name)}` : ''), 15000);
  // name, created; newest first ("YYYY-MM-DD HH:MM" sorts as text)
  const snaps = $derived([...rows(snap)].sort((a, b) => (a[1] < b[1] ? 1 : a[1] > b[1] ? -1 : 0)).map((r) => ({ name: r[0], created: r[1] })));

  const kind = (c) => (isVm(c) ? 'VM' : 'CT');
  const word = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1).toLowerCase() : '');
  const dot = (s) => (/running/i.test(s) ? 'ok' : /stopped/i.test(s) ? 'off' : 'warn');
  const plan = (e, c, action) => { e.stopPropagation(); openPlan('ct', [c.name, action], `${action} ${c.name}`); };
  const spaced = (v) => (v || '').replace(/^(\d+)([A-Za-z]+)$/, '$1 $2');
  const dash = (v) => (v && v !== '-' ? v : '–');
  const myServices = $derived(sel ? servicesOf(sel, services) : []);
  const myRecipes = $derived(sel ? recipes.filter((r) => r.cts.includes(sel.name)) : []);
  const sharePath = (b) => (b.pool === 'fast' ? '/storage/fast/shares' : '/storage/bulk/shares');

  const columns = [
    { key: 'name', label: 'Name' }, { key: 'type', label: 'Type', value: kind, optional: true }, { key: 'state', label: 'State', value: (c) => word(c.state) },
    { key: 'address', label: 'Address' }, { key: 'ram', label: 'RAM', sort: 'num', optional: true, value: (c) => sizeToBytes(c.ram) },
    { key: 'cpu', label: 'CPU', sort: 'num', optional: true, value: (c) => Number(c.cpu) },
    { key: 'lastSnap', label: 'Last snapshot', optional: true }, { key: 'route', label: 'Route', optional: true, value: (c) => servicesOf(c, services).length },
    { key: 'actions', label: '', sort: false, align: 'right' },
  ];
  const tabs = [{ id: 'storage', label: 'Storage' }, { id: 'snap', label: 'Snapshots' }, { id: 'logs', label: 'Logs' }, { id: 'route', label: 'Route' }];
</script>

<PageHeader title="Instances" crumb={ui.host} sub={cts.length ? `${running} of ${cts.length} running` : 'Containers and virtual machines.'}>
  {#snippet actions()}
    <button class="btn" disabled={!running} title="Snapshot and update every running container, one after the other (shows the plan first)" onclick={() => openPlan('ct', ['all', 'update-all'], 'Update all')}><i class="ph ph-arrows-clockwise"></i>Update all</button>
    <button class="btn btn-primary" onclick={() => openCreate(CreateInstance)}><i class="ph ph-plus"></i>Create</button>
  {/snippet}
</PageHeader>

<PageState loading={!ctl.loaded} error={ctl.error?.message} hasData={ctl.data != null} empty={ctl.loaded && !cts.length && !ctl.error}
           emptyIcon="cube" emptyTitle="No instances yet" emptyText="An instance is a container or a virtual machine. Create the first one, or set an app up from Apps."
           retry={() => refresh(['/api/sys/ct/list'])}>
  {#snippet emptyAction()}<button class="btn btn-primary" onclick={() => openCreate(CreateInstance)}><i class="ph ph-plus"></i>Create</button>{/snippet}
  <Split open={!!sel}>
    {#snippet list()}
      <div class="card" style="padding:0">
      <Table id="instances" {columns} rows={cts} key="name" selected={sel?.name} onrow={(c) => { selName = c.name; }} loading={!ctl.loaded} empty="No instances.">
        {#snippet cell(c, col)}
          {#if col.key === 'name'}<span class="nm"><i class="ph ph-{ctIcon(c)} ic"></i>{c.name}</span>
          {:else if col.key === 'type'}<span class="kd">{kind(c)}</span>
          {:else if col.key === 'state'}<StatusDot state={dot(c.state)} label={word(c.state)} />
          {:else if col.key === 'address'}<span class="mono addr">{c.address}</span>
          {:else if col.key === 'ram'}{spaced(c.ram)}
          {:else if col.key === 'cpu'}{c.cpu}
          {:else if col.key === 'lastSnap'}<span class="kd">{dash(c.lastSnap)}</span>
          {:else if col.key === 'route'}
            {@const s = servicesOf(c, services)}
            {#if s.length}<a {...link('/instances/services')}>{s[0].names && s[0].names !== '-' ? s[0].names.split(',')[0] : s[0].name}{s.length > 1 ? ` +${s.length - 1}` : ''}</a>{:else}<span class="kd">–</span>{/if}
          {:else}
            <span class="acts">
              <button class="btn btn-ghost btn-icon ib" title={isRunning(c) ? 'Stop' : 'Start'} aria-label="{isRunning(c) ? 'Stop' : 'Start'} {c.name}" onclick={(e) => plan(e, c, isRunning(c) ? 'stop' : 'start')}><i class="ph {isRunning(c) ? 'ph-stop' : 'ph-play'}"></i></button>
              <button class="btn btn-ghost btn-icon ib" title="Restart" aria-label="Restart {c.name}" onclick={(e) => plan(e, c, 'restart')}><i class="ph ph-arrow-clockwise"></i></button>
              <button class="btn btn-ghost btn-icon ib nophone" title="Snapshot" aria-label="Snapshot {c.name}" onclick={(e) => plan(e, c, 'snapshot')}><i class="ph ph-camera"></i></button>
            </span>
          {/if}
        {/snippet}
      </Table>
      </div>
    {/snippet}
    {#snippet side()}
      {#if sel}
        <Drawer title={sel.name} chip={kind(sel)} state={dot(sel.state)} stateLabel={word(sel.state)} {tabs} bind:tab onclose={() => { selName = ''; }}>
          {#snippet children(t)}
            <Kv items={[
              { k: 'Address', v: sel.address }, { k: 'RAM / CPU', v: `${spaced(sel.ram) || '–'} / ${sel.cpu || '–'}` },
            ]} />
            <div class="bk">
              <span class="kd">Backup</span>
              {#if backupKnown && sel.name in backupOf}
                <a {...link('/protection/backup')} title="Change this on the Backup page"><span class="tag {backupOf[sel.name] ? 'tag-accent' : 'tag-neutral'}">{backupOf[sel.name] ? 'in the backup' : 'not in the backup'}</span></a>
              {:else}<span class="kd">{backupKnown ? 'not listed' : 'not known (no backup disk, or storage locked)'}</span>{/if}
            </div>

            {#if t === 'storage'}
              <div class="sec">
                <div class="sh"><b>Storage</b><span class="kd">disks and shares this instance sees</span></div>
                <div class="rows">
                  {#each bindings as b (b.device)}
                    <div class="r">
                      <div class="rt">
                        <Chip>{b.kind}</Chip>
                        {#if b.share && b.share !== '-'}<a {...link(sharePath(b), 'shares', b.share)} title="Open the share">{b.share}</a>{:else}<span class="mono">{b.source}</span>{/if}
                        <span class="kd">{b.mode}</span>
                        <button class="btn btn-ghost btn-icon ib" style="margin-left:auto" title="Remove this binding" aria-label="Remove {b.device}" onclick={() => openPlan('ct', [sel.name, 'remove-storage', '--device', b.device], `Remove ${b.device} from ${sel.name}`)}><i class="ph ph-x"></i></button>
                      </div>
                      <div class="rs mono">{b.source} → {b.inside}</div>
                      {#if b.also && b.also !== '-'}<div class="rs">Also mounted by {b.also}</div>{/if}
                    </div>
                  {:else}
                    <div class="kd pad">{bind.loaded ? 'No storage bindings.' : 'Loading…'}</div>
                  {/each}
                </div>
                <button class="btn sm" onclick={() => openCreate(BindStorage, { ct: sel.name })}><i class="ph ph-plus"></i>Bind a share</button>
              </div>
            {:else if t === 'snap'}
              <div class="sec">
                <div class="sh"><b>Snapshots</b><span class="kd">nightly at 02:00, kept 7 days. ZFS goes back to the newest only: restoring an older one deletes the newer ones first.</span></div>
                <div class="rows">
                  {#each snaps as sn, i (sn.name)}
                    <div class="r"><div class="rt">
                      <span class="mono">{sn.name}</span><span class="kd">{sn.created}</span>
                      <span class="acts" style="margin-left:auto">
                        <button class="btn btn-ghost btn-icon ib" aria-label="Restore {sn.name}" title={i === 0 ? 'Go back to this snapshot' : 'Go back to this snapshot (the newer ones are deleted)'} onclick={() => openPlan('ct', [sel.name, 'restore', '--snapshot', sn.name], `Restore ${sel.name}`)}><i class="ph ph-arrow-u-up-left"></i></button>
                        <button class="btn btn-ghost btn-icon ib bad" aria-label="Delete {sn.name}" title="Delete this snapshot (the plan asks for the instance name)" onclick={() => openPlan('ct', [sel.name, 'delete-snapshot', '--snapshot', sn.name], `Delete snapshot ${sn.name}`)}><i class="ph ph-trash"></i></button>
                      </span>
                    </div></div>
                  {:else}
                    <div class="kd pad">{snap.loaded ? (snap.error ? 'The snapshots could not be read.' : 'No snapshots yet.') : 'Loading…'}</div>
                  {/each}
                </div>
                <button class="btn sm" onclick={() => openPlan('ct', [sel.name, 'snapshot'], `Snapshot ${sel.name}`)}><i class="ph ph-camera"></i>Snapshot now</button>
              </div>
            {:else if t === 'logs'}
              {#key sel.name}<LogsTab ct={sel.name} />{/key}
            {:else}
              <div class="sec">
                <div class="sh"><b>Route</b><span class="kd">what the reverse proxy publishes for this instance</span></div>
                <div class="rows">
                  {#each myServices as s (s.name)}
                    <div class="r"><div class="rt">
                      <a {...link('/instances/services')}>{s.title && s.title !== '-' ? s.title : s.name}</a>
                      <span class="tag {s.exposure === 'public-ok' ? 'tag-accent' : 'tag-neutral'}">{s.exposure}</span>
                    </div><div class="rs">{s.names && s.names !== '-' ? s.names : 'no public name'} → {s.target}</div></div>
                  {:else}
                    <div class="kd pad">{svc.loaded ? 'No service describes this instance, so it has no route.' : 'Loading…'}</div>
                  {/each}
                </div>
                {#if myRecipes.length}<div class="rs">Set up by the recipe {#each myRecipes as r, i}{i ? ', ' : ''}<a {...link('/instances/apps', 'recipes', r.name)}>{r.name}</a>{/each}.</div>{/if}
              </div>
            {/if}
          {/snippet}
          {#snippet actions()}
            <button class="btn sm" onclick={(e) => plan(e, sel, isRunning(sel) ? 'stop' : 'start')}><i class="ph {isRunning(sel) ? 'ph-stop' : 'ph-play'}"></i>{isRunning(sel) ? 'Stop' : 'Start'}</button>
            <button class="btn sm" onclick={(e) => plan(e, sel, 'restart')}><i class="ph ph-arrow-clockwise"></i>Restart</button>
            <button class="btn sm" title="Snapshot the instance, then update the software inside" onclick={() => openPlan('ct', [sel.name, 'update'], `Update ${sel.name}`)}><i class="ph ph-arrows-clockwise"></i>Update</button>
            <button class="btn sm" disabled={!ui.features.terminal || !isRunning(sel)} title={!ui.features.terminal ? 'Switch on webTerminal in machine.toml' : isRunning(sel) ? 'A shell inside the instance' : 'The instance is not running'} onclick={() => openCreate(Terminal, { target: sel.name, title: sel.name })}><i class="ph ph-terminal-window"></i>Terminal</button>
            <button class="btn sm" onclick={() => openCreate(InstanceSettings, { ct: sel })}><i class="ph ph-sliders"></i>Settings</button>
            <button class="btn sm btn-danger" title="Delete the instance (the plan asks for its name)" onclick={() => openPlan('ct', [sel.name, 'delete'], `Delete ${sel.name}`)}><i class="ph ph-trash"></i>Delete</button>
          {/snippet}
        </Drawer>
      {/if}
    {/snippet}
  </Split>
</PageState>

<style>
  .nm { display: flex; align-items: center; gap: 7px; font-weight: 500; }
  .ic { color: var(--fg-3); }
  .kd { color: var(--fg-3); }
  .addr { font-size: 12px; color: var(--fg-2); }
  .acts { display: flex; justify-content: flex-end; gap: 2px; }
  .ib { width: 28px; min-height: 28px; color: var(--fg-2); }
  .ib.bad { color: var(--bad); }
  /* a phone: Stop/Start and Restart stay in the row, Snapshot is in the drawer (Snapshots tab) */
  @media (max-width: 860px) { .nophone { display: none; } }
  .bk { display: flex; align-items: center; gap: 10px; padding: 10px 16px; border-bottom: 1px solid var(--line); }
  .sec { display: flex; flex-direction: column; gap: 10px; padding: 14px 16px; align-items: flex-start; }
  .sh { display: flex; flex-direction: column; gap: 2px; }
  .sh .kd { font-size: 12px; }
  .rows { align-self: stretch; border: 1px solid var(--line); }
  .r { padding: 8px 10px; border-bottom: 1px solid var(--line); }
  .r:last-child { border-bottom: 0; }
  .rt { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; }
  .rs { font-size: 12px; color: var(--fg-3); overflow-wrap: anywhere; margin-top: 2px; }
  .rs.mono, .mono { font-size: 12px; }
  .pad { padding: 10px; font-size: 12.5px; }
</style>
