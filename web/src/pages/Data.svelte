<script>
  import PageHeader from '../shell/PageHeader.svelte';
  import { poll, rows } from '../data.svelte.js';
  import Table from '../shell/Table.svelte';
  import { ui } from '../ui.svelte.js';
  import { session } from '../api.js';
  import { live } from '../live.svelte.js';
  import { parseLiveRows } from '../livestatus.js';
  import { go } from '../route.svelte.js';

  // Off mode: the existing collected-reads table, kept unchanged in behaviour.
  const offSt = poll(() => (!ui.features.live ? '/api/sys/reads/status' : ''), 5000);
  // reads status: read, interval s, age s (-1 = never kept), ms, exit code, bytes (- = nothing kept yet)
  const num = (v) => (v === '-' || v === undefined || v === '' ? null : Number(v));
  const reads = $derived(rows(offSt).map((r) => {
    const every = num(r[1]), age = num(r[2]), ms = num(r[3]), rc = num(r[4]), bytes = num(r[5]);
    const state = age === null || age < 0 ? 'never' : age > Math.max(3 * every, 30) ? 'late' : rc ? 'failing' : 'fresh';
    return { read: r[0], every, age: age !== null && age >= 0 ? age : null, ms, rc, bytes, state };
  }));
  const late = $derived(reads.filter((r) => r.state === 'late' || r.state === 'never').length);
  const slow = $derived(reads.filter((r) => r.ms !== null && r.ms >= 5000).length);

  // Live mode: the live-state topics themselves.
  const liveSt = poll(() => (ui.features.live ? '/api/sys/live/status' : ''), 5000, 'live');
  const liveRows = $derived(parseLiveRows(rows(liveSt)));
  const problemRows = $derived(liveRows.filter((r) => r.state === 'stale' || r.state === 'never' || r.state === 'failing'));
  const liveDown = $derived(liveSt.error?.status === 503 && !liveSt.error?.retryAfter);
  const liveRefreshing = $derived(liveSt.error?.status === 503 && liveSt.error?.retryAfter > 0);

  // Mid-session live-to-off switch: a 502 on the live read is the signature of the server
  // having switched back to direct reads. Re-fetch the session once, then let the polls and SSE follow.
  let checkedOff = $state(false);
  $effect(() => { if (ui.features.live) checkedOff = false; });
  $effect(() => {
    const e = liveSt.error;
    if (ui.features.live && e && e.status === 502 && !checkedOff) {
      checkedOff = true;
      session().then((s) => { if (s && !s.features?.live) ui.features = s.features; }).catch(() => {});
    }
  });

  const secs = (s) => (s === null ? '' : s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${Math.round(s / 3600)} h`);
  const took = (ms) => (ms === null ? '' : ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`);
  const kb = (b) => (b === null ? '' : b < 1024 ? `${b} B` : `${(b / 1024).toFixed(1)} KB`);
  const tone = (s) => (s === 'fresh' ? 'var(--st-ok, var(--color-neutral-300))' : s === 'failing' ? 'var(--st-warn)' : 'var(--st-bad)');
  const liveTone = (s) => ({ fresh: 'var(--st-ok)', pending: 'var(--fg-2)', stale: 'var(--st-warn)', never: 'var(--st-bad)', failing: 'var(--st-warn)' }[s] || 'var(--fg-2)');
  const when = (ts) => (ts ? new Date(ts * 1000).toLocaleString() : '');

  const offColumns = [
    { key: 'read', label: 'Read', value: (r) => r.read },
    { key: 'state', label: 'State', value: (r) => r.state },
    { key: 'every', sort: 'num', optional: true, label: 'Every', value: (r) => r.every, align: 'right' },
    { key: 'age', sort: 'num', label: 'Kept', value: (r) => r.age, align: 'right' },
    { key: 'ms', sort: 'num', label: 'Takes', value: (r) => r.ms, align: 'right' },
    { key: 'bytes', sort: 'num', optional: true, label: 'Size', value: (r) => r.bytes, align: 'right' },
  ];

  const liveColumns = [
    { key: 'topic', label: 'Topic', value: (r) => r.topic },
    { key: 'state', label: 'State', value: (r) => r.state },
    { key: 'every', sort: 'num', optional: true, label: 'Every', value: (r) => r.every, align: 'right' },
    { key: 'age', sort: 'num', label: 'Age', value: (r) => r.age, align: 'right' },
    { key: 'gen', sort: 'num', optional: true, label: 'Gen', value: (r) => r.gen, align: 'right' },
    { key: 'rc', sort: 'num', optional: true, label: 'Exit', value: (r) => r.rc, align: 'right' },
    { key: 'err', label: 'Error', value: (r) => r.err },
    { key: 'tsErr', sort: 'num', optional: true, label: 'Error time', value: (r) => r.tsErr, align: 'right' },
  ];
</script>

<div class="page">
  <PageHeader title="Diagnostics" crumb="Monitoring" sub="How fresh the pages are, and what makes them slow." />

  {#if !ui.features.live}
    <div class="note"><i class="ph ph-info"></i>
      <span>A timer reads these every few seconds and keeps the output in the state database, so a page opens without waiting for the scripts.
        {#if reads.length}{late ? `${late} read(s) are late or were never kept: is hs-reads-collect running? ` : 'All of them are on time. '}{slow ? `${slow} take 5 s or more. ` : ''}{/if}
        The refresh button in the top bar runs a page's scripts at once.</span>
    </div>

    <div class="card elev-sm" style="padding:12px 14px">
      <Table id="data-reads" columns={offColumns} rows={reads} key="read" compact loading={!offSt.loaded}
             empty={offSt.error ? 'The list could not be read.' : 'No read is collected (the list scripts/lib/collected-reads.tsv is empty or not there).'}>
        {#snippet cell(r, col)}
          {#if col.key === 'read'}<code>{r.read}</code>
          {:else if col.key === 'state'}<span style="color:{tone(r.state)}">{r.state}{r.state === 'failing' ? ` (exit ${r.rc})` : ''}</span>
          {:else if col.key === 'every'}<span class="c">{secs(r.every)}</span>
          {:else if col.key === 'age'}<span class="c">{secs(r.age)}</span>
          {:else if col.key === 'ms'}<span class="c" style="color:{r.ms >= 5000 ? 'var(--st-warn)' : ''}">{took(r.ms)}</span>
          {:else}<span class="c">{kb(r.bytes)}</span>{/if}
        {/snippet}
      </Table>
    </div>
    <div class="muted">The list of reads is <code>scripts/lib/collected-reads.tsv</code> in the repository (the words of the read, and how often in seconds). <code>hs sys state reads</code> and <code>hs sys reads status</code> show the same on the command line.</div>
  {:else}
    {#if liveDown}
      <div class="note bad"><i class="ph ph-warning-circle"></i>
        <span>The live state service is down. The table shows the last data; polling every 5 s until it comes back. Check <code>systemctl status redis-hobnix hs-live</code>.</span>
      </div>
    {:else if liveRefreshing}
      <div class="note"><i class="ph ph-spinner"></i>
        <span>Live state is starting; the first reading should arrive in a few seconds.</span>
      </div>
    {:else if !live.open}
      <div class="note"><i class="ph ph-pause-circle"></i>
        <span>Live updates are paused; polling every 5 s until the stream reconnects.</span>
      </div>
    {/if}

    {#if problemRows.length}
      <div class="note bad"><i class="ph ph-warning-circle"></i>
        <span>{problemRows.length} topic(s) are stale, never read, or failing. See <button class="link-btn" onclick={() => go('/operations/health')}>Health</button> and <code>hs-live</code> for details.</span>
      </div>
    {:else if liveRows.length}
      <div class="note"><i class="ph ph-check-circle"></i><span>All live topics are fresh.</span></div>
    {/if}

    <div class="card elev-sm" style="padding:12px 14px">
      <Table id="data-live" columns={liveColumns} rows={liveRows} key="topic" compact loading={!liveSt.loaded}
             empty={liveSt.error ? 'The live topics could not be read.' : 'No live topics are configured.'}>
        {#snippet cell(r, col)}
          {#if col.key === 'topic'}<code>{r.topic}</code>
          {:else if col.key === 'state'}<span style="color:{liveTone(r.state)}">{r.state}</span>
          {:else if col.key === 'every'}<span class="c">{secs(r.every)}</span>
          {:else if col.key === 'age'}<span class="c">{secs(r.age)}</span>
          {:else if col.key === 'gen'}<span class="c">{r.gen}</span>
          {:else if col.key === 'rc'}<span class="c">{r.rc === null ? '-' : r.rc}</span>
          {:else if col.key === 'err'}<span class="c" style="color:{r.err ? 'var(--st-bad)' : ''}">{r.err ?? '-'}</span>
          {:else}<span class="c">{when(r.tsErr)}</span>{/if}
        {/snippet}
      </Table>
    </div>
    <div class="muted">These are the live-state topics in Redis. The <code>live</code> row describes the previous collection by design. <code>hs sys live status</code> shows the same on the command line.</div>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .crumb { font-size: 11px; color: var(--color-neutral-500); }
  .tl { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
  .ttl { font-size: 20px; font-weight: 500; }
  .sub, .muted { font-size: 12px; color: var(--color-neutral-500); }
  .c { padding: 6px 8px; color: var(--color-neutral-300); font-variant-numeric: tabular-nums; }
  .note { display: flex; gap: 10px; align-items: center; padding: 10px 12px; border-radius: var(--r); background: var(--color-neutral-900); box-shadow: inset 0 0 0 1px var(--color-neutral-800); font-size: 12.5px; color: var(--color-neutral-300); }
  .note.bad { background: color-mix(in oklch, var(--st-bad) 12%, var(--color-neutral-900)); color: var(--color-neutral-200); }
</style>
