<script>
  // Events: the event log (hs sys event list, ADR 0005), newest first. Filters: source (asked of the server), level, kind and time (in the browser).
  // New rows arrive through the live stream (`domain` items of /api/events, no polling while it is open); a resync, or a closed stream, reads again.
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { live } from '../live.svelte.js';
  import { lang } from '../lang.svelte.js';
  import { ui } from '../ui.svelte.js';
  import { agoShort } from '../format.js';
  import { tr } from '../i18n.js';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Combobox from '../ui/Combobox.svelte';
  import Button from '../ui/Button.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import { parseRow, eventText, merge, filterRows, SINCE, sinceFrom } from './events.js';

  const STEP = 100;
  let limit = $state(STEP);
  let source = $state('');
  let level = $state('');
  let kind = $state('');
  let since = $state('');

  const path = $derived(`/api/sys/event/list?n=${limit}${source ? `&source=${encodeURIComponent(source)}` : ''}`);
  // an open stream carries the news: the timer is long then
  const list = poll(() => path, 30000, undefined);   // the stream brings new rows at once; this slow read is the safety net while it is closed
  // a resync says rows may be lost: read again (the poll follows live.resyncs only with a topic, so ask for it here)
  let seenResync = live.resyncs;
  $effect(() => { if (live.resyncs !== seenResync) { seenResync = live.resyncs; refresh([path]); } });

  const read = $derived(rows(list).map(parseRow));
  // rows from the stream that the read does not hold yet (only those that match the source filter)
  const news = $derived(live.events.map(parseRow).filter((e) => !source || e.source === source));
  const all = $derived(merge(read, news, 1000));
  const shown = $derived(filterRows(all, { level, kind, since: sinceFrom(since) }));
  const sources = $derived([...new Set(all.map((e) => e.source))].sort());
  const sourceOptions = $derived([{ value: '', label: tr('All sources') }, ...(source && !sources.includes(source) ? [source] : []), ...sources]);
  const levelOptions = [{ value: '', label: 'All levels' }, 'info', 'warn', 'error'];
  const sinceOptions = SINCE.map(([v, l]) => ({ value: v, label: l }));
  const tone = { info: 'ok', warn: 'warn', error: 'bad' };
  const rowsItems = $derived(shown.map((e) => ({ ...e, key: String(e.id), name: `${e.source}.${e.kind}`, say: eventText(e, lang.code) })));
  const more = $derived(read.length >= limit && limit < 1000);

  const columns = [
    { key: 'time', label: 'Time', sort: 'num', width: '120px' },
    { key: 'level', label: 'Level', width: '90px' },
    { key: 'name', label: 'Kind', width: '190px', optional: true },
    { key: 'subject', label: 'Subject', optional: true },
    { key: 'say', label: 'What happened' },
  ];
</script>

<div class="page">
  <PageHeader title="Events" crumb="{ui.host} / Operations" sub="What happened on this server, newest first." />

  <div class="bar">
    <Combobox options={sourceOptions} bind:value={source} label="Source" onchange={() => { limit = STEP; }} />
    <Combobox options={levelOptions} bind:value={level} label="Level" />
    <Combobox options={sinceOptions} bind:value={since} label="Time" />
    <input class="input" bind:value={kind} placeholder="Kind, e.g. job.failed" aria-label="Kind" maxlength="60" autocomplete="off" spellcheck="false" />
  </div>

  <PageState loading={!list.loaded} error={list.error?.message ?? ''} hasData={list.data != null} empty={list.loaded && !rowsItems.length}
             emptyIcon="list-bullets" emptyTitle="No events" emptyText="Nothing matches. Events are written as things happen on the server.">
    <div class="card mat">
      <Table id="events" {columns} rows={rowsItems} key="key" sort={{ key: 'time', dir: 'desc' }}>
        {#snippet cell(e, col)}
          {#if col.key === 'time'}<span use:tip={new Date(e.time * 1000).toLocaleString()}>{agoShort(e.time) || '-'}</span>
          {:else if col.key === 'level'}<StatusDot state={tone[e.level]} label={e.level} />
          {:else if col.key === 'name'}<code>{e.name}</code>
          {:else if col.key === 'subject'}{e.subject}
          {:else}{e.say}{/if}
        {/snippet}
      </Table>
    </div>
    {#if more}<div class="more"><Button onclick={() => { limit += STEP; }}>Show older events</Button></div>{/if}
  </PageState>
</div>

<style>
  .bar { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0; align-items: center; }
  .more { margin-top: 12px; }
</style>
