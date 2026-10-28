<script>
  // Storage > Shares: every share (the Samba shares of bulk, the instance volumes of fast) in one list, with its permissions, snapshots and
  // history in a drawer; the folders of deleted shares are kept in the second view. /storage/shares?pool=bulk|fast filters, ?view=snapshots opens
  // the Snapshots tab. The "in the backup" switch is NOT here (it lives on Backup): a share only shows a read-only badge.
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import { StatusDot, Chip, Kv, Drawer, Split, Banner } from '../ui/index.js';
  import { poll, rows } from '../data.svelte.js';
  import { takeSelection, setSelection } from '../select.svelte.js';
  import { route, go } from '../route.svelte.js';
  import { bytes } from '../format.js';
  import { openPlan, openCreate } from '../ui.svelte.js';
  import NewShare from '../forms/shares/NewShare.svelte';
  import RenameShare from '../forms/shares/RenameShare.svelte';
  import DeleteShare from '../forms/shares/DeleteShare.svelte';
  import RestoreShare from '../forms/shares/RestoreShare.svelte';
  import AddAccess from '../forms/shares/AddAccess.svelte';
  import { parseSize } from './storage/pool.js';

  let { deck } = $props();

  const POOLS = [{ id: 'all', label: 'All' }, { id: 'bulk', label: 'bulk' }, { id: 'fast', label: 'fast' }];
  const pool = $derived(POOLS.some((p) => p.id === route.query.pool) ? route.query.pool : 'all');
  const view = $derived(route.query.view === 'kept' ? 'kept' : 'shares');
  const query = (o) => {
    const q = new URLSearchParams({ ...(pool !== 'all' ? { pool } : {}), ...(view === 'kept' ? { view } : {}), ...o });
    for (const [k, v] of [...q]) if (!v || v === 'all' || (k === 'view' && v === 'shares')) q.delete(k);
    return `/storage/shares${[...q].length ? `?${q}` : ''}`;
  };
  let selName = $state('');
  let tab = $state('info');
  $effect(() => { const n = takeSelection('shares'); if (n) { selName = n; tab = 'info'; } });
  const locked = $derived(!!deck?.data?.locked);

  const overview = poll('/api/sys/shares/overview', 30000);
  const deleted = poll('/api/sys/shares/deleted', 60000);
  const cts = poll('/api/sys/ct/list', 30000);

  // name, kind, path, cache, size_bytes, measured, backup, disks, mounted_in (name(ro|rw), comma separated)
  const samba = $derived(rows(overview).map((r) => ({
    name: r[0], kind: r[1], path: r[2], cache: r[3], size: Number(r[4]) || 0, measured: r[5], backup: r[6], disks: r[7], mounted: r[8],
    pool: (r[2] ?? '').split('/')[1] || 'bulk', volume: false,
  })));
  // ct list: name, type, state, ..., disk (col 9): the instances' own volumes on fast (read only here; the instance owns them)
  const volumes = $derived(rows(cts).filter((r) => r[9] && r[9] !== '-').map((r) => ({
    name: r[0], kind: 'volume', path: '', cache: '-', size: parseSize(r[9]), measured: '', backup: '-', disks: 'fast', mounted: r[0], pool: 'fast', volume: true,
  })));
  const all = $derived([...samba, ...volumes]);
  const shares = $derived(all.filter((s) => pool === 'all' || s.pool === pool));
  const sel = $derived(shares.find((s) => s.name === selName) ?? null);
  const measured = $derived(samba.find((s) => s.measured)?.measured ?? '');
  const snapraid = $derived(samba.some((s) => s.measured));
  const hasCache = $derived(samba.some((s) => s.cache === 'on' || s.cache === 'off'));

  const kept = $derived(rows(deleted).map((r) => ({ name: r[0], kind: r[1], size: Number(r[2]) || 0, disks: r[3] })));

  // an auto-selection when the old Snapshots address is opened
  let snapOpened = false;
  $effect(() => {
    if (route.query.view === 'snapshots' && !snapOpened && overview.loaded) {
      snapOpened = true;
      const z = shares.find((s) => isZfs(s));
      if (z) { selName = z.name; tab = 'snap'; }
    }
  });

  const editable = (s) => !!s && !s.volume && s.kind !== 'other';
  const isZfs = (s) => !!s && !s.volume && !!s.disks && s.disks !== '-' && !s.disks.startsWith('data-') && !s.measured;
  const dash = (v) => (v && v !== '-' ? v : '');
  const size = (n) => (!n ? '' : n >= 1e12 ? `${(n / 1e12).toFixed(2)} TB` : n >= 1e9 ? `${Math.round(n / 1e9)} GB` : bytes(n));
  const host = $derived(deck?.data?.host ?? 'homeserver');
  const mountedBy = (s) => (dash(s.mounted) ? s.mounted.split(',').map((x) => x.trim()).filter(Boolean).map((x) => ({ text: x, name: x.replace(/\s*\(.*$/, '') })) : []);
  const openInstance = (name) => { setSelection('instances', name); go('/instances'); };

  // drawer data (ACL and snapshots are per share; read only for the selected one)
  const acl = poll(() => (editable(sel) ? `/api/sys/shares/acl/${encodeURIComponent(sel.name)}` : ''), 30000);
  const hist = poll(() => (editable(sel) ? `/api/sys/shares/history/${encodeURIComponent(sel.name)}` : ''), 30000);
  const backups = poll(() => (editable(sel) && tab === 'hist' ? '/api/sys/backup/snapshots?tag=shares' : ''), 60000);
  // sid, name, user|group, level
  const entries = $derived(rows(acl).map((r) => ({ sid: r[0], name: r[1], type: r[2], level: r[3] })));
  // name, created, auto|manual, used (any order: sorted oldest first)
  const snaps = $derived([...rows(hist)].map((r) => ({ name: r[0], created: r[1], how: r[2] })).sort((a, b) => (a.created < b.created ? -1 : a.created > b.created ? 1 : 0)));
  const auto = $derived(snaps.some((x) => x.how === 'auto'));
  const newest = $derived(snaps.length ? snaps[snaps.length - 1] : null);
  // backup restore points: id, time, tags
  const points = $derived(rows(backups).map((r) => ({ id: r[0], time: r[1] })).reverse().slice(0, 10));

  const LEVELS = ['none', 'read', 'write', 'full'];
  const setLevel = (e, l) => l !== e.level && openPlan('shares', [sel.name, 'perm', '--set', `${e.sid}=${l}`], `${e.name}: ${l} on ${sel.name}`);
  const toggle = (what, to) => openPlan('shares', [sel.name, what, '--to', to], `${what === 'cache' ? 'Upload cache' : 'Automatic snapshots'} of ${sel.name} ${to}`);

  const columns = [
    { key: 'name', label: 'Share' }, { key: 'kind', label: 'Kind', optional: true }, { key: 'pool', label: 'Pool', optional: true },
    { key: 'size', label: 'Size', sort: 'num', value: (s) => s.size }, { key: 'backup', label: 'Backup', optional: true },
    { key: 'cache', label: 'Cache', optional: true }, { key: 'disks', label: 'Where', optional: true }, { key: 'mounted', label: 'Mounted by', optional: true },
  ];
  const keptCols = [{ key: 'name', label: 'Kept folder' }, { key: 'kind', label: 'Kind' }, { key: 'size', label: 'Size', sort: 'num' }, { key: 'disks', label: 'Where' }, { key: 'actions', label: '', sort: false, align: 'right' }];
</script>

<PageHeader title="Shares" crumb="Storage" sub={measured ? `Sizes measured ${measured}.` : 'Network shares, who may use them and what has been kept of them.'}>
  {#snippet actions()}
    {#if hasCache}<button class="btn" disabled={locked} title="(snapraid layout) Move the uploaded files from the SSD cache to the data disks now" onclick={() => openPlan('admin', ['cache-mover'], 'Empty the upload cache')}><i class="ph ph-arrow-line-down"></i>Empty cache</button>{/if}
    <button class="btn btn-primary" disabled={locked} onclick={() => openCreate(NewShare)}><i class="ph ph-plus"></i>New share</button>
  {/snippet}
</PageHeader>

<div class="bar">
  <div class="seg" role="tablist" aria-label="View">
    <label class="seg-opt"><input type="radio" name="sview" checked={view === 'shares'} onchange={() => go(query({ view: 'shares' }))} />Shares</label>
    <label class="seg-opt"><input type="radio" name="sview" checked={view === 'kept'} onchange={() => go(query({ view: 'kept' }))} />Kept folders{deleted.loaded ? ` · ${kept.length}` : ''}</label>
  </div>
  {#if view === 'shares'}
    <div class="seg" role="tablist" aria-label="Pool">
      {#each POOLS as p (p.id)}
        <label class="seg-opt"><input type="radio" name="spool" checked={pool === p.id} onchange={() => { selName = ''; go(query({ pool: p.id })); }} />{p.label}</label>
      {/each}
    </div>
  {/if}
</div>

{#if view === 'kept'}
  <PageState loading={!deleted.loaded} hasData={deleted.data != null} error={deleted.error?.message ?? ''} empty={deleted.loaded && !kept.length} emptyIcon="folder-dashed"
             emptyTitle="No kept folders" emptyText="When a share is deleted its folder stays as a renamed copy until someone removes it for good.">
    <Banner tone="info">Deleting a share keeps its files as <code>name.deleted-date</code>, never published again. Remove a kept folder for good only when you are sure; copies in old backup snapshots stay until they age out.</Banner>
    <div class="card gap">
      <Table id="kept" columns={keptCols} rows={kept} key="name" compact empty="No kept folders.">
        {#snippet cell(k, col)}
          {#if col.key === 'name'}<span class="nm"><i class="ph ph-folder-dashed"></i><code>{k.name}</code></span>
          {:else if col.key === 'kind'}<Chip>{k.kind}</Chip>
          {:else if col.key === 'size'}{size(k.size) || '–'}
          {:else if col.key === 'disks'}<span class="mute">{dash(k.disks) || '–'}</span>
          {:else}<span class="acts">
            <button class="btn sm" disabled={locked} title="Bring the folder back as a share under its old name; nothing is overwritten or removed" onclick={() => openPlan('shares', [k.name, 'undelete'], `Restore ${k.name.replace(/\.deleted-\d{8}$/, '')}`)}><i class="ph ph-arrow-counter-clockwise"></i>Restore</button>
            <button class="btn sm btn-danger" disabled={locked} onclick={() => openPlan('shares', [k.name, 'purge'], `Remove ${k.name} for good`)}><i class="ph ph-trash-simple"></i>Remove for good</button>
          </span>{/if}
        {/snippet}
      </Table>
    </div>
  </PageState>
{:else}
  <PageState loading={!overview.loaded} hasData={overview.data != null} error={overview.error?.message ?? ''} empty={overview.loaded && !shares.length} emptyIcon="folders"
             emptyTitle={pool === 'all' ? 'No shares yet' : `No shares on ${pool}`} emptyText={pool === 'fast' ? 'Fast holds the instances’ own volumes; network shares live on bulk.' : 'A share is a folder that Windows and Linux computers on the network can open.'}>
    {#snippet emptyAction()}<button class="btn btn-primary" disabled={locked} onclick={() => openCreate(NewShare)}><i class="ph ph-plus"></i>New share</button>{/snippet}
    <Split open={!!sel}>
      {#snippet list()}
        <div class="card gap">
          <Table id="shares" {columns} rows={shares} key="name" compact selected={sel?.name} onrow={(s) => { selName = s.name; tab = 'info'; }} empty="No shares.">
            {#snippet cell(s, col)}
              {#if col.key === 'name'}<span class="nm"><i class="ph {s.volume ? 'ph-cube' : s.kind === 'sensitive' ? 'ph-folder-lock' : 'ph-folder'}"></i>{s.name}</span>
              {:else if col.key === 'kind'}<span class="mute">{s.kind}</span>
              {:else if col.key === 'pool'}<Chip>{s.pool}</Chip>
              {:else if col.key === 'size'}<span class="nw">{size(s.size) || '–'}</span>
              {:else if col.key === 'backup'}{#if s.volume || s.kind === 'other'}<span class="mute">–</span>{:else}<StatusDot state={s.backup === 'on' ? 'ok' : 'off'} label={s.backup === 'on' ? 'in backup' : 'not in backup'} />{/if}
              {:else if col.key === 'cache'}<span class="mute">{dash(s.cache) || '–'}</span>
              {:else if col.key === 'disks'}<span class="mute">{dash(s.disks) || '–'}</span>
              {:else}<span class="mute">{dash(s.mounted) || '–'}</span>{/if}
            {/snippet}
          </Table>
        </div>
      {/snippet}
      {#snippet side()}
        {#if sel}
          <Drawer title={sel.name} chip={sel.volume ? 'volume' : sel.kind} bind:tab onclose={() => (selName = '')}
                  tabs={editable(sel) ? [{ id: 'info', label: 'Overview' }, { id: 'perm', label: 'Permissions' }, { id: 'snap', label: 'Snapshots' }, { id: 'hist', label: 'History' }] : []}>
            {#snippet children(t)}
              {#if !editable(sel) || t === 'info'}
                <Kv items={[
                  { k: 'Pool', v: sel.pool }, { k: 'Size', v: size(sel.size) },
                  { k: 'Network path', v: sel.volume ? '' : `\\\\${host}\\${sel.name}` }, { k: 'Folder', v: sel.path }, { k: 'Where', v: dash(sel.disks) },
                  { k: 'Upload cache', v: dash(sel.cache) },
                  { k: 'Backup', v: sel.volume || sel.kind === 'other' ? '' : sel.backup === 'on' ? 'in the nightly backup' : 'not in the backup' },
                ]} />
                <div class="pad">
                  {#if mountedBy(sel).length}
                    <div class="sh"><b>Mounted by</b></div>
                    <div class="links">{#each mountedBy(sel) as m}<button class="btn sm" onclick={() => openInstance(m.name)}><i class="ph ph-cube"></i>{m.text}</button>{/each}</div>
                  {:else}<p class="mute">No instance mounts this {sel.volume ? 'volume' : 'share'}.</p>{/if}
                  {#if sel.volume}<p class="mute">An instance volume belongs to its instance: change it there.</p>{:else if sel.kind !== 'other'}
                    <p class="mute">Whether it is in the backup is set on <button class="link-btn" onclick={() => go('/protection/backup')}>Backup</button>.</p>
                  {/if}
                </div>
              {:else if t === 'perm'}
                <div class="pad">
                  <div class="sh"><b>Permissions</b><span class="mute">apply at the next connection</span><span class="grow"></span>
                    <button class="btn sm" disabled={locked} onclick={() => openCreate(AddAccess, { share: sel.name, taken: entries.map((e) => e.sid) })}><i class="ph ph-plus"></i>Add</button></div>
                  {#each entries as e (e.sid)}
                    <div class="arow2">
                      <span class="nm"><i class="ph {e.type === 'group' ? 'ph-users-three' : 'ph-user'}"></i>{e.name}</span>
                      <div class="lv" role="group" aria-label="Access of {e.name}">
                        {#each LEVELS as l}<button type="button" class="lvb" class:on={l === e.level} aria-pressed={l === e.level} disabled={locked} title={l === e.level ? '' : `Set ${e.name} to ${l}`} onclick={() => setLevel(e, l)}>{l}</button>{/each}
                      </div>
                    </div>
                  {:else}
                    <p class="mute">{acl.loaded ? 'No entries.' : 'Loading…'}</p>
                  {/each}
                </div>
              {:else if t === 'snap'}
                <div class="pad">
                  {#if !isZfs(sel)}
                    <Banner tone="info">Snapshots exist on ZFS only. {snapraid ? 'This server keeps its shares on SnapRAID, so the restore points come from the backup (History tab).' : 'This share is not on a ZFS dataset.'}</Banner>
                  {:else}
                    <div class="sh"><b>Snapshots</b><span class="mute">{auto ? 'automatic: hourly, kept 24 h / 7 d / 4 w' : 'automatic snapshots are off'}</span></div>
                    {#each [...snaps].reverse() as n (n.name)}
                      <div class="trow"><code class="grow">{n.name}</code><span class="mute">{n.created}</span><Chip>{n.how}</Chip></div>
                    {:else}<p class="mute">{hist.loaded ? 'No snapshots yet.' : 'Loading…'}</p>{/each}
                    <p class="mute">ZFS can only go back to the newest snapshot; newer ones are deleted by a roll-back.</p>
                  {/if}
                </div>
              {:else}
                <div class="pad">
                  <div class="sh"><b>Restore points</b><span class="mute">from the backup, newest first</span></div>
                  {#each points as p (p.id)}<div class="trow"><code>{p.id}</code><span class="grow"></span><span class="mute">{p.time}</span></div>
                  {:else}<p class="mute">{backups.loaded ? 'The backup has no restore points for shares yet.' : 'Loading…'}</p>{/each}
                  <p class="mute">A restore puts the files into the share <code>restored</code>; the original is not touched.</p>
                </div>
              {/if}
            {/snippet}
            {#snippet actions()}
              {#if editable(sel)}
                {#if tab === 'snap' && isZfs(sel)}
                  <button class="btn sm" disabled={locked} onclick={() => openPlan('shares', [sel.name, 'snapshot'], `Snapshot ${sel.name}`)}><i class="ph ph-camera"></i>Snapshot now</button>
                  <button class="btn sm" disabled={locked || !hist.loaded || hist.error} onclick={() => toggle('auto', auto ? 'off' : 'on')}><i class="ph ph-clock-clockwise"></i>Automatic {auto ? 'off' : 'on'}</button>
                  <button class="btn sm" disabled={locked || !newest} title={newest ? `Roll back to ${newest.name}` : 'No snapshot to roll back to'} onclick={() => openPlan('shares', [sel.name, 'rollback', '--snapshot', newest.name], `Roll back ${sel.name}`)}><i class="ph ph-arrow-u-up-left"></i>Roll back</button>
                {:else if tab === 'hist'}
                  <button class="btn sm" disabled={locked} onclick={() => openCreate(RestoreShare, { share: sel.name })}><i class="ph ph-arrow-counter-clockwise"></i>Restore from backup…</button>
                {:else}
                  {#if sel.kind === 'shares' && (sel.cache === 'on' || sel.cache === 'off')}<button class="btn sm" disabled={locked} onclick={() => toggle('cache', sel.cache === 'on' ? 'off' : 'on')}><i class="ph ph-lightning"></i>Cache {sel.cache === 'on' ? 'off' : 'on'}</button>{/if}
                  <button class="btn sm" disabled={locked} onclick={() => openCreate(RenameShare, { share: sel.name })}><i class="ph ph-pencil-simple"></i>Rename…</button>
                  <button class="btn sm" disabled={locked} title="Hand the files of this share to adminuser again" onclick={() => openPlan('shares', [sel.name, 'repair'], `Repair ${sel.name}`)}><i class="ph ph-wrench"></i>Repair</button>
                  <button class="btn sm btn-danger" disabled={locked} onclick={() => openCreate(DeleteShare, { share: sel.name })}><i class="ph ph-trash-simple"></i>Delete…</button>
                {/if}
              {/if}
            {/snippet}
          </Drawer>
        {/if}
      {/snippet}
    </Split>
  </PageState>
{/if}

<style>
  .bar { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 14px; }
  .seg { max-width: 100%; overflow-x: auto; }
  .card { overflow-x: auto; }
  .gap { padding: 4px 8px; }
  .pad { padding: 12px 16px; }
  .nm { display: inline-flex; align-items: center; gap: 8px; }
  .nm i { color: var(--fg-3); }
  .acts { display: inline-flex; gap: 6px; flex-wrap: wrap; }
  .mute { color: var(--fg-3); font-size: 12px; }
  .nw { white-space: nowrap; }
  code { font-size: 12px; }
  .sh { display: flex; align-items: baseline; gap: 8px; margin-bottom: 8px; }
  .links { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 8px; }
  .trow { display: flex; align-items: center; gap: 10px; padding: 7px 0; border-bottom: 1px solid var(--line); }
  .arow2 { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 7px 0; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
  .lv { display: inline-flex; border: 1px solid var(--line-2); }
  .lvb { all: unset; box-sizing: border-box; cursor: pointer; padding: 4px 9px; font-size: 12px; color: var(--fg-2); }
  .lvb + .lvb { border-left: 1px solid var(--line-2); }
  .lvb:hover:not(:disabled) { background: var(--panel-2); }
  .lvb.on { background: var(--panel-3); color: var(--fg); font-weight: 600; }
  .lvb:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
  .lvb:disabled { opacity: 0.5; cursor: not-allowed; }
</style>
