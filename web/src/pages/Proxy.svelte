<script>
  // proxyserver summary (design screen 19): what the VPS's status document holds today; the rest of the design's cards say "not available yet".
  import { bytes, pct } from '../format.js';
  import Spark from '../shell/Spark.svelte';
  import { route, go } from '../route.svelte.js';
  import { tick } from 'svelte';
  import { useProxy, KNOWN, brief } from './proxy/proxy.svelte.js';
  import { mail, watcher, ports, certificate } from './proxy/status.js';
  import ProxyHead from './proxy/ProxyHead.svelte';
  import ProxyGate from './proxy/ProxyGate.svelte';
  import NotYet from './proxy/NotYet.svelte';

  const px = useProxy();
  const d = $derived(px.doc);

  const memUsed = $derived(d?.mem ? d.mem.total - d.mem.available : null);
  const memPct = $derived(d?.mem ? (memUsed / d.mem.total) * 100 : 0);
  const sys = $derived(d?.pools?.system);
  const sysPct = $derived(sys?.size ? (sys.used / sys.size) * 100 : 0);
  const ts = $derived(d?.tailscale);
  const tsOk = $derived(ts === 'Running');
  // the 24 h history draws the line; the live readings (two counters apart) take over once there are enough
  const cpuHist = $derived(px.cpuLive.length >= 2 ? px.cpuLive : px.hours('cpu'));
  const memHist = $derived(px.hours('mem'));

  const meters = $derived([
    { icon: 'ph-cpu', label: 'CPU', value: px.cpu == null ? '–' : `${pct(px.cpu)} %`, of: d?.load ? `load ${d.load[0]}` : '', pct: px.cpu ?? 0, hist: cpuHist },
    { icon: 'ph-memory', label: 'Memory', value: memUsed == null ? '–' : (memUsed / 1073741824).toFixed(1), of: d?.mem ? `/ ${(d.mem.total / 1073741824).toFixed(d.mem.total < 1.5e10 ? 1 : 0)} GiB` : 'not available', pct: memPct, hist: memHist },
    { icon: 'ph-hard-drive', label: 'System disk', value: sys?.size ? `${Math.round(sysPct)} %` : '–', of: sys?.size ? `${bytes(sys.used)} / ${bytes(sys.size)}` : 'not available', pct: sysPct, hist: [] },
    { icon: 'ph-plugs-connected', label: 'Tailscale', value: ts ?? '–', of: d?.net_tailscale ? `↓ ${bytes(d.net_tailscale.rx_bytes)} ↑ ${bytes(d.net_tailscale.tx_bytes)}` : '', pct: tsOk ? 100 : 0, hist: [] },
  ]);

  const mailS = $derived(mail(d));
  const watchS = $derived(watcher(d));
  const portS = $derived(ports(d));
  const certS = $derived(certificate(d));
  const queue = $derived(mailS.queue);
  const rev = $derived(d?.revision && typeof d.revision === 'object' ? d.revision : null);
  const when = (t) => (t ? new Date(t * 1000).toLocaleString() : '–');
  const age = (s) => (s == null ? '–' : s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : s < 172800 ? `${Math.round(s / 3600)} h` : `${Math.round(s / 86400)} d`);

  // the tree rows /mail, /watcher, /certificate of the node open this page scrolled to their card (and mark it)
  const SECTION = { '/mail': 'mail', '/watcher': 'watcher', '/certificate': 'certificate' };
  const focus = $derived(SECTION[route.path] ?? '');
  $effect(() => {
    const id = focus;
    px.state;                                   // the cards appear once the document is there
    if (id) tick().then(() => document.getElementById(`px-${id}`)?.scrollIntoView({ block: 'start', behavior: 'smooth' }));
    else document.querySelector('main')?.scrollTo({ top: 0 });
  });
  const failed = $derived(d?.failed_units);
  const dotOf = (ok) => (ok == null ? 'off' : ok ? 'ok' : 'warn');
  const svc = $derived([
    { label: 'Failed units', value: failed == null ? 'not available' : failed === 0 ? 'none' : String(failed), dot: dotOf(failed == null ? null : failed === 0) },
    { label: 'Tailscale', value: ts ?? 'not available', dot: dotOf(ts == null ? null : tsOk) },
    { label: 'Problems', value: d?.problems == null ? 'not available' : d.problems === 0 ? 'none' : String(d.problems), dot: dotOf(d?.problems == null ? null : d.problems === 0) },
    ...(d?.net ? [{ label: `Public network (${d.net.iface})`, value: `↓ ${bytes(d.net.rx_bytes)} · ↑ ${bytes(d.net.tx_bytes)}`, dot: 'off', meta: 'since boot' }] : []),
  ]);
  // keys a later VPS version may add: shown as they are
  const extra = $derived(d ? Object.entries(d).filter(([k, v]) => !KNOWN.includes(k) && v != null) : []);
</script>

<div class="page">
  <ProxyHead {px} summary />
  <ProxyGate {px}>
    <div class="meters">
      {#each meters as m}
        <div class="card elev-sm meter">
          <div class="mrow"><i class="ph {m.icon}"></i>{m.label}</div>
          <div class="mval"><span class="big">{m.value}</span><span class="of">{m.of}</span></div>
          <div class="bar"><div style="width:{m.pct}%"></div></div>
          {#if m.label === 'CPU' || m.label === 'Memory'}<Spark values={m.hist} />{/if}
        </div>
      {/each}
    </div>

    <div class="two">
      <div class="col">
        <div class="card elev-sm c" class:focus={focus === 'mail'} id="px-mail">
          <div class="ch"><i class="ph ph-envelope-simple"></i><span class="ct">Mail entry</span><span class="dot {mailS.dot}" title={mailS.title}></span></div>
          <div class="qrow"><span class="q">{queue ?? '–'}</span><span class="of">{queue == null ? 'not available' : queue === 0 ? 'queue empty' : queue === 1 ? 'message held in the queue' : 'messages held in the queue'}</span></div>
          {#if mailS.stalwart != null || mailS.spf != null || mailS.oldest != null || mailS.last != null}
            <div class="kv">
              {#if mailS.oldest != null}<div class="srow"><span class="sl">Oldest message</span><span class="sv">{queue ? age(mailS.oldest) : 'none waiting'}</span></div>{/if}
              {#if mailS.last != null}<div class="srow"><span class="sl">Last delivery</span><span class="sv">{when(mailS.last)}</span></div>{/if}
              {#if mailS.stalwart != null}<div class="srow"><span class="dot {mailS.stalwart ? 'ok' : 'bad'}"></span><span class="sl">stalwart</span><span class="sv">{mailS.stalwart ? 'answers' : 'does not answer'}</span></div>{/if}
              {#if mailS.spf != null}<div class="srow"><span class="dot {mailS.spf === 'pass' ? 'ok' : 'warn'}"></span><span class="sl">SPF</span><span class="sv">{mailS.spf}</span></div>{/if}
            </div>
          {:else}
            <NotYet>The oldest message, the last delivery and whether stalwart answers are not in the status document.</NotYet>
          {/if}
        </div>

        <div class="card elev-sm c" class:focus={focus === 'watcher'} id="px-watcher">
          <div class="ch"><i class="ph ph-binoculars"></i><span class="ct">Outside watcher</span><span class="dot {watchS.dot}" title={watchS.title}></span></div>
          {#if watchS.dot === 'off'}
            <NotYet>The watcher's state, the heartbeat age and the watched addresses are not in the status document.</NotYet>
          {:else}
            <div class="kv">
              {#if watchS.state}<div class="srow"><span class="sl">State</span><span class="sv">{watchS.state}</span></div>{/if}
              {#if watchS.age != null}<div class="srow"><span class="sl">Heartbeat</span><span class="sv">{age(watchS.age)} ago</span></div>{/if}
              {#each watchS.sites as s}
                {@const up = s.code >= 100 && s.code < 500}
                <div class="srow"><span class="dot {up ? 'ok' : 'bad'}"></span><span class="sl">{s.name ?? s.url}</span><span class="sv">{s.code ?? 'no answer'}</span>{#if s.since}<span class="sm">since {when(s.since)}</span>{/if}</div>
              {/each}
            </div>
          {/if}
        </div>
      </div>

      <div class="col">
        <div class="card elev-sm c">
          <div class="ch"><i class="ph ph-plugs"></i><span class="ct">Ports</span><span class="dot {portS.dot}" title={portS.title}></span></div>
          {#if portS.dot === 'off' && !portS.groups.length}
            <NotYet>The forwarded and open ports are not in the status document.</NotYet>
          {:else}
            <div class="kv">
              {#each portS.groups as g}
                <div class="srow"><span class="dot {g.dot}"></span><span class="sl">{g.name}</span><span class="sv">{g.total} port{g.total === 1 ? '' : 's'}{g.target ? ` → ${g.target}` : ''}</span>{#if g.probe}<span class="sm">{g.probe.ok ? 'answers' : 'does not answer'}{g.probe.ms != null ? ` · ${g.probe.ms} ms` : ''}</span>{/if}</div>
              {/each}
            </div>
          {/if}
          <button class="btn btn-ghost sm" style="align-self:flex-start" onclick={() => go('/ports')}>All ports<i class="ph ph-caret-right"></i></button>
        </div>

        <div class="card elev-sm c" style="gap:0" class:focus={focus === 'certificate'} id="px-certificate">
          <div class="ch" style="margin-bottom:6px"><i class="ph ph-certificate"></i><span class="ct">Certificate &amp; services</span><span class="dot {certS.dot}" title={certS.title}></span></div>
          {#each svc as r}
            <div class="srow"><span class="dot {r.dot}"></span><span class="sl">{r.label}</span><span class="sv">{r.value}</span>{#if r.meta}<span class="sm">{r.meta}</span>{/if}</div>
          {/each}
          <div class="srow"><span class="dot {certS.dot}"></span><span class="sl">Certificate</span>{#if certS.days != null}<span class="sv">{Math.round(certS.days)} days left</span>{#if certS.domain}<span class="sm">{certS.domain}</span>{/if}{:else}<span class="sv muted">not available yet</span>{/if}</div>
          <div class="srow"><span class="dot {rev ? 'ok' : 'off'}"></span><span class="sl">Config revision</span>{#if rev}<span class="sv"><span class="mono">{rev.hash}</span> {rev.subject ?? ''}</span>{:else}<span class="sv muted">not available yet</span>{/if}</div>
          {#if d?.os}<div class="srow"><span class="dot off"></span><span class="sl">System</span><span class="sv">{d.os}{d.region ? ` · ${d.region}` : ''}</span></div>{/if}
        </div>
      </div>
    </div>

    {#if extra.length}
      <div class="card elev-sm c" style="gap:0">
        <div class="ch" style="margin-bottom:6px"><i class="ph ph-list-magnifying-glass"></i><span class="ct">More from the VPS</span></div>
        {#each extra as [k, v]}
          <div class="srow"><span class="sl mono">{k}</span><span class="sv mono">{brief(v)}</span></div>
        {/each}
      </div>
    {/if}
  </ProxyGate>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .meters { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; }
  .meter { padding: 12px 14px; gap: 8px; }
  .mrow { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--color-neutral-400); }
  .mval { display: flex; align-items: baseline; gap: 6px; }
  .big { font-size: 24px; font-weight: 500; white-space: nowrap; }
  .of { font-size: 12px; color: var(--color-neutral-500); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .bar { height: 4px; border-radius: var(--r); background: var(--color-neutral-800); }
  .bar div { height: 4px; border-radius: var(--r); background: var(--color-accent); }
  .two { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(440px, 100%), 1fr)); gap: 14px; align-items: start; }
  .col { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
  .c { padding: 14px 16px; gap: 10px; }
  .ch { display: flex; align-items: center; gap: 8px; }
  .ch i { color: var(--color-accent); }
  .ch .dot { margin-left: auto; }
  .focus { box-shadow: 0 0 0 1px var(--color-accent); }
  .kv { display: flex; flex-direction: column; }
  .ct { font-size: 14px; font-weight: 500; }
  .qrow { display: flex; align-items: baseline; gap: 10px; }
  .q { font-size: 28px; font-weight: 500; }
  .srow { display: flex; align-items: center; gap: 10px; padding: 6px 0; box-shadow: inset 0 -1px 0 color-mix(in srgb, var(--color-text) 6%, transparent); }
  .sl { width: 170px; flex: none; color: var(--color-neutral-400); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sv { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
  .sm { font-size: 11px; color: var(--color-neutral-500); }
  .muted { color: var(--color-neutral-500); }
  .mono { font-family: ui-monospace, Menlo, monospace; font-size: 12px; }
</style>
