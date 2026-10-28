<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // Storage > Disks: every disk of this server in one list (/storage/disks, filter ?pool=bulk|fast|none|missing), a drawer for the selected one
  // (SMART history, self-test results, the actions that belong to a single disk). Changing pool membership (replace, remove, close, convert)
  // stays on Pools; a free disk is added from here (the Pools plan).
  import UsageBar from '../shell/UsageBar.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import { StatusDot, Chip, Kv, Drawer, Split, Banner } from '../ui/index.js';
  import { poll, rows } from '../data.svelte.js';
  import { takeSelection } from '../select.svelte.js';
  import { route, go } from '../route.svelte.js';
  import { healthDot } from '../format.js';
  import { openPlan, openCreate } from '../ui.svelte.js';
  import AddDisks from '../forms/storage/AddDisks.svelte';
  import WipeDisk from '../forms/storage/WipeDisk.svelte';
  import ForgetDisk from '../forms/storage/ForgetDisk.svelte';
  import OtherDisk from '../forms/storage/OtherDisk.svelte';
  import DetachDisk from '../forms/storage/DetachDisk.svelte';
  import RecoverDisk from '../forms/storage/RecoverDisk.svelte';
  import { filesLink } from '../files/links.js';
  import { diskPool, sizeTxt, hoursTxt, roleLabel, dateOf, serialIn } from './storage/pool.js';

  let { deck } = $props();

  const TABS = [{ id: 'all', label: 'All' }, { id: 'bulk', label: 'bulk' }, { id: 'fast', label: 'fast' }, { id: 'none', label: 'Free' }, { id: 'missing', label: 'Missing' }];
  const filter = $derived(TABS.some((t) => t.id === route.query.pool) ? route.query.pool : 'all');
  const setFilter = (id) => { selName = ''; go(id === 'all' ? '/storage/disks' : `/storage/disks?pool=${id}`); };
  let selName = $state('');
  let tab = $state('info');
  $effect(() => { const n = takeSelection('disks'); if (n) { selName = n; tab = 'info'; } });

  const locked = $derived(!!deck?.data?.locked);
  const mon = poll('/api/sys/monitor/disks', 30000);
  const health = poll('/api/sys/disk-health/list', 60000);
  const inv = poll('/api/sys/state/disks', 30000);
  // data disks that are out of the pool by hand: member, detached | recovering, since (epoch)
  const marks = poll('/api/sys/disk/marks', 15000);
  const markOf = $derived(Object.fromEntries(rows(marks).map((r) => [r[0], r[1]])));
  const poolInfo = poll('/api/sys/pool/info?pool=bulk', 60000);
  const bulkSnap = $derived(rows(poolInfo).some((r) => /SnapRAID/i.test(r[0] ?? '')));
  const membBulk = poll('/api/sys/pool/members?pool=bulk', 30000);
  const membFast = poll('/api/sys/pool/members?pool=fast', 30000);

  // monitor disks: name, bytes, SSD/HDD, role, temp, health, hours, reallocated, pending, crc, model+serial, free, power, filesystem (xfs, ext4, zfs, ... / none / -)
  const all = $derived(rows(mon).map((r) => ({
    name: r[0], size: Number(r[1]), kind: r[2], role: r[3], temp: r[4], smart: r[5], hours: r[6], realloc: r[7], pending: r[8], crc: r[9], model: r[10], free: r[11], fs: r[13],
  })));
  // disk-health list: name, size, kind, model, verdict, hours, first reason
  const verdicts = $derived(Object.fromEntries(rows(health).map((r) => [r[0], { verdict: r[4], reason: r[6] }])));
  // state disks: serial, model, size, dev, state, role, pool, first_seen, last_seen, worse, note
  const known = $derived(rows(inv).map((r) => ({ serial: r[0], model: r[1], size: Number(r[2]), dev: r[3], state: r[4], role: r[5], first: r[7], lastSeen: Number(r[8]), note: r[10] })));
  const missing = $derived(known.filter((k) => k.state === 'missing'));

  const isLoose = (d) => d.role === 'free' || d.role === 'mounted';
  const counts = $derived({
    all: all.length, bulk: all.filter((d) => diskPool(d.role) === 'bulk').length, fast: all.filter((d) => diskPool(d.role) === 'fast').length,
    none: all.filter(isLoose).length, missing: missing.length,
  });
  const visible = $derived(all.filter((d) => (filter === 'all' ? true : filter === 'none' ? isLoose(d) : filter === 'missing' ? false : diskPool(d.role) === filter)));
  const sel = $derived(filter === 'missing' ? null : all.find((d) => d.name === selName) ?? null);
  const selMissing = $derived(filter === 'missing' ? missing.find((m) => m.serial === selName) ?? null : null);

  const verdictOf = (d) => {
    const v = verdicts[d.name]?.verdict;
    return v && v !== '-' ? v : d.smart && d.smart !== '-' ? d.smart : 'idle';
  };
  const stateOf = (d) => (markOf[memberOf(d)] ? 'info' : healthDot(verdictOf(d) === 'idle' ? '' : verdictOf(d)));
  const wordOf = (d) => (markOf[memberOf(d)] ? markOf[memberOf(d)] : verdictOf(d));
  // the model column holds "model serial": split off the last word
  const modelOf = (d) => (d.model ?? '').trim().replace(/\s+\S+$/, '');
  const serialOf = (d) => (d.model ?? '').trim().split(/\s+/).pop();

  // The pool member a disk is (SnapRAID: "bulk data-01" -> data-01; ZFS: the by-id name of the members list) and its group (data | parity | mirror-0 ...)
  const membRows = (p) => rows(p === 'fast' ? membFast : membBulk);
  const snapRole = (d) => /^bulk (data|parity)-\d+$/.test(d?.role ?? '');
  const memberOf = (d) => {
    if (!d || !diskPool(d.role)) return '';
    if (snapRole(d)) return d.role.replace(/^bulk /, '');
    return membRows(diskPool(d.role)).map((r) => r[0]).find((n) => serialIn(d.model, n)) ?? '';
  };
  const roleText = (d) => {
    if (snapRole(d)) return roleLabel(d.role);
    const g = membRows(diskPool(d.role)).find((r) => r[0] === memberOf(d))?.[3];
    return g && g !== '-' ? g : roleLabel(d.role);
  };
  const poolText = (d) => diskPool(d.role) || (isLoose(d) ? 'free' : d.role);
  // the pane next to a disk in the file manager: another data disk (a pool disk and its own pool never meet there)
  const otherDisk = (member) => { const o = dataMembers('bulk').find((n) => n !== member); return o ? `disk:${o}` : ''; };
  const dataMembers = (p) => membRows(p).filter((r) => r[3] === 'data' && r[2] === 'ONLINE').map((r) => r[0]);

  // ── the drawer: SMART history and self-tests
  const rec = $derived(known.find((k) => k.dev === sel?.name && k.state !== 'missing'));
  const serial = $derived(rec?.serial ?? '');
  const hist = poll(() => (serial ? `/api/sys/state/smart/${encodeURIComponent(serial)}` : ''), 60000);
  const results = poll(() => (sel ? `/api/sys/disk/results/${encodeURIComponent(sel.name)}` : ''), 60000);
  // state smart: time, realloc, pending, crc, temp, hours (newest first)
  const readings = $derived(rows(hist).map((r) => ({ t: Number(r[0]), pending: Number(r[2]), temp: Number(r[4]) })).filter((x) => !isNaN(x.t)).reverse());
  const spanTxt = $derived.by(() => {
    if (readings.length < 2) return '';
    const h = (readings[readings.length - 1].t - readings[0].t) / 3600;
    return h <= 48 ? `last ${Math.max(1, Math.round(h))} hours` : `last ${Math.round(h / 24)} days`;
  });
  const pts = (vals, w, y) => vals.map((v, i) => `${((i / Math.max(1, vals.length - 1)) * w).toFixed(1)},${y(v).toFixed(1)}`).join(' ');
  const pend = $derived(readings.filter((x) => !isNaN(x.pending)).map((x) => x.pending));
  const pendMax = $derived(Math.max(10, ...pend));
  const linePts = $derived(pts(pend, 400, (v) => 56 - (v / pendMax) * 50));
  const temps = $derived(readings.filter((x) => !isNaN(x.temp)).map((x) => x.temp));
  const tempPts = $derived(pts(temps, 400, (v) => 40 - Math.max(0.05, Math.min(0.95, (v - 20) / 35)) * 40));
  // `disk results` lines: "Short offline Completed without error at 21400 h"
  const tests = $derived(rows(results).map((r) => r.join(' ').trim()).filter((l) => l && !/^none yet/i.test(l) && !/^A test is running/i.test(l)).map((l) => {
    const m = /^(\S+)\s+(?:\S+\s+)?(.*?)\s*(?:at (\d+) h)?$/.exec(l);
    return { kind: /^ext/i.test(m?.[1] ?? '') ? 'long' : (m?.[1] ?? l).toLowerCase(), result: m?.[2] ?? '', when: m?.[3] ? `at ${hoursTxt(m[3])}` : '' };
  }));
  const running = $derived(rows(results).map((r) => r.join(' ')).find((l) => /^A test is running/i.test(l)));
  const num = (v) => (v && v !== '-' ? v : '–');
  const fsText = (d) => (d.fs && d.fs !== '-' ? d.fs : '–');

  const runTest = (kind) => openPlan('disk', [sel.name, 'test', kind], `${kind === 'long' ? 'Long' : 'Short'} test of ${sel.name}`);
  const addToPool = (pool) => openCreate(AddDisks, { pool, variant: 'empty', snap: pool === 'bulk' ? bulkSnap : false });
  const poolForNew = $derived(filter === 'fast' ? 'fast' : 'bulk');
  const lockTip = (t) => (locked ? 'The storage is locked' : t);

  const columns = [
    { key: 'name', label: 'Disk' }, { key: 'pool', label: 'Pool', value: (d) => poolText(d) }, { key: 'role', label: 'Role', value: (d) => roleText(d), optional: true },
    { key: 'model', label: 'Model', value: (d) => modelOf(d), optional: true }, { key: 'size', label: 'Size', sort: 'num', value: (d) => d.size }, { key: 'fs', label: 'Format', value: (d) => fsText(d), optional: true },
    { key: 'smart', label: 'SMART', value: (d) => verdictOf(d) }, { key: 'temp', label: 'Temp', sort: 'num', value: (d) => Number(d.temp), optional: true },
    { key: 'hours', label: 'Power-on', sort: 'num', value: (d) => Number(d.hours), optional: true },
  ];
  const missCols = [{ key: 'model', label: 'Disk' }, { key: 'dev', label: 'Was' }, { key: 'serial', label: 'Serial' }, { key: 'seen', label: 'Last seen', sort: 'num', value: (m) => m.lastSeen }];
</script>

<PageHeader title="Disks" crumb="Storage" sub="Every disk of this server: where it belongs, how healthy it is, what it has been through.">
  {#snippet actions()}
    <button class="btn" disabled={locked} use:tip={lockTip('Look at a USB or hot-plug disk: mount it read-only, copy from it, eject it')} onclick={() => openCreate(OtherDisk, {})}><i class="ph ph-usb"></i>Other disk</button>
    <button class="btn btn-primary" disabled={locked || !counts.none} use:tip={lockTip(counts.none ? 'Pick free disks and see the plan' : 'There is no free disk')} onclick={() => addToPool(poolForNew)}><i class="ph ph-plus"></i>Add disks to a pool</button>
  {/snippet}
</PageHeader>

<div class="tabs seg" role="tablist" aria-label="Filter">
  {#each TABS as t (t.id)}
    <label class="seg-opt"><input type="radio" name="dfilter" checked={filter === t.id} onchange={() => setFilter(t.id)} />{t.label}<span class="cnt">{counts[t.id] ?? ''}</span></label>
  {/each}
</div>

<PageState loading={!mon.loaded} hasData={mon.data != null} error={mon.error?.message ?? ''} empty={mon.loaded && !all.length && !missing.length} emptyIcon="hard-drive" emptyTitle="No disks found"
           emptyText="The disks could not be listed. Is the storage locked or the collector not running?">
  {#if filter === 'missing'}
    <Split open={!!selMissing}>
      {#snippet list()}
        <div class="card">
          {#if missing.length}
            <Table id="disks-missing" columns={missCols} rows={missing} key="serial" compact selected={selMissing?.serial} onrow={(m) => (selName = m.serial)} empty="No disk is missing.">
              {#snippet cell(m, col)}
                {#if col.key === 'model'}<StatusDot state="warn" label={m.model || m.serial} />
                {:else if col.key === 'dev'}<code>{m.dev}</code>
                {:else if col.key === 'serial'}<code>{m.serial}</code>
                {:else}<span class="mute">{m.lastSeen ? dateOf(m.lastSeen) : '–'}</span>{/if}
              {/snippet}
            </Table>
          {:else}
            <p class="mute pad">Nothing is missing: every disk the server has seen is still connected.</p>
          {/if}
        </div>
      {/snippet}
      {#snippet side()}
        {#if selMissing}
          <Drawer title={selMissing.model || selMissing.serial} chip="missing" state="warn" stateLabel="not connected" onclose={() => (selName = '')}>
            <Kv items={[{ k: 'Serial', v: selMissing.serial }, { k: 'Was', v: selMissing.dev }, { k: 'Size', v: sizeTxt(selMissing.size) }, { k: 'First seen', v: dateOf(selMissing.first) }, { k: 'Last seen', v: dateOf(selMissing.lastSeen) }, { k: 'Role', v: selMissing.role }]} />
            <p class="mute pad">A missing disk can only be forgotten. If it is a pool member, replace it from its pool first.</p>
            {#snippet actions()}
              <button class="btn btn-danger" disabled={locked} use:tip={'Take this disk off the list for good'} onclick={() => openCreate(ForgetDisk, { serial: selMissing.serial, model: selMissing.model, dev: selMissing.dev })}><i class="ph ph-trash-simple"></i>Forget…</button>
            {/snippet}
          </Drawer>
        {/if}
      {/snippet}
    </Split>
  {:else}
    {#if deck?.data?.locked}<Banner tone="warn">Storage is locked: pool disks may be missing from this list until it is unlocked.</Banner>{/if}
    {#if missing.length && filter === 'all'}
      <Banner tone="warn">{missing.length} disk{missing.length === 1 ? ' is' : 's are'} missing since the last collector run.
        {#snippet action()}<button use:tip={'Show the disks that are missing'} class="btn sm" onclick={() => setFilter('missing')}>Show</button>{/snippet}
      </Banner>
    {/if}
    <Split open={!!sel}>
      {#snippet list()}
        <div class="card">
          <Table id="disks" {columns} rows={visible} key="name" compact selected={sel?.name} onrow={(d) => { selName = d.name; tab = 'info'; }}
                 empty={filter === 'none' ? 'Every disk belongs to a pool, the system or the backup.' : 'No disks here.'}>
            {#snippet cell(d, col)}
              {#if col.key === 'name'}<code>{d.name}</code>
              {:else if col.key === 'pool'}<Chip>{poolText(d)}</Chip>
              {:else if col.key === 'role'}<span class="mute">{diskPool(d.role) ? roleText(d) : ''}</span>
              {:else if col.key === 'model'}<span class="mute">{modelOf(d)}</span>
              {:else if col.key === 'size'}<span class="nw"><UsageBar free={d.free} size={d.size} width={96} /></span>
              {:else if col.key === 'fs'}<span class="nw mute">{fsText(d)}</span>
              {:else if col.key === 'smart'}<StatusDot state={stateOf(d)} label={wordOf(d)} />
              {:else if col.key === 'temp'}<span class="nw">{d.temp && d.temp !== '-' ? `${d.temp} °C` : '–'}</span>
              {:else}<span class="nw mute">{hoursTxt(d.hours)}</span>{/if}
            {/snippet}
          </Table>
        </div>
      {/snippet}
      {#snippet side()}
        {#if sel}
          {@const member = memberOf(sel)}
          <Drawer title={sel.name} chip={poolText(sel)} state={stateOf(sel)} stateLabel={wordOf(sel)} bind:tab onclose={() => (selName = '')}
                  tabs={[{ id: 'info', label: 'Overview' }, { id: 'smart', label: 'SMART' }, { id: 'tests', label: 'Tests' }]}>
            {#snippet children(t)}
              {#if t === 'info'}
                <Kv items={[
                  { k: 'Model', v: modelOf(sel) }, { k: 'Serial', v: serialOf(sel) }, { k: 'Size', v: sizeTxt(sel.size) }, { k: 'Type', v: sel.kind }, { k: 'Format', v: fsText(sel) },
                  { k: 'Pool', v: poolText(sel) }, { k: 'Role', v: diskPool(sel.role) ? roleText(sel) : sel.role },
                  { k: 'Temperature', v: sel.temp && sel.temp !== '-' ? `${sel.temp} °C` : '' }, { k: 'Power-on', v: hoursTxt(sel.hours) },
                  { k: 'Free space', v: sel.free && sel.free !== '-' ? sizeTxt(Number(sel.free)) : '' }, { k: 'First seen', v: rec?.first ? dateOf(rec.first) : '' },
                ]} />
                {#if verdicts[sel.name]?.reason && verdicts[sel.name].reason !== '-'}<p class="pad">{verdicts[sel.name].reason}</p>{/if}
                {#if markOf[member]}<div class="pad"><Banner tone="info">{markOf[member] === 'detached' ? 'This disk is out of /bulk on purpose (detached). Attach it again when you are done.' : 'Recovery is running or waiting for its finish; the disk is out of /bulk until then.'}</Banner></div>{/if}
                <div class="pad links">
                  {#if diskPool(sel.role)}<button use:tip={`Open the pool ${diskPool(sel.role)}`} class="btn sm" onclick={() => go(`/storage/pools/${diskPool(sel.role)}`)}><i class="ph ph-cylinder"></i>Pool {diskPool(sel.role)}</button>{/if}
                  <button use:tip={'Open the health page'} class="btn sm" onclick={() => go('/operations/health')}><i class="ph ph-heartbeat"></i>Health</button>
                  <button use:tip={'Open the encryption page'} class="btn sm" onclick={() => go('/storage/encryption')}><i class="ph ph-lock-key"></i>Encryption</button>
                </div>
              {:else if t === 'smart'}
                <Kv items={[{ k: 'Pending sectors', v: num(sel.pending) }, { k: 'Reallocated', v: num(sel.realloc) }, { k: 'CRC errors', v: num(sel.crc) }, { k: 'Verdict', v: verdictOf(sel) }]} />
                <div class="pad">
                  {#if readings.length > 1}
                    <div class="sh"><b>Pending sectors</b><span class="mute">{spanTxt}</span></div>
                    <svg viewBox="0 0 400 60" preserveAspectRatio="none" class="chart" style="height:56px"><polygon points="0,60 {linePts} 400,60" fill="color-mix(in oklch, var(--accent) 22%, transparent)"></polygon><polyline points={linePts} fill="none" stroke="var(--accent)" stroke-width="1.5" vector-effect="non-scaling-stroke"></polyline></svg>
                    <div class="sh" style="margin-top:14px"><b>Temperature</b><span class="mute">{spanTxt}{temps.length ? ` · now ${temps[temps.length - 1]} °C` : ''}</span></div>
                    <svg viewBox="0 0 400 40" preserveAspectRatio="none" class="chart" style="height:36px"><polyline points={tempPts} fill="none" stroke="var(--fg-3)" stroke-width="1.3" vector-effect="non-scaling-stroke"></polyline></svg>
                  {:else}
                    <div class="sh"><b>History</b></div>
                    <p class="mute">{!serial ? 'This disk is not in the inventory yet.' : hist.loaded ? 'Not enough readings yet.' : 'Loading…'}</p>
                  {/if}
                </div>
              {:else}
                <div class="pad">
                  <div class="sh"><b>Self-tests</b><span class="mute">newest first</span></div>
                  {#if running}<div class="trow"><span class="tk">now</span><span class="grow">{running.replace(/^A test is running:\s*/i, '')}</span><StatusDot state="info" label="running" /></div>{/if}
                  {#each tests as x}
                    <div class="trow"><span class="tk">{x.kind}</span><span class="grow">{x.when}</span><StatusDot state={/^Completed without error/i.test(x.result) ? 'ok' : 'warn'} label={x.result} /></div>
                  {:else}
                    {#if !running}<p class="mute">{results.loaded ? 'No self-tests on record.' : 'Loading…'}</p>{/if}
                  {/each}
                </div>
              {/if}
            {/snippet}
            {#snippet actions()}
              <button class="btn sm" disabled={!!running} use:tip={running ? 'A test is running in this disk' : 'About two minutes; shows the plan first'} onclick={() => runTest('short')}><i class="ph ph-pulse"></i>Short test</button>
              <button class="btn sm" disabled={!!running} use:tip={running ? 'A test is running in this disk' : 'Reads the whole surface (hours); shows the plan first'} onclick={() => runTest('long')}><i class="ph ph-pulse"></i>Long test</button>
              {#if isLoose(sel)}
                <button class="btn sm btn-primary" disabled={locked} use:tip={lockTip('Pick this disk and see the plan')} onclick={() => addToPool(poolForNew)}><i class="ph ph-plus"></i>Add to a pool…</button>
                <button class="btn sm" disabled={locked} use:tip={lockTip('Mount it read-only, copy from it, eject it')} onclick={() => openCreate(OtherDisk, {})}><i class="ph ph-usb"></i>Mount read-only…</button>
                <button class="btn sm btn-danger" disabled={locked} use:tip={lockTip('Erase this disk so it can be added to a pool')} onclick={() => openCreate(WipeDisk, { disk: sel.name, model: modelOf(sel), size: sel.size })}><i class="ph ph-eraser"></i>Format…</button>
              {/if}
              {#if snapRole(sel) && /data/.test(sel.role) && member}
                <button class="btn sm" disabled={locked} use:tip={'Take this disk out of /bulk to work on it (or put it back)'} onclick={() => openCreate(DetachDisk, { pool: 'bulk', member })}><i class="ph ph-plugs"></i>{markOf[member] === 'detached' ? 'Attach…' : 'Detach…'}</button>
                <button class="btn sm" disabled={locked} use:tip={'Look at the files of this disk, next to another disk'} onclick={() => go(filesLink({ left: `disk:${member}`, right: otherDisk(member) }))}><i class="ph ph-folder-open"></i>Browse files</button>
                <button class="btn sm" disabled={locked} use:tip={'Move files to another data disk in the file manager; their path stays'} onclick={() => go(filesLink({ left: `disk:${member}`, path: '/shares', right: otherDisk(member), rpath: '/shares' }))}><i class="ph ph-arrows-left-right"></i>Move files…</button>
                <button class="btn sm" disabled={locked} use:tip={'Get deleted files back from this disk'} onclick={() => openCreate(RecoverDisk, { pool: 'bulk', member, members: dataMembers('bulk') })}><i class="ph ph-first-aid-kit"></i>Recover…</button>
              {/if}
            {/snippet}
          </Drawer>
        {/if}
      {/snippet}
    </Split>
  {/if}
</PageState>

<style>
  .tabs { margin-bottom: 14px; max-width: 100%; overflow-x: auto; }
  .cnt { font: 500 10.5px var(--mono); color: var(--fg-3); }
  .card { padding: 4px 8px; overflow-x: auto; }
  .pad { padding: 12px 16px; margin: 0; }
  .mute { color: var(--fg-3); font-size: 12px; }
  .nw { white-space: nowrap; }
  code { font-size: 12px; }
  .links { display: flex; flex-wrap: wrap; gap: 8px; }
  .sh { display: flex; align-items: baseline; gap: 8px; margin-bottom: 6px; }
  .chart { width: 100%; display: block; }
  .trow { display: flex; align-items: center; gap: 10px; padding: 7px 0; border-bottom: 1px solid var(--line); }
  .tk { width: 50px; color: var(--fg-3); font: 12px var(--mono); }
</style>
