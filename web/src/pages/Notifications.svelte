<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // Notifications: the channels (where a message can go) against the message classes they carry. hs sys notify channels / providers read,
  // hs sys notify plan|start add|set|remove|test change. A tick saves at once.
  import { poll, rows, refresh } from '../data.svelte.js';
  import { start } from '../api.js';
  import { openCreate, openPlan, ui } from '../ui.svelte.js';
  import ChannelForm from '../forms/ops/ChannelForm.svelte';
  import { agoShort } from '../format.js';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Banner from '../ui/Banner.svelte';
  import Switch from '../ui/Switch.svelte';
  import Chip from '../ui/Chip.svelte';
  import StatusDot from '../ui/StatusDot.svelte';

  const CH = '/api/sys/notify/channels';
  const CLASSES = [['alarm', 'Alarms'], ['status', 'Status'], ['heartbeat', 'Heartbeat'], ['digest', 'Digest']];
  const columns = [
    { key: 'name', label: 'Channel' },
    { key: 'provider', label: 'Provider' },
    { key: 'on', label: 'On', sort: false, width: '48px' },
    ...CLASSES.map(([k, l]) => ({ key: k, label: l, sort: false, width: '78px' })),
    { key: 'minprio', label: 'Lowest priority' },
    { key: 'quiet', label: 'Quiet hours' },
    { key: 'outside', label: 'Outside' },
    { key: 'last', label: 'Last send', sort: false },
    { key: 'act', label: '', sort: false },
  ];

  // Why a cell is disabled, by provider and class: shown as the tooltip and as small text, so "why can't I?" needs no click. The provider's own `caps`
  // (hs sys notify channels, column 10) decide WHICH cells are disabled; this table only says why. A provider that is not listed gets the plain sentence.
  const WHY = {
    email: { heartbeat: 'Email: a message every 15 minutes is sent as the heartbeat; that is not suited to email.' },
    matrix: { heartbeat: 'Matrix: the outside watcher can only read an ntfy topic today, so it cannot see a Matrix heartbeat.' },
    homeassistant: { heartbeat: 'Home Assistant lamp: a lamp cannot show a heartbeat.', digest: 'Home Assistant lamp: a lamp cannot show a digest.' },
  };
  const why = (i, k) => WHY[i.provider]?.[k] ?? `${i.provider} cannot carry this.`;

  const list = poll(CH, 8000);
  const prov = poll('/api/sys/notify/providers', 60000);

  // name, provider, enabled, minprio, quiet, outside, source, ready, categories, caps, last time (epoch seconds or -), ok|failed|-, reason|-
  const items = $derived(rows(list).map((r) => ({
    raw: r, name: r[0], provider: r[1], on: r[2] === 'yes', minprio: r[3], quiet: r[4], outside: r[5], source: r[6], ready: r[7],
    cats: new Set((r[8] ?? '').split(',')), caps: new Set((r[9] ?? '').split(',')),
    last: { when: agoShort(r[10]), result: r[11] === 'ok' || r[11] === 'failed' ? r[11] : '', reason: r[12] && r[12] !== '-' ? r[12] : '' },
  })));
  // while the storage is locked this server is down: one enabled channel outside it must carry the alarms
  const noOutside = $derived(list.loaded && !list.error && !items.some((i) => i.on && i.outside === 'outside' && i.cats.has('alarm')));

  let msg = $state('');
  let msgBad = $state(false);
  let busy = $state('');

  async function change(args, label) {
    busy = label;
    msg = '';
    try {
      const r = await start('notify', args);
      msgBad = r.status !== 'done';
      msg = msgBad ? (r.reason || 'The server refused this.') : '';
    } catch (e) {
      msgBad = true;
      msg = e.message;
    } finally {
      busy = '';
      await refresh([CH]);
    }
  }

  function toggleClass(i, c) {
    const s = new Set(i.cats);
    s.has(c) ? s.delete(c) : s.add(c);
    const out = CLASSES.map((x) => x[0]).filter((x) => s.has(x)).join(',');
    if (!out) { msgBad = true; msg = `${i.name} must carry something: switch the channel off instead.`; return; }
    change(['set', i.name, '--categories', out], i.name + c);
  }
  const toggleOn = (i) => change(['set', i.name, '--enabled', i.on ? 'no' : 'yes'], i.name + 'on');

  async function test(i) {
    busy = i.name + 'test';
    msg = '';
    try {
      const r = await start('notify', ['test', i.name]);
      msgBad = r.status !== 'done';
      msg = msgBad ? `The test message did not arrive: ${r.reason || 'no answer'}` : `The test message was handed to ${i.name}.`;
    } catch (e) {
      msgBad = true;
      msg = e.message;
    } finally {
      busy = '';
    }
  }
  const add = () => openCreate(ChannelForm, { providers: rows(prov), ondone: () => refresh([CH]) });
  const edit = (i) => openCreate(ChannelForm, { providers: rows(prov), channel: i.raw, ondone: () => refresh([CH]) });
</script>

<div class="page">
  <PageHeader title="Notifications" crumb="{ui.host} / Monitoring" sub="Where messages go, and which kinds each place gets.">
    {#snippet actions()}<button use:tip={!prov.loaded ? 'Loading the providers' : 'Add a push channel'} class="btn btn-primary" disabled={!prov.loaded} onclick={add}><i class="ph ph-plus"></i>Add channel</button>{/snippet}
  </PageHeader>

  {#if noOutside}
    <Banner tone="warn">No enabled channel outside this server carries alarms. While the storage is locked this server is down, and you will not hear about it. Add a channel on a service that is not on this server (the public ntfy.sh, or email).
      {#snippet action()}<button use:tip={!prov.loaded ? 'Loading the providers' : 'Add a push channel'} class="btn sm" disabled={!prov.loaded} onclick={add}>Add channel</button>{/snippet}
    </Banner>
  {/if}
  {#if msg}<Banner tone={msgBad ? 'bad' : 'ok'}>{msg}</Banner>{/if}

  <PageState loading={!list.loaded} error={list.error?.message ?? ''} hasData={list.data != null} empty={list.loaded && !items.length}
             emptyIcon="bell" emptyTitle="No channel yet" emptyText="Add a channel to hear about problems. ntfy needs only a long random topic address (a secret you type once; it is never shown again).">
    {#snippet emptyAction()}<button use:tip={!prov.loaded ? 'Loading the providers' : 'Add a push channel'} class="btn btn-primary" disabled={!prov.loaded} onclick={add}><i class="ph ph-plus"></i>Add channel</button>{/snippet}

    <div class="card mat">
      <Table id="notify" {columns} rows={items} key="name">
        {#snippet cell(i, col)}
          {#if col.key === 'name'}<b>{i.name}</b>{#if i.ready !== 'ok'} <Chip>incomplete</Chip>{/if}{#if i.source === 'derived'} <Chip>old setting</Chip>{/if}
          {:else if col.key === 'provider'}<Chip>{i.provider}</Chip>
          {:else if col.key === 'on'}<Switch checked={i.on} disabled={!!busy} label="{i.name} on" onchange={() => toggleOn(i)} />
          {:else if col.key === 'minprio'}{i.minprio}
          {:else if col.key === 'quiet'}{i.quiet === 'ignore' ? 'ignored' : 'respected'}
          {:else if col.key === 'outside'}<StatusDot state={i.outside === 'outside' ? 'ok' : 'off'} label={i.outside === 'outside' ? 'outside' : 'on this server'} />
          {:else if col.key === 'last'}
            {#if i.last.result}<StatusDot state={i.last.result === 'ok' ? 'ok' : 'bad'} label={i.last.result === 'ok' ? 'sent' : 'failed'} /> <span class="when" use:tip={i.last.reason}>{i.last.when}{i.last.reason ? ` · ${i.last.reason}` : ''}</span>{:else}<span class="when">never</span>{/if}
          {:else if col.key === 'act'}
            <span class="acts">
              <button use:tip={busy ? 'Another test is running' : 'Send one test message to this channel'} class="btn btn-ghost sm" disabled={!!busy} onclick={() => test(i)} use:tip={'Send one test message to this channel'}>{busy === i.name + 'test' ? 'Sending…' : 'Send test'}</button>
              <button class="btn btn-ghost btn-icon" aria-label="Edit {i.name}" use:tip={'Edit'} onclick={() => edit(i)}><i class="ph ph-pencil-simple"></i></button>
              <button class="btn btn-ghost btn-icon" aria-label="Remove {i.name}" use:tip={'Remove'} onclick={() => openPlan('notify', ['remove', i.name], 'Remove ' + i.name)}><i class="ph ph-trash"></i></button>
            </span>
          {:else}
            <Switch box checked={i.cats.has(col.key) && i.caps.has(col.key)} disabled={!!busy || !i.caps.has(col.key)} reason={why(i, col.key)} label="{i.name} carries {col.label}" onchange={() => toggleClass(i, col.key)} />
          {/if}
        {/snippet}
      </Table>
    </div>

    <div class="cards">
      {#each items as i (i.name)}
        <div class="card ch">
          <div class="ct"><b>{i.name}</b><Chip>{i.provider}</Chip><span class="grow"></span><Switch checked={i.on} disabled={!!busy} label="{i.name} on" onchange={() => toggleOn(i)} /></div>
          {#each CLASSES as [k, l]}
            <div class="cl"><Switch box checked={i.cats.has(k) && i.caps.has(k)} disabled={!!busy || !i.caps.has(k)} reason={why(i, k)} showReason label="{i.name} carries {l}" onchange={() => toggleClass(i, k)} /><span>{l}</span></div>
          {/each}
          <div class="meta">Last send: {i.last.result ? `${i.last.result === 'ok' ? 'sent' : 'failed'} ${i.last.when}${i.last.reason ? ` (${i.last.reason})` : ''}` : 'never'}</div>
          <div class="meta">Lowest priority {i.minprio} · quiet hours {i.quiet === 'ignore' ? 'ignored' : 'respected'} · {i.outside === 'outside' ? 'outside this server' : 'on this server'}</div>
          <div class="acts"><button use:tip={busy ? 'Another test is running' : 'Send one test message to this channel'} class="btn btn-secondary sm" disabled={!!busy} onclick={() => test(i)}>Send test</button><button use:tip={'Change this channel'} class="btn btn-ghost sm" onclick={() => edit(i)}>Edit</button><button use:tip={'Remove this channel: no messages go there any more'} class="btn btn-ghost sm" onclick={() => openPlan('notify', ['remove', i.name], 'Remove ' + i.name)}>Remove</button></div>
        </div>
      {/each}
    </div>

    <p class="note">
      Alarms: problems and the lock alarm. Status: started, finished, ok. Heartbeat: the “still alive” message every 15 minutes for a watcher outside; it ignores quiet hours and the lowest priority.
      Digest: the one message that lists what the quiet hours held back. “Urgent” always gets through to an enabled channel; a channel that is off stays silent. Secrets (a topic address, a token) are typed once and never shown again.
    </p>
  </PageState>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .mat { padding: 8px 12px; overflow-x: auto; }
  .cards { display: none; flex-direction: column; gap: 12px; }
  .ch { gap: 10px; }
  .ct { display: flex; align-items: center; gap: 10px; }
  .grow { flex: 1; }
  .cl { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .when { font-size: 12px; color: var(--fg-3); }
  .meta, .note { font-size: 12px; color: var(--fg-3); margin: 0; }
  .acts { display: inline-flex; gap: 4px; justify-content: flex-end; flex-wrap: wrap; }
  @media (max-width: 860px) { .mat { display: none; } .cards { display: flex; } }
</style>
