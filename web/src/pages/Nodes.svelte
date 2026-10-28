<script>
  // All servers at a glance: this server and every node of `hs node list`, one row each. Each remote node is asked for
  // its status document over SSH (the word status only); a node that does not answer keeps its last document and says since when.
  // A row opens the drawer: facts, the key line its owner has to allow, remove. Adding a node changes nothing on the other server.
  import { untrack } from 'svelte';
  import { poll, rows } from '../data.svelte.js';
  import { go } from '../route.svelte.js';
  import { ui, openPlan, openCreate } from '../ui.svelte.js';
  import Table from '../shell/Table.svelte';
  import NodeProbe from '../shell/NodeProbe.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Chip from '../ui/Chip.svelte';
  import Kv from '../ui/Kv.svelte';
  import Split from '../ui/Split.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import NodeAdd from '../forms/ops/NodeAdd.svelte';
  import NodeKey from './nodes/NodeKey.svelte';
  import { since, capList } from './nodes/nodes.js';

  let { deck } = $props();

  const nlist = poll('/api/sys/node/list', 15000);
  const reports = $state({});
  const report = (name, dot, state, extra = {}) => {
    const r = untrack(() => reports[name]);
    if (!r || r.dot.state !== dot.state || r.dot.title !== dot.title || r.state !== state || r.doc?.time !== extra.doc?.time || r.why !== (extra.why ?? ''))
      reports[name] = { dot, state, doc: extra.doc ?? r?.doc ?? null, caps: extra.caps ?? null, why: extra.why ?? '' };
  };

  // name, kind, host, port, source (file|setting), key (ok|locked|missing)
  const remote = $derived(rows(nlist).map((r) => ({ name: r[0], kind: r[1], host: r[2], port: r[3], source: r[4], key: r[5] ?? 'missing' })));
  const nodes = $derived.by(() => {
    const d = deck?.data;
    const local = { name: ui.host, kind: 'main', host: 'this server', port: '', source: 'local', key: 'ok', state: d ? (d.locked ? 'warn' : 'ok') : 'off', word: d?.locked ? 'storage locked' : d ? 'online' : 'reading',
      time: d?.time ?? null, problems: d?.problems ?? null, caps: Array.isArray(ui.features.capabilities) ? ui.features.capabilities : [] };
    const out = [local];
    for (const n of remote) {
      const r = reports[n.name];
      let state = 'off', word = 'reading';
      if (n.key === 'missing') word = 'no key yet';
      else if (n.key === 'locked') word = 'key locked';
      else if (r) { state = r.dot.state; word = r.dot.title; }
      out.push({ ...n, state, word, time: r?.doc?.time ?? null, problems: r?.doc?.problems ?? null, caps: r?.caps ?? null, why: r?.why ?? '' });
    }
    return out;
  });

  let selName = $state('');
  const sel = $derived(nodes.find((n) => n.name === selName));

  const columns = [
    { key: 'name', label: 'Server' }, { key: 'kind', label: 'Kind', optional: true }, { key: 'host', label: 'Host', optional: true },
    { key: 'word', label: 'State' }, { key: 'time', label: 'Last answer', sort: 'num', optional: true },
    { key: 'problems', label: 'Problems', sort: 'num', align: 'right' }, { key: 'caps', label: 'Parts', sort: false, optional: true },
  ];
  const kindLabel = { main: 'this server', peer: 'home server', edge: 'edge node', vps: 'proxyserver' };
</script>

{#each remote.filter((n) => n.key === 'ok') as n (n.name)}<NodeProbe name={n.name} onstate={report} />{/each}

<PageHeader title="Nodes" crumb={ui.host} sub="The servers this one can look at. A remote server is only read: nothing here changes it.">
  {#snippet actions()}<button class="btn btn-primary" onclick={() => openCreate(NodeAdd, { ondone: () => { /* the list is read again within 15 s */ } })}><i class="ph ph-plus"></i>Add a server</button>{/snippet}
</PageHeader>

<PageState loading={!nlist.loaded} error={nlist.error?.message} hasData={nlist.data != null} empty={false}>
  <Split open={!!sel}>
    {#snippet list()}
      <div class="card" style="padding:0">
        <Table id="nodes" {columns} rows={nodes} key="name" selected={sel?.name} onrow={(n) => (selName = n.name)} sort={{ key: 'name', dir: 'asc' }} empty="No other servers yet.">
          {#snippet cell(n, col)}
            {#if col.key === 'name'}<b>{n.name}</b>
            {:else if col.key === 'kind'}<Chip>{kindLabel[n.kind] ?? n.kind}</Chip>
            {:else if col.key === 'host'}<span class="mono">{n.host}</span>
            {:else if col.key === 'word'}<StatusDot state={n.state} label={n.word} />
            {:else if col.key === 'time'}<span class="muted">{n.kind === 'main' ? 'now' : since(n.time)}</span>
            {:else if col.key === 'problems'}{n.problems ?? '–'}
            {:else}
              {@const c = capList(n.caps)}
              <span class="caps">{#each c.shown as x}<Chip>{x}</Chip>{/each}{#if c.more}<span class="muted">+{c.more}</span>{/if}{#if !c.shown.length}<span class="muted">–</span>{/if}</span>
            {/if}
          {/snippet}
        </Table>
      </div>
      {#if remote.length === 0 && nlist.loaded}
        <p class="muted pad">No other server yet. Add one, make its key, and give its owner one line to allow; it then shows up here with its own pages.</p>
      {/if}
    {/snippet}
    {#snippet side()}
      {#if sel}
        <Drawer title={sel.name} chip={kindLabel[sel.kind] ?? sel.kind} state={sel.state} stateLabel={sel.word} onclose={() => (selName = '')}>
          <Kv items={[
            { k: 'Host', v: sel.host }, { k: 'Port', v: sel.port }, { k: 'Last answer', v: sel.kind === 'main' ? 'now' : since(sel.time) },
            { k: 'Problems', v: sel.problems }, { k: 'Source', v: sel.source === 'setting' ? 'the setting vpsHost' : sel.source === 'file' ? 'the node list' : 'this server' },
            { k: 'Parts', v: Array.isArray(sel.caps) && sel.caps.length ? sel.caps.join(', ') : '' },
          ]} />
          {#if sel.kind !== 'main'}
            {#if sel.why}<p class="why">{sel.why}</p>{/if}
            <div class="sec">
              <h3>Key</h3>
              <NodeKey name={sel.name} canChange={sel.source === 'file'} />
              {#if sel.source === 'setting'}<p class="muted">This node comes from the setting <code>vpsHost</code>; its key is made with <code>hs vps key</code> and it goes away with <code>hs config unset vpsHost</code>.</p>{/if}
            </div>
          {/if}
          {#snippet actions()}
            <button class="btn btn-primary" onclick={() => go(`/node/${encodeURIComponent(sel.name)}`)}><i class="ph ph-arrow-right"></i>Open</button>
            {#if sel.kind !== 'main' && sel.source === 'file'}
              <button class="btn btn-ghost danger" onclick={() => { const n = sel.name; selName = ''; openPlan('node', ['remove', n], `Remove ${n}`); }}><i class="ph ph-trash"></i>Remove…</button>
            {/if}
          {/snippet}
        </Drawer>
      {/if}
    {/snippet}
  </Split>
</PageState>

<style>
  .mono { font: 12px var(--mono); }
  .muted { color: var(--fg-3); font-size: 12.5px; }
  .pad { padding: 12px 4px; }
  .caps { display: flex; gap: 4px; flex-wrap: wrap; align-items: center; }
  .sec { padding: 12px 16px; display: flex; flex-direction: column; gap: 8px; }
  h3 { margin: 0; font: 500 11px var(--mono); letter-spacing: 0.06em; text-transform: uppercase; color: var(--fg-3); }
  .why { margin: 0; padding: 10px 16px; color: var(--bad-ink, var(--bad)); font-size: 13px; }
  .danger { color: var(--bad); }
</style>
