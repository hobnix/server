<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // The node's home: "is it fine, and what needs me?". A node card with the Halftone, the meters, one line per fact that
  // opens the page that OWNS it, one UsageBar per pool, and two shortcuts that open plans (Back up now, Update). No tables of disks, shares or problems.
  // Storage locked: the unlock form replaces the pool bars (the shell's lock banner is the same component).
  import UsageBar from '../shell/UsageBar.svelte';
  import { untrack } from 'svelte';
  import { poll, rows } from '../data.svelte.js';
  import { live } from '../live.svelte.js';
  import { go } from '../route.svelte.js';
  import { openPlan, ui } from '../ui.svelte.js';
  import { pct, duration } from '../format.js';
  import Spark from '../shell/Spark.svelte';
  import Halftone from '../shell/Halftone.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import UnlockForm from '../forms/unlock/UnlockForm.svelte';
  import Banner from '../ui/Banner.svelte';
  import StatusDot from '../ui/StatusDot.svelte';

  let { deck } = $props();    // the shared status document (Shell polls it)

  const status = poll('/api/sys/status', 15000, 'status');
  const ups = poll('/api/sys/ups/status', 20000);
  const setup = poll('/api/sys/setup/list', 30000);
  const updates = poll(() => (deck.data?.locked ? '' : '/api/sys/system/updates'), 60000);
  const setupRows = $derived(rows(setup));
  const setupOpen = $derived(setupRows.length > 0 && setupRows.some((r) => r[0] === 'finished' && r[1] !== 'done') ? setupRows.filter((r) => r[0] !== 'finished' && r[1] === 'open').length : 0);
  const behind = $derived(Number(rows(updates).find((r) => r[0] === 'behind')?.[1]) || 0);

  const d = $derived(deck.data);
  const locked = $derived(!!d?.locked);

  // --- CPU and memory: the document holds counters, so the load is the difference between two readings
  let prev = null;
  let cpu = $state(null);
  let cpuHist = $state([]);
  let memHist = $state([]);
  let gpuHist = $state([]);
  let upsHist = $state([]);
  $effect(() => {
    const x = deck.data;
    if (!x || !x.cpu || (prev && prev.time === x.time)) return;
    if (prev?.cpu) {
      const dt = x.cpu.total - prev.cpu.total, di = x.cpu.idle - prev.cpu.idle;
      if (dt > 0) {
        cpu = Math.max(0, Math.min(100, (1 - di / dt) * 100));
        cpuHist = [...cpuHist, cpu].slice(-40);
      }
    }
    if (x.mem) memHist = [...memHist, (1 - x.mem.available / x.mem.total) * 100].slice(-40);
    if (x.gpu && x.gpu.util != null) gpuHist = [...gpuHist, Number(x.gpu.util)].slice(-40);
    prev = x;
  });
  const memUsed = $derived(d?.mem ? d.mem.total - d.mem.available : null);

  // --- UPS
  const upsMap = $derived(Object.fromEntries(rows(ups).map((r) => [r[0], r[1]])));
  const upsConfigured = $derived(upsMap.configured === 'yes' && upsMap.reachable === 'yes');
  // one reading per answer; the history is read untracked, otherwise appending to it would re-run this effect forever
  $effect(() => {
    ups.data;
    const c = Number(upsMap.charge);
    if (upsConfigured && upsMap.charge && !isNaN(c)) untrack(() => { upsHist = [...upsHist, c].slice(-40); });
  });

  // the four meters (the node card); the UPS meter opens Hardware, the owner of the sensors
  const meters = $derived([
    { icon: 'ph-cpu', label: 'CPU', sub: '', value: cpu == null ? '–' : `${pct(cpu)} %`, of: d?.load ? `load ${d.load[0]}` : '', hist: cpuHist, to: '/monitoring/hardware' },
    { icon: 'ph-memory', label: 'Memory', sub: '', value: memUsed == null ? '–' : (memUsed / 1073741824).toFixed(1), of: d?.mem ? `/ ${(d.mem.total / 1073741824).toFixed(0)} GiB` : '', hist: memHist, to: '/monitoring/hardware' },
    d?.gpu
      ? { icon: 'ph-graphics-card', label: 'GPU', sub: `${d.gpu.name}${d.gpu.temp != null ? ` · ${d.gpu.temp} °C` : ''}`, value: `${pct(d.gpu.util)} %`, of: `VRAM ${(d.gpu.mem_used / 1e9).toFixed(1)} / ${(d.gpu.mem_total / 1e9).toFixed(0)} GB`, hist: gpuHist, to: '/monitoring/hardware' }
      : { icon: 'ph-graphics-card', label: 'GPU', sub: '', value: '–', of: 'No graphics card found', hist: [], to: '/monitoring/hardware' },
    upsConfigured
      ? { icon: 'ph-battery-charging', label: 'UPS', sub: upsMap.state || '', value: upsMap.charge ? `${upsMap.charge} %` : '–', of: [upsMap.load ? `load ${upsMap.load} %` : '', upsMap.runtime ? `${Math.round(Number(upsMap.runtime) / 60)} min` : ''].filter(Boolean).join(' · '), hist: upsHist, to: '/monitoring/hardware' }
      : { icon: 'ph-battery-charging', label: 'UPS', sub: '', value: '–', of: upsMap.configured === 'yes' ? 'Not reachable' : 'Not set up (ups in machine.toml)', hist: [], to: '/monitoring/hardware' },
  ]);

  // --- one UsageBar per pool (the numbers are in the status document)
  const pools = $derived(['bulk', 'fast'].map((n) => ({ name: n, ...(d?.pools?.[n] ?? {}) })).filter((p) => p.size > 0));

  // --- one line per fact: icon, label, value, a note, the dot, and the page that owns it (a click opens it)
  const OWNER = { Backup: '/protection/backup', Encryption: '/storage/encryption', Instances: '/instances', 'Upload cache': '/storage/bulk', 'Parity sync': '/storage/bulk', Scrub: '/storage/bulk', 'Disk health': '/storage/bulk/disks', 'Hottest disk': '/monitoring/hardware' };
  const facts = $derived.by(() => {
    const m = {};
    const jobs = [];
    for (const r of rows(status)) { if (r[0] === 'job') jobs.push(r.slice(1)); else m[r[0]] ??= r.slice(1); }
    const out = [];
    const problems = d?.problems ?? 0;
    out.push({ icon: 'ph-heartbeat', k: 'Health', t: problems ? `${problems} problem${problems === 1 ? '' : 's'}` : 'no problems', meta: '', dot: problems ? 'warn' : 'ok', to: '/operations/health' });
    if (m.backup) {
      const [st, age] = m.backup;
      const h = Number(age) / 3600;
      const short = isNaN(h) ? '' : h < 1 ? 'less than 1 h ago' : h < 48 ? `${Math.floor(h)} h ago` : `${Math.floor(h / 24)} d ago`;
      out.push(st === 'ok' ? { icon: 'ph-cloud-check', k: 'Backup', t: 'ok', meta: short, dot: 'ok' }
        : st === 'failed' ? { icon: 'ph-cloud-warning', k: 'Backup', t: 'the last backup failed', meta: '', dot: 'bad' }
        : { icon: 'ph-cloud', k: 'Backup', t: 'no backup yet', meta: '', dot: 'warn' });
    }
    if (behind > 0) out.push({ icon: 'ph-arrow-circle-up', k: 'Updates', t: `${behind} new change${behind === 1 ? '' : 's'} upstream`, meta: '', dot: 'info', plan: ['system', ['update'], 'Update'] });
    if (m.encryption) {
      const e = m.encryption[0];
      out.push({ icon: e === 'locked' ? 'ph-lock' : 'ph-lock-open', k: 'Encryption', t: { open: 'open', locked: 'locked', none: 'not encrypted' }[e] ?? e, meta: '', dot: e === 'locked' ? 'warn' : 'ok' });
    }
    if (m.instances) out.push({ icon: 'ph-cube', k: 'Instances', t: locked ? `${m.instances[0]} of ${m.instances[1]}` : `${m.instances[0]} of ${m.instances[1]} running`, meta: '', dot: m.instances[0] === m.instances[1] ? 'ok' : 'warn' });
    if (m.cache) {
      const used = (m.cache[0] || '').replace(/\s*\(.*$/, '');
      out.push({ icon: 'ph-tray-arrow-down', k: 'Upload cache', t: m.cache[1] ? `${m.cache[1]} % used` : m.cache[0], meta: m.cache[1] ? used : '', dot: 'ok' });
    }
    for (const [unit, res, last, next] of jobs) {
      const sync = /sync/.test(unit);
      out.push({ icon: sync ? 'ph-arrows-clockwise' : 'ph-broom', k: sync ? 'Parity sync' : /scrub/.test(unit) ? 'Scrub' : unit, t: res === 'noparity' ? 'no parity disk' : res === 'never' ? 'has not run yet' : res === 'ok' ? 'ok' : 'failed', meta: res === 'never' || res === 'noparity' ? '' : `last ${last}${next && next !== '-' ? ` · next ${next}` : ''}`, dot: res === 'ok' ? 'ok' : res === 'failed' ? 'bad' : res === 'noparity' ? 'warn' : 'off' });
    }
    if (m.smart) out.push({ icon: 'ph-heartbeat', k: 'Disk health', t: m.smart[1] ? m.smart[1] : 'all fine', meta: `${m.smart[0]} disks`, dot: m.smart[1] ? 'warn' : 'ok' });
    if (m.hottest) out.push({ icon: 'ph-thermometer', k: 'Hottest disk', t: m.hottest[0], meta: `${m.hottest[1]} °C`, dot: Number(m.hottest[1]) >= 55 ? 'warn' : 'ok' });
    if (m.event) out.push({ icon: 'ph-plug', k: 'Last event', t: m.event[1], meta: m.event[0], dot: 'off', to: '/operations/health' });
    return out.map((f) => ({ to: OWNER[f.k] ?? null, ...f }));
  });

  const bootedAgo = $derived(d?.uptime_s != null ? duration(d.uptime_s) : '');
  const hostName = $derived(d?.host ?? 'homeserver');
  const open = (f) => (f.plan ? openPlan(...f.plan) : f.to ? go(f.to) : null);
</script>

<div class="page">
  <PageHeader title="Summary" crumb={hostName} sub="What needs you on {hostName} right now.">
    {#snippet actions()}
      <button use:tip={locked ? 'Storage is locked' : 'Back up everything now'} class="btn btn-secondary" disabled={locked} onclick={() => openPlan('backup', ['now'], 'Back up now')}><i class="ph ph-archive"></i>Back up now</button>
      <button use:tip={locked ? 'Storage is locked' : 'Update the server (snapshots first; shows the plan)'} class="btn btn-primary" disabled={locked} onclick={() => openPlan('system', ['update'], 'Update')}><i class="ph ph-arrow-circle-up"></i>Update…</button>
    {/snippet}
  </PageHeader>

  {#if !locked && setupOpen}
    <Banner tone="warn" icon="list-checks">Finish the setup: {setupOpen} item{setupOpen === 1 ? '' : 's'} still open.
      {#snippet action()}<button use:tip={'Open the first-run checklist'} class="btn sm" onclick={() => go('/setup')}>Open Setup<i class="ph ph-arrow-right"></i></button>{/snippet}
    </Banner>
  {/if}
  {#if ui.features.live && !live.open}
    <Banner tone="info" icon="pause-circle">Live updates paused. The page reads every few seconds until they are back.</Banner>
  {/if}
  {#if status.error?.status === 503 && !status.data}
    <Banner tone="warn">{status.error.retryAfter ? 'The server is refreshing its state. This page updates in a moment.' : 'The state service is down. Other pages still work.'}</Banner>
  {/if}
  {#if deck.error && !d}
    <Banner tone="bad">This server does not answer.</Banner>
  {/if}

  <div class="node xh">
    <Halftone cell={4} focus={[1, 0]} reach={0.8} opacity={0.85} />
    <div class="nhead">
      <div class="tile"><i class="ph ph-hard-drives"></i></div>
      <div class="nname">
        <div class="row"><span class="name">{hostName}</span><StatusDot state={d ? (locked ? 'warn' : 'ok') : 'off'} label={d ? (locked ? 'storage locked' : 'online') : deck.error ? 'not reachable' : 'loading'} /></div>
        <div class="muted">{d ? `${locked ? 'booted' : 'up'} ${bootedAgo}${d.load ? ` · load ${d.load.join(' ')}` : ''}${d.encryption && d.encryption !== 'none' ? ` · encryption ${d.encryption}` : ''}` : ''}</div>
      </div>
    </div>
    <div class="meters">
      {#each meters as m}
        <button class="meter" onclick={() => go(m.to)} use:tip={'Open Hardware'}>
          <span class="mrow"><i class="ph {m.icon}"></i>{m.label}<span class="msub">{m.sub}</span></span>
          <span class="mval"><span class="big">{m.value}</span><span class="of">{m.of}</span></span>
          {#if !locked}<Spark values={m.hist} />{/if}
        </button>
      {/each}
    </div>
  </div>

  <div class="two">
    {#if locked}
      <div class="card unlock">
        <div class="ttl"><i class="ph ph-lock"></i>Storage is locked</div>
        <p class="lead">The encrypted disks stay closed until the passphrase is entered. Until then the Incus instances, ZFS pools, Samba shares, the domain controller and the bulk timers are down, and Update and rebuild are refused.</p>
        <UnlockForm />
      </div>
    {:else}
      <div class="card">
        <div class="ctitle">Pools</div>
        {#each pools as p}
          <button class="prow" onclick={() => go(`/storage/${p.name}`)}>
            <span class="pn"><i class="ph {p.name === 'bulk' ? 'ph-cylinder' : 'ph-lightning'}"></i>{p.name}</span>
            <StatusDot state={p.health && p.health !== 'ONLINE' ? 'warn' : 'ok'} label={p.health && p.health !== 'ONLINE' ? p.health.toLowerCase() : 'online'} />
            <UsageBar used={p.used} size={p.size} width={180} />
          </button>
        {:else}
          <div class="muted">{d ? 'No pool yet.' : 'Loading…'}</div>
        {/each}
      </div>
    {/if}

    <div class="card">
      <div class="ctitle">Status</div>
      {#each facts as f}
        {#if f.to || f.plan}
          <button class="srow link" onclick={() => open(f)}><i class="ph {f.icon}"></i><span class="sk">{f.k}</span><span class="sv">{f.t}</span><span class="sm">{f.meta}</span><StatusDot state={f.dot} bare label={f.t} /><i class="ph ph-caret-right go"></i></button>
        {:else}
          <div class="srow"><i class="ph {f.icon}"></i><span class="sk">{f.k}</span><span class="sv">{f.t}</span><span class="sm">{f.meta}</span><StatusDot state={f.dot} bare label={f.t} /><i class="ph ph-caret-right go hid"></i></div>
        {/if}
      {:else}
        <div class="muted">{status.loaded ? 'No status available.' : 'Loading…'}</div>
      {/each}
    </div>
  </div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .node { position: relative; overflow: hidden; display: flex; flex-direction: column; gap: 16px; padding: 16px 18px; border: 1px solid var(--line); background: var(--panel); }
  .node > :global(*:not(.ht)) { position: relative; z-index: 1; }
  .node > :global(.ht) { z-index: 0; }
  .nhead { display: flex; align-items: center; gap: 12px; }
  .tile { width: 38px; height: 38px; display: grid; place-items: center; font-size: 20px; color: var(--accent); border: 1px solid var(--line); background: var(--panel-2); flex: none; }
  .row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .name { font-size: 20px; font-weight: 600; letter-spacing: -0.02em; }
  .muted { font-size: 12px; color: var(--fg-3); }
  .meters { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; }
  .meter { all: unset; box-sizing: border-box; cursor: pointer; display: flex; flex-direction: column; gap: 8px; padding: 12px 14px; border: 1px solid var(--line); background: color-mix(in oklch, var(--panel) 88%, transparent); }
  .meter:hover { border-color: var(--line-2, var(--fg-3)); }
  .meter:focus-visible, .prow:focus-visible, .srow:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
  .mrow { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--fg-2); }
  .msub { margin-left: auto; font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--fg-3); }
  .mval { display: flex; align-items: baseline; gap: 6px; }
  .big { font-size: 24px; font-weight: 500; white-space: nowrap; }
  .of { font-size: 12px; color: var(--fg-3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .two { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(420px, 100%), 1fr)); gap: 14px; align-items: start; }
  .ctitle { font-size: 14px; font-weight: 600; margin-bottom: 4px; }
  .prow { all: unset; box-sizing: border-box; cursor: pointer; display: flex; align-items: center; gap: 14px; flex-wrap: wrap; padding: 10px 6px; border-bottom: 1px solid var(--line); }
  .prow:hover, .srow.link:hover { background: var(--panel-2); }
  .pn { display: flex; align-items: center; gap: 8px; font-weight: 500; width: 84px; }
  .pn i { color: var(--fg-3); }
  .srow { all: unset; box-sizing: border-box; display: flex; align-items: center; gap: 10px; padding: 8px 6px; border-bottom: 1px solid var(--line); width: 100%; }
  .srow.link { cursor: pointer; }
  .srow > i:first-child { font-size: 16px; color: var(--fg-3); }
  .sk { width: 96px; flex: none; color: var(--fg-2); }
  .sv { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sm { font-size: 11px; color: var(--fg-3); white-space: nowrap; }
  .go { font-size: 11px; color: var(--fg-3); }
  .go.hid { visibility: hidden; }
  .unlock { gap: 12px; }
  .ttl { display: flex; align-items: center; gap: 10px; font-size: 16px; font-weight: 600; }
  .ttl i { font-size: 20px; color: var(--warn); }
  .lead { margin: 0; color: var(--fg-2); max-width: 560px; }
</style>
