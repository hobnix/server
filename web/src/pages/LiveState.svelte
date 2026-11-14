<script>
  // Monitoring > Live state: every live-state topic with its static facts and its stored state, one read (`hs sys live inspect`).
  // Updates come from /api/events (topic live); 5 s polling only while the stream is down. Refresh asks the collector to read a topic now.
  import PageHeader from '../shell/PageHeader.svelte';
  import Table from '../shell/Table.svelte';
  import Button from '../ui/Button.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import Banner from '../ui/Banner.svelte';
  import Split from '../ui/Split.svelte';
  import Kv from '../ui/Kv.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import { poll } from '../data.svelte.js';
  import { ui } from '../ui.svelte.js';
  import { live } from '../live.svelte.js';
  import { tr } from '../i18n.js';
  import { get, liveRefresh } from '../api.js';
  import { parseInspect } from '../livestatus.js';

  const on = $derived(ui.features.live && (!Array.isArray(ui.features.capabilities) || ui.features.capabilities.includes('live-state')));
  const st = poll(() => (on ? '/api/sys/live/inspect' : ''), 5000, 'live');
  const parsed = $derived(parseInspect(st.data));
  const down = $derived(st.error?.status === 503 && !st.error?.retryAfter);
  const starting = $derived(st.error?.status === 503 && st.error?.retryAfter > 0);

  const secs = (s) => (s === null || s === undefined ? '' : s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${Math.round(s / 3600)} h`);
  const when = (ts) => (ts ? new Date(ts * 1000).toLocaleString() : '');
  const dot = (s) => ({ fresh: 'ok', ok: 'ok', pending: 'info', stale: 'warn', failing: 'warn', never: 'bad', off: 'off' }[s] || 'off');

  const columns = $derived([
    { key: 'topic', label: 'Topic', value: (r) => r.topic },
    { key: 'source', label: 'Source', optional: true, value: (r) => r.words.join(' ') },
    { key: 'every', sort: 'num', optional: true, label: 'Every', value: (r) => r.every, align: 'right' },
    ...(parsed.has.ttl ? [{ key: 'ttl', sort: 'num', optional: true, label: 'TTL', value: (r) => r.ttl, align: 'right' }] : []),
    { key: 'state', label: 'State', value: (r) => r.state },
    { key: 'age', sort: 'num', label: 'Age', value: (r) => r.age, align: 'right' },
    { key: 'gen', sort: 'num', optional: true, label: 'Gen', value: (r) => r.gen, align: 'right' },
    { key: 'rc', sort: 'num', optional: true, label: 'Exit', value: (r) => r.rc, align: 'right' },
    { key: 'err', label: 'Error', value: (r) => r.err },
    { key: 'cap', optional: true, label: 'Capability', value: (r) => r.cap ?? '' },
    { key: 'groups', optional: true, label: 'Groups', value: (r) => r.groups.join(', ') },
    ...(parsed.has.needs ? [{ key: 'needs', optional: true, label: 'Needs', value: (r) => (r.needs || []).join(', ') }] : []),
    { key: 'actions', label: '', sort: false },
  ]);

  // the Raw drawer
  let rawTopic = $state('');
  let raw = $state(null);
  let rawErr = $state(false);
  async function openRaw(topic) {
    rawTopic = topic; raw = null; rawErr = false;
    try {
      const d = await get('/api/sys/live/raw/' + encodeURIComponent(topic), true);
      if (rawTopic === topic) raw = d;
    } catch { if (rawTopic === topic) rawErr = true; }
  }
  // Refresh: a refused request (409 capability off, 400, 401) is shown above the table, not dropped
  let refreshErr = $state('');
  async function refresh(topic) {
    refreshErr = '';
    try { await liveRefresh(topic); } catch (e) { refreshErr = e?.message || String(e); }
  }
  const kb = (b) => (b < 1024 ? `${b} B` : `${(b / 1024).toFixed(1)} KB`);
</script>

<div class="page">
  <PageHeader title="Live state" crumb="Monitoring" sub={tr('Every live-state topic, what is stored for it, and its last error.')} />

  {#if !on}
    <Banner tone="info">{tr('Live state is off. Turn on the capability live-state under Settings > Capabilities to see its topics here.')}</Banner>
  {:else}
    {#if down}
      <div class="note bad"><i class="ph ph-warning-circle"></i>
        <span>{tr('The live state service is down. The table shows the last data; polling every 5 s until it comes back. Check')} <code>systemctl status redis-hobnix hs-live</code>.</span>
      </div>
    {:else if starting}
      <div class="note"><i class="ph ph-circle-notch spin"></i>
        <span>{tr('Live state is starting; the first reading should arrive in a few seconds.')}</span>
      </div>
    {:else if !live.open}
      <div class="note"><i class="ph ph-pause-circle"></i>
        <span>{tr('Live updates are paused; polling every 5 s until the stream reconnects.')}</span>
      </div>
    {/if}

    {#if refreshErr}
      <div class="note bad"><i class="ph ph-warning-circle"></i><span>{tr('The refresh was refused:')} {refreshErr}</span></div>
    {/if}

    <Split open={!!rawTopic}>
      {#snippet list()}
    <div class="card elev-sm" style="padding:12px 14px">
      <Table id="live-inspect" {columns} rows={parsed.rows} key="topic" compact loading={!st.loaded}
             empty={tr(st.error ? 'The live topics could not be read.' : 'No live topics are configured.')}>
        {#snippet cell(r, col)}
          {#if col.key === 'topic'}<code>{r.topic}</code>{#if r.origin === 'extension'} <span class="chip">{tr('extension')}</span>{/if}
          {:else if col.key === 'source'}<code>{r.words.join(' ')}</code>
          {:else if col.key === 'every'}<span class="c">{secs(r.every)}</span>
          {:else if col.key === 'ttl'}<span class="c">{r.ttl ?? ''}</span>
          {:else if col.key === 'state'}<StatusDot state={dot(r.state)} label={tr(r.state)} />
          {:else if col.key === 'age'}<span class="c">{secs(r.age)}</span>
          {:else if col.key === 'gen'}<span class="c">{r.gen}</span>
          {:else if col.key === 'rc'}<span class="c">{r.rc === null ? '-' : r.rc}</span>
          {:else if col.key === 'err'}<span class="c" style="color:{r.err ? 'var(--bad)' : ''}">{r.err ?? '-'}</span>{#if r.tsErr}<div class="c muted">{when(r.tsErr)}</div>{/if}
          {:else if col.key === 'cap'}<span class="c">{r.cap ?? '-'}{r.cap_on === false ? ' (off)' : ''}</span>
          {:else if col.key === 'groups'}<span class="c">{r.groups.join(', ') || '-'}</span>
          {:else if col.key === 'needs'}<span class="c">{(r.needs || []).join(', ') || '-'}</span>
          {:else if col.key === 'actions'}
            <span class="acts">
              <Button size="sm" icon="arrow-clockwise" disabled={r.cap_on === false} onclick={() => refresh(r.topic)}>{tr('Refresh')}</Button>
              <Button size="sm" onclick={() => openRaw(r.topic)}>{tr('Raw')}</Button>
            </span>
          {/if}
        {/snippet}
      </Table>
    </div>
      {/snippet}
      {#snippet side()}
      <Drawer title={rawTopic} onclose={() => { rawTopic = ''; raw = null; }}>
        {#if rawErr}
          <div class="note bad"><i class="ph ph-warning-circle"></i><span>{tr('The stored output could not be read.')}</span></div>
        {:else if !raw}
          <div class="muted">{tr('Loading…')}</div>
        {:else if raw.stored === false}
          <EmptyState icon="tray" title={tr('Nothing is stored for this topic yet.')} />
        {:else}
          <Kv items={[{ k: tr('Gen'), v: String(raw.gen ?? '-') }, { k: tr('Exit'), v: String(raw.rc ?? '-') }, { k: tr('Stored'), v: when(raw.ts) || '-' }, { k: tr('Size'), v: kb(raw.bytes || 0) }]} />
          {#if raw.truncated}<div class="muted">{tr('Shows the first 64 KiB of {n} bytes.').replace('{n}', String(raw.bytes))}</div>{/if}
          <pre class="raw">{raw.out}</pre>
        {/if}
      </Drawer>
      {/snippet}
    </Split>

    <div class="muted"><code>hs sys live inspect</code> {tr('shows the same on the command line.')}</div>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .muted { font-size: 12px; color: var(--fg-2); }
  .c { padding: 6px 8px; color: var(--fg-1, var(--fg-2)); font-variant-numeric: tabular-nums; }
  .acts { display: flex; gap: 6px; }
  .chip { font-size: 11px; padding: 0 6px; box-shadow: inset 0 0 0 1px var(--line); color: var(--fg-2); }
  .note { display: flex; gap: 10px; align-items: center; padding: 10px 12px; border-radius: var(--r); background: var(--panel); box-shadow: inset 0 0 0 1px var(--line); font-size: 12.5px; }
  .note.bad { color: var(--bad); }
  .raw { margin: 8px 0 0; max-height: 60vh; overflow: auto; white-space: pre; font-family: 'Geist Mono', monospace; font-size: 12px; }
</style>
