<script>
  import PageHeader from '../shell/PageHeader.svelte';
  import { poll, rows } from '../data.svelte.js';
  import { bytes, pct, duration } from '../format.js';
  import { openPlan } from '../ui.svelte.js';

  let { deck } = $props();
  const ups = poll('/api/sys/ups/status', 20000);
  const disks = poll('/api/sys/monitor/disks', 30000);
  const config = poll('/api/sys/system/config', 60000);
  const hw = poll('/api/sys/hardware', 20000);

  const d = $derived(deck?.data);
  // the document holds counters: the load is the difference between two readings
  let prev = null;
  let cpu = $state(null);
  $effect(() => {
    const x = deck?.data;
    if (!x || !x.cpu || (prev && prev.time === x.time)) return;
    if (prev?.cpu) {
      const dt = x.cpu.total - prev.cpu.total, di = x.cpu.idle - prev.cpu.idle;
      if (dt > 0) cpu = Math.max(0, Math.min(100, (1 - di / dt) * 100));
    }
    prev = x;
  });
  const memUsed = $derived(d?.mem ? d.mem.total - d.mem.available : null);
  const memPct = $derived(d?.mem ? (memUsed / d.mem.total) * 100 : null);

  const u = $derived(Object.fromEntries(rows(ups).map((r) => [r[0], r[1]])));
  const upsOk = $derived(u.configured === 'yes' && u.reachable === 'yes');
  const upsState = $derived({ online: 'online · on mains', battery: 'on battery', low: 'battery low' }[u.state] ?? u.state ?? '');

  // `sys system config` is a plain table: a header, then setting and value split by two or more spaces
  const cfg = $derived.by(() => {
    const m = {};
    for (const line of (config.data?.text ?? '').split('\n').slice(1)) {
      const p = line.trim().split(/\s{2,}|\t/);
      if (p.length >= 2) m[p[0]] = p.slice(1).join(' ');
    }
    return m;
  });

  // `sys hardware`: cpu-model / cpu-cores / cpu-threads <value>, temp <name> <deg C>, fan <name> <rpm>
  const hwRows = $derived(rows(hw));
  const one = (k) => hwRows.find((r) => r[0] === k)?.[1];
  const cpuModel = $derived(one('cpu-model'));
  const cpuCores = $derived(one('cpu-cores'));
  const cpuThreads = $derived(one('cpu-threads'));
  const boardTemps = $derived(hwRows.filter((r) => r[0] === 'temp').map((r) => ({ name: r[1], t: Number(r[2]), max: /^CPU/.test(r[1]) ? 100 : 80 })));
  const cpuTemp = $derived(boardTemps.find((t) => t.name === 'CPU package') ?? boardTemps.find((t) => t.name === 'CPU') ?? boardTemps.find((t) => /^CPU/.test(t.name)));
  const fans = $derived(hwRows.filter((r) => r[0] === 'fan').map((r) => ({ name: r[1], rpm: Number(r[2]) })));
  const spinning = $derived(fans.filter((f) => f.rpm > 0));

  const gb = (n) => (n == null ? '–' : `${String(Number((n / 1e9).toFixed(n >= 1e11 ? 0 : 1)))} GB`);
  // the bar of a temperature is scaled to a typical limit of its kind (SSD 70, HDD 60, graphics card 90 degrees); warn above 80 % of it
  const temps = $derived([
    ...rows(disks).filter((r) => r[4] && r[4] !== '-' && !isNaN(r[4])).map((r) => ({ name: r[0], t: Number(r[4]), max: r[2] === 'HDD' ? 60 : 70 })),
    ...(d?.gpu?.temp != null ? [{ name: 'GPU', t: d.gpu.temp, max: 90 }] : []),
    ...boardTemps,
  ].sort((a, b) => b.t - a.t));
</script>

<div class="page">
  <PageHeader title="Hardware" crumb="Monitoring" sub="Sensors, fans and the UPS of this server.">
    {#snippet actions()}<button class="btn btn-secondary" title="Run the fans at full speed for a few seconds to blow dust out of the case" onclick={() => openPlan('admin', ['fans-clean'], 'Clean the fans')}><i class="ph ph-fan"></i>Clean fans</button>{/snippet}
  </PageHeader>

  <div class="grid">
    <div class="card elev-sm c">
      <div class="ch"><i class="ph ph-cpu"></i><span class="ct">CPU</span></div>
      <div class="big"><span>{cpu != null ? `${pct(cpu)} %` : '–'}</span><span class="of">{d?.load ? `load ${d.load.join(' · ')}` : deck?.loaded ? 'not available' : 'Loading…'}</span></div>
      <div class="bar"><div style="width:{cpu ?? 0}%"></div></div>
      {#if cpuModel}<div class="model">{cpuModel}</div>{/if}
      {#if cpuCores}<div class="row"><span class="rl">Cores</span><span class="rv">{cpuCores}{cpuThreads && cpuThreads !== cpuCores ? ` · ${cpuThreads} threads` : ''}</span></div>{/if}
      {#if cpuTemp}<div class="row"><span class="rl">Temperature</span><span class="rv">{cpuTemp.t} °C</span></div>{/if}
      {#if !cpuModel && hw.loaded}<div class="note">{hw.error ? 'The processor details could not be read.' : 'This machine reports no processor details.'}</div>{/if}
    </div>

    <div class="card elev-sm c">
      <div class="ch"><i class="ph ph-memory"></i><span class="ct">Memory</span></div>
      {#if d?.mem}
        <div class="model">{gb(d.mem.total)}</div>
        <div class="big"><span>{bytes(memUsed)}</span><span class="of">in use · {bytes(d.mem.available)} available</span></div>
        <div class="bar"><div style="width:{memPct}%"></div></div>
        {#if cfg.zfsArcMaxGB}<div class="row"><span class="rl">ZFS ARC</span><span class="rv">{cfg.zfsArcMaxGB} GB (limit zfsArcMaxGB)</span></div>{/if}
      {:else}
        <div class="big"><span>–</span><span class="of">{deck?.loaded ? 'not available' : 'Loading…'}</span></div>
      {/if}
    </div>

    <div class="card elev-sm c">
      <div class="ch"><i class="ph ph-graphics-card"></i><span class="ct">GPU</span>{#if cfg.gpu}<span class="tag tag-neutral" style="padding:1px 7px;margin-left:auto">gpu = {cfg.gpu}</span>{/if}</div>
      {#if d?.gpu}
        <div class="model">NVIDIA {d.gpu.name}</div>
        <div class="row"><span class="rl">Utilisation</span><span class="rv">{pct(d.gpu.util)} %</span></div>
        <div class="row"><span class="rl">VRAM</span><span class="rv">{gb(d.gpu.mem_used)} of {gb(d.gpu.mem_total)}</span></div>
        <div class="row"><span class="rl">Temperature</span><span class="rv">{d.gpu.temp} °C</span></div>
        <div class="note">The integrated GPU drives the monitor; the RTX is passed to containers.</div>
      {:else}
        <div class="note">{deck?.loaded ? 'No graphics card found.' : 'Loading…'}</div>
      {/if}
    </div>

    <div class="card elev-sm c">
      <div class="ch"><i class="ph ph-battery-charging"></i><span class="ct">UPS</span>{#if u.configured === 'yes'}<span class="tag tag-neutral" style="padding:1px 7px;margin-left:auto">ups = on</span>{/if}</div>
      {#if upsOk}
        {#if u.model}<div class="model">{u.model}</div>{/if}
        <div class="big"><span>{u.charge ?? '–'} %</span><span class="of">{upsState}</span></div>
        <div class="bar"><div style="width:{Number(u.charge) || 0}%"></div></div>
        {#if u.runtime && !isNaN(u.runtime)}<div class="row"><span class="rl">Runtime</span><span class="rv">{duration(Number(u.runtime))} at current load</span></div>{/if}
        {#if u.load}<div class="row"><span class="rl">Load</span><span class="rv">{u.load} %</span></div>{/if}
        {#if u.replace === 'yes'}<div class="row"><span class="rl">Battery</span><span class="rv">replace the battery</span></div>{/if}
      {:else}
        <div class="note">{!ups.loaded ? 'Loading…' : u.configured === 'yes' ? 'The UPS cannot be reached.' : 'No UPS set up (ups in machine.toml).'}</div>
      {/if}
    </div>

    <div class="card elev-sm c" style="gap:8px">
      <div class="ch"><i class="ph ph-thermometer"></i><span class="ct">Temperatures</span></div>
      {#each temps as t}
        <div class="trow">
          <span style="color:var(--color-neutral-300)">{t.name}</span>
          <div class="bar b5"><div style="width:{Math.min(100, Math.round((t.t / t.max) * 100))}%;background:{t.t / t.max > 0.8 ? 'var(--st-warn)' : 'var(--color-accent-500)'}"></div></div>
          <span style="text-align:right">{t.t} °C</span>
        </div>
      {:else}
        <div class="note">{disks.loaded ? 'No temperatures available.' : 'Loading…'}</div>
      {/each}
      {#if !temps.some((t) => /^CPU/.test(t.name)) && hw.loaded}<div class="note">No CPU or mainboard temperature sensor is reported (driver not loaded or a virtual machine).</div>{/if}
    </div>

    <div class="card elev-sm c" style="gap:8px">
      <div class="ch"><i class="ph ph-fan"></i><span class="ct">Fans</span>{#if fans.length}<span class="tag tag-neutral" style="padding:1px 7px;margin-left:auto">{spinning.length} of {fans.length} spinning</span>{/if}</div>
      {#each spinning as f}
        <div class="row"><span class="rl" style="width:150px">{f.name}</span><span class="rv">{f.rpm} rpm</span></div>
      {:else}
        <div class="note">{!hw.loaded ? 'Loading…' : fans.length ? 'No fan reports a speed.' : 'No fan sensor found (the fan controller driver of the board is not loaded).'}</div>
      {/each}
      {#if fans.length > spinning.length && spinning.length}<div class="note">{fans.length - spinning.length} more fan header{fans.length - spinning.length === 1 ? '' : 's'} report no speed (nothing plugged in).</div>{/if}
      <div class="note">To blow dust out of the case run <code>hs fans clean</code> on the server. A cleaning reminder is not built.</div>
    </div>
  </div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .head { display: flex; align-items: center; gap: 12px; }
  .crumb { font-size: 11px; color: var(--color-neutral-500); }
  .title { font-size: 20px; font-weight: 500; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(320px, 100%), 1fr)); gap: 14px; align-items: stretch; }
  .c { padding: 14px 16px; gap: 10px; }
  .ch { display: flex; align-items: center; gap: 8px; }
  .ch i { color: var(--color-accent); }
  .ct { font-size: 14px; font-weight: 500; }
  .model { font-size: 16px; font-weight: 500; }
  .big { display: flex; align-items: baseline; gap: 8px; }
  .big > span:first-child { font-size: 28px; font-weight: 500; }
  .of { color: var(--color-neutral-400); }
  .bar { height: 6px; border-radius: var(--r); background: var(--color-neutral-800); }
  .bar > div { height: 6px; border-radius: var(--r); background: var(--color-accent-500); }
  .bar.b5, .bar.b5 > div { height: 5px; }
  .row { display: flex; gap: 10px; padding: 4px 0; box-shadow: inset 0 -1px 0 color-mix(in srgb, var(--color-text) 6%, transparent); }
  .rl { width: 110px; color: var(--color-neutral-400); }
  .rv { flex: 1; }
  .trow { display: grid; grid-template-columns: 90px minmax(0, 1fr) 48px; gap: 10px; align-items: center; }
  .note { font-size: 11.5px; color: var(--color-neutral-500); }
</style>
