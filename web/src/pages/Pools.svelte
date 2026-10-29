<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // Storage > Pools: the list (/storage/pools) and the detail of one pool (/storage/pools/<name>) in one page. Membership changes (add, adopt,
  // replace, remove, close, open, convert) and scrub / sync live here; everything about a single disk lives on Disks (a link, not a copy).
  import UsageBar from '../shell/UsageBar.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import { StatusDot, Chip, Kv, Banner } from '../ui/index.js';
  import { poll, rows } from '../data.svelte.js';
  import { route, go } from '../route.svelte.js';
  import { filesLink } from '../files/links.js';
  import { setSelection } from '../select.svelte.js';
  import { openPlan, openCreate } from '../ui.svelte.js';
  import AddDisks from '../forms/storage/AddDisks.svelte';
  import ReplaceMember from '../forms/storage/ReplaceMember.svelte';
  import RemoveMember from '../forms/storage/RemoveMember.svelte';
  import ConvertPool from '../forms/storage/ConvertPool.svelte';
  import CloseDisk from '../forms/storage/CloseDisk.svelte';
  import { parseInfo, percentOf, diskPool, serialIn, sizeTxt, parseSize } from './storage/pool.js';

  let { deck } = $props();

  const NAMES = ['bulk', 'fast'];
  const pool = $derived(route.path.startsWith('/storage/pools/') ? route.path.slice('/storage/pools/'.length) : '');
  const locked = $derived(!!deck?.data?.locked);

  // ── shared by list and detail
  const disks = poll('/api/sys/monitor/disks', 30000);
  // monitor disks: name, bytes, SSD/HDD, role, temp, health, hours, reallocated, pending, crc, model+serial, free
  const monitor = $derived(rows(disks).map((r) => ({ name: r[0], role: r[3], model: r[10], free: r[11] })));
  const freeDisks = $derived(monitor.filter((d) => d.role === 'free' || d.role === 'mounted'));

  const infoBulk = poll('/api/sys/pool/info?pool=bulk', 15000);
  const infoFast = poll('/api/sys/pool/info?pool=fast', 15000);
  const infos = $derived({ bulk: infoBulk, fast: infoFast });
  const factsOf = (name) => parseInfo(rows(infos[name])).facts;
  const isSnap = (f) => /SnapRAID/i.test(f.layout ?? '');
  const layoutOf = (f) => (isSnap(f) ? 'SnapRAID' : /ZFS/i.test(f.layout ?? '') ? 'ZFS mirror' : (f.layout ?? ''));
  const dotOf = (state) => {
    const t = (state ?? '').toLowerCase();
    return /degraded|fault|unavail|no parity/.test(t) ? 'bad' : /online|protected/.test(t) ? 'ok' : /not/.test(t) ? 'warn' : 'off';
  };

  // ── the list
  const list = $derived(NAMES.map((name) => {
    const f = factsOf(name), dp = deck?.data?.pools?.[name];
    const loaded = infos[name].loaded, failed = loaded && !rows(infos[name]).length;
    const created = loaded && !failed && !/not created/i.test(f.state ?? '');
    return {
      name, loaded, failed, created, layout: layoutOf(f), state: (f.state ?? '').toLowerCase(), sync: f['last sync'] ?? '',
      size: dp?.size ?? 0, used: dp?.used ?? null, count: monitor.filter((d) => diskPool(d.role) === name).length,
    };
  }));
  const shown = $derived(list.filter((p) => p.created || p.failed || !p.loaded));
  const notYet = $derived(list.filter((p) => p.loaded && !p.failed && !p.created));
  const columns = [
    { key: 'name', label: 'Pool' }, { key: 'layout', label: 'Layout', optional: true }, { key: 'usage', label: 'Usage', sort: 'num', value: (p) => p.used ?? -1 },
    { key: 'state', label: 'State' }, { key: 'count', label: 'Disks', sort: 'num', optional: true }, { key: 'sync', label: 'Last sync', optional: true },
  ];

  // ── the detail
  const info = poll(() => (pool ? `/api/sys/pool/info?pool=${pool}` : ''), 15000);
  const memb = poll(() => (pool ? `/api/sys/pool/members?pool=${pool}` : ''), 15000);
  const shares = poll(() => (pool === 'bulk' ? '/api/sys/shares/overview' : ''), 30000);
  const cts = poll(() => (pool === 'fast' ? '/api/sys/ct/list' : ''), 30000);

  // what the pool is doing (`hs sys pool state`): lock <free|busy|pool-change|unknown> text / paused <yes|no> text / scrub <pool> <running|ok|errors|never|unknown> text / sync bulk <running|ok|never|unknown> text.
  // `pool info` has no scrub field on either layout (SnapRAID: "last sync" only), so the scrub and sync lines come from here.
  const st = poll(() => (pool ? `/api/sys/pool/state?pool=${pool}` : ''), 10000);
  const stRows = $derived(rows(st));
  const lockRow = $derived(stRows.find((r) => r[0] === 'lock'));
  const lockState = $derived(lockRow?.[1] ?? '');
  const paused = $derived(stRows.find((r) => r[0] === 'paused')?.[1] === 'yes');
  const scrubRow = $derived(stRows.find((r) => r[0] === 'scrub' && r[1] === pool));
  const syncRow = $derived(stRows.find((r) => r[0] === 'sync' && r[1] === pool));
  const running = $derived(scrubRow?.[2] === 'running' || syncRow?.[2] === 'running');
  const lockTxt = { free: 'free', busy: 'in use', 'pool-change': 'held by a pool change', unknown: 'unknown' };

  const f = $derived(parseInfo(rows(info)).facts);
  const snap = $derived(isSnap(f));
  const layout = $derived(layoutOf(f));
  const notCreated = $derived(info.loaded && /not created/i.test(f.state ?? ''));
  const failed = $derived(info.loaded && !rows(info).length);
  const dp = $derived(deck?.data?.pools?.[pool]);
  const stateTxt = $derived((f.state ?? '').toLowerCase());
  const pctUsed = $derived(percentOf(f.used) ?? (dp?.size ? Math.round((dp.used / dp.size) * 100) : null));

  // pool members: name, bytes, state, group (mirror | data | parity), filesystem, encryption, closed (SnapRAID: no new files)
  const members = $derived(rows(memb).map((r) => {
    const mon = monitor.find((m) => (snap ? m.role === `bulk ${r[0]}` : diskPool(m.role) === pool && serialIn(m.model, r[0])));
    return { name: r[0], dev: mon?.name ?? r[0], size: Number(r[1]), free: mon?.free, state: r[2], group: r[3], fs: r[4], enc: r[5], closed: r[6] === 'closed' };
  }));
  const memberDot = (m) => (m.state === 'ONLINE' ? 'ok' : /DEGRADED|FAULT|UNAVAIL|REMOVED/i.test(m.state) ? 'bad' : 'warn');
  const convertible = $derived(snap ? members.filter((m) => m.group === 'data' && m.state === 'ONLINE').map((m) => m.name) : []);
  const luks = $derived(members.some((m) => m.enc === 'luks'));

  const unavailable = $derived(locked || failed || !layout);
  const why = (t) => (locked ? 'The storage is locked: the pools are down' : unavailable ? 'The pool is not available' : t);
  const runTitle = $derived(why(snap ? 'Update the parity now (shows the plan first)' : `Scrub ${pool} now (shows the plan first)`));

  // shares overview: name, kind, path, cache, size_bytes, ...
  const shareRows = $derived(rows(shares).filter((r) => r[1] !== 'other'));
  const shareBytes = $derived(shareRows.reduce((a, r) => a + (Number(r[4]) || 0), 0));
  // ct list: name, type, state, address, ram, cpu, autostart, mac pinned, docker, disk, ...
  const volumes = $derived(rows(cts).filter((r) => r[9] && r[9] !== '-'));
  const volBytes = $derived(volumes.reduce((a, r) => a + parseSize(r[9]), 0));

  const facts = $derived.by(() => {
    const out = [];
    if (layout) out.push({ k: 'Layout', v: layout });
    const enc = members.find((m) => m.enc && m.enc !== '-');
    if (enc) out.push({ k: 'Encryption', v: `${enc.enc === 'luks' ? 'LUKS per disk' : enc.enc}${locked ? '' : ' · open'}` });
    if (syncRow) out.push({ k: 'Parity sync', v: syncRow[2] === 'running' ? 'running now' : syncRow[3] });
    else if (f['last sync']) out.push({ k: 'Last parity sync', v: f['last sync'] });
    if (scrubRow) out.push({ k: 'Scrub', v: scrubRow[2] === 'running' ? `running, since ${scrubRow[3]}` : scrubRow[2] === 'unknown' ? '–' : scrubRow[3] });
    if (lockRow && lockState !== 'unknown') out.push({ k: 'Bulk lock', v: lockTxt[lockState] ?? lockState });
    if (f['upload cache']) out.push({ k: 'Upload cache', v: f['upload cache'].replace(/\s*\(.*/, '') });
    if (snap) out.push({ k: 'Merged by mergerfs', v: '/mnt/bulk/pool, shared as /bulk' });
    if (pool === 'fast') out.push({ k: 'Incus storage pool', v: '"default"' });
    return out;
  });

  const fsText = (m) => (m.fs && m.fs !== '-' ? m.fs : '–');
  const memberCols = [
    { key: 'dev', label: 'Disk' }, { key: 'role', label: 'Role', value: (m) => (snap ? m.name : m.group) }, { key: 'state', label: 'State' },
    { key: 'size', label: 'Size', sort: 'num', value: (m) => m.size, optional: true }, { key: 'fs', label: 'Format', value: (m) => fsText(m), optional: true }, { key: 'actions', label: '', sort: false, align: 'right' },
  ];
  const openDisk = (m) => { setSelection('disks', m.dev); go(`/storage/disks?pool=${pool}`); };
  const addPool = (variant) => openCreate(AddDisks, { pool, variant, snap: notCreated ? undefined : snap });
</script>

{#if !pool}
  <PageHeader title="Pools" crumb="Storage" sub="How the disks are grouped, how full they are and whether the redundancy holds.">
    {#snippet actions()}
      {#if freeDisks.length}<button use:tip={'Show the disks that belong to no pool'} class="btn" onclick={() => go('/storage/disks?pool=none')}><i class="ph ph-hard-drive"></i>{freeDisks.length} free disk{freeDisks.length === 1 ? '' : 's'}</button>{/if}
    {/snippet}
  </PageHeader>
  <PageState loading={!(infoBulk.loaded && infoFast.loaded)} hasData={infoBulk.loaded && infoFast.loaded} empty={!shown.length} emptyIcon="cylinder" emptyTitle="No pool yet"
             emptyText="A pool groups disks into one place for the shares. Pick free disks to create the first one.">
    <div class="card"><div class="scrollx">
      <Table id="pools" {columns} rows={shown} key="name" onrow={(p) => go(`/storage/pools/${p.name}`)} empty="No pools.">
        {#snippet cell(p, col)}
          {#if col.key === 'name'}<span class="nm"><i class="ph {p.name === 'fast' ? 'ph-lightning' : 'ph-cylinder'}"></i>{p.name}</span>
          {:else if col.key === 'layout'}{#if p.layout}<Chip>{p.layout}</Chip>{:else}–{/if}
          {:else if col.key === 'usage'}{#if p.size}<UsageBar used={p.used} size={p.size} />{:else}<span class="mute">{p.loaded ? 'not mounted' : '…'}</span>{/if}
          {:else if col.key === 'state'}<StatusDot state={p.failed ? 'bad' : dotOf(p.state)} label={p.failed ? 'cannot be read' : p.state || (p.loaded ? 'unknown' : 'reading')} />
          {:else if col.key === 'count'}{p.count || '–'}
          {:else}<span class="mute">{p.sync || '–'}</span>{/if}
        {/snippet}
      </Table>
    </div></div>
    {#if notYet.length}
      <p class="mute">Not created yet: {notYet.map((p) => p.name).join(', ')}. Open the pool's page to create it from free disks.</p>
    {/if}
  </PageState>
{:else}
  <PageHeader title={pool} crumb="Storage › Pools" sub={layout ? `${layout}${members.length ? ` · ${members.length} disk${members.length === 1 ? '' : 's'}` : ''}${luks ? ' · LUKS' : ''}` : ''}>
    {#snippet actions()}
      <button use:tip={'Back to the list of pools'} class="btn" onclick={() => go('/storage/pools')}><i class="ph ph-caret-left"></i>All pools</button>
      <button class="btn" disabled={locked || failed} use:tip={locked ? 'The storage is locked: the pools are down' : 'Pick free disks and see the plan'} onclick={() => addPool('empty')}><i class="ph ph-plus"></i>{notCreated ? 'Create pool' : snap ? 'Add disks' : 'Add mirror pair'}</button>
      {#if snap}<button class="btn" disabled={why('') !== ''} use:tip={why('Bring a disk that already holds files into the pool')} onclick={() => addPool('adopt')}><i class="ph ph-hand-arrow-down"></i>Adopt disks</button>{/if}
      <button class="btn btn-primary" disabled={unavailable || notCreated} use:tip={runTitle}
        onclick={() => (snap ? openPlan('system', ['sync'], 'Sync parity') : openPlan('system', ['scrub', '--pool', pool], `Scrub ${pool}`))}><i class="ph {snap ? 'ph-arrows-clockwise' : 'ph-broom'}"></i>{snap ? 'Sync parity now' : 'Scrub now'}</button>
    {/snippet}
  </PageHeader>

  <PageState loading={!info.loaded} hasData={info.loaded} error={failed ? 'the pool could not be read' : ''}>
    {#if notCreated}
      <Banner tone="info">The pool {pool} has not been created yet. {#if freeDisks.length}{freeDisks.length} free disk{freeDisks.length === 1 ? ' is' : 's are'} available.{:else}There is no free disk to build it from.{/if}
        {#snippet action()}<button use:tip={locked ? 'Storage is locked' : 'Pick free disks and make a new pool'} class="btn sm" disabled={locked} onclick={() => addPool('empty')}>Create pool</button>{/snippet}
      </Banner>
    {:else}
      {#if paused}<Banner tone="warn">The health check paused the parity sync, scrub and upload cache mover because of a failing disk or pool. Lift it under Health (<code>hs health resume</code>).</Banner>{/if}
      {#if lockState === 'pool-change'}<Banner tone="info">A pool change is running and owns the bulk lock: syncs, scrubs and share renames wait or are skipped until it is done.</Banner>
      {:else if lockState === 'busy'}<Banner tone="info">{running ? 'A sync or scrub is running.' : 'Something holds the bulk lock (a parity sync, scrub, upload cache mover, share rename or disk move).'} Changes that need the lock wait until it is free.</Banner>{/if}
      <div class="card xh cap">
        {#if dp?.size}
          <div class="cap-top"><StatusDot state={dotOf(stateTxt)} label={stateTxt || 'unknown'} /><span class="mute">{pctUsed != null ? `${pctUsed} % used` : ''}</span></div>
          <UsageBar block used={dp.used} size={dp.size} />
        {:else}
          <p class="mute">{info.loaded ? 'No capacity available (the pool is not mounted).' : 'Loading…'}</p>
        {/if}
        {#if facts.length}<Kv items={facts} cols={3} />{/if}
      </div>

      <div class="card sect">
        <div class="sh"><b>Members</b><span class="mute">{members.some((m) => m.state !== 'ONLINE') ? 'check the state column' : members.length ? (snap ? 'all present' : 'all ONLINE') : ''}</span>
          <span class="grow"></span><button use:tip={'Show the disks of this pool'} class="btn sm btn-ghost" onclick={() => go(`/storage/disks?pool=${pool}`)}>Disks of this pool<i class="ph ph-caret-right"></i></button></div>
        <div class="scrollx">
          <Table id="pool-members" columns={memberCols} rows={members} key="name" compact loading={!memb.loaded} empty="No members.">
            {#snippet cell(m, col)}
              {#if col.key === 'dev'}<button class="link-btn" use:tip={'Open this disk'} onclick={() => openDisk(m)}><code>{m.dev}</code></button>
              {:else if col.key === 'role'}<Chip>{snap ? m.name : m.group}</Chip>{#if m.closed} <Chip>closed</Chip>{/if}
              {:else if col.key === 'state'}<StatusDot state={memberDot(m)} label={(m.state ?? '').toLowerCase()} />
              {:else if col.key === 'size'}<span class="nw"><UsageBar free={m.free} size={m.size} width={96} /></span>
              {:else if col.key === 'fs'}<span class="nw mute">{fsText(m)}</span>
              {:else}
                <span class="acts">
                  {#if snap ? /^data-\d+$/.test(m.name) : true}<button class="btn btn-ghost btn-icon sq" use:tip={snap ? 'Browse the files of this disk' : 'Browse the files of this pool'} aria-label="Browse" disabled={locked} onclick={() => go(filesLink({ left: snap ? `disk:${m.name}` : `pool:${pool}` }))}><i class="ph ph-folder-open"></i></button>{/if}
                  <button class="btn btn-ghost btn-icon sq" use:tip={'Replace this disk'} aria-label="Replace" disabled={locked} onclick={() => openCreate(ReplaceMember, { pool, member: m.name, snap })}><i class="ph ph-swap"></i></button>
                  {#if snap}<button class="btn btn-ghost btn-icon sq" use:tip={convertible.includes(m.name) ? 'Change filesystem or LUKS; its files are moved away first' : 'Only an online data disk can be converted'} aria-label="Convert" disabled={locked || !convertible.includes(m.name)} onclick={() => openCreate(ConvertPool, { pool, member: m.name, members: convertible })}><i class="ph ph-arrows-clockwise"></i></button>{/if}
                  {#if snap && m.group === 'data'}<button class="btn btn-ghost btn-icon sq" use:tip={m.closed ? 'Closed: no new files. Open it again or move its files away' : 'Stop putting new files on this disk (optionally move its files away)'} aria-label={m.closed ? 'Open' : 'Close'} disabled={locked || m.state !== 'ONLINE'} onclick={() => openCreate(CloseDisk, { pool, member: m.name, closed: m.closed })}><i class="ph ph-{m.closed ? 'lock-key-open' : 'prohibit'}"></i></button>{/if}
                  <button class="btn btn-ghost btn-icon sq" use:tip={snap ? 'Remove this disk' : 'Detach this disk'} aria-label={snap ? 'Remove' : 'Detach'} disabled={locked} onclick={() => openCreate(RemoveMember, { pool, member: m.name, snap })}><i class="ph ph-link-break"></i></button>
                </span>
              {/if}
            {/snippet}
          </Table>
        </div>
      </div>

      <div class="card sect">
        {#if pool === 'bulk'}
          <div class="sh"><b>Shares</b><span class="mute">{shares.loaded ? `${shareRows.length} share${shareRows.length === 1 ? '' : 's'}${shareBytes ? ` · ${sizeTxt(shareBytes)}` : ''}` : 'Loading…'}</span>
            <span class="grow"></span><button use:tip={'Show the shares in this pool'} class="btn sm btn-ghost" onclick={() => go('/storage/shares?pool=bulk')}>Shares<i class="ph ph-caret-right"></i></button></div>
        {:else}
          <div class="sh"><b>Instance volumes</b><span class="mute">{cts.loaded ? `${volumes.length} volume${volumes.length === 1 ? '' : 's'}${volBytes ? ` · ${sizeTxt(volBytes)}` : ''} · Incus pool "default"` : 'Loading…'}</span>
            <span class="grow"></span><button use:tip={'Show the shares in this pool'} class="btn sm btn-ghost" onclick={() => go('/storage/shares?pool=fast')}>Shares<i class="ph ph-caret-right"></i></button>
            <button use:tip={'Show the instances'} class="btn sm btn-ghost" onclick={() => go('/instances')}>Instances<i class="ph ph-caret-right"></i></button></div>
        {/if}
      </div>
    {/if}
  </PageState>
{/if}

<style>
  .card { margin-bottom: 14px; }
  .cap { padding: 16px 18px; gap: 14px; }
  .cap-top { display: flex; align-items: center; gap: 12px; }
  .sect { padding: 12px 14px; gap: 8px; }
  .sh { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .mute { color: var(--fg-3); font-size: 12px; }
  .nm { display: inline-flex; align-items: center; gap: 8px; font-weight: 500; }
  .nm i { color: var(--fg-3); }
  .scrollx { overflow-x: auto; }
  .acts { display: flex; justify-content: flex-end; gap: 2px; }
  .sq { width: 28px; min-height: 28px; }
  .nw { white-space: nowrap; }
  code { font-size: 12px; }
</style>
