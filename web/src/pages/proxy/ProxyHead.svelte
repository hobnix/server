<script>
  // Page header. `summary` = the node header of the design (tile, name, online dot, meta line, health chip); otherwise crumb + title.
  import { duration } from '../../format.js';
  import { ui, openPlan } from '../../ui.svelte.js';
  import { route } from '../../route.svelte.js';
  import { VPS_NODE } from '../../redirects.js';
  // vps update / vps watch exist for the proxyserver node only (CHANGES["vps"]); another edge node is looked at, never changed from here
  const canAct = $derived(route.node === VPS_NODE);
  let { px, summary = false, title = '', sub = '' } = $props();
  const d = $derived(px.doc);
  const age = $derived(d?.time ? Math.max(0, Math.round(Date.now() / 1000 - d.time)) : null);
  // the document is older than a few minutes: the VPS stopped writing it
  const stale = $derived(age != null && age > 300);
  const word = $derived(px.state === 'ok' ? (stale ? 'status is old' : 'online') : px.state === 'down' ? 'not reachable' : px.state === 'off' ? 'not configured' : 'loading');
  const dot = $derived(px.state === 'ok' ? (stale ? 'warn' : 'ok') : px.state === 'down' ? 'bad' : 'off');
  const meta = $derived(d ? [d.uptime_s != null ? `up ${duration(d.uptime_s)}` : '', d.load ? `load ${d.load.join(' ')}` : ''].filter(Boolean).join(' · ') : '');
</script>

{#if summary}
  <div class="head">
    <div class="tile"><i class="ph ph-globe-hemisphere-west"></i></div>
    <div style="min-width:0">
      <div style="display:flex;align-items:center;gap:8px"><span class="name">{d?.host ?? route.node ?? 'proxyserver'}</span><span class="state"><span class="dot {dot}"></span>{word}</span></div>
      <div class="muted">{meta}</div>
    </div>
    <div style="flex:1"></div>
    <!-- vps update / vps watch: hs sys vps plan|start runs them over SSH with a key that can do only that (machine.toml: vpsHost, `hs vps key`) -->
    {#if canAct}<button class="btn btn-secondary" disabled={!ui.features.vps} title={ui.features.vps ? 'Pull the configuration on the proxyserver and rebuild it' : 'Set vpsHost in machine.toml (steps: docs/web-interface.md)'} onclick={() => openPlan('vps', ['update'], 'Update the proxyserver')}><i class="ph ph-arrow-circle-up"></i>vps update</button>
    <button class="btn btn-secondary" disabled={!ui.features.vps} title={ui.features.vps ? 'Check the home server from the proxyserver now' : 'Set vpsHost in machine.toml (steps: docs/web-interface.md)'} onclick={() => openPlan('vps', ['watch'], 'Watch the home server from outside')}><i class="ph ph-binoculars"></i>vps watch</button>{/if}
    {#if d}
      <span class="chip"><span class="dot {d.problems > 0 ? 'warn' : d.problems === 0 ? 'ok' : 'off'}"></span>Health · {d.problems == null ? 'not available' : d.problems > 0 ? `${d.problems} problem${d.problems === 1 ? '' : 's'}` : 'no problems'}</span>
    {/if}
  </div>
{:else}
  <div class="head">
    <div><div class="crumb">{route.node || 'proxyserver'}</div><div style="display:flex;align-items:baseline;gap:10px;flex-wrap:wrap"><span class="title">{title}</span>{#if sub}<span class="muted">{sub}</span>{/if}</div></div>
  </div>
{/if}

<style>
  .head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .tile { width: 38px; height: 38px; border-radius: var(--r); display: grid; place-items: center; font-size: 20px; color: var(--color-accent); box-shadow: inset 0 0 0 1px var(--color-neutral-800); background: var(--color-neutral-900); flex: none; }
  .name { font-size: 20px; font-weight: 500; }
  .state { display: flex; align-items: center; gap: 5px; font-size: 12px; color: var(--color-neutral-400); }
  .muted { font-size: 12px; color: var(--color-neutral-500); }
  .crumb { font-size: 11px; color: var(--color-neutral-500); }
  .title { font-size: 20px; font-weight: 500; }
  .chip { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; padding: 5px 12px; border-radius: var(--r); box-shadow: inset 0 0 0 1px var(--color-neutral-800); color: var(--color-neutral-300); }
</style>
