<script>
  import { poll, rows } from '../data.svelte.js';
  import { openPlan, openCreate, ui } from '../ui.svelte.js';
  import { route, go } from '../route.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageTabs from '../ui/PageTabs.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Banner from '../ui/Banner.svelte';
  import { ctOf, link } from './instances/ct.js';
  import PeerMount from '../forms/ops/PeerMount.svelte';
  import PeerAttach from '../forms/ops/PeerAttach.svelte';
  import PeerOffer from '../forms/ops/PeerOffer.svelte';
  import PeerOffered from '../forms/ops/PeerOffered.svelte';
  import RouterSetup from '../forms/ops/RouterSetup.svelte';
  import Table from '../shell/Table.svelte';

  let { deck } = $props();
  let offered = $state(null);   // the answer of "Give access": holds the new password once; dropped when the dialog is closed
  const list = poll('/api/sys/ct/list', 15000);
  const remote = poll('/api/sys/remote/list', 30000);
  const config = poll('/api/sys/system/config', 60000);
  // the router (UniFi) is optional: without a key on the server these reads fail and the page says so
  const nets = poll('/api/sys/unifi/networks', 60000);
  const clients = poll('/api/sys/unifi/clients', 30000);
  const portsRead = poll('/api/sys/ports/list', 60000);
  const dnsRead = poll('/api/sys/dns/list', 60000);

  const d = $derived(deck?.data);
  const cts = $derived(rows(list).map(ctOf));

  // tabs: Overview, DNS, Ports, Router, Remote shares (the address keeps the tab: ?tab=dns)
  const tabs = [{ id: 'overview', label: 'Overview' }, { id: 'dns', label: 'DNS' }, { id: 'ports', label: 'Ports' }, { id: 'router', label: 'Router' }, { id: 'remote', label: 'Remote shares' }];
  const tab = $derived(tabs.some((t) => t.id === route.query.tab) ? route.query.tab : 'overview');
  const pick = (id) => go(id === 'overview' ? '/network' : `/network?tab=${id}`);

  // the IPv4 address in a cell such as "10.10.95.20 (eth0)"
  const ADDR = /(\d+)\.(\d+)\.(\d+)\.(\d+)/;
  function parseAddr(s) {
    const m = ADDR.exec(s || '');
    return m ? { prefix: `${m[1]}.${m[2]}.${m[3]}`, n: Number(m[4]) } : null;
  }
  const parsed = $derived(cts.map((c) => ({ ...c, a: parseAddr(c.address) })).filter((c) => c.a));
  // the network of the instances: the prefix most instances share
  const prefix = $derived.by(() => {
    const count = {};
    for (const c of parsed) count[c.a.prefix] = (count[c.a.prefix] ?? 0) + 1;
    return Object.entries(count).sort((a, b) => b[1] - a[1])[0]?.[0] ?? '';
  });
  const onNet = $derived(parsed.filter((c) => c.a.prefix === prefix));

  // networks: name, subnet, dhcp true|false, first, last
  const routerNets = $derived(rows(nets).map((r) => ({ name: r[0], subnet: r[1], dhcp: r[2] === 'true', from: r[3], to: r[4] })));
  // clients: ip, mac, name, reserved|online|reserved+online
  const byIp = $derived(Object.fromEntries(rows(clients).map((r) => [r[0], { mac: r[1], name: r[2] === '-' ? '' : r[2], how: r[3] }])));
  const routerOk = $derived(nets.loaded && !nets.error);
  const routerOff = $derived((nets.loaded && nets.error) || (clients.loaded && clients.error));
  const howTxt = (h) => (h === 'reserved+online' ? 'reserved, online' : h);

  // ports: listen rows (kind, where, proto, port, bind, process, status, note), proxy rows (kind, where, tcp, port, host name, source, status, note)
  const listen = $derived(rows(portsRead).filter((r) => r[0] === 'listen').map((r) => ({ where: r[1], proto: r[2], port: r[3], bind: r[4], proc: r[5], status: r[6], note: r[7] })));
  const rules = $derived(rows(portsRead).filter((r) => r[0] === 'proxy').map((r) => ({ where: r[1], port: r[3], host: r[4], status: r[6], note: r[7] })));
  const flagged = $derived(listen.filter((l) => l.status === 'admin' || l.status === 'unexpected').length);
  const ruleDot = (st) => (st === 'ok' ? 'ok' : st === 'info' || st === 'unknown' ? 'warn' : 'bad');
  const portDot = (st) => (st === 'expected' ? 'ok' : st === 'admin' ? 'bad' : 'warn');

  // DNS names: name, type, value
  const dnsNames = $derived(rows(dnsRead).map((r) => ({ name: r[0], type: r[1], value: r[2] })));

  const bands = [['edge', 10], ['apps', 20], ['games', 30], ['tools', 40]];
  const ranges = $derived(bands.map(([name, from]) => ({
    name,
    span: `.${from} – .${from + 9}`,
    cells: Array.from({ length: 10 }, (_, i) => {
      const n = from + i;
      const ct = onNet.find((x) => x.a.n === n);
      const rt = byIp[`${prefix}.${n}`];
      const title = ct ? `${prefix}.${n} · ${ct.name}${rt ? ` · ${howTxt(rt.how)} at the router` : ''}` : rt ? `${prefix}.${n} · ${rt.name || rt.mac} · ${howTxt(rt.how)} at the router` : `${prefix || '?'}.${n} · free`;
      return { n, name: ct?.name ?? rt?.name ?? '', title, used: !!ct, router: !ct && !!rt };
    }),
  })));
  const others = $derived(onNet.filter((c) => c.a.n < 10 || c.a.n >= 50));

  // `sys system config` is a plain table: a header, then setting and value split by two or more spaces
  const cfg = $derived.by(() => {
    const m = {};
    for (const line of (config.data?.text ?? '').split('\n').slice(1)) {
      const p = line.trim().split(/\s{2,}|\t/);
      if (p.length >= 2) m[p[0]] = p.slice(1).join(' ');
    }
    return m;
  });
  // vlans = { home = 95 }: the first name and number
  const VLAN = /(\w[\w-]*)\s*=\s*(\d+)/;
  const vlan = $derived.by(() => { const m = VLAN.exec(cfg.vlans ?? ''); return m ? { name: m[1], id: m[2] } : null; });

  // kind, peer, share, host or login, state
  const rem = $derived(rows(remote).map((r) => ({ kind: r[0], peer: r[1], share: r[2], state: r[4] })));
  const remDot = (s) => (s === 'mounted' || s === 'given' || s === 'attached' ? 'ok' : 'warn');
  const kindWord = (k) => (k === 'mount' ? 'attach' : k);

  // addresses of the router's clients that the map above cannot show (other ranges, other networks)
  const elsewhere = $derived(Object.keys(byIp).filter((ip) => !(ip.startsWith(prefix + '.') && Number(ip.split('.')[3]) >= 10 && Number(ip.split('.')[3]) < 50)).length);

  const chain = [['Internet', 'tag-neutral'], ['Cloudflare Tunnel', 'tag-neutral'], ['cloudflared', 'tag-neutral'], ['Zoraxy', 'tag-accent'], ['instance', 'tag-neutral']];

  const columns = [{ key: 'host', label: 'Name' }, { key: 'where', label: 'Goes to', value: (r) => `${r.where}:${r.port}` }];
  const remoteCols = [{ key: 'kind', label: 'Kind', value: (r) => kindWord(r.kind) }, { key: 'peer', label: 'Peer' }, { key: 'share', label: 'Share' }, { key: 'state', label: 'State' }, { key: 'actions', label: '', sort: false, align: 'right' }];
  const netCols = [{ key: 'name', label: 'Network' }, { key: 'subnet', label: 'Subnet' }, { key: 'dhcp', label: 'DHCP', value: (n) => (n.dhcp && n.from !== '-' ? `${n.from} – ${n.to}` : 'off') }];
  const portCols = [{ key: 'where', label: 'Where' }, { key: 'port', label: 'Port', value: (l) => Number(l.port) , sort: 'num' }, { key: 'proc', label: 'Process' }, { key: 'status', label: 'Status' }];
  const dnsCols = [{ key: 'name', label: 'Name' }, { key: 'type', label: 'Type' }, { key: 'value', label: 'Value' }];
</script>

<PageHeader title="Network" crumb={ui.host} sub={vlan ? `Site ${vlan.name} · UniFi. Addresses, names, ports and the way in from the outside.` : 'Addresses, names, ports and the way in from the outside.'} />

<PageTabs {tabs} {tab} onpick={pick} />

{#if tab === 'overview'}
  <div class="facts">
    <div class="card fact">
      <div class="flab"><i class="ph ph-house-line"></i>Host</div>
      <div class="fval">{d?.host ?? '–'}</div>
      <div class="fsub">{d?.net?.iface ? `physical port ${d.net.iface}` : ''}</div>
    </div>
    <div class="card fact">
      <div class="flab"><i class="ph ph-cube"></i>Instances</div>
      <div class="fval">{prefix ? `${prefix}.0/24` : '–'}</div>
      <div class="fsub">{vlan ? `VLAN ${vlan.id} · ` : ''}{list.loaded ? (list.error && !cts.length ? 'could not be read' : `${cts.length} instances`) : 'Loading…'}</div>
    </div>
    <div class="card fact">
      <div class="flab"><i class="ph ph-plugs-connected"></i>Router</div>
      <div class="fval">{routerOk ? `${routerNets.length} networks` : '–'}</div>
      <div class="fsub">{routerOk ? `${Object.keys(byIp).length} addresses reserved or online` : nets.loaded ? 'not connected: see the Router tab' : 'Loading…'}</div>
    </div>
  </div>

  <div class="card" style="padding:14px 16px;gap:10px">
    <div class="ch"><b>Addresses on {vlan ? `VLAN ${vlan.id}` : 'the instance network'}</b><span class="sub">fixed at the UniFi router · MAC pinned in Incus · a name opens the instance</span></div>
    {#each ranges as r}
      <div class="band">
        <div><div style="font-size:13px">{r.name}</div><div class="sub">{r.span}</div></div>
        <div class="cellrow">
          {#each r.cells as c}
            <div class="cell" class:used={c.used} class:router={c.router} title={c.title}>
              <span class="cn">.{c.n}</span>
              {#if c.used}<a class="nm" {...link('/instances', 'instances', c.name)}>{c.name}</a>{:else}<span class="nm">{c.name}</span>{/if}
            </div>
          {/each}
        </div>
      </div>
    {/each}
    {#if others.length}
      <div class="note">Outside these ranges: {#each others as c, i}{i ? ', ' : ''}<a {...link('/instances', 'instances', c.name)}>{c.name}</a> ({c.address.split(' ')[0]}){/each}</div>
    {/if}
    <div class="note">{list.loaded ? (list.error && !cts.length ? 'The instances could not be read (is the storage locked?).' : routerOff ? 'Shows instances with an address. The router could not be asked: UniFi is not set up on this server, or the key is wrong (Router tab).' : clients.loaded ? `Filled cells are instances; outlined cells are other devices the router has reserved or sees online.${elsewhere ? ` ${elsewhere} more address(es) at the router lie outside these ranges.` : ''}` : 'Loading…') : 'Loading…'}</div>
    <div><button class="btn sm" title="Pin the MAC address of every instance" onclick={() => openPlan('admin', ['pin-macs'], 'Pin the MAC addresses')}><i class="ph ph-push-pin"></i>Pin MACs</button></div>
  </div>

  <div class="card" style="padding:12px 14px;gap:8px">
    <div class="ch"><b>Public access</b><span class="sub">what the internet can reach</span></div>
    <div class="chain">
      {#each chain as [name, cls], i}
        {#if i}<i class="ph ph-arrow-right" style="color:var(--fg-3)"></i>{/if}
        <span class="tag {cls}">{name}</span>
      {/each}
    </div>
    <Table id="zoraxy-rules" {columns} rows={rules} key="host" compact loading={!portsRead.loaded}
           empty={portsRead.error && !listen.length ? 'The rules could not be read.' : 'No Zoraxy rule could be read (is Zoraxy running?).'}>
      {#snippet cell(r, col)}
        {#if col.key === 'host'}<span title={r.note && r.note !== '-' ? r.note : ''}>{r.host}</span>
        {:else}<span class="goes"><StatusDot state={ruleDot(r.status)} bare label={r.status} />{r.where}:{r.port}{#if r.status === 'WARN'}<span class="tag tag-neutral" style="color:var(--bad)">admin interface</span>{/if}</span>{/if}
      {/snippet}
    </Table>
    <div class="note">Every rule is reachable from the internet. Admin interfaces (Incus, Zoraxy, Arcane, Homepage, Grafana, docs) have no rule on purpose. Games go through the proxyserver instead.</div>
  </div>

{:else if tab === 'dns'}
  <div class="card" style="padding:12px 14px;gap:8px">
    <div class="ch"><b>DNS names</b><span class="sub">of the instances, in the domain</span>
      <button class="btn btn-primary sm" style="margin-left:auto" title="Create, correct and remove the DNS names of the instances (shows the plan first)" onclick={() => openPlan('dns', ['sync'], 'Sync DNS names')}><i class="ph ph-arrows-clockwise"></i>Sync DNS names</button></div>
    <Table id="dns-names" columns={dnsCols} rows={dnsNames} compact loading={!dnsRead.loaded}
           empty={dnsRead.error ? 'The names could not be read (no domain, or the domain controller is down).' : 'No names yet: Sync DNS names creates them.'}>
      {#snippet cell(n, col)}
        {#if col.key === 'name'}{#if cts.some((c) => c.name === n.name.split('.')[0])}<a {...link('/instances', 'instances', n.name.split('.')[0])}>{n.name}</a>{:else}{n.name}{/if}
        {:else if col.key === 'type'}<span class="kd">{n.type}</span>
        {:else}<span class="mono">{n.value}</span>{/if}
      {/snippet}
    </Table>
  </div>

{:else if tab === 'ports'}
  <div class="card" style="padding:12px 14px;gap:8px">
    <div class="ch"><b>Open ports</b><span class="sub">{listen.length} listening{flagged ? ` · ${flagged} to look at` : ''} · what listens on the server and in each instance · loopback-only sockets left out</span></div>
    <Table id="net-ports" columns={portCols} rows={listen} compact loading={!portsRead.loaded} empty={portsRead.error ? 'The ports could not be read.' : 'Nothing listens.'}>
      {#snippet cell(l, col)}
        {#if col.key === 'where'}{#if cts.some((c) => c.name === l.where)}<a {...link('/instances', 'instances', l.where)}>{l.where}</a>{:else}{l.where}{/if}
        {:else if col.key === 'port'}{l.port}/{l.proto}{l.bind && l.bind !== '-' ? ` · ${l.bind}` : ''}
        {:else if col.key === 'proc'}<span class="kd">{l.proc && l.proc !== '-' ? l.proc : '–'}</span>
        {:else}<StatusDot state={portDot(l.status)} label={l.status + (l.note && l.note !== '-' ? ` · ${l.note}` : '')} />{/if}
      {/snippet}
    </Table>
    <div class="note">Admin means an admin interface: it must have no Zoraxy rule. To mark a port as expected, add a line to /var/lib/hs/ports-expected on the server. The ports of the proxyserver are on its own node.</div>
  </div>

{:else if tab === 'router'}
  <div class="card" style="padding:12px 14px;gap:8px">
    <div class="ch"><b>Router</b><span class="sub">UniFi · networks and DHCP ranges</span>
      <button class="btn btn-primary sm" style="margin-left:auto" title="Store the address and the API key of the UniFi router" onclick={() => openCreate(RouterSetup)}><i class="ph ph-plugs-connected"></i>{routerOk ? 'Change router…' : 'Connect router…'}</button></div>
    {#if routerOff && !routerOk}
      <Banner tone="info">The router could not be asked: UniFi is not set up on this server, or the key is wrong. Connect it to see the networks and to keep the instance addresses in step.</Banner>
    {/if}
    <Table id="router-nets" columns={netCols} rows={routerNets} key="name" compact loading={!nets.loaded} empty="No networks to show.">
      {#snippet cell(n, col)}
        {#if col.key === 'name'}{n.name}
        {:else if col.key === 'subnet'}<span class="mono">{n.subnet}</span>
        {:else}<span class="mono">{n.dhcp && n.from !== '-' ? `${n.from} – ${n.to}` : 'off'}</span>{/if}
      {/snippet}
    </Table>
    {#if routerOk}<div class="note">{Object.keys(byIp).length} address(es) reserved or online. Fixed addresses for instances are shown on the Overview tab; the instances are on the Instances page.</div>{/if}
  </div>

{:else}
  <div class="card" style="padding:12px 14px;gap:8px">
    <div class="ch"><b>Remote shares</b><span class="sub">between homeservers: a peer connection, not a share of this server</span>
      <button class="btn btn-ghost sm" style="margin-left:auto" title="Mount a share of another homeserver, read only" onclick={() => openCreate(PeerMount)}><i class="ph ph-plus"></i>Mount a share…</button>
      <button class="btn btn-ghost sm" title="Let another homeserver read one of your shares" onclick={() => openCreate(PeerOffer, { ondone: (r) => (offered = r) })}><i class="ph ph-share-network"></i>Give access…</button></div>
    <Table id="remote-shares" columns={remoteCols} rows={rem} compact loading={!remote.loaded} empty={remote.error ? 'Remote shares could not be read.' : 'No shares with other servers.'}>
      {#snippet cell(r, col)}
        {#if col.key === 'kind'}<span class="tag tag-neutral">{kindWord(r.kind)}</span>
        {:else if col.key === 'peer'}{r.peer}
        {:else if col.key === 'share'}<span class="kd">{r.share}</span>
        {:else if col.key === 'state'}<StatusDot state={remDot(r.state)} label={r.state} />
        {:else}<span style="white-space:nowrap">{#if r.kind === 'mount'}
                <button class="btn btn-ghost sm" title="Give an instance the shares of {r.peer}, or take them away" onclick={() => openCreate(PeerAttach, { peer: r.peer, instances: cts.map((c) => c.name) })}>Instance…</button>
                <button class="btn btn-ghost sm" title="Stop using {r.share} of {r.peer}" onclick={() => openPlan('peers', ['remove', r.peer, r.share], 'Stop using ' + r.peer + ' / ' + r.share)}>Remove…</button>
              {:else}
                <button class="btn btn-ghost sm" title="Make a new password for {r.peer}" onclick={() => openCreate(PeerOffer, { peer: r.peer, share: r.share, newpw: true, ondone: (o) => (offered = o) })}>New password…</button>
                <button class="btn btn-ghost sm" title="Take the access to {r.share} away from {r.peer}" onclick={() => openPlan('peers', ['revoke', r.peer, r.share], 'Take back the access of ' + r.peer)}>Revoke…</button>
              {/if}</span>{/if}
      {/snippet}
    </Table>
  </div>
{/if}

{#if offered}<PeerOffered offer={offered} onclose={() => (offered = null)} />{/if}

<style>
  .sub { font-size: 12px; color: var(--fg-3); }
  .note { font-size: 12px; color: var(--fg-3); }
  .kd { color: var(--fg-3); }
  .ch { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
  .ch b { font-size: 14px; font-weight: 600; }
  .facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
  .fact { padding: 12px 14px; gap: 4px; }
  .flab { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--fg-3); }
  .fval { font-size: 16px; font-weight: 600; }
  .fsub { font-size: 12px; color: var(--fg-3); }
  .band { display: grid; grid-template-columns: 110px minmax(0, 1fr); gap: 12px; align-items: center; }
  .cellrow { display: grid; grid-template-columns: repeat(10, minmax(0, 1fr)); gap: 4px; }
  .cell { height: 38px; padding: 3px 5px; background: var(--bg); border: 1px solid var(--line); display: flex; flex-direction: column; justify-content: center; overflow: hidden; }
  .cell.used { background: color-mix(in oklch, var(--accent) 16%, var(--panel)); border-color: color-mix(in oklch, var(--accent) 45%, var(--line)); }
  .cell.router { background: transparent; border-color: var(--line-2); }
  .cn { font-size: 10px; color: var(--fg-3); }
  .nm { font-size: 10.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .goes { display: flex; align-items: center; gap: 6px; color: var(--fg-2); }
  .chain { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; font-size: 12px; color: var(--fg-2); }
  @media (max-width: 860px) { .band { grid-template-columns: 1fr; gap: 4px; } .cellrow { grid-template-columns: repeat(5, minmax(0, 1fr)); } }
</style>
