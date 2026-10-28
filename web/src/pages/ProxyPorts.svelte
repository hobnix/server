<script>
  // proxyserver Ports: every port the VPS forwards or opens itself, one tree-table like the Disks card of the Summary page (group rows with
  // the group's totals, port blocks indented underneath). Everything comes from the status document's `ports` key (docs/PLAN-web-backend.md).
  import { useProxy } from './proxy/proxy.svelte.js';
  import { ports } from './proxy/status.js';
  import ProxyHead from './proxy/ProxyHead.svelte';
  import ProxyGate from './proxy/ProxyGate.svelte';
  import NotYet from './proxy/NotYet.svelte';

  const px = useProxy();
  const p = $derived(ports(px.doc));
  const ICON = { games: 'ph-game-controller', rtc: 'ph-video-camera', mail: 'ph-envelope-simple', own: 'ph-shield-check' };
  const n = (c, w) => `${c} ${w}${c === 1 ? '' : 's'}`;
  // games/rtc rows are forwarded to a target; mail/own rows are open on the VPS itself
  const through = (g) => g.id === 'games' || g.id === 'rtc';
  const rowDot = (r) => (r.forwarded === true ? 'ok' : r.forwarded === false ? 'warn' : 'off');
  const rowWord = (g, r) => (r.forwarded === true ? (through(g) ? 'forwarded' : 'open') : r.forwarded === false ? (through(g) ? 'not forwarded' : 'not open') : 'unknown');
  const groupNote = (g) => {
    if (g.id === 'mail') return 'not forwarded: the VPS accepts it and relays it on';
    if (g.id === 'own') return 'not forwarded';
    return n(g.rows.length, 'block');
  };
</script>

<div class="page">
  <ProxyHead {px} title="Ports" sub="what the proxyserver forwards to your servers or opens itself" />
  <ProxyGate {px}>
    <div class="card elev-sm pcard">
      <div class="top">
        <span class="ctitle">Ports</span>
        <span class="muted">{p.groups.length ? n(p.groups.length, 'group') : ''}</span>
        <span style="flex:1"></span>
        <span class="dot {p.dot}" title={p.title}></span>
      </div>
      {#if p.dot === 'off' && !p.groups.length}
        <NotYet>The list of forwarded and open ports is not in the status document.</NotYet>
      {:else}
        <div class="tablescroll"><table class="table">
          <thead><tr><th>Name</th><th class="opt">Proto</th><th>Ports</th><th class="opt">Count</th><th class="opt">Target</th><th>Status</th></tr></thead>
          <tbody>
            {#each p.groups as g}
              <tr class="grow">
                <td style="padding-left:6px"><span class="nm" style="font-weight:500"><i class="ph ph-caret-down car"></i><i class="ph {ICON[g.id] ?? 'ph-plugs'} ic"></i>{g.name}</span></td>
                <td class="kd" colspan="2">{groupNote(g)}</td>
                <td class="kd opt">{g.total || ''}</td>
                <td class="kd mono opt">{g.target ?? ''}</td>
                <td>
                  <span class="hl"><span class="dot {g.dot}"></span>{#if g.probe}{g.probe.ok ? 'answers' : 'does not answer'}{#if g.probe.ms != null}<span class="kd">{g.probe.ms} ms</span>{/if}{:else}{g.dot === 'off' ? 'unknown' : ''}{/if}</span>
                </td>
              </tr>
              {#each g.rows as r}
                <tr>
                  <td style="padding-left:26px"><span class="nm">{r.name}</span></td>
                  <td class="kd opt">{r.proto}</td>
                  <td class="mono">{r.ports}</td>
                  <td class="kd opt">{r.count ?? ''}</td>
                  <td class="kd mono opt">{g.target ?? ''}</td>
                  <td><span class="hl"><span class="dot {rowDot(r)}"></span>{rowWord(g, r)}</span></td>
                </tr>
              {/each}
            {/each}
          </tbody>
        </table></div>
        <div class="foot muted">
          {p.forwardedPorts ? `${n(p.forwardedPorts, 'port')} forwarded to ${n(p.targets, 'target')}` : 'No port is forwarded'}{p.openPorts ? ` · ${n(p.openPorts, 'port')} open on the proxyserver itself` : ''} · SSH (22) is closed publicly: Tailscale only
        </div>
      {/if}
    </div>
  </ProxyGate>
</div>

<style>
  @media (max-width: 860px) { .opt { display: none; } }
  .page { display: flex; flex-direction: column; gap: 14px; }
  .pcard { padding: 14px 16px; gap: 10px; }
  .top { display: flex; align-items: center; gap: 8px; }
  .ctitle { font-size: 14px; font-weight: 500; }
  .table { font-size: 12.5px; }
  .table :global(td), .table :global(th) { padding: 5px 8px; }
  .grow { background-color: color-mix(in srgb, var(--color-text) 3%, transparent); }
  .nm { display: flex; align-items: center; gap: 7px; }
  .car { font-size: 10px; width: 10px; color: var(--color-neutral-500); }
  .ic { color: var(--color-neutral-400); }
  .kd { color: var(--color-neutral-400); white-space: nowrap; }
  .hl { display: flex; align-items: center; gap: 6px; white-space: nowrap; }
  .mono { font-family: ui-monospace, Menlo, monospace; font-size: 12px; }
  .foot { font-size: 12px; }
</style>
